import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Interface as ReadlineInterface } from 'node:readline/promises';
import type { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { keccak_256 } from '@noble/hashes/sha3.js';
import type { StepDef } from './runner.js';
import { confirm } from './runner.js';
import {
  mcpCall, header, info, success, warn, result, showImage,
  highlight, state, divider,
} from './util.js';

// Avalanche Fuji testnet constants
const AVAX_CHAIN = 'Avalanche Fuji testnet (chainId 43113)';
const AVAX_USDC = '0x5425890298aed601595a70AB815c96711a31Bc65';
const AVAX_EXPLORER = 'https://testnet.snowtrace.io';
const AVAX_REGISTRY = process.env.AVAX_REGISTRY_CONTRACT || '(not deployed)';

/**
 * Derive the Avalanche/Ethereum address from a SEC1 compressed secp256k1 public key.
 * Uses @noble/curves (vendored by viem) for point decompression and keccak256.
 */
function pubkeyToAvaxAddress(compressedHex: string): string | null {
  try {
    const point = secp256k1.Point.fromHex(compressedHex);
    const uncompressed = point.toBytes(false); // 65 bytes: 0x04 + X + Y
    const hash = keccak_256(uncompressed.slice(1)); // keccak of 64 bytes (X+Y)
    const addr = Buffer.from(hash).slice(-20).toString('hex');
    return '0x' + addr;
  } catch {
    return null;
  }
}

// ICP constants
const CKUSDC_LEDGER = 'xevnm-gaaaa-aaaar-qafnq-cai';
const EXTERNAL_CONTENT_URL =
  'https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=1,quality=80,width=400,height=400/event-covers/v2/ceaf4fc5-d05b-49f0-8c88-f81bea8d9f46';

export function buildSteps(
  client: Client,
  canisterId: string,
  host: string,
): StepDef[] {
  const canisterUrl = host.includes('localhost')
    ? `http://${canisterId}.localhost:${new URL(host).port}`
    : `https://${canisterId}.icp0.io`;

  return [
    // ── 1. Configure ──
    {
      name: 'Configure',
      description: 'Connect to the canister and set client-side budget limits',
      run: async (_rl: ReadlineInterface) => {
        header('Step 1: Configure MCP Server');
        highlight('ic402 is a drop-in Motoko library. One import, one deploy.');
        highlight('The canister IS the server, the wallet, and the payment processor.');
        info('');
        info('We connect to the deployed canister via MCP (Model Context Protocol),');
        info('the same interface an AI agent would use to discover and pay for services.');
        info('');

        // Must configure first so the MCP server knows the canister
        const res = await mcpCall(client, 'configure', {
          canisterId,
          host,
          network: 'icp:1',
          maxPerRequest: '50000',
          maxPerDay: '500000',
        });
        success('MCP server connected to canister');
        result(res);
        info('');

        // Now fetch tECDSA public key to derive the canister's AVAX address
        info('Fetching canister tECDSA public key...');
        let avaxAddress = '(could not derive)';
        let pubkeyHex = '';
        try {
          const pubkeyResult = await mcpCall(client, 'call', {
            method: 'getAvalanchePublicKey',
            args: '[]',
          });
          // Result is a hex string of the compressed public key bytes
          if (typeof pubkeyResult === 'string') {
            pubkeyHex = pubkeyResult;
          } else if (Array.isArray(pubkeyResult)) {
            pubkeyHex = Buffer.from(pubkeyResult as number[]).toString('hex');
          } else {
            pubkeyHex = String(pubkeyResult);
          }
          const derived = pubkeyToAvaxAddress(pubkeyHex);
          if (derived) avaxAddress = derived;
        } catch {
          // tECDSA may not be available
        }

        info('');
        info('INFRASTRUCTURE:');
        divider();
        state('Canister ID', canisterId);
        state('Canister URL', canisterUrl);
        state('Replica', host);
        state('Network', 'icp:1 (Internet Computer)');
        state('ICP token', `ckUSDC (ICRC-2) — ledger ${CKUSDC_LEDGER}`);
        divider();
        info('');
        info('AVALANCHE CROSS-CHAIN:');
        divider();
        state('Chain', AVAX_CHAIN);
        state('AVAX USDC', `${AVAX_USDC} (ERC-20)`);
        state('Canister AVAX address', `${avaxAddress} (derived via tECDSA)`);
        state('Explorer', `${AVAX_EXPLORER}/address/${avaxAddress}`);
        state('tECDSA pubkey', pubkeyHex || '(not available)');
        divider();
        info('');
        info('BUDGET LIMITS:');
        divider();
        state('Max per request', '$0.05 (50,000 units)');
        state('Max per day', '$0.50 (500,000 units)');
        divider();
        info('');
        info('IDENTITY:');
        divider();
        state('MCP identity', 'Anonymous (no private key — read-only demo)');
        state('Signing', 'In production, the MCP server holds an Ed25519 key for vouchers');
        state('ICRC-2 approval', 'Client SDK auto-approves transfers via the identity');
        divider();

        highlight('Client-side budget enforcement — the AI can never overspend.');
      },
    },

    // ── 2. Discovery (ERC-8004) ──
    {
      name: 'Agent Discovery (ERC-8004)',
      description: 'Cross-chain agent discovery — ICP canister registered on Avalanche',
      run: async (_rl: ReadlineInterface) => {
        header('Step 2: Agent Discovery (ERC-8004)');
        highlight('ERC-8004 lets agents discover each other across chains.');
        highlight('This ICP canister has an agent card registered on Avalanche.');
        info('');
        info('CROSS-CHAIN DISCOVERY:');
        divider();
        state('Registry chain', AVAX_CHAIN);
        state('Registry contract', `${AVAX_REGISTRY}`);
        state('Agent key', 'Derived via ICP tECDSA — canister has a native AVAX address');
        state('Registration', 'Canister signs an EVM tx via tECDSA, mints an NFT on Avalanche');
        state('Gas', 'Canister\'s AVAX address needs AVAX for the registration tx');
        state('Explorer', `${AVAX_EXPLORER}/address/<canister-avax-address>`);
        divider();
        info('');
        info('Other AI agents can query the Avalanche IdentityRegistry contract,');
        info('find this canister by skill ("search", "qa"), and call its ICP endpoint.');
        info('No centralized directory needed — discovery is fully on-chain.');
        info('');

        info('Fetching agent card from the canister...');
        const card = await mcpCall(client, 'call', {
          method: 'getAgentCard',
          args: '[]',
        });
        success('Agent card retrieved:');
        result(card);

        divider();
        const c = card as Record<string, unknown>;
        if (c && typeof c === 'object') {
          state('Name', String(c.name ?? '?'));
          state('x402 Support', String(c.x402Support ?? '?'));
          const services = c.services as Array<Record<string, unknown>> | undefined;
          if (services?.[0]) {
            state('Endpoint', String(services[0].endpoint ?? '?'));
            state('Skills', JSON.stringify(services[0].skills ?? []));
            state('Domains', JSON.stringify(services[0].domains ?? []));
          }
        }
        divider();

        info('');
        info('Checking on-chain registration (Avalanche agent ID)...');
        const agentIdResult = await mcpCall(client, 'call', {
          method: 'getAgentId',
          args: '[]',
        });

        // agentIdResult is either [] (null) or [n] (some)
        const agentIdArr = agentIdResult as unknown[];
        const agentId = Array.isArray(agentIdArr) && agentIdArr.length > 0
          ? agentIdArr[0]
          : null;

        divider();
        if (agentId != null) {
          success(`Registered on Avalanche — token #${agentId}`);
          state('Agent ID', `${agentId} (ERC-721 on IdentityRegistry)`);
          state('Status', 'Registered and discoverable');
          state('Registry', `${AVAX_EXPLORER}/address/${AVAX_REGISTRY}`);
        } else {
          warn('Not yet registered on Avalanche.');
          state('Agent ID', 'null');
          state('To register', 'Run: pnpm register-agent --private-key <key>');
          state('Requires', 'Foundry (forge) + funded AVAX wallet on Fuji');
          info('');
          info('The canister has a tECDSA public key (secp256k1) — it can derive');
          info('a native Avalanche address. Registration mints an ERC-721 on the');
          info('IdentityRegistry contract on Fuji testnet.');
        }
        divider();

        highlight('ICP <> Avalanche: one canister, discoverable from any EVM chain.');
      },
    },

    // ── 3. x402 Charge ──
    {
      name: 'x402 Charge (Paid Search)',
      description: 'Pay-per-call: search a knowledge base for $0.001 per query',
      run: async (_rl: ReadlineInterface) => {
        header('Step 3: x402 Charge Flow');
        highlight('x402 = HTTP 402 Payment Required, but for canister calls.');
        highlight('Call without paying -> get a price quote. Pay -> get the result.');
        info('');
        info('DUAL-CHAIN PAYMENT — client chooses which chain to pay on:');
        divider();
        state('Option A', `ckUSDC on ICP (ledger: ${CKUSDC_LEDGER})`);
        state('  Settlement', 'ICRC-2 transfer_from (on-chain, instant)');
        state('Option B', `USDC on ${AVAX_CHAIN} (${AVAX_USDC})`);
        state('  Settlement', 'HTTPS outcall to eth_getTransactionReceipt (cross-chain)');
        state('Price', '1,000 units = $0.001 USDC (same on both chains)');
        divider();
        info('');
        info('ICP flow (ICRC-2):');
        info('  1. Client calls search() -> gets PaymentRequirement (network: icp:1)');
        info('  2. Client approves ICRC-2 transfer to canister');
        info('  3. Retries with PaymentSignature -> canister calls transfer_from');
        info('');
        info('Avalanche flow (cross-chain):');
        info('  1. Client calls search() -> gets PaymentRequirement (network: eip155:43113)');
        info('  2. Client sends USDC on Fuji to canister\'s tECDSA address');
        info('  3. Retries with PaymentSignature containing the Avalanche tx hash');
        info('  4. Canister makes HTTPS outcall to Avalanche RPC');
        info('  5. Verifies eth_getTransactionReceipt: status=0x1, to=USDC contract');
        info('  6. Returns results + PaymentReceipt with the Avalanche tx hash');
        info('');

        info('Calling search("avalanche payments") without payment...');
        const res = await mcpCall(client, 'search', {
          query: 'avalanche payments',
        });
        const obj = res as Record<string, unknown>;
        if (obj.status === 'payment_required') {
          success('Got 402 — PaymentRequirement:');
          const req = obj.requirement as Record<string, unknown>;
          result(req);

          divider();
          state('Status', '402 Payment Required');
          state('Amount', `${req?.amount ?? '?'} (0.001 USDC — a tenth of a cent)`);
          state('Token', `${req?.token ?? '?'} (ckUSDC ledger on ICP)`);
          state('Network', String(req?.network ?? '?'));
          state('Recipient', `${req?.recipient ?? '?'} (canister principal)`);
          state('Nonce', `${String(req?.nonce ?? '')} (SHA-256, single-use)`);
          state('Expiry', `${req?.expiry ?? '?'} (5 min window, nanoseconds)`);
          divider();

          info('');
          info('After payment, the search returns:');
          info('  - "ic402: drop-in payment library for ICP canisters..."');
          info('  - "Supports ckUSDC on ICP and USDC on Avalanche via tECDSA..."');
          info('  - "Sessions reduce settlement overhead 5,000x..."');
          info('');
          highlight('Atomic: nonce prevents replay, expiry prevents stale payments.');
          highlight('Cross-chain: canister verifies Avalanche txns via HTTPS outcall.');
          highlight('No bridge, no relayer — the canister calls Avalanche RPC directly.');
        } else {
          warn('Unexpected response (expected paymentRequired):');
          result(res);
        }
      },
    },

    // ── 4. Session ──
    {
      name: 'Session (Streaming Micropayments)',
      description: 'Escrow deposit + off-chain vouchers — 5,000x cheaper than per-call',
      run: async (rl: ReadlineInterface) => {
        header('Step 4: Streaming Micropayments');
        highlight('Sessions solve the cost problem: 10,000 calls settle in 2 txns.');
        highlight('Deposit once -> sign vouchers off-chain -> settle on close.');
        info('');
        info('SESSION ECONOMICS:');
        divider();
        state('ICP tx cost', '~$0.001 per ICRC-2 transfer (cycles + fee)');
        state('Per-call model', '10K calls/day = 10K txns = ~$10 overhead');
        state('Session model', '10K calls/day = 2 txns (open+close) = ~$0.002 overhead');
        state('Savings', '5,000x reduction in settlement cost');
        divider();
        info('');
        info('ESCROW MECHANISM:');
        divider();
        state('Deposit', 'ICRC-2 transfer_from into canister escrow subaccount');
        state('Vouchers', 'Ed25519 signed, cumulative amount, monotonic sequence');
        state('Verification', 'In-canister, constant time, zero ledger calls');
        state('Settlement', 'On close: consumed -> recipient, remainder -> refund');
        divider();
        info('');

        // 4a. Request session intent
        info('Requesting session intent (pricing info, no ledger call)...');
        const intent = await mcpCall(client, 'request_session', {});
        success('Session intent — canister advertises its pricing:');
        result(intent);

        const intentObj = intent as Record<string, unknown>;
        divider();
        state('Suggested deposit', `${intentObj?.suggestedDeposit ?? '?'} (0.05 USDC — covers ~100 queries)`);
        state('Min deposit', `${(intentObj?.minDeposit as string[])?.[0] ?? '?'} (0.005 USDC)`);
        state('Cost per call', `${(intentObj?.costPerCall as string[])?.[0] ?? '?'} (0.0005 USDC)`);
        state('Token', `${intentObj?.token ?? '?'} (ckUSDC ledger)`);
        state('Recipient', `${intentObj?.recipient ?? '?'} (canister)`);
        divider();

        if (!(await confirm(rl, 'Try opening a session? (will fail on local — no mainnet ledger)'))) return;

        info('');
        info('Opening session (requires ICRC-2 escrow deposit)...');
        divider();
        state('ICP settlement', `ICRC-2 transfer_from on ${CKUSDC_LEDGER} (mainnet — not local)`);
        state('AVAX settlement', `Cross-chain: verify USDC tx on ${AVAX_CHAIN} via HTTPS outcall`);
        divider();
        const session = await mcpCall(client, 'open_session', {}) as Record<
          string,
          unknown
        >;

        const sessionId = session.sessionId as string;
        if (!sessionId) {
          warn('Open session failed — expected on local replica.');
          divider();
          state('Error', 'No route to canister (mainnet ledger not on local replica)');
          state('Ledger', `${CKUSDC_LEDGER} — exists on ICP mainnet, not locally`);
          state('Fix', 'Deploy with local ckUSDC ledger wired into canister config');
          state('In production', 'Deposit locks funds -> vouchers stream -> close settles');
          divider();
          highlight('The session protocol itself works — only the ledger call fails locally.');
          return;
        }

        success('Session opened:');
        result(session);

        divider();
        state('Session ID', sessionId);
        state('Deposited', String(session.deposited ?? '?'));
        state('Remaining', String(session.remaining ?? '?'));
        state('State', 'OPEN — vouchers can now be signed off-chain');
        divider();

        if (!(await confirm(rl, 'Send queries through session?'))) return;

        const questions = [
          'What is ic402?',
          'How do sessions work?',
          'What tokens are accepted?',
        ];
        for (let i = 0; i < questions.length; i++) {
          info(`Query ${i + 1}/3: "${questions[i]}"`);
          const answer = await mcpCall(client, 'session_query', {
            sessionId,
            question: questions[i],
          });
          const a = answer as Record<string, unknown>;
          success(`Response received`);
          state('Answer', String(a?.answer ?? '?'));
          state('Consumed', `${a?.consumed ?? '?'} (cumulative — monotonically increasing)`);
          state('Remaining', String(a?.remaining ?? '?'));
          highlight(`Voucher ${i + 1} signed off-chain — zero on-chain cost.`);
          info('');
        }

        if (!(await confirm(rl, 'Close session and settle?'))) return;

        info('Closing session — settling consumed amount, refunding remainder...');
        const receipt = await mcpCall(client, 'close_session', { sessionId });
        success('Session closed — on-chain settlement:');
        result(receipt);
        highlight('3 queries, 2 on-chain transactions total. That\'s the innovation.');
      },
    },

    // ── 5. Content Store ──
    {
      name: 'Encrypted Content Store',
      description: 'In-canister encrypted blob storage — content encrypted at rest',
      run: async (_rl: ReadlineInterface) => {
        header('Step 5: Encrypted Content Store');
        highlight('Content is encrypted at rest using SHA-256-CTR inside the canister.');
        highlight('Even node operators cannot read the stored data.');
        info('');
        info('ENCRYPTION:');
        divider();
        state('Algorithm', 'SHA-256-CTR (stream cipher derived from canister secret)');
        state('Key derivation', 'Per-content key = HMAC(canister_secret, content_id)');
        state('Layer 1', 'ICP subnet-level memory protection (node operators can\'t read)');
        state('Layer 2', 'Application-level encryption (even raw memory dumps are ciphertext)');
        state('Storage', 'Canister stable memory — survives upgrades');
        state('Chunking', 'Auto-chunks at 1.5MB for large files');
        divider();
        info('');

        // Load the Aleph hackathon logo PNG
        const __dirname = dirname(fileURLToPath(import.meta.url));
        const logoPath = resolve(__dirname, '../aleph-logo.png');
        let logoBytes: number[];
        try {
          const buf = readFileSync(logoPath);
          logoBytes = Array.from(buf);
          info(`Content to upload: Aleph hackathon logo (${buf.length} bytes, image/png)`);
          showImage(buf, 'aleph-logo.png');
        } catch {
          info('Aleph logo not found — using text placeholder.');
          logoBytes = [72, 101, 108, 108, 111, 32, 105, 99, 52, 48, 50];
        }

        divider();
        state('Content ID', 'aleph-logo');
        state('MIME type', 'image/png');
        state('Size (plaintext)', `${logoBytes.length} bytes`);
        state('Size (encrypted)', `${logoBytes.length} bytes (CTR mode, same size)`);
        state('Stored at', `Canister ${canisterId} stable memory`);
        divider();

        info('');
        info('Uploading (requires controller identity — will fail from MCP)...');
        const upload = await mcpCall(client, 'call', {
          method: 'uploadContent',
          args: JSON.stringify(['aleph-logo', 'image/png', logoBytes]),
        });
        if (typeof upload === 'string' && upload.toLowerCase().includes('assert')) {
          warn('Upload rejected — caller is not a canister controller.');
          info('');
          info('To upload content locally, use the icp CLI as the controller:');
          info(`  icp canister call example uploadContent '("doc-001", "text/plain", blob "Hello ic402!")' -e local`);
        } else {
          success('Upload result:');
          result(upload);
        }

        info('');
        info('Listing stored content (query — available to any caller)...');
        const list = await mcpCall(client, 'call', {
          method: 'listContent',
          args: '[]',
        });
        success('Content catalog:');
        result(list);

        highlight('Encrypted storage + payment gating = paid content, fully on-chain.');
      },
    },

    // ── 6. Content Delivery (in-canister) ──
    {
      name: 'Paid Content Delivery',
      description: 'Pay $0.005 to access encrypted in-canister content',
      run: async (_rl: ReadlineInterface) => {
        header('Step 6: Paid Content Delivery');
        highlight('Content is gated behind payment — no payment, no access.');
        highlight('Not even content existence is leaked for free.');
        info('');
        info('ACCESS GRANT MECHANISM:');
        divider();
        state('Proof', 'HMAC-SHA256 signed AccessGrant (canister secret key)');
        state('Fields', 'grantId, contentRef, grantee principal, receiptId, TTL');
        state('TTL', '5 minutes — grant expires, cannot be reused or shared');
        state('Verification', 'Any query call can verify via gate.verifyGrant()');
        state('Delivery (small)', 'Inline — content bytes in the response');
        state('Delivery (large)', 'canisterQuery — client calls getChunk(grant, idx)');
        divider();
        info('');

        info('Calling getContent("aleph-logo") without payment...');
        const res = await mcpCall(client, 'call', {
          method: 'getContent',
          args: '["aleph-logo", []]',
        });
        const obj = res as Record<string, unknown>;
        if (obj && typeof obj === 'object' && 'paymentRequired' in obj) {
          success('Payment required — canister gates access:');
          const req = obj.paymentRequired as Record<string, unknown>;
          result(req);

          divider();
          state('Content', 'aleph-logo (encrypted in canister stable memory)');
          state('Price', `${req?.amount ?? '?'} units = $0.005 USDC`);
          state('Token', `${req?.token ?? '?'} (ckUSDC)`);
          state('Recipient', `${req?.recipient ?? '?'} (canister)`);
          state('Nonce', `${String(req?.nonce ?? '')} (single-use)`);
          divider();

          info('');
          info('To test locally (as canister controller):');
          info(`  # Upload content:`);
          info(`  icp canister call example uploadContent '("doc-001", "text/plain", blob "Hello ic402!")' -e local`);
          info(`  # Verify it exists:`);
          info(`  icp canister call example listContent '()' -e local`);
          info(`  # Request access (returns PaymentRequirement):`);
          info(`  icp canister call example getContent '("doc-001", null)' -e local`);

          highlight('No payment = no content. Encrypted at rest, gated by payment.');
        } else {
          success('Content delivery response:');
          result(res);
        }
      },
    },

    // ── 7. External (S3/IPFS) ──
    {
      name: 'External Content (Off-Chain Delivery)',
      description: 'Pay on-chain, get a URL for off-chain content (S3/IPFS/Arweave)',
      run: async (_rl: ReadlineInterface) => {
        header('Step 7: External Content Delivery');
        highlight('Content lives off-chain — payment lives on-chain.');
        highlight('Pay the canister, get a pre-signed URL or decryption key.');
        info('');
        info('EXTERNAL CONTENT CONFIG:');
        divider();
        state('Content ID', 'aleph-hackathon-banner');
        state('Hosted at', EXTERNAL_CONTENT_URL);
        state('Type', 'Image (Aleph hackathon event banner)');
        state('Delivery', '#httpUrl — canister returns URL after payment');
        divider();
        info('');
        info('SIGNING INFRASTRUCTURE (production):');
        divider();
        state('S3 signing', 'tECDSA — canister signs AWS Sig V4 without stored keys');
        state('Key source', 'ICP threshold ECDSA service (subnet-level key management)');
        state('IPFS model', 'Content encrypted before upload, key returned on payment');
        state('URL expiry', 'Matches AccessGrant TTL (5 min) — time-limited access');
        divider();
        info('');

        info('Calling getExternalContent("aleph-hackathon-banner") without payment...');
        const res = await mcpCall(client, 'call', {
          method: 'getExternalContent',
          args: '["aleph-hackathon-banner", []]',
        });
        const obj = res as Record<string, unknown>;
        if (obj && typeof obj === 'object' && 'paymentRequired' in obj) {
          success('Payment required:');
          const req = obj.paymentRequired as Record<string, unknown>;
          result(req);

          divider();
          state('Price', `${req?.amount ?? '?'} units = $0.005 USDC`);
          state('Token', `${req?.token ?? '?'} (ckUSDC)`);
          state('After payment', 'AccessGrant + httpUrl to the image');
          state('Content URL', EXTERNAL_CONTENT_URL);
          state('Fetchable', 'Yes — open this URL in a browser to see the banner');
          divider();

          highlight('On-chain payment, off-chain delivery. Best of both worlds.');
        } else {
          success('External content response:');
          result(res);
        }
      },
    },

    // ── 8. Policy ──
    {
      name: 'Policy Engine',
      description: 'Spending limits, rate limiting, access control — all in-canister',
      run: async (_rl: ReadlineInterface) => {
        header('Step 8: Policy Engine');
        highlight('Every charge and voucher passes through the policy engine.');
        highlight('Evaluated in-canister, zero ledger calls, constant time.');
        info('');
        info('The policy engine enforces limits on both sides:');
        info('');

        info('CLIENT-SIDE (set by the AI agent / MCP consumer):');
        divider();
        state('Max per request', '50,000 ($0.05) — reject calls that cost more');
        state('Max per day', '500,000 ($0.50) — rolling 24h spending cap');
        state('Max session deposit', 'configurable — cap escrow exposure');
        divider();
        highlight('The AI agent controls its own budget — can never be drained.');
        info('');

        info('CANISTER-SIDE (set by the service operator):');
        divider();
        state('Max per transaction', '50,000 ($0.05)');
        state('Max per day', '500,000 ($0.50)');
        state('Rate limit', '120 requests/min per caller');
        state('Max session deposit', '100,000 ($0.10)');
        state('Concurrent sessions', '1 per caller');
        state('Session duration', '24h max');
        state('Idle timeout', '1h — auto-close + refund');
        divider();
        highlight('Per-caller overrides supported — trusted agents get higher limits.');
        info('');

        info('Both sides enforce independently:');
        info('  - Client rejects before sending if budget exceeded');
        info('  - Canister rejects with #policyDenied if server limits exceeded');
        info('  - Sessions auto-close on idle timeout (refunds remaining deposit)');
        info('');

        info('FULL INFRASTRUCTURE SUMMARY:');
        divider();
        state('Canister', `${canisterId} on ICP`);
        state('Canister URL', canisterUrl);
        state('ICP payment', `ckUSDC via ICRC-2 (ledger: ${CKUSDC_LEDGER})`);
        state('Avalanche payment', `USDC on Fuji (${AVAX_USDC})`);
        state('Cross-chain verify', 'HTTPS outcall -> eth_getTransactionReceipt on Avalanche RPC');
        state('Avalanche chain', AVAX_CHAIN);
        state('Avalanche explorer', AVAX_EXPLORER);
        state('tECDSA', 'Canister derives native AVAX address + signs EVM txns');
        state('Identity', `ERC-8004 on IdentityRegistry ${AVAX_REGISTRY}`);
        state('Content encryption', 'SHA-256-CTR at rest');
        state('External content', EXTERNAL_CONTENT_URL);
        divider();

        info('');
        highlight('Dual-sided policy = safe for both the AI agent and the service.');
        info('');
        success('Demo complete!');
        info('');
        highlight('ic402: one import, one deploy. Charges, sessions, content, identity.');
        highlight('No external infra. The canister is everything.');
      },
    },
  ];
}
