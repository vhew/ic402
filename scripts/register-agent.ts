#!/usr/bin/env npx tsx
/**
 * register-agent.ts — Deploy IdentityRegistry + register agent on Base Sepolia
 *
 * This script:
 *   1. Connects to the ICP canister and gets its tECDSA public key
 *   2. Derives the canister's Base C-Chain address
 *   3. Deploys the IdentityRegistry contract (or uses an existing one)
 *   4. Registers the agent with the canister's agent card
 *   5. Stores the token ID back in the canister via setAgentRegistration()
 *
 * Usage:
 *   npx tsx scripts/register-agent.ts \
 *     --private-key <hex>                     # ETH wallet for gas
 *     [--canister-id <principal>]             # defaults to local example canister
 *     [--host http://localhost:4944]          # ICP replica
 *     [--rpc https://sepolia.base.org]
 *     [--contract <address>]                  # skip deploy, use existing
 *     [--ecdsa-key dfx_test_key]             # tECDSA key name
 *
 * Prerequisites:
 *   - Local ICP replica running with the example canister deployed
 *   - An Base Sepolia wallet with testnet ETH (get from https://faucet for Base Sepolia ETH)
 *   - forge installed (curl -L https://foundry.paradigm.xyz | bash && foundryup)
 */

import { execSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  type Hex,
  type Address,
} from 'viem';
import { publicKeyToAddress } from 'viem/utils';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia } from 'viem/chains';
import { Actor, HttpAgent } from '@icp-sdk/core/agent';

// ---------------------------------------------------------------------------
// Parse arguments
// ---------------------------------------------------------------------------

const { values: args } = parseArgs({
  options: {
    'private-key': { type: 'string' },
    'canister-id': { type: 'string' },
    host: { type: 'string', default: 'http://localhost:4944' },
    rpc: { type: 'string', default: 'https://sepolia.base.org' },
    contract: { type: 'string' },
    'ecdsa-key': { type: 'string', default: 'dfx_test_key' },
    help: { type: 'boolean', default: false },
  },
});

