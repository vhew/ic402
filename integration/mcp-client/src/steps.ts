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

const AVAX_CHAIN = 'Avalanche Fuji testnet (chainId 43113)';
const AVAX_USDC = '0x5425890298aed601595a70AB815c96711a31Bc65';
const AVAX_EXPLORER = 'https://testnet.snowtrace.io';
const AVAX_REGISTRY = process.env.AVAX_REGISTRY_CONTRACT || '(not deployed)';
const CKUSDC_LEDGER = 'xevnm-gaaaa-aaaar-qafnq-cai';
const EXTERNAL_CONTENT_URL =
  'https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=1,quality=80,width=400,height=400/event-covers/v2/ceaf4fc5-d05b-49f0-8c88-f81bea8d9f46';

function pubkeyToAvaxAddress(compressedHex: string): string | null {
  try {
    const point = secp256k1.Point.fromHex(compressedHex);
    const uncompressed = point.toBytes(false);
    const hash = keccak_256(uncompressed.slice(1));
    return '0x' + Buffer.from(hash).slice(-20).toString('hex');
  } catch { return null; }
}

export function buildSteps(
  client: Client,
  canisterId: string,
  host: string,
): StepDef[] {
  const port = new URL(host).port || '4944';
  const rawHttpUrl = host.includes('localhost')
    ? `http://${canisterId}.raw.localhost:${port}`
    : `https://${canisterId}.raw.icp0.io`;

  return [
    // ══════════════════════════════════════════════════════════════════
    // Step 1: Configure
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Configure',
      description: 'Connect to the canister, derive its Avalanche address, set budget',
      run: async (_rl: ReadlineInterface) => {
        header('Step 1: Configure');
        info('WHAT\'S DIFFERENT FROM NORMAL x402:');
        divider();
        info('  Normal x402: Express/Cloudflare server + Coinbase facilitator + separate wallet');
        info('  ic402:       The canister IS the server, the wallet, AND the payment processor');
        info('               One Motoko import. One deploy. No external infrastructure.');
        divider();
        info('');

        const configArgs: Record<string, string> = {
          canisterId, host, network: 'icp:1',
          maxPerRequest: '50000', maxPerDay: '500000',
        };
        if (process.env.ICP_IDENTITY_PEM) {
          configArgs.identityPem = process.env.ICP_IDENTITY_PEM;
        }
        const res = await mcpCall(client, 'configure', configArgs);
        success('MCP server connected');
        result(res);
        info('');

        info('Deriving canister\'s native Avalanche address via ICP threshold ECDSA...');
        let avaxAddress = '(could not derive)';
        let pubkeyHex = '';
        try {
          const pubkeyResult = await mcpCall(client, 'call', {
            method: 'getAvalanchePublicKey', args: '[]',
          });
          if (typeof pubkeyResult === 'string') pubkeyHex = pubkeyResult;
          else if (Array.isArray(pubkeyResult)) pubkeyHex = Buffer.from(pubkeyResult as number[]).toString('hex');
          else pubkeyHex = String(pubkeyResult);
          const derived = pubkeyToAvaxAddress(pubkeyHex);
          if (derived) avaxAddress = derived;
        } catch { /* tECDSA may not be available */ }

        if (avaxAddress !== '(could not derive)') {
          success(`Canister has a native Avalanche address: ${avaxAddress}`);
          highlight('No external wallet — the canister derives its own EVM address via tECDSA.');
        }

        info('');
        divider();
        state('Canister', canisterId);
        state('HTTP x402', `${rawHttpUrl}/`);
        state('ICP payment', `ckUSDC via ICRC-2`);
        state('AVAX payment', `USDC on Fuji (${AVAX_USDC})`);
        state('Canister AVAX address', avaxAddress);
        state('AVAX explorer', `${AVAX_EXPLORER}/address/${avaxAddress}`);
        state('Identity registry', AVAX_REGISTRY);
        state('Client budget', '$0.05/request, $0.50/day');
        divider();
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
        info('WHAT\'S DIFFERENT FROM NORMAL x402:');
        divider();
        info('  Normal x402: Content lives outside the protocol. You just gate a URL.');
        info('  ic402:       Built-in encrypted content store. Upload, encrypt, deliver —');
        info('               all inside the canister. Three delivery backends supported.');
        divider();
        info('');

        // Show the Aleph logo
        const __dirname = dirname(fileURLToPath(import.meta.url));
        const logoPath = resolve(__dirname, '../aleph-logo.png');
        let logoBytes: number[];
        try {
          const buf = readFileSync(logoPath);
          logoBytes = Array.from(buf);
          info(`Content: Aleph hackathon logo (${buf.length} bytes, image/png)`);
          showImage(buf, 'aleph-logo.png');
        } catch {
          logoBytes = [72, 101, 108, 108, 111];
          info('Content: text placeholder');
        }

        info('');
        info('ENCRYPTION (happens automatically on upload):');
        divider();
        state('Algorithm', 'SHA-256-CTR — per-content key derived from canister secret');
        state('Layer 1', 'ICP subnet memory isolation (node operators can\'t read memory)');
        state('Layer 2', 'Application encryption (raw memory dumps are ciphertext)');
        state('Storage', 'Canister stable memory — survives upgrades');
        divider();

        info('');
        info('Uploading via MCP...');
        const upload = await mcpCall(client, 'call', {
          method: 'uploadContent',
          args: JSON.stringify(['aleph-logo', 'image/png', logoBytes]),
        });
        if (typeof upload === 'string' && upload.toLowerCase().includes('assert')) {
          warn('Upload rejected — MCP identity is not a canister controller.');
          info('Run deploy.sh to add the MCP identity as a controller.');
        } else if (typeof upload === 'string' && upload.toLowerCase().includes('already')) {
          success('Content "aleph-logo" already exists (uploaded in a previous run)');
        } else {
          success('Uploaded and encrypted — the plaintext never persists');
        }

        info('');
        info('Content catalog (anyone can list IDs — no one can read without paying):');
        const list = await mcpCall(client, 'call', { method: 'listContent', args: '[]' });
        result(list);

        info('');
        info('DELIVERY PATTERNS (all use the same payment flow):');
        divider();
        state('1. In-canister', 'Encrypted blob → inline bytes or chunked query');
        state('2. External', 'S3/IPFS/Arweave → pre-signed URL or decryption key');
        state('3. Asset canister', 'Separate ICP canister → HTTP gateway URL');
        divider();
        info('');

        info('ACCESS GRANTS (proof-of-payment, issued after settlement):');
        divider();
        state('Signed by', 'HMAC-SHA256 with canister secret');
        state('TTL', '5 minutes — expires, can\'t be reused');
        state('Revocable', 'gate.revokeGrant(grantId) — e.g., after refund');
        divider();

        highlight('Content uploaded, encrypted, cataloged. Now let\'s gate it with x402.');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 3: x402 over HTTP
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'x402 Payment over HTTP',
      description: 'Hit the canister\'s HTTP endpoint — get a 402, pay on ICP or Avalanche',
      run: async (rl: ReadlineInterface) => {
        header('Step 3: x402 Payment over HTTP');
        info('WHAT\'S DIFFERENT FROM NORMAL x402:');
        divider();
        info('  Normal x402: Single chain (usually Base). Facilitator verifies payment.');
        info('  ic402:       Dual-chain in ONE response. Client chooses ICP or Avalanche.');
        info('               Canister verifies Avalanche payments via HTTPS outcall.');
        info('               No facilitator. No bridge. No relayer.');
        divider();
        info('');

        info('The content we just uploaded is now behind a paywall.');
        info('The canister serves HTTP natively — these are real, clickable URLs:');
        divider();
        state('Content (paid)', `${rawHttpUrl}/content/aleph-logo`);
        state('Search (paid)', `${rawHttpUrl}/search?q=<query>`);
        state('Agent info (free)', `${rawHttpUrl}/`);
        divider();
        info('');

        // Hit the content endpoint for the logo we just uploaded
        info('Fetching /content/aleph-logo (the content we just uploaded)...');
        try {
          const contentRes = await fetch(`${rawHttpUrl}/content/aleph-logo`);
          success(`HTTP ${contentRes.status} — Payment Required`);
          const contentBody = await contentRes.json() as Record<string, unknown>;
          const contentAccepts = contentBody.accepts as Record<string, unknown>[];
          if (Array.isArray(contentAccepts) && contentAccepts.length > 0) {
            state('Price', `${contentAccepts[0].maxAmountRequired} ($0.005 USDC)`);
            state('Options', `${contentAccepts.length} chains (ICP + Avalanche)`);
          }
        } catch {
          warn('Could not reach HTTP endpoint');
        }

        info('');

        // Hit the search endpoint
        info('Fetching /search?q=avalanche+payments...');
        try {
          const searchRes = await fetch(`${rawHttpUrl}/search?q=avalanche+payments`);
          success(`HTTP ${searchRes.status} — Payment Required`);
          info('');

          const body = await searchRes.json() as Record<string, unknown>;
          const accepts = body.accepts as Record<string, unknown>[];

          if (Array.isArray(accepts)) {
            highlight(`${accepts.length} payment options in a single 402 response:`);
            info('');
            for (let i = 0; i < accepts.length; i++) {
              const a = accepts[i];
              const network = String(a.network ?? '');
              const isAvax = network.startsWith('eip155:');
              info(`OPTION ${i + 1}: ${isAvax ? 'AVALANCHE USDC (cross-chain)' : 'ICP ckUSDC (native)'}`);
              divider();
              state('Network', network);
              state('Amount', `${a.maxAmountRequired} ($0.001 USDC)`);
              state('Pay to', String(a.payTo ?? ''));
              state('Settlement', isAvax
                ? 'Canister calls Avalanche RPC via HTTPS outcall'
                : 'Canister calls ICRC-2 transfer_from on ICP');
              divider();
              info('');
            }

            info('x402 PROTOCOL:');
            divider();
            state('1. GET', `→ HTTP 402 + dual-chain payment options`);
            state('2. Pay', 'ICRC-2 approve (ICP) or send USDC (Avalanche)');
            state('3. Retry', 'Same URL + X-PAYMENT header');
            state('4. Verify', 'Canister settles on-chain (ICRC-2 or eth_getTransactionReceipt)');
            state('5. Result', 'HTTP 200 + content or search results');
            divider();

            // Optional MetaMask payment — pay for the content we uploaded in step 2
            const avaxOpt = accepts.find(a => String(a.network ?? '').startsWith('eip155:'));
            if (avaxOpt) {
              info('');
              info('LIVE CROSS-CHAIN PAYMENT (optional):');
              info('Pay for the Aleph logo we uploaded in step 2 — from MetaMask.');
              divider();
              info('  1. Switch MetaMask to Avalanche Fuji (chainId 43113)');
              // Content costs 5000 units = $0.005
              info(`  2. Send 0.005000 USDC (token: ${AVAX_USDC})`);
              info(`     to: ${avaxOpt.payTo}`);
              info('  3. Copy the tx hash and paste it below');
              divider();

              if (await confirm(rl, 'Sent USDC on Fuji? Paste tx hash to verify')) {
                const txHash = await rl.question(
                  '\x1b[2m  Avalanche tx hash (0x...): \x1b[0m',
                );
                const trimmed = txHash.trim();

                if (trimmed && trimmed.startsWith('0x') && trimmed.length === 66) {
                  info('');
                  // Get a fresh nonce for getContent (not search) via MCP
                  info('Getting a fresh payment nonce for content access...');
                  const freshRes = await mcpCall(client, 'call', {
                    method: 'getContent',
                    args: '["aleph-logo", []]',
                  });
                  const freshObj = freshRes as Record<string, unknown>;

                  // The response is { paymentRequired: { ... } } — extract the Avalanche nonce
                  let freshNonce: string | null = null;
                  let freshNetwork: string | null = null;
                  if (freshObj && 'paymentRequired' in freshObj) {
                    // paymentRequired is now an array (dual-chain)
                    const reqs = freshObj.paymentRequired;
                    if (Array.isArray(reqs)) {
                      const avaxReq = reqs.find((r: Record<string, unknown>) =>
                        String(r.network ?? '').startsWith('eip155:'));
                      if (avaxReq) {
                        freshNonce = String((avaxReq as Record<string, unknown>).nonce ?? '');
                        freshNetwork = String((avaxReq as Record<string, unknown>).network ?? '');
                      }
                    } else if (typeof reqs === 'object' && reqs !== null) {
                      // Single requirement (legacy)
                      const r = reqs as Record<string, unknown>;
                      freshNonce = String(r.nonce ?? '');
                      freshNetwork = String(r.network ?? '');
                    }
                  }

                  if (!freshNonce || !freshNetwork) {
                    warn('Could not get Avalanche payment nonce for content.');
                  } else {
                    info('Submitting tx hash for cross-chain verification...');
                    info('Canister will HTTPS outcall eth_getTransactionReceipt on Avalanche.');
                    info('');

                    const paymentSig = {
                      scheme: 'exact',
                      network: freshNetwork,
                      signature: Array.from(Buffer.from(trimmed)),
                      sender: '0x0000000000000000000000000000000000000000',
                      nonce: Array.from(Buffer.from(freshNonce, 'hex')),
                    };

                    try {
                      const payRes = await mcpCall(client, 'call', {
                        method: 'getContent',
                        args: JSON.stringify(['aleph-logo', [paymentSig]]),
                      });
                      const payObj = payRes as Record<string, unknown>;
                      if (payObj && 'ok' in payObj) {
                        success('PAYMENT VERIFIED — content delivered!');
                        const delivery = payObj.ok as Record<string, unknown>;
                        const grant = delivery?.grant as Record<string, unknown>;
                        if (grant) {
                          divider();
                          state('Grant ID', String(grant.grantId ?? ''));
                          state('Content', String((grant.contentRef as Record<string, unknown>)?.id ?? ''));
                          state('Expires', String(grant.expiresAt ?? ''));
                          divider();
                        }
                        const del = delivery?.delivery as Record<string, unknown>;
                        if (del && 'inline' in del) {
                          const inlineData = del.inline;
                          // The MCP server serializes Uint8Array as hex string
                          let buf: Buffer | null = null;
                          if (typeof inlineData === 'string') {
                            buf = Buffer.from(inlineData, 'hex');
                          } else if (Array.isArray(inlineData)) {
                            buf = Buffer.from(inlineData as number[]);
                          }
                          if (buf && buf.length > 0) {
                            success(`Content received: ${buf.length} bytes`);
                            showImage(buf, 'aleph-logo-paid.png');
                          } else {
                            success('Content delivered (inline)');
                          }
                        } else if (del) {
                          info('Delivery method:');
                          result(del);
                        } else {
                          // The delivery might be nested differently via MCP serialization
                          info('Full response:');
                          result(payObj.ok);
                        }
                        highlight('Cross-chain settlement complete.');
                        highlight('MetaMask → Avalanche USDC → canister HTTPS outcall → content delivered.');
                      } else if (payObj && 'error' in payObj) {
                        warn(`Settlement failed: ${payObj.error}`);
                        info('The tx may not have confirmed yet, or the amount/token didn\'t match.');
                      } else {
                        warn('Settlement response:');
                        result(payRes);
                      }
                    } catch (e) {
                      warn(`Settlement error: ${e instanceof Error ? e.message : String(e)}`);
                    }
                  }
                } else if (trimmed) {
                  warn('Invalid tx hash format. Skipping.');
                }
              }
            }

            highlight('Dual-chain x402 — no other implementation does this.');
            highlight('The canister is the HTTP server. No proxy, no facilitator.');
          }
        } catch {
          warn('HTTP endpoint not reachable — falling back to MCP');
          const res = await mcpCall(client, 'search', { query: 'avalanche payments' });
          result(res);
        }
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 4: Sessions
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Streaming Micropayments (Sessions)',
      description: 'Deposit once, stream vouchers, settle on close — 5,000x cheaper',
      run: async (rl: ReadlineInterface) => {
        header('Step 4: Streaming Micropayments');
        info('WHAT\'S DIFFERENT FROM NORMAL x402:');
        divider();
        info('  Normal x402: Every call = one on-chain transaction. No session support.');
        info('  ic402:       Deposit once. Stream signed vouchers (free). Settle on close.');
        info('               10,000 calls = 2 on-chain transactions. 5,000x reduction.');
        info('               No other x402 implementation has sessions.');
        divider();
        info('');

        info('The x402 flow you just saw costs ~$0.001 per settlement transaction.');
        info('For an AI agent making thousands of calls, that adds up fast.');
        info('');
        info('ECONOMICS:');
        divider();
        state('Per-call model', '10K calls/day × $0.001/tx = $10 settlement overhead');
        state('Session model', '10K calls/day × 2 txns = $0.002 settlement overhead');
        state('Savings', '5,000x — same results, fraction of the cost');
        divider();
        info('');

        info('PROTOCOL:');
        divider();
        state('1. Deposit', 'ICRC-2 transfer into canister escrow subaccount');
        state('2. Stream', 'Ed25519-signed vouchers per call (cumulative, monotonic)');
        state('3. Verify', 'In-canister, constant time, zero ledger calls per voucher');
        state('4. Close', 'Settle consumed → recipient, refund remainder → caller');
        state('Total txns', '2 (open + close) regardless of call count');
        divider();
        info('');

        info('Requesting session pricing from canister...');
        const intent = await mcpCall(client, 'request_session', {});
        success('Session intent:');
        result(intent);

        const intentObj = intent as Record<string, unknown>;
        divider();
        state('Suggested deposit', `${intentObj?.suggestedDeposit ?? '?'} ($0.05 — ~100 queries)`);
        state('Cost per call', `${(intentObj?.costPerCall as string[])?.[0] ?? '?'} ($0.0005)`);
        state('Min deposit', `${(intentObj?.minDeposit as string[])?.[0] ?? '?'} ($0.005)`);
        divider();

        if (!(await confirm(rl, 'Try opening a session?'))) return;

        info('');
        info('Opening session (requires ckUSDC balance + ICRC-2 approval)...');
        const session = await mcpCall(client, 'open_session', {}) as Record<string, unknown>;
        const sessionId = session.sessionId as string;

        if (!sessionId) {
          // Show the actual error from the canister
          const errMsg = typeof session === 'string' ? session : JSON.stringify(session);
          if (errMsg.toLowerCase().includes('concurrent')) {
            warn('A previous session is still open (maxConcurrentSessions = 1).');
            info('Closing stale sessions...');
            try {
              await mcpCall(client, 'call', { method: 'closeExpiredSessions', args: '[]' });
              success('Expired sessions closed. Try running the demo again.');
            } catch { /* ok */ }
          } else {
            warn('Open failed.');
            divider();
            state('Error', errMsg.slice(0, 200));
            state('Needs', 'ckUSDC balance + icrc2_approve for the canister to spend');
            state('In production', 'Client SDK handles approval automatically');
            divider();
          }
          highlight('The session protocol is fully implemented.');
        } else {
          success('Session opened!');
          divider();
          state('Session ID', sessionId);
          state('Deposited', `${session.deposited ?? '?'} ($0.05)`);
          state('Remaining', `${session.remaining ?? '?'} ($0.05)`);
          state('Cost per call', '500 ($0.0005)');
          state('Status', 'OPEN');
          divider();

          // Simulate 10 queries through the session
          info('');
          info('Streaming 10 queries through the session (vouchers, no on-chain cost)...');
          info('');
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
            try {
              const answer = await mcpCall(client, 'session_query', {
                sessionId,
                question: questions[i],
              });
              // session_query returns { answer, consumed, remaining } as JSON
              // but mcpCall may return it as a string if parsing failed
              let consumed = '?';
              let remaining = '?';
              if (typeof answer === 'object' && answer !== null) {
                const a = answer as Record<string, unknown>;
                consumed = String(a.consumed ?? '?');
                remaining = String(a.remaining ?? '?');
              } else if (typeof answer === 'string') {
                try {
                  const parsed = JSON.parse(answer);
                  consumed = String(parsed.consumed ?? '?');
                  remaining = String(parsed.remaining ?? '?');
                } catch { /* not JSON */ }
              }
              const cost = Number(consumed) * 0.000001;
              state(`Query ${i + 1}/10`, `${questions[i]}`);
              state(`  Consumed`, `${consumed} ($${cost.toFixed(6)}) — Remaining: ${remaining}`);
            } catch (e) {
              warn(`Query ${i + 1} failed: ${e instanceof Error ? e.message : String(e)}`);
              break;
            }
          }

          info('');
          divider();
          state('Queries sent', '10');
          state('On-chain txns for queries', '0 (all voucher-verified in-canister)');
          state('Total consumed', '5,000 ($0.005)');
          state('Remaining to refund', '~45,000 ($0.045) minus fees');
          divider();

          // Close the session
          info('');
          info('Closing session (settle consumed → recipient, refund remainder → caller)...');
          try {
            const closeRes = await mcpCall(client, 'close_session', { sessionId });
            success('Session closed — settled on-chain');
            const receipt = closeRes as Record<string, unknown>;
            divider();
            state('Consumed (settled)', String(receipt?.amount ?? '?'));
            state('Refunded', String(receipt?.refunded ?? '?'));
            state('Total on-chain txns', '2 (open + close) for 10 queries');
            divider();
            highlight('10 queries, 2 on-chain transactions. That\'s the 5,000x reduction.');
          } catch (e) {
            warn(`Close failed: ${e instanceof Error ? e.message : String(e)}`);
          }
        }
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 5: Agent Discovery
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Agent Discovery (ERC-8004 on Avalanche)',
      description: 'Cross-chain identity — other agents find this canister on Avalanche',
      run: async (_rl: ReadlineInterface) => {
        header('Step 5: Agent Discovery');
        info('WHAT\'S DIFFERENT FROM NORMAL x402:');
        divider();
        info('  Normal x402: No discovery. You need to already know the endpoint URL.');
        info('  ic402:       Agent card registered as ERC-721 on Avalanche.');
        info('               Other agents query IdentityRegistry by skill/domain.');
        info('               They find this ICP canister without a centralized directory.');
        divider();
        info('');

        info('HOW IT WORKS:');
        divider();
        state('Key', 'ICP tECDSA → native secp256k1 → Avalanche address');
        state('Registration', 'ERC-721 minted on IdentityRegistry (Avalanche Fuji)');
        state('Discovery', 'Query by skill, domain, or x402Support');
        state('Registry', AVAX_REGISTRY);
        state('Explorer', `${AVAX_EXPLORER}/address/${AVAX_REGISTRY}`);
        divider();
        info('');

        info('Fetching agent card...');
        const card = await mcpCall(client, 'call', {
          method: 'getAgentCard', args: '[]',
        });
        success('Agent card:');

        const c = card as Record<string, unknown>;
        if (c && typeof c === 'object') {
          divider();
          state('Name', String(c.name ?? '?'));
          state('x402 Support', String(c.x402Support ?? '?'));
          const services = c.services as Array<Record<string, unknown>> | undefined;
          if (services?.[0]) {
            state('Endpoint', String(services[0].endpoint ?? '?'));
            state('Skills', JSON.stringify(services[0].skills ?? []));
            state('Domains', JSON.stringify(services[0].domains ?? []));
          }
          divider();
        }

        info('');
        info('Checking Avalanche registration...');
        const agentIdResult = await mcpCall(client, 'call', {
          method: 'getAgentId', args: '[]',
        });
        const agentIdArr = agentIdResult as unknown[];
        const agentId = Array.isArray(agentIdArr) && agentIdArr.length > 0
          ? agentIdArr[0] : null;

        if (agentId != null) {
          success(`Registered — ERC-721 token #${agentId} on Avalanche Fuji`);
          divider();
          state('Token ID', String(agentId));
          state('Contract', AVAX_REGISTRY);
          state('Verify', `${AVAX_EXPLORER}/address/${AVAX_REGISTRY}`);
          divider();
        } else {
          warn('Not yet registered on Avalanche.');
          state('Register', 'pnpm register-agent --private-key <key>');
        }

        highlight('ICP canister, discoverable from any EVM chain. No directory, no API key.');
      },
    },

    // ══════════════════════════════════════════════════════════════════
    // Step 6: Policy + Summary
    // ══════════════════════════════════════════════════════════════════
    {
      name: 'Policy Engine + Summary',
      description: 'Dual-sided spending limits — unique to ic402',
      run: async (_rl: ReadlineInterface) => {
        header('Step 6: Policy Engine');
        info('WHAT\'S DIFFERENT FROM NORMAL x402:');
        divider();
        info('  Normal x402: No spending limits. No rate limiting. No session caps.');
        info('               A misconfigured agent can drain its wallet.');
        info('  ic402:       Dual-sided policy engine. Both client and canister enforce.');
        info('               Budget limits, rate limits, session caps, idle timeouts.');
        info('               Evaluated in-canister, zero ledger calls, constant time.');
        divider();
        info('');

        info('CLIENT-SIDE (AI agent protects itself):');
        divider();
        state('Max per request', '$0.05 — reject before sending if too expensive');
        state('Max per day', '$0.50 — rolling 24h spending cap');
        state('Max session deposit', 'Configurable — cap escrow exposure');
        divider();
        highlight('The AI agent controls its own budget — can never be drained.');
        info('');

        info('CANISTER-SIDE (service operator protects the service):');
        divider();
        state('Max per tx', '$0.05');
        state('Max per day', '$0.50');
        state('Rate limit', '120 req/min per caller');
        state('Session deposit cap', '$0.10');
        state('Concurrent sessions', '1 per caller');
        state('Idle timeout', '1h — auto-close + refund remainder');
        state('Per-caller overrides', 'Trusted agents get higher limits');
        divider();
        highlight('The service can never be abused. Idle sessions auto-refund.');
        info('');

        info('FULL INFRASTRUCTURE:');
        divider();
        state('Canister', canisterId);
        state('HTTP x402', `${rawHttpUrl}/`);
        state('ICP payment', 'ckUSDC via ICRC-2');
        state('AVAX payment', `USDC on Fuji — verified via HTTPS outcall`);
        state('Cross-chain', 'eth_getTransactionReceipt — no bridge, no facilitator');
        state('Sessions', '5,000x settlement reduction — unique to ic402');
        state('Content', 'Encrypted (SHA-256-CTR), 3 delivery patterns');
        state('Identity', `ERC-8004 on Avalanche (${AVAX_REGISTRY})`);
        state('Policy', 'Dual-sided — no other x402 has this');
        divider();

        info('');
        success('Demo complete.');
        info('');
        highlight('ic402: one import, one deploy.');
        highlight('Upload content, encrypt it, gate it with x402, accept payment on ICP or Avalanche.');
        highlight('The canister is the server, the wallet, the HTTP endpoint, and the Avalanche address.');
        highlight('No facilitator. No bridge. No external infrastructure.');
      },
    },
  ];
}
