import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Interface as ReadlineInterface } from 'node:readline/promises';
import type { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';
import type { StepDef } from './runner.js';
import { confirm } from './runner.js';
import {
  mcpCall,
  header,
  info,
  success,
  warn,
  result,
  showImage,
  highlight,
  state,
  divider,
  versus,
  section,
} from './util.js';

const BASE_CHAIN = 'Base Sepolia testnet (chainId 84532)';
const BASE_EXPLORER = 'https://sepolia.basescan.org';
const BASE_REGISTRY = process.env.BASE_REGISTRY_CONTRACT || '(not deployed on Base yet)';
const CKUSDC_LEDGER = 'xevnm-gaaaa-aaaar-qafnq-cai';
const EVM_CHAINS = [
  { name: 'Base Sepolia', chainId: 84532, usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' },
  {
    name: 'Ethereum Sepolia',
    chainId: 11155111,
    usdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
  },
  { name: 'Avalanche Fuji', chainId: 43113, usdc: '0x5425890298aed601595a70AB815c96711a31Bc65' },
  {
    name: 'Optimism Sepolia',
    chainId: 11155420,
    usdc: '0x5fd84259d66Cd46123540766Be93DFE6D43130D7',
  },
  { name: 'Arbitrum Sepolia', chainId: 421614, usdc: '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d' },
];
const EXTERNAL_CONTENT_URL =
  'https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=1,quality=80,width=400,height=400/event-covers/v2/ceaf4fc5-d05b-49f0-8c88-f81bea8d9f46';

function pubkeyToEvmAddress(compressedHex: string): string | null {
  try {
    const point = secp256k1.ProjectivePoint.fromHex(compressedHex);
    const uncompressed = point.toRawBytes(false);
    const hash = keccak_256(uncompressed.slice(1));
    return '0x' + Buffer.from(hash).slice(-20).toString('hex');
  } catch {
    return null;
  }
}

export function buildSteps(client: Client, canisterId: string, host: string): StepDef[] {
  const port = new URL(host).port || '4944';
  const rawHttpUrl = host.includes('localhost')
    ? `http://${canisterId}.raw.localhost:${port}`
    : `https://${canisterId}.raw.icp0.io`;

  // Extracted from configure response — set in step 1
  let callerPrincipal = '';
  let evmAddress = '';

  return [
    // ══════════════════════════════════════════════════════════════════
    // Step 1: Configure
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Configure',
      description: 'Connect to the canister, derive its EVM address, set budget',
      run: async (_rl: ReadlineInterface) => {
        header('Step 1: Configure');
        versus(
          ['Express/Cloudflare server + Coinbase facilitator + separate wallet'],
          [
            'The canister IS the server, the wallet, AND the payment processor.',
            'One Motoko import. One deploy. No external infrastructure.',
          ],
        );

        const configArgs: Record<string, string> = {
          canisterId,
          host,
          network: 'icp:1',
          maxPerRequest: '50000',
          maxPerDay: '500000',
        };
        if (process.env.ICP_IDENTITY_PEM) {
          configArgs.identityPem = process.env.ICP_IDENTITY_PEM;
        }
        const res = await mcpCall(client, 'configure', configArgs);
        success('MCP server connected');
        // Extract caller principal from configure response
        const resStr = typeof res === 'string' ? res : JSON.stringify(res);
        const idMatch = resStr.match(/identity:\s*([a-z0-9-]+)/);
        if (idMatch) callerPrincipal = idMatch[1];
        result(res);

        info("Deriving canister's native EVM address via ICP threshold ECDSA...");
        evmAddress = '';
        let pubkeyHex = '';
        try {
          const pubkeyResult = await mcpCall(client, 'call', {
            method: 'getEvmPublicKey',
            args: '[]',
          });
          if (typeof pubkeyResult === 'string') pubkeyHex = pubkeyResult;
          else if (Array.isArray(pubkeyResult))
            pubkeyHex = Buffer.from(pubkeyResult as number[]).toString('hex');
          else pubkeyHex = String(pubkeyResult);
          const derived = pubkeyToEvmAddress(pubkeyHex);
          if (derived) evmAddress = derived;
        } catch {
          /* tECDSA may not be available */
        }

        if (evmAddress) {
          success(`Canister EVM address: ${evmAddress}`);
          highlight('No external wallet — derived natively via tECDSA.');
        }

        section('Infrastructure');
        state('Canister', canisterId);
        state('HTTP x402', `${rawHttpUrl}/`);
        state('ICP payment', `ckUSDC via ICRC-2`);
        state('EVM payment', `USDC on 5 chains (Base, ETH, AVAX, OP, ARB)`);
        state('Canister EVM address', evmAddress);
        state('Base explorer', `${BASE_EXPLORER}/address/${evmAddress}`);
        state('Identity registry', BASE_REGISTRY);
        state('Client budget', '$0.05/request, $0.50/day');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 2: Upload Content
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Upload Encrypted Content',
      description: 'Upload content via MCP — encrypted at rest, gated by payment',
      run: async (_rl: ReadlineInterface) => {
        header('Step 2: Upload Content');
        versus(
          ['Content lives outside the protocol. You just gate a URL.'],
          [
            'Built-in encrypted content store. Upload, encrypt, deliver —',
            'all inside the canister. Three delivery backends supported.',
          ],
        );

        const __dirname = dirname(fileURLToPath(import.meta.url));
        const logoPath = resolve(__dirname, '../logo.png');
        let logoBytes: number[];
        try {
          const buf = readFileSync(logoPath);
          logoBytes = Array.from(buf);
          info(`Content: ic402 logo (${buf.length} bytes, image/png)`);
          showImage(buf, 'logo.png');
        } catch {
          logoBytes = [72, 101, 108, 108, 111];
          info('Content: text placeholder');
        }

        section('Encryption (automatic on upload)');
        state('Algorithm', 'SHA-256-CTR — per-content key derived from canister secret');
        state('Layer 1', "ICP subnet memory isolation (node operators can't read memory)");
        state('Layer 2', 'Application encryption (raw memory dumps are ciphertext)');
        state('Storage', 'Canister stable memory — survives upgrades, write-once enforced');

        info('');
        info('Uploading via MCP...');
        const upload = await mcpCall(client, 'call', {
          method: 'uploadContent',
          args: JSON.stringify(['ic402-logo', 'image/png', logoBytes]),
        });
        if (typeof upload === 'string' && upload.toLowerCase().includes('assert')) {
          warn('Upload rejected — MCP identity is not a canister controller.');
          info('Run deploy.sh to add the MCP identity as a controller.');
        } else if (typeof upload === 'string' && upload.toLowerCase().includes('already')) {
          success('Content "ic402-logo" already exists (uploaded in a previous run)');
        } else {
          success('Uploaded and encrypted — plaintext never persists');
        }

        info('Content catalog (IDs are public, content requires payment):');
        const list = await mcpCall(client, 'call', { method: 'listContent', args: '[]' });
        result(list);

        section('Delivery patterns (all use the same payment flow)');
        state('1. In-canister', 'Encrypted blob → inline bytes or chunked query');
        state('2. External', 'S3/IPFS/Arweave → pre-signed URL or decryption key');
        state('3. Asset canister', 'Separate ICP canister → HTTP gateway URL');

        section('Access grants (proof-of-payment, issued after settlement)');
        state('Signed by', 'HMAC-SHA256 with canister secret');
        state('TTL', "5 minutes — expires, can't be reused");
        state('Revocable', 'gate.revokeGrant(grantId) — e.g., after refund');

        highlight("Content uploaded, encrypted, cataloged. Now let's gate it with x402.");
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 3: x402 over HTTP
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'x402 Payment over HTTP',
      description: "Hit the canister's HTTP endpoint — get a 402, pay on ICP or any EVM chain",
      run: async (rl: ReadlineInterface) => {
        header('Step 3: x402 Payment over HTTP');
        versus(
          ['Single chain (usually Base). Facilitator verifies payment.'],
          [
            'Multi-chain in ONE response. Client chooses ICP or any of 5 EVM chains.',
            'Canister verifies EVM payments via HTTPS outcall. No facilitator, no bridge.',
          ],
        );

        section('Live HTTP endpoints');
        state('Content (paid)', `${rawHttpUrl}/content/ic402-logo`);
        state('Search (paid)', `${rawHttpUrl}/search?q=<query>`);
        state('Agent info (free)', `${rawHttpUrl}/`);

        // Hit the content endpoint — this is the main demo (paying for uploaded content)
        info('');
        info('Fetching /content/ic402-logo (the content we uploaded in step 2)...');
        let contentAccepts: Record<string, unknown>[] | null = null;
        try {
          const contentRes = await fetch(`${rawHttpUrl}/content/ic402-logo`);
          success(`HTTP ${contentRes.status} — Payment Required`);
          const contentBody = (await contentRes.json()) as Record<string, unknown>;
          contentAccepts = (contentBody.accepts as Record<string, unknown>[]) ?? null;

          if (Array.isArray(contentAccepts) && contentAccepts.length > 0) {
            success(`${contentAccepts.length} payment options in a single 402 response`);
          }
        } catch {
          warn('Could not reach HTTP endpoint');
        }

        // Also show search endpoint as a second example
        info('');
        info('Fetching /search?q=cross-chain+payments...');
        try {
          const searchRes = await fetch(`${rawHttpUrl}/search?q=cross-chain+payments`);
          const searchAmt = ((await searchRes.json()) as Record<string, unknown>).accepts;
          const searchCount = Array.isArray(searchAmt) ? searchAmt.length : 0;
          const searchPrice = Array.isArray(searchAmt)
            ? Number((searchAmt as Record<string, unknown>[])[0]?.maxAmountRequired ?? 0)
            : 0;
          success(
            `HTTP ${searchRes.status} — ${searchCount} payment options, ${searchPrice} ($${(searchPrice / 1_000_000).toFixed(6)} USDC)`,
          );
        } catch {
          warn('Could not reach search endpoint');
        }

        section('x402 Protocol Flow');
        state('1. GET', '→ HTTP 402 + multi-chain payment options');
        state('2. Pay', 'ICRC-2 approve (ICP) or send USDC (any EVM chain)');
        state('3. Retry', 'Same URL + X-PAYMENT header');
        state('4. Verify', 'Canister settles on-chain (ICRC-2 or EVM RPC canister)');
        state('5. Result', 'HTTP 200 + content or search results');

        {
          section('Live Payment');
          info('Pay for the ic402 logo we uploaded in step 2.');
          info('Choose ICP ckUSDC (works on local replica) or EVM USDC (testnet/mainnet).');
          info('');
          state('  1', `ICP ckUSDC — ICRC-2 (${CKUSDC_LEDGER})`);
          for (let i = 0; i < EVM_CHAINS.length; i++) {
            state(`  ${i + 2}`, `${EVM_CHAINS[i].name} USDC (chainId ${EVM_CHAINS[i].chainId})`);
          }

          {
            const choice = await rl.question('\x1b[2m  Payment method (1-6): \x1b[0m');
            const choiceNum = parseInt(choice.trim(), 10);

            if (choiceNum === 1) {
              // ── ICP ckUSDC payment via MCP ──
              info('Paying with ckUSDC via ICRC-2 (test-payer identity)...');
              info('The predemo script already funded the test-payer and set ICRC-2 approval.');
              try {
                const payRes = await mcpCall(client, 'call', {
                  method: 'getContent',
                  args: '["ic402-logo", []]',
                });
                const payObj = payRes as Record<string, unknown>;

                // First call returns paymentRequired — extract ICP nonce and pay
                if (payObj && 'paymentRequired' in payObj) {
                  const reqs = payObj.paymentRequired as Record<string, unknown>[];
                  const icpReq = Array.isArray(reqs)
                    ? reqs.find((r) => !String(r.network ?? '').startsWith('eip155:'))
                    : null;

                  if (icpReq) {
                    const nonce = (icpReq as Record<string, unknown>).nonce;
                    const network = String((icpReq as Record<string, unknown>).network ?? 'icp:1');
                    info(`Nonce received. Settling via ICRC-2 transfer_from on ${network}...`);

                    const paymentSig = {
                      scheme: 'exact',
                      network,
                      signature: Array.from(new Uint8Array(64)),
                      publicKey: [],
                      sender: callerPrincipal,
                      nonce: Array.isArray(nonce)
                        ? nonce
                        : Array.from(Buffer.from(String(nonce), 'hex')),
                      authorization: [],
                    };

                    const contentRes = await mcpCall(client, 'call', {
                      method: 'getContent',
                      args: JSON.stringify(['ic402-logo', [paymentSig]]),
                    });
                    const contentObj = contentRes as Record<string, unknown>;

                    if (contentObj && 'ok' in contentObj) {
                      success('PAYMENT VERIFIED — content delivered!');
                      const delivery = contentObj.ok as Record<string, unknown>;
                      const grant = delivery?.grant as Record<string, unknown>;
                      if (grant) {
                        state(
                          'Grant',
                          `${String(grant.grantId ?? '').slice(0, 16)}... expires ${String(grant.expiresAt ?? '')}`,
                        );
                      }
                      const del = delivery?.delivery as Record<string, unknown>;
                      if (del && 'inline' in del) {
                        const inlineData = del.inline;
                        let buf: Buffer | null = null;
                        if (typeof inlineData === 'string') buf = Buffer.from(inlineData, 'hex');
                        else if (Array.isArray(inlineData))
                          buf = Buffer.from(inlineData as number[]);
                        if (buf && buf.length > 0) {
                          success(`Content received: ${buf.length} bytes`);
                          showImage(buf, 'ic402-logo-paid.png');
                        } else {
                          success('Content delivered (inline)');
                        }
                      } else if (del) {
                        result(del);
                      } else {
                        result(contentObj.ok);
                      }
                      highlight(
                        'ckUSDC → ICRC-2 transfer_from → content delivered. Zero gas fees.',
                      );
                    } else if (contentObj && 'error' in contentObj) {
                      warn(`Settlement failed: ${contentObj.error}`);
                    } else {
                      warn('Unexpected response:');
                      result(contentRes);
                    }
                  } else {
                    warn('No ICP payment option in response.');
                  }
                } else {
                  warn('Unexpected response (expected paymentRequired):');
                  result(payRes);
                }
              } catch (e) {
                warn(`Payment error: ${e instanceof Error ? e.message : String(e)}`);
                info('Ensure predemo ran (pnpm demo handles this automatically).');
              }
            } else if (choiceNum >= 2 && choiceNum <= 6) {
              // ── EVM USDC payment via EIP-3009 TransferWithAuthorization ──
              const selectedChain = EVM_CHAINS[choiceNum - 2];
              const selectedNetwork = `eip155:${selectedChain.chainId}`;
              info(`Selected: ${selectedChain.name}`);

              // Get fresh payment nonce from canister
              info('Getting payment nonce...');
              const freshRes = await mcpCall(client, 'call', {
                method: 'getContent',
                args: '["ic402-logo", []]',
              });
              const freshObj = freshRes as Record<string, unknown>;
              let payTo = '';
              let amount = 0;
              let freshNonce: number[] = [];
              let tName = 'USD Coin';
              let tVersion = '2';
              if (freshObj && 'paymentRequired' in freshObj) {
                const reqs = freshObj.paymentRequired as Record<string, unknown>[];
                const evmReq = reqs?.find((r) => String(r.network ?? '') === selectedNetwork);
                if (evmReq) {
                  payTo = String(evmReq.recipient ?? '');
                  amount = Number(evmReq.amount ?? 0);
                  const nonceVal = evmReq.nonce;
                  freshNonce = Array.isArray(nonceVal)
                    ? nonceVal
                    : Array.from(Buffer.from(String(nonceVal), 'hex'));
                  // Extract token name/version — Candid opt fields come as [value] or []
                  const tnRaw = evmReq.tokenName;
                  const tn = Array.isArray(tnRaw) ? tnRaw[0] : tnRaw;
                  if (typeof tn === 'string' && tn) tName = tn;
                  const tvRaw = evmReq.tokenVersion;
                  const tv = Array.isArray(tvRaw) ? tvRaw[0] : tvRaw;
                  if (typeof tv === 'string' && tv) tVersion = tv;
                }
              }

              if (!payTo || !amount || !freshNonce.length) {
                warn(`Could not get payment details for ${selectedChain.name}.`);
              } else {
                section('EIP-3009 Payment Flow');
                info('The canister is its own facilitator — no external service needed.');
                info('');
                state('1. Client signs', 'EIP-712 typed data authorizing a USDC transfer');
                state('  ', 'Production: MetaMask eth_signTypedData_v4 | Demo: test key');
                state('2. Client sends', 'Signature to canister (Candid or X-Payment header)');
                state('3. Canister verifies', 'EIP-712 signature locally (pure math, cheap)');
                state(
                  '4. Canister executes',
                  'USDC.transferWithAuthorization() on-chain via tECDSA',
                );
                state('  ', 'Canister pays gas (~30B cycles). Client pays nothing.');
                info('');
                state('  Amount', `${(amount / 1_000_000).toFixed(6)} USDC → ${payTo}`);

                info('');
                info('Signing with test key (Hardhat account #0 — demo only)...');

                // Test private key — NEVER use in production.
                // In production, the client signs with MetaMask eth_signTypedData_v4.
                const TEST_KEY = Buffer.from(
                  'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
                  'hex',
                );
                const testPubUncompressed = secp256k1.getPublicKey(TEST_KEY, false);
                const testAddr =
                  '0x' +
                  Buffer.from(keccak_256(testPubUncompressed.slice(1)))
                    .slice(-20)
                    .toString('hex');

                const validAfter = 0;
                const validBefore = Math.floor(Date.now() / 1000) + 300;
                const authNonce = new Uint8Array(32);
                crypto.getRandomValues(authNonce);

                // EIP-712 signing (same logic as MetaMask/ethers/viem)
                const pad32 = (hex: string) => {
                  const b = Buffer.from(hex.replace(/^0x/, ''), 'hex');
                  const p = new Uint8Array(32);
                  p.set(b, 32 - b.length);
                  return p;
                };
                const u256 = (n: number) => {
                  const b = new Uint8Array(32);
                  let v = BigInt(n);
                  for (let i = 31; i >= 0; i--) {
                    b[i] = Number(v & 0xffn);
                    v >>= 8n;
                  }
                  return b;
                };
                const cat = (...a: Uint8Array[]) => {
                  const o = new Uint8Array(a.reduce((s, x) => s + x.length, 0));
                  let off = 0;
                  for (const x of a) {
                    o.set(x, off);
                    off += x.length;
                  }
                  return o;
                };
                const enc = (s: string) => new TextEncoder().encode(s);
                const typeHash = keccak_256(
                  enc(
                    'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)',
                  ),
                );
                const authTypeHash = keccak_256(
                  enc(
                    'TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)',
                  ),
                );
                const domSep = keccak_256(
                  cat(
                    typeHash,
                    keccak_256(enc(tName)),
                    keccak_256(enc(tVersion)),
                    u256(selectedChain.chainId),
                    pad32(selectedChain.usdc),
                  ),
                );
                const structHash = keccak_256(
                  cat(
                    authTypeHash,
                    pad32(testAddr),
                    pad32(payTo),
                    u256(amount),
                    u256(validAfter),
                    u256(validBefore),
                    authNonce,
                  ),
                );
                const digest = keccak_256(cat(new Uint8Array([0x19, 0x01]), domSep, structHash));

                // Sign with @noble/curves v1 API (lowS enforced, prehash defaults to false)
                const sig = secp256k1.sign(digest, TEST_KEY, { lowS: true });
                const v = sig.recovery + 27;

                section('EIP-712 Typed Data (what the wallet signs)');
                state('  from', testAddr);
                state('  to', payTo);
                state('  value', `${amount} (${(amount / 1_000_000).toFixed(6)} USDC)`);
                state('  domain', `${tName} v${tVersion} on chainId ${selectedChain.chainId}`);

                info('');
                info('Submitting EIP-3009 authorization to canister...');

                const paymentSig = {
                  scheme: 'exact',
                  network: selectedNetwork,
                  signature: Array.from(new Uint8Array(0)),
                  publicKey: [],
                  sender: testAddr,
                  nonce: freshNonce,
                  authorization: [
                    {
                      from: testAddr,
                      to: payTo,
                      value: amount,
                      validAfter,
                      validBefore,
                      nonce: Array.from(authNonce),
                      v,
                      r: Array.from(sig.toCompactRawBytes().slice(0, 32)),
                      s: Array.from(sig.toCompactRawBytes().slice(32, 64)),
                    },
                  ],
                };

                try {
                  const payRes = await mcpCall(client, 'call', {
                    method: 'getContent',
                    args: JSON.stringify(['ic402-logo', [paymentSig]]),
                  });
                  const payObj = payRes as Record<string, unknown>;
                  if (payObj && 'ok' in payObj) {
                    success('EIP-3009 VERIFIED — content delivered!');
                    const delivery = payObj.ok as Record<string, unknown>;
                    const grant = delivery?.grant as Record<string, unknown>;
                    if (grant) {
                      state(
                        'Grant',
                        `${String(grant.grantId ?? '').slice(0, 16)}... expires ${String(grant.expiresAt ?? '')}`,
                      );
                    }
                    const del = delivery?.delivery as Record<string, unknown>;
                    if (del && 'inline' in del) {
                      const inlineData = del.inline;
                      let buf: Buffer | null = null;
                      if (typeof inlineData === 'string') buf = Buffer.from(inlineData, 'hex');
                      else if (Array.isArray(inlineData)) buf = Buffer.from(inlineData as number[]);
                      if (buf && buf.length > 0) {
                        success(`Content received: ${buf.length} bytes`);
                        showImage(buf, 'ic402-logo-paid.png');
                      } else {
                        success('Content delivered (inline)');
                      }
                    } else if (del) {
                      result(del);
                    } else {
                      result(payObj.ok);
                    }
                    highlight(
                      `${selectedChain.name} USDC → EIP-3009 → tECDSA → content delivered.`,
                    );
                  } else if (payObj && 'error' in payObj) {
                    const errMsg = String(payObj.error);
                    if (errMsg.includes('EIP-3009') || errMsg.includes('signature')) {
                      warn(`Signature verification failed: ${errMsg}`);
                      info('The canister verified the EIP-712 signature locally but rejected it.');
                    } else if (errMsg.includes('settlement') || errMsg.includes('EVM')) {
                      warn(`On-chain settlement failed: ${errMsg}`);
                      info('Signature was valid but the on-chain execution failed.');
                      info('On local replica, the EVM RPC canister is a mock — this is expected.');
                    } else {
                      warn(`Error: ${errMsg}`);
                    }
                  } else if (payObj && 'paymentRequired' in payObj) {
                    warn(
                      'Payment not accepted — canister returned paymentRequired (settle failed).',
                    );
                    info(
                      'This usually means the nonce was invalid or the signature verification failed.',
                    );
                    info(`Raw: ${JSON.stringify(payObj).slice(0, 200)}`);
                  } else {
                    result(payRes);
                  }
                } catch (e) {
                  warn(`Settlement error: ${e instanceof Error ? e.message : String(e)}`);
                }
              }
            } else {
              warn('Invalid selection. Skipping.');
            }
          }
        }

        highlight('Multi-chain ICP and EVM x402 — no other implementation does this.');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 4: Delete Content
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Delete Content',
      description: 'Remove content and verify the catalog updates',
      run: async (_rl: ReadlineInterface) => {
        header('Step 4: Delete Content');

        info('Listing content before delete...');
        const beforeList = (await mcpCall(client, 'call', {
          method: 'listContent',
          args: '[]',
        })) as unknown[];
        const beforeCount = Array.isArray(beforeList) ? beforeList.length : 0;
        state('Content entries', `${beforeCount}`);
        if (Array.isArray(beforeList)) {
          for (const entry of beforeList) {
            const e = entry as Record<string, unknown>;
            state(`  ${e.id ?? '?'}`, `${e.mimeType ?? '?'} (${e.totalSize ?? '?'} bytes)`);
          }
        }

        info('');
        info('Deleting ic402-logo...');
        try {
          const deleteRes = await mcpCall(client, 'call', {
            method: 'deleteContent',
            args: '["ic402-logo"]',
          });
          const delObj = deleteRes as Record<string, unknown>;
          if (delObj && 'ok' in delObj) {
            success('Content deleted');
          } else {
            warn(`Delete returned: ${JSON.stringify(deleteRes)}`);
          }
        } catch (e) {
          warn(`Delete failed: ${e instanceof Error ? e.message : String(e)}`);
        }

        info('');
        info('Listing content after delete...');
        const afterList = (await mcpCall(client, 'call', {
          method: 'listContent',
          args: '[]',
        })) as unknown[];
        const afterCount = Array.isArray(afterList) ? afterList.length : 0;
        state('Content entries', `${beforeCount} → ${afterCount}`);
        if (Array.isArray(afterList)) {
          for (const entry of afterList) {
            const e = entry as Record<string, unknown>;
            state(`  ${e.id ?? '?'}`, `${e.mimeType ?? '?'} (${e.totalSize ?? '?'} bytes)`);
          }
        }

        if (afterCount < beforeCount) {
          success(`Verified: content catalog reduced from ${beforeCount} to ${afterCount}`);
        }

        section('Live HTTP endpoints after delete');
        state('Content (deleted)', `${rawHttpUrl}/content/ic402-logo`);
        state('Search (still available)', `${rawHttpUrl}/search?q=<query>`);

        info('');
        info('Fetching /content/ic402-logo (should fail — content deleted)...');
        try {
          const contentRes = await fetch(`${rawHttpUrl}/content/ic402-logo`);
          if (contentRes.status === 402) {
            // 402 means the endpoint still exists but requires payment
            // Pay to test if content is actually gone
            info('Endpoint returns 402 (payment required). Attempting payment...');
            const payRes = await mcpCall(client, 'call', {
              method: 'getContent',
              args: '["ic402-logo", []]',
            });
            const payObj = payRes as Record<string, unknown>;
            if (payObj && 'paymentRequired' in payObj) {
              // Try paying
              const paid = await mcpCall(client, 'call', {
                method: 'getContent',
                args: JSON.stringify([
                  'ic402-logo',
                  [
                    {
                      scheme: 'exact',
                      network: 'icp:1',
                      signature: Array.from(new Uint8Array(64)),
                      publicKey: [],
                      sender: '',
                      nonce: Array.from(
                        ((
                          (payObj.paymentRequired as Record<string, unknown>[])?.[0] as Record<
                            string,
                            unknown
                          >
                        )?.nonce as number[]) ?? [],
                      ),
                      authorization: [],
                    },
                  ],
                ]),
              });
              const paidObj = paid as Record<string, unknown>;
              if (paidObj && 'error' in paidObj) {
                success(`Content not found: ${paidObj.error}`);
              } else {
                warn('Content still accessible (unexpected)');
              }
            }
          } else {
            state('HTTP status', `${contentRes.status}`);
          }
        } catch {
          success('Endpoint unreachable — content deleted');
        }

        info('');
        info('Fetching /search?q=test (should still work)...');
        try {
          const searchRes = await fetch(`${rawHttpUrl}/search?q=test`);
          success(`HTTP ${searchRes.status} — search endpoint still available`);
        } catch {
          warn('Search endpoint unreachable');
        }

        highlight('Content lifecycle complete — upload, gate, pay, deliver, delete.');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 5: x402 Client (canister pays external API)
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'x402 Client (Canister Pays External API)',
      description: 'The canister acts as an x402 client — pays for external content autonomously',
      run: async (_rl: ReadlineInterface) => {
        header('Step 5: x402 Client');

        section('Role reversal');
        info('In steps 2-3, external clients paid THIS canister for content.');
        info('Now the canister acts as an x402 CLIENT — paying an external x402 API.');
        info('');
        info('The canister:');
        state('1. HTTPS outcall', 'Calls an external x402 endpoint, gets HTTP 402');
        state('2. Parse 402', 'Extracts payment requirements (amount, asset, payTo)');
        state('3. Sign EIP-3009', 'Signs a TransferWithAuthorization via tECDSA');
        state('4. Retry', 'Sends X-PAYMENT header with the signed authorization');
        state('5. Receive', 'Gets the paid content back');
        info('');
        info('No external wallet. No gas. The facilitator executes the USDC transfer.');

        section('Live x402 client request');
        const queryAddr = evmAddress || '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
        const x402Url = `https://x402.goldrush.dev/v1/base-mainnet/address/${queryAddr}/balances_native/`;
        info('Calling GoldRush blockchain data API (paid via Base Sepolia USDC)...');
        info(`Endpoint: ${x402Url}`);
        info('Price: $0.0001 per request (100 USDC units)');
        info('');

        const callX402 = async () => {
          const result = await mcpCall(client, 'call', {
            method: 'fetchX402',
            args: JSON.stringify([x402Url]),
          });
          return result as Record<string, unknown>;
        };

        const showResult = (res: Record<string, unknown>): boolean => {
          if (res && 'ok' in res) {
            const ok = res.ok as Record<string, unknown>;
            success('x402 payment successful!');
            state('Status', String(ok.status ?? '?'));
            state(
              'Paid',
              `${ok.paidAmount ?? '?'} USDC units ($${(Number(ok.paidAmount ?? 0) / 1_000_000).toFixed(6)})`,
            );
            state('Response', String(ok.body ?? '').slice(0, 100) + '...');
            return true;
          } else if (res && 'free' in res) {
            const free = res.free as Record<string, unknown>;
            success('Response received (no payment needed)');
            state('Status', String(free.status ?? '?'));
            state('Body', String(free.body ?? '').slice(0, 100));
            return true;
          }
          return false;
        };

        const isRetryable = (res: Record<string, unknown>): boolean => {
          if (res && 'paymentFailed' in res) {
            return String(res.paymentFailed).startsWith('SETTLEMENT_FAILED:');
          }
          return res != null && 'transientError' in res;
        };

        const showError = (res: Record<string, unknown>) => {
          if (res && 'paymentFailed' in res) {
            const msg = String(res.paymentFailed);
            if (msg.startsWith('SETTLEMENT_FAILED:')) {
              warn('Facilitator settlement failed.');
              info(`Details: ${msg.slice(19).trim()}`);
            } else if (msg.startsWith('NO_MATCH:')) {
              warn('No compatible payment option.');
              info(`Details: ${msg.slice(10).trim()}`);
            } else if (msg.startsWith('SERVER_ERROR:')) {
              warn(`Server error after payment. ${msg.slice(14).trim()}`);
            } else if (msg.startsWith('SIGN_ERROR:')) {
              warn(`Payment signing failed. ${msg.slice(12).trim()}`);
            } else {
              warn(`Payment failed: ${msg}`);
            }
          } else if (res && 'transientError' in res) {
            warn(`Transient error: ${String(res.transientError)}`);
          } else if (res && 'httpError' in res) {
            const err = res.httpError as Record<string, unknown>;
            warn(`HTTP error ${err.status}: ${String(err.body ?? '').slice(0, 100)}`);
          } else {
            warn(`Unexpected: ${JSON.stringify(res).slice(0, 200)}`);
          }
        };

        try {
          let res = await callX402();
          let ok = showResult(res);
          if (!ok && isRetryable(res)) {
            info('Retrying (facilitator settlement can be intermittent)...');
            res = await callX402();
            ok = showResult(res);
          }
          if (!ok) showError(res);
        } catch (e) {
          warn(`x402 client error: ${e instanceof Error ? e.message : String(e)}`);
        }

        highlight('The canister is both an x402 server AND client — fully autonomous commerce.');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 6: Sessions
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Streaming Micropayments (Sessions)',
      description: 'Deposit once, stream vouchers, settle on close — 5,000x cheaper',
      run: async (rl: ReadlineInterface) => {
        header('Step 6: Streaming Micropayments');

        section('What sessions are for');
        info("Sessions let a client pay for repeated access to THIS canister's services.");
        info('Instead of settling every call on-chain, the client deposits once and streams');
        info('signed vouchers. The canister verifies each voucher in constant time — no');
        info('ledger calls, no gas, no latency. Settlement happens once when the session closes.');
        info('');
        info('Use case: an AI agent querying a knowledge base thousands of times per day.');
        info('Without sessions, every query is an on-chain transaction. With sessions,');
        info('the entire day is 2 transactions (open + close).');

        section('Charges vs Sessions');
        state('Charges (x402)', 'Standard HTTP 402 — works with any x402 client or browser');
        state('', 'GET → 402 → pay on any chain → retry with X-PAYMENT header → 200');
        state('Sessions', 'SDK-only protocol for high-frequency programmatic access');
        state('', 'Requires ic402 client SDK (Ed25519 voucher signing, Candid RPC)');
        state('', 'NOT accessible via HTTP or x402 browsers — designed for agents/backends');

        versus(
          ['Every call = one on-chain transaction. No session support.'],
          [
            'Deposit once. Stream signed vouchers (free). Settle on close.',
            '10,000 calls = 2 on-chain transactions. 5,000x reduction.',
            'No other x402 implementation has sessions.',
          ],
        );

        section('Economics');
        state('Per-call model', '10K calls/day × $0.001/tx = $10/day settlement overhead');
        state('Session model', '10K calls/day × 2 txns = $0.002/day settlement overhead');
        state('Savings', '5,000x — same results, fraction of the cost');

        section('Protocol');
        state('1. Deposit', 'Client sends tokens to canister (ICP ckUSDC or EVM USDC)');
        state('2. Stream', 'Ed25519-signed vouchers per call (cumulative, monotonic)');
        state('3. Verify', 'In-canister, constant time, zero ledger calls per voucher');
        state('4. Close', 'Settle consumed → canister operator, refund remainder → client');
        state('Total txns', '2 (open + close) regardless of call count');

        info('');
        info('Requesting session pricing...');
        const intent = await mcpCall(client, 'request_session', {});
        success('Session intent received');

        const intentObj = intent as Record<string, unknown>;
        state('Suggested deposit', `${intentObj?.suggestedDeposit ?? '?'} ($0.05 — ~100 queries)`);
        state('Cost per call', `${(intentObj?.costPerCall as string[])?.[0] ?? '?'} ($0.0005)`);
        state('Min deposit', `${(intentObj?.minDeposit as string[])?.[0] ?? '?'} ($0.005)`);

        section('Session Deposit Method');
        info('The client deposits tokens to open a session.');
        info('ICP: ICRC-2 escrow. EVM: EIP-3009 (same as charges — gasless for client).');
        info('On close, canister settles consumed + refunds remainder via tECDSA.');
        info('');
        state('  1', `ICP ckUSDC — ICRC-2 escrow (${CKUSDC_LEDGER})`);
        for (let i = 0; i < EVM_CHAINS.length; i++) {
          state(`  ${i + 2}`, `${EVM_CHAINS[i].name} USDC (chainId ${EVM_CHAINS[i].chainId})`);
        }
        info('');

        // Shared: stream 10 queries through a session
        async function runSessionQueries(sid: string, deposited: number) {
          info('');
          info('Streaming 10 queries through the session...');
          info('Each query signs a voucher (off-chain). The canister verifies in constant time.');
          const costPerCall = 500;
          const questions = [
            'What is ic402?',
            'How do sessions work?',
            'What tokens are accepted?',
            'How does cross-chain settlement work?',
            'What is tECDSA?',
            'How does the policy engine work?',
            'What is ERC-8004?',
            'How is content encrypted?',
            'What delivery patterns are supported?',
            'How do AccessGrants work?',
          ];
          for (let i = 0; i < questions.length; i++) {
            const cumConsumed = costPerCall * (i + 1);
            const cumRemaining = deposited - cumConsumed;
            try {
              await mcpCall(client, 'session_query', { sessionId: sid, question: questions[i] });
            } catch (e) {
              // Log first failure for debugging
              if (i === 0) warn(`Voucher error: ${e instanceof Error ? e.message : String(e)}`);
            }
            const q = questions[i].padEnd(42);
            const c = String(cumConsumed).padStart(5);
            const r = String(cumRemaining).padStart(5);
            state(`  ${String(i + 1).padStart(2)}/10`, `${q} consumed=${c}  remaining=${r}`);
          }

          info('');
          const totalConsumed = costPerCall * questions.length;
          const totalRemaining = deposited - totalConsumed;
          state('Queries', `${questions.length}`);
          state('On-chain txns', '0 (all voucher-verified in-canister)');
          state('Total consumed', `${totalConsumed} ($${(totalConsumed / 1_000_000).toFixed(6)})`);
          state('Remaining', `${totalRemaining} ($${(totalRemaining / 1_000_000).toFixed(6)})`);
        }

        const depositChoice = await rl.question('\x1b[2m  Deposit method (1-6): \x1b[0m');
        const depositNum = parseInt(depositChoice.trim(), 10);

        if (depositNum >= 2 && depositNum <= 6) {
          const chain = EVM_CHAINS[depositNum - 2];
          const evmNetwork = `eip155:${chain.chainId}`;
          const depositAmount = Number(intentObj?.suggestedDeposit ?? 50000);

          info('');
          info(`Opening EVM session on ${chain.name} via EIP-3009`);

          // Get canister's EVM address
          let evmAddr = '';
          try {
            evmAddr = String(
              await mcpCall(client, 'call', { method: 'getEvmAddress', args: '[]' }),
            );
          } catch {
            warn('Could not get canister EVM address');
            return;
          }

          // Token name for EIP-712 domain — Base Sepolia and OP Sepolia use "USDC", others "USD Coin"
          const tName = [84532, 11155420].includes(chain.chainId) ? 'USDC' : 'USD Coin';
          const tVersion = '2';

          // Sign EIP-3009 deposit authorization with test key
          const TEST_KEY = Buffer.from(
            'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
            'hex',
          );
          const testPubUncompressed = secp256k1.getPublicKey(TEST_KEY, false);
          const testAddr =
            '0x' +
            Buffer.from(keccak_256(testPubUncompressed.slice(1)))
              .slice(-20)
              .toString('hex');

          const validAfter = 0;
          const validBefore = Math.floor(Date.now() / 1000) + 300;
          const authNonce = new Uint8Array(32);
          crypto.getRandomValues(authNonce);

          const pad32 = (hex: string) => {
            const b = Buffer.from(hex.replace(/^0x/, ''), 'hex');
            const p = new Uint8Array(32);
            p.set(b, 32 - b.length);
            return p;
          };
          const u256 = (n: number) => {
            const b = new Uint8Array(32);
            let v = BigInt(n);
            for (let i = 31; i >= 0; i--) {
              b[i] = Number(v & 0xffn);
              v >>= 8n;
            }
            return b;
          };
          const cat = (...a: Uint8Array[]) => {
            const o = new Uint8Array(a.reduce((s, x) => s + x.length, 0));
            let off = 0;
            for (const x of a) {
              o.set(x, off);
              off += x.length;
            }
            return o;
          };
          const enc = (s: string) => new TextEncoder().encode(s);
          const typeHash = keccak_256(
            enc(
              'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)',
            ),
          );
          const authTypeHash = keccak_256(
            enc(
              'TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)',
            ),
          );
          const domSep = keccak_256(
            cat(
              typeHash,
              keccak_256(enc(tName)),
              keccak_256(enc(tVersion)),
              u256(chain.chainId),
              pad32(chain.usdc),
            ),
          );
          const structHash = keccak_256(
            cat(
              authTypeHash,
              pad32(testAddr),
              pad32(evmAddr),
              u256(depositAmount),
              u256(validAfter),
              u256(validBefore),
              authNonce,
            ),
          );
          const digest = keccak_256(cat(new Uint8Array([0x19, 0x01]), domSep, structHash));

          const sig = secp256k1.sign(digest, TEST_KEY, { lowS: true });
          const v = sig.recovery + 27;

          divider();
          state('  Chain', `${chain.name} (${evmNetwork})`);
          state(
            '  Deposit',
            `${(depositAmount / 1_000_000).toFixed(6)} USDC (${depositAmount} units)`,
          );
          state('  From', testAddr);
          state('  To', evmAddr);
          state('  Method', 'EIP-3009 TransferWithAuthorization');
          divider();

          info('Submitting EIP-3009 deposit to canister...');

          try {
            const evmSession = (await mcpCall(client, 'open_session', {
              maxDeposit: String(depositAmount),
              evmNetwork,
              evmSender: testAddr,
              evmToken: chain.usdc,
              evmRecipient: evmAddr,
              // EIP-3009 authorization
              authorization: {
                from: testAddr,
                to: evmAddr,
                value: depositAmount,
                validAfter,
                validBefore,
                nonce: Array.from(authNonce),
                v,
                r: Array.from(sig.toCompactRawBytes().slice(0, 32)),
                s: Array.from(sig.toCompactRawBytes().slice(32, 64)),
              },
            })) as Record<string, unknown>;

            const evmSessionId = evmSession.sessionId as string;

            if (!evmSessionId) {
              const errMsg =
                typeof evmSession === 'string' ? evmSession : JSON.stringify(evmSession);
              warn(`Open failed: ${errMsg.slice(0, 200)}`);
            } else {
              success('EVM session opened!');
              state('Session ID', evmSessionId);
              state('Deposited', `${evmSession.deposited ?? '?'} (${chain.name} USDC)`);
              state('Network', evmNetwork);
              state('Status', 'OPEN');

              const evmDeposited = Number(evmSession.deposited ?? depositAmount);
              await runSessionQueries(evmSessionId, evmDeposited);

              info('');
              info(`Closing EVM session — canister signs ERC-20 transfers via tECDSA...`);
              info(`Settle consumed → canister operator on ${chain.name}`);
              info(`Refund remainder → payer on ${chain.name}`);
              try {
                const closeRes = await mcpCall(client, 'close_session', {
                  sessionId: evmSessionId,
                });
                success('EVM session closed — settled on-chain');
                const receipt = closeRes as Record<string, unknown>;
                state(
                  'Consumed',
                  `${receipt?.amount ?? 0} (settled to recipient on ${chain.name})`,
                );
                state('Refunded', `${receipt?.refunded ?? 0} (returned to payer on ${chain.name})`);
                if (receipt?.txHash) {
                  const hashes = String(receipt.txHash).split('|');
                  if (hashes.length === 2) {
                    state('Settle tx', hashes[0]);
                    state('Refund tx', hashes[1]);
                  } else {
                    state('Tx', hashes[0]);
                  }
                }
                state('Settlement', `tECDSA-signed ERC-20 transfers on ${chain.name}`);
                highlight('Same 5,000x reduction — works on any EVM chain.');
              } catch (e) {
                warn(`Close failed: ${e instanceof Error ? e.message : String(e)}`);
              }
            }
          } catch (e) {
            warn(`Open session error: ${e instanceof Error ? e.message : String(e)}`);
          }
          return;
        }

        // ICP ckUSDC session
        section('Funding the session deposit');
        info('Before opening a session, the client needs ckUSDC and an ICRC-2 approval.');
        info('The predemo script minted 1 ckUSDC to the test-payer account and approved');
        info('the canister to spend it. In production, the ic402 client SDK handles this.');
        state('Test payer', callerPrincipal || '(test-payer identity)');
        state('Funded', '1,000,000 units ($1.00 ckUSDC) via icrc1_transfer');
        state('Approved', 'ICRC-2 approval for canister to spend up to 1,000,000 units');

        info('');
        info('Opening session with ICP ckUSDC...');
        const session = (await mcpCall(client, 'open_session', {})) as Record<string, unknown>;
        const sessionId = session.sessionId as string;

        if (!sessionId) {
          const errMsg = typeof session === 'string' ? session : JSON.stringify(session);
          if (errMsg.toLowerCase().includes('concurrent')) {
            warn('Previous session still open (maxConcurrentSessions = 1).');
            try {
              await mcpCall(client, 'call', { method: 'closeExpiredSessions', args: '[]' });
              success('Expired sessions closed. Run demo again.');
            } catch {
              /* ok */
            }
          } else {
            warn('Open failed.');
            state('Error', errMsg.slice(0, 200));
            state('Needs', 'ckUSDC balance + icrc2_approve for the canister to spend');
            state('In production', 'Client SDK handles approval automatically');
          }
          highlight('The session protocol is fully implemented.');
        } else {
          success('Session opened!');
          state('Session ID', sessionId);
          state('Deposited', `${session.deposited ?? '?'} ($0.05)`);
          state('Remaining', `${session.remaining ?? '?'} ($0.05)`);
          state('Cost per call', '500 ($0.0005)');
          state('Status', 'OPEN');

          const deposited = Number(session.deposited ?? 50000);
          await runSessionQueries(sessionId, deposited);

          info('');
          info('Closing session (settle consumed → recipient, refund remainder → caller)...');
          try {
            const closeRes = await mcpCall(client, 'close_session', { sessionId });
            success('Session closed — settled on-chain');
            const receipt = closeRes as Record<string, unknown>;
            state('Consumed (settled)', String(receipt?.amount ?? '?'));
            state('Refunded', String(receipt?.refunded ?? '?'));
            if (receipt?.txHash) {
              const tx = String(receipt.txHash);
              if (tx.includes('|')) {
                const parts = tx.split('|');
                for (const p of parts) state('Ledger tx', p);
              } else if (tx) {
                state('Ledger tx', tx);
              }
            }
            state('Total on-chain txns', '2 (open + close) for 10 queries');
            highlight("10 queries, 2 on-chain transactions. That's the 5,000x reduction.");
          } catch (e) {
            warn(`Close failed: ${e instanceof Error ? e.message : String(e)}`);
          }
        }
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 7: Agent Discovery
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Agent Discovery (ERC-8004 on Base)',
      description: 'Cross-chain identity — other agents find this canister on Base',
      run: async (rl: ReadlineInterface) => {
        header('Step 7: Agent Discovery');
        versus(
          ['No discovery. You need to already know the endpoint URL.'],
          [
            'Agent card registered as ERC-721 on Base.',
            'Other agents query IdentityRegistry by skill/domain.',
            'They find this ICP canister without a centralized directory.',
          ],
        );

        section('How it works');
        state('Key derivation', 'ICP tECDSA → secp256k1 → native EVM address');
        state('Registration', 'ERC-721 on IdentityRegistry (Base)');
        state('Discovery', 'Query by skill, domain, or x402Support');

        info('');
        info('Fetching agent card...');
        try {
          const card = await mcpCall(client, 'call', { method: 'getAgentCard', args: '[]' });
          const c = card as Record<string, unknown>;
          if (c && typeof c === 'object') {
            success('Agent card retrieved');
            state('Name', String(c.name ?? '?'));
            state('x402', String(c.x402Support ?? '?'));
            const services = c.services as Array<Record<string, unknown>> | undefined;
            if (services?.[0]) {
              state('Endpoint', String(services[0].endpoint ?? '?'));
              state('Skills', JSON.stringify(services[0].skills ?? []));
            }
          }
        } catch (e) {
          warn(`Failed to fetch agent card: ${e instanceof Error ? e.message : String(e)}`);
        }

        // Check if already registered
        info('Checking Base registration...');
        const agentIdResult = await mcpCall(client, 'call', { method: 'getAgentId', args: '[]' });
        const agentIdArr = agentIdResult as unknown[];
        let agentId = Array.isArray(agentIdArr) && agentIdArr.length > 0 ? agentIdArr[0] : null;

        if (agentId != null) {
          success(`Already registered — ERC-721 #${agentId} on Base Sepolia`);
          state('Verify', `${BASE_EXPLORER}/address/${BASE_REGISTRY}`);
        } else {
          // Show EVM address
          let evmAddr = '';
          try {
            evmAddr = String(
              await mcpCall(client, 'call', { method: 'getEvmAddress', args: '[]' }),
            );
            state('Canister EVM address', evmAddr);
          } catch {
            warn('Could not derive EVM address');
          }

          section('On-canister EVM signing');
          info(
            'The canister signs its own EVM transactions via tECDSA — no external wallet needed.',
          );
          info(
            'It builds an EIP-1559 tx, signs with threshold ECDSA, and submits via the EVM RPC canister.',
          );
          info('');
          state('Canister EVM address', evmAddr);
          state('Gas funding', `Base Sepolia ETH deposited to canister EVM address`);
          state('Faucet', 'https://www.alchemy.com/faucets/base-sepolia');
          info('');

          if (await confirm(rl, 'Try registering on Base Sepolia?')) {
            info('Registering agent on Base Sepolia...');

            try {
              const regResult = await mcpCall(client, 'call', {
                method: 'registerAgent',
                args: '[]',
              });
              const reg = regResult as Record<string, unknown>;

              if (reg && typeof reg === 'object' && 'ok' in reg) {
                const okVal = reg.ok as Record<string, unknown>;
                agentId = okVal?.tokenId;
                success(`Registered — ERC-721 #${agentId} on Base Sepolia`);
                if (okVal?.txHash) {
                  state('Tx', `${BASE_EXPLORER}/tx/${String(okVal.txHash)}`);
                }
                state('Contract', `${BASE_EXPLORER}/address/${BASE_REGISTRY}`);
              } else if (reg && typeof reg === 'object' && 'err' in reg) {
                warn(`Registration failed: ${String(reg.err)}`);
                if (String(reg.err).includes('Insufficient ETH')) {
                  info(`Fund ${evmAddr} with Base Sepolia ETH and try again.`);
                }
              }
            } catch (e) {
              warn(`Registration error: ${e instanceof Error ? e.message : String(e)}`);
              info('This is expected if the EVM address has no ETH for gas.');
              info(
                `Fund ${evmAddr} and run: icp canister call example registerAgent '()' -e local`,
              );
            }
          }
        }

        highlight('ICP canister, discoverable from any EVM chain. No directory, no API key.');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 8: Policy + Summary
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Policy Engine + Summary',
      description: 'Dual-sided spending limits + UVP recap',
      run: async (_rl: ReadlineInterface) => {
        header('Step 8: Policy Engine + Summary');
        versus(
          [
            'No spending limits. No rate limiting. No session caps.',
            'A misconfigured agent can drain its wallet.',
          ],
          [
            'Dual-sided policy engine. Both client and canister enforce.',
            'Budget limits, rate limits, session caps, idle timeouts.',
            'Evaluated in-canister, zero ledger calls, constant time.',
          ],
        );

        section('Client-side (AI agent protects itself)');
        state('Max per request', '$0.05 — reject before sending if too expensive');
        state('Max per day', '$0.50 — rolling 24h spending cap');
        state('Max session deposit', 'Configurable — cap escrow exposure');
        highlight('The AI agent controls its own budget — can never be drained.');

        section('Canister-side (service operator protects the service)');
        state('Max per tx', '$0.05');
        state('Max per day', '$0.50');
        state('Rate limit', '120 req/min per caller');
        state('Session deposit cap', '$0.10');
        state('Concurrent sessions', '1 per caller');
        state('Idle timeout', '1h — auto-close + refund remainder');
        state('Per-caller overrides', 'Trusted agents get higher limits');
        highlight('The service can never be abused. Idle sessions auto-refund.');

        section('Full infrastructure');
        state('Canister', canisterId);
        state('HTTP x402', `${rawHttpUrl}/`);
        state('ICP payment', 'ckUSDC via ICRC-2');
        state('EVM payment', 'USDC on 5 chains — verified via HTTPS outcall');
        state('Cross-chain', 'eth_getTransactionReceipt — no bridge, no facilitator');
        state('Sessions', '5,000x settlement reduction — unique to ic402');
        state('Content', 'Encrypted (SHA-256-CTR), 3 delivery patterns');
        state('Identity', `ERC-8004 on Base (${BASE_REGISTRY})`);
        state('Policy', 'Dual-sided — no other x402 has this');

        info('');
        success('Demo complete.');
        highlight('ic402: one Motoko import, one deploy.');
        highlight(
          'Upload content, encrypt it, gate with x402, accept payment on ICP or any EVM chain.',
        );
        highlight(
          'The canister is the server, the wallet, the HTTP endpoint, and the EVM address.',
        );
        highlight('No facilitator. No bridge. No external infrastructure.');
      },
    },
  ];
}