if (args.help || !args['private-key']) {
  console.log(`
Usage: npx tsx scripts/register-agent.ts --private-key <hex> [options]

Required:
  --private-key <hex>     Base wallet private key (for gas fees)
                          Get testnet ETH from https://faucet for Base Sepolia ETH

Options:
  --canister-id <id>      ICP canister principal (auto-detected from local replica)
  --host <url>            ICP replica URL (default: http://localhost:4944)
  --rpc <url>             Base Sepolia RPC (default: https://sepolia.base.org)
  --contract <address>    Use existing IdentityRegistry contract (skip deploy)
  --ecdsa-key <name>      tECDSA key name (default: dfx_test_key)
`);
  process.exit(args.help ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, '..');
const CONTRACTS_DIR = resolve(PROJECT_ROOT, 'contracts');

// IdentityRegistry ABI (matches contracts/IdentityRegistry.sol)
const REGISTRY_ABI = [
  {
    name: 'register',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'name', type: 'string' },
      { name: 'description', type: 'string' },
      { name: 'endpoint', type: 'string' },
      { name: 'skills', type: 'string[]' },
      { name: 'domains', type: 'string[]' },
      { name: 'x402Support', type: 'bool' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getAgent',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [
      {
        name: '',
        type: 'tuple',
        components: [
          { name: 'name', type: 'string' },
          { name: 'description', type: 'string' },
          { name: 'endpoint', type: 'string' },
          { name: 'skills', type: 'string[]' },
          { name: 'domains', type: 'string[]' },
          { name: 'x402Support', type: 'bool' },
        ],
      },
    ],
  },
  {
    name: 'ownerOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    name: 'totalAgents',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'nextTokenId',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function log(msg: string) {
  console.log(`  ${msg}`);
}
function ok(msg: string) {
  console.log(`  \x1b[32m✓ ${msg}\x1b[0m`);
}
function st(key: string, val: string) {
  console.log(`  \x1b[36m${key}:\x1b[0m ${val}`);
}
function hr() {
  console.log(`  ${'─'.repeat(56)}`);
}

/**
 * Derive Ethereum/Base address from a SEC1 compressed secp256k1 public key.
 * Uses viem's built-in publicKeyToAddress which handles decompression + keccak.
 */
function pubkeyToAddress(compressedPubkey: Uint8Array): Address {
  const hex = `0x${Buffer.from(compressedPubkey).toString('hex')}` as Hex;
  return publicKeyToAddress(hex);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  // Dynamic import to avoid top-level await
  const { IDL } = await import('@icp-sdk/core/candid');

  const AgentCardIDL = IDL.Record({
    name: IDL.Text,
    description: IDL.Text,
    services: IDL.Vec(
      IDL.Record({
        name: IDL.Text,
        endpoint: IDL.Text,
        version: IDL.Text,
        skills: IDL.Vec(IDL.Text),
        domains: IDL.Vec(IDL.Text),
      }),
    ),
    x402Support: IDL.Bool,
  });

  const idlFactory = () =>
    IDL.Service({
      getAgentCard: IDL.Func([], [AgentCardIDL], ['query']),
      getAgentId: IDL.Func([], [IDL.Opt(IDL.Nat)], ['query']),
      getEvmPublicKey: IDL.Func([], [IDL.Vec(IDL.Nat8)], []),
      setAgentRegistration: IDL.Func([IDL.Nat], [], []),
    });

  console.log('\n\x1b[1m\x1b[36m  ic402 Agent Registration (Base Sepolia)\x1b[0m\n');

  // ── 1. Resolve canister ID ──

  let canisterId = args['canister-id'];
  if (!canisterId) {
    try {
      canisterId = execSync('icp canister status example -e local --id-only', {
        encoding: 'utf-8',
      }).trim();
    } catch {
      console.error('ERROR: Could not detect canister ID. Pass --canister-id or deploy first.');
      process.exit(1);
    }
  }

  const host = args.host!;
  const rpc = args.rpc!;
  const ecdsaKey = args['ecdsa-key']!;

  hr();
  st('Canister', canisterId);
  st('ICP host', host);
  st('Base RPC', rpc);
  st('tECDSA key', ecdsaKey);
  hr();

  // ── 2. Connect to ICP canister ──

  log('');
  log('Connecting to ICP canister...');
  const agent = await HttpAgent.create({ host, shouldFetchRootKey: host.includes('localhost') });
  const actor = Actor.createActor(idlFactory, { agent, canisterId }) as any;

  // Get agent card
  const card = await actor.getAgentCard();
  ok('Agent card retrieved');
  st('Name', card.name);
  st('x402', String(card.x402Support));
  if (card.services?.[0]) {
    st('Endpoint', card.services[0].endpoint);
    st('Skills', card.services[0].skills.join(', '));
  }

  // ── Check if already registered ──

  const existingId = await actor.getAgentId();
  const alreadyRegistered = Array.isArray(existingId) && existingId.length > 0;
  if (alreadyRegistered) {
    ok(`Agent already registered — token #${existingId[0]}`);
    st('Agent ID', String(existingId[0]));
    log('');
    log('To re-register, call setAgentRegistration(0) to reset, then run again.');
    log('Skipping registration.');

    // Still show the key info
    log('');
    log('Requesting tECDSA public key from canister...');
    const pubkeyRaw: number[] = await actor.getEvmPublicKey();
    const pubkey = new Uint8Array(pubkeyRaw);
    const canisterAvaxAddress = pubkeyToAddress(pubkey);
    ok(`Canister's Base address: ${canisterAvaxAddress}`);

    console.log('');
    hr();
    console.log('\x1b[1m\x1b[32m  Agent already registered.\x1b[0m');
    hr();
    st('Token ID', String(existingId[0]));
    st('Canister', canisterId);
    st('Canister ETH addr', canisterAvaxAddress);
    st('Chain', 'Base Sepolia (84532)');
    console.log('');
    return;
  }

  // ── 3. Get tECDSA public key ──

  log('');
  log('Requesting tECDSA public key from canister...');
  const pubkeyRaw: number[] = await actor.getEvmPublicKey();
  const pubkey = new Uint8Array(pubkeyRaw);
  ok(`Public key: ${Buffer.from(pubkey).toString('hex').slice(0, 20)}... (${pubkey.length} bytes)`);

  const canisterAvaxAddress = pubkeyToAddress(pubkey);
  ok(`Canister's Base address: ${canisterAvaxAddress}`);
  st('Basescan', `https://sepolia.basescan.org/address/${canisterAvaxAddress}`);

  // ── 4. Set up Base wallet ──

  log('');
  const account = privateKeyToAccount(args['private-key'] as Hex);
  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(rpc),
  });
  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(rpc),
  });

  const balance = await publicClient.getBalance({ address: account.address });
  st('Deployer wallet', account.address);
  st('ETH balance', `${Number(balance) / 1e18} ETH`);

  if (balance === 0n) {
    console.error('\n  ERROR: Deployer wallet has no ETH. Get testnet ETH from:');
    console.error('    https://faucet for Base Sepolia ETH');
    process.exit(1);
  }

  // ── 5. Deploy or connect to IdentityRegistry ──

  let contractAddress: Address;

  if (args.contract) {
    contractAddress = getAddress(args.contract);
    ok(`Using existing contract: ${contractAddress}`);
  } else {
    log('');
    log('Compiling IdentityRegistry contract...');

    // Check forge is available
    try {
      execSync('forge --version', { stdio: 'pipe' });
    } catch {
      console.error('\n  ERROR: Foundry (forge) is not installed.');
      console.error('  Install with: curl -L https://foundry.paradigm.xyz | bash && foundryup');
      process.exit(1);
    }

    // Compile (foundry.toml in CONTRACTS_DIR sets src=src, out=out)
    execSync(`forge build --root "${CONTRACTS_DIR}"`, { stdio: 'pipe' });
    ok('Contract compiled');

    // Read bytecode
    const artifact = JSON.parse(
      readFileSync(
        resolve(CONTRACTS_DIR, 'out/IdentityRegistry.sol/IdentityRegistry.json'),
        'utf-8',
      ),
    );
    const bytecode = artifact.bytecode.object as Hex;

    log('Deploying IdentityRegistry to Base Sepolia...');
    const deployHash = await walletClient.deployContract({
      abi: REGISTRY_ABI,
      bytecode,
    });

    log(`Tx: ${deployHash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: deployHash });
    contractAddress = receipt.contractAddress!;
    ok(`Deployed: ${contractAddress}`);
    st('Basescan', `https://sepolia.basescan.org/address/${contractAddress}`);
  }

  // ── 6. Register agent ──

  log('');
  log('Registering agent on IdentityRegistry...');

  const service = card.services?.[0] ?? { endpoint: '', skills: [], domains: [] };

  const registerHash = await walletClient.writeContract({
    address: contractAddress,
    abi: REGISTRY_ABI,
    functionName: 'register',
    args: [
      card.name,
      card.description,
      service.endpoint,
      service.skills,
      service.domains,
      card.x402Support,
    ],
  });

  log(`Tx: ${registerHash}`);
  const registerReceipt = await publicClient.waitForTransactionReceipt({ hash: registerHash });
  ok(`Registration confirmed (block ${registerReceipt.blockNumber})`);
  st('Tx', `https://sepolia.basescan.org/tx/${registerHash}`);

  // Read the token ID from the contract
  const totalAgents = await publicClient.readContract({
    address: contractAddress,
    abi: REGISTRY_ABI,
    functionName: 'nextTokenId',
  });
  const tokenId = Number(totalAgents) - 1;
  ok(`Agent token ID: ${tokenId}`);

  // Verify the registration
  const registeredAgent = await publicClient.readContract({
    address: contractAddress,
    abi: REGISTRY_ABI,
    functionName: 'getAgent',
    args: [BigInt(tokenId)],
  });
  ok(`Verified on-chain: ${(registeredAgent as any).name}`);

  // ── 7. Store agentId in canister ──
  //
  // Use `icp canister call` instead of the actor because
  // setAgentRegistration is controller-only and the icp CLI
  // uses the local-dev identity (which is the controller).

  log('');
  log('Storing agent token ID in ICP canister...');
  const env = host.includes('localhost') ? 'local' : 'ic';
  execSync(`icp canister call example setAgentRegistration '(${tokenId} : nat)' -e ${env}`, {
    stdio: 'pipe',
  });
  ok('agentId stored in canister');

  // Verify
  const storedId = await actor.getAgentId();
  ok(`Canister reports agentId: ${storedId}`);

  // ── Summary ──

  console.log('');
  hr();
  console.log('\x1b[1m\x1b[32m  Agent registered successfully!\x1b[0m');
  hr();
  st('Token ID', String(tokenId));
  st('Contract', contractAddress);
  st('Canister', canisterId);
  st('Canister ETH addr', canisterAvaxAddress);
  st('Chain', 'Base Sepolia (84532)');
  st('Contract on Basescan', `https://sepolia.basescan.org/address/${contractAddress}`);
  st('Tx on Basescan', `https://sepolia.basescan.org/tx/${registerHash}`);
  console.log('');
}

main().catch((err) => {
  console.error('\nFatal:', err.message ?? err);
  process.exit(1);
});
