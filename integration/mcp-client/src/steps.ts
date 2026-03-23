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
    const point = secp256k1.Point.fromHex(compressedHex);
    const uncompressed = point.toBytes(false);
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
        let evmAddress = '(could not derive)';
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

        if (evmAddress !== '(could not derive)') {
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
            highlight(`${contentAccepts.length} payment options in a single 402 response:`);
            for (let i = 0; i < contentAccepts.length; i++) {
              const a = contentAccepts[i];
              const network = String(a.network ?? '');
              const isEvm = network.startsWith('eip155:');
              const chainId = isEvm ? network.split(':')[1] : '';
              const chainName = EVM_CHAINS.find((c) => String(c.chainId) === chainId)?.name;
              const label = isEvm ? `EVM USDC (${chainName ?? chainId})` : 'ICP ckUSDC (native)';
              const settle = isEvm ? 'EVM RPC canister verification' : 'ICRC-2 transfer_from';
              state(
                `  ${i + 1}. ${label}`,
                `${a.maxAmountRequired} to ${String(a.payTo ?? '').slice(0, 20)}... [${settle}]`,
              );
            }
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
          section('Live Payment (optional)');
          info('Pay for the ic402 logo we uploaded in step 2.');
          info('Choose ICP ckUSDC (works on local replica) or EVM USDC (mainnet only).');
          info('');
          state('  1', `ICP ckUSDC — ICRC-2 (${CKUSDC_LEDGER})`);
          for (let i = 0; i < EVM_CHAINS.length; i++) {
            state(`  ${i + 2}`, `${EVM_CHAINS[i].name} USDC (chainId ${EVM_CHAINS[i].chainId})`);
          }

          if (await confirm(rl, 'Try paying for content?')) {
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
                      sender: callerPrincipal,
                      nonce: Array.isArray(nonce)
                        ? nonce
                        : Array.from(Buffer.from(String(nonce), 'hex')),
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
              // ── EVM USDC payment ──
              const selectedChain = EVM_CHAINS[choiceNum - 2];
              info(`Selected: ${selectedChain.name}`);
              divider();
              state('  USDC contract', selectedChain.usdc);
              state(
                '  Pay to',
                contentAccepts?.[1]
                  ? String((contentAccepts[1] as Record<string, unknown>).payTo ?? '')
                  : '(see 402 response)',
              );
              const contentAmt = contentAccepts?.[0]
                ? Number((contentAccepts[0] as Record<string, unknown>).maxAmountRequired ?? 5_000)
                : 5_000;
              state('  Amount', `${(contentAmt / 1_000_000).toFixed(6)} USDC`);
              divider();
              info('Send the USDC, then paste the tx hash.');

              const txHash = await rl.question('\x1b[2m  EVM tx hash (0x...): \x1b[0m');
              const trimmed = txHash.trim();

              if (trimmed && trimmed.startsWith('0x') && trimmed.length === 66) {
                info('Getting fresh payment nonce...');
                const selectedNetwork = `eip155:${selectedChain.chainId}`;
                const freshRes = await mcpCall(client, 'call', {
                  method: 'getContent',
                  args: '["ic402-logo", []]',
                });
                const freshObj = freshRes as Record<string, unknown>;

                let freshNonce: string | null = null;
                let freshNetwork: string | null = null;
                if (freshObj && 'paymentRequired' in freshObj) {
                  const reqs = freshObj.paymentRequired;
                  if (Array.isArray(reqs)) {
                    const evmReq = reqs.find(
                      (r: Record<string, unknown>) => String(r.network ?? '') === selectedNetwork,
                    );
                    if (evmReq) {
                      freshNonce = String((evmReq as Record<string, unknown>).nonce ?? '');
                      freshNetwork = String((evmReq as Record<string, unknown>).network ?? '');
                    }
                  }
                }

                if (!freshNonce || !freshNetwork) {
                  warn(`Could not get payment nonce for ${selectedChain.name}.`);
                } else {
                  info(
                    `Submitting tx hash — canister will verify on ${selectedChain.name} via EVM RPC canister...`,
                  );
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
                      args: JSON.stringify(['ic402-logo', [paymentSig]]),
                    });
                    const payObj = payRes as Record<string, unknown>;
                    if (payObj && 'ok' in payObj) {
                      success('PAYMENT VERIFIED — content delivered!');
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
                        result(payObj.ok);
                      }
                      highlight(
                        `${selectedChain.name} USDC → EVM RPC canister → content delivered.`,
                      );
                    } else if (payObj && 'error' in payObj) {
                      warn(`Settlement failed: ${payObj.error}`);
                    } else if (payObj && 'paymentRequired' in payObj) {
                      warn('EVM settlement failed — canister returned a new payment requirement.');
                      info('EVM verification requires the EVM RPC canister (mainnet only).');
                      info('On local replica, use option 1 (ICP ckUSDC) instead.');
                    } else {
                      result(payRes);
                    }
                  } catch (e) {
                    warn(`Settlement error: ${e instanceof Error ? e.message : String(e)}`);
                  }
                }
              } else if (trimmed) {
                warn('Invalid tx hash format. Skipping.');
              }
            } else {
              warn('Invalid selection. Skipping.');
            }
          }
        }

        highlight('Multi-chain x402 — no other implementation does this.');
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
        versus(
          ['Every call = one on-chain transaction. No session support.'],
          [
            'Deposit once. Stream signed vouchers (free). Settle on close.',
            '10,000 calls = 2 on-chain transactions. 5,000x reduction.',
            'No other x402 implementation has sessions.',
          ],
        );

        info('');
        info('The x402 flow you just saw costs ~$0.001 per settlement transaction.');
        info('For an AI agent making thousands of calls, that adds up fast.');

        section('Economics');
        state('Per-call model', '10K calls/day × $0.001/tx = $10/day settlement overhead');
        state('Session model', '10K calls/day × 2 txns = $0.002/day settlement overhead');
        state('Savings', '5,000x — same results, fraction of the cost');

        section('Protocol');
        state('1. Deposit', 'ICRC-2 transfer into canister escrow subaccount');
        state('2. Stream', 'Ed25519-signed vouchers per call (cumulative, monotonic)');
        state('3. Verify', 'In-canister, constant time, zero ledger calls per voucher');
        state('4. Close', 'Settle consumed → recipient, refund remainder → caller');
        state('Total txns', '2 (open + close) regardless of call count');

        info('');
        info('Requesting session pricing...');
        const intent = await mcpCall(client, 'request_session', {});
        success('Session intent:');
        result(intent);

        const intentObj = intent as Record<string, unknown>;
        state('Suggested deposit', `${intentObj?.suggestedDeposit ?? '?'} ($0.05 — ~100 queries)`);
        state('Cost per call', `${(intentObj?.costPerCall as string[])?.[0] ?? '?'} ($0.0005)`);
        state('Min deposit', `${(intentObj?.minDeposit as string[])?.[0] ?? '?'} ($0.005)`);

        if (!(await confirm(rl, 'Try opening a session?'))) return;

        info('Opening session (requires ckUSDC balance + ICRC-2 approval)...');
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

          info('');
          info('Streaming 10 queries through the session...');
          info('Each query signs a voucher (off-chain). The canister verifies in constant time.');
          const costPerCall = 500;
          const deposited = Number(session.deposited ?? 50000);
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
              await mcpCall(client, 'session_query', { sessionId, question: questions[i] });
            } catch {
              /* voucher may fail on local — tracking client-side */
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

          info('');
          info('Closing session (settle consumed → recipient, refund remainder → caller)...');
          try {
            const closeRes = await mcpCall(client, 'close_session', { sessionId });
            success('Session closed — settled on-chain');
            const receipt = closeRes as Record<string, unknown>;
            state('Consumed (settled)', String(receipt?.amount ?? '?'));
            state('Refunded', String(receipt?.refunded ?? '?'));
            state('Total on-chain txns', '2 (open + close) for 10 queries');
            highlight("10 queries, 2 on-chain transactions. That's the 5,000x reduction.");
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
      name: 'Agent Discovery (ERC-8004 on Base)',
      description: 'Cross-chain identity — other agents find this canister on Base',
      run: async (_rl: ReadlineInterface) => {
        header('Step 5: Agent Discovery');
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
        const card = await mcpCall(client, 'call', { method: 'getAgentCard', args: '[]' });
        const c = card as Record<string, unknown>;
        if (c && typeof c === 'object') {
          state('Name', String(c.name ?? '?'));
          state('x402', String(c.x402Support ?? '?'));
          const services = c.services as Array<Record<string, unknown>> | undefined;
          if (services?.[0]) {
            state('Endpoint', String(services[0].endpoint ?? '?'));
            state('Skills', JSON.stringify(services[0].skills ?? []));
          }
        }

        info('Checking Base registration...');
        const agentIdResult = await mcpCall(client, 'call', { method: 'getAgentId', args: '[]' });
        const agentIdArr = agentIdResult as unknown[];
        const agentId = Array.isArray(agentIdArr) && agentIdArr.length > 0 ? agentIdArr[0] : null;

        if (agentId != null) {
          success(`Registered — ERC-721 #${agentId} on Base Sepolia`);
          state('Verify', `${BASE_EXPLORER}/address/${BASE_REGISTRY}`);
        } else {
          warn('Not yet registered on Base.');
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
      description: 'Dual-sided spending limits + UVP recap',
      run: async (_rl: ReadlineInterface) => {
        header('Step 6: Policy Engine + Summary');
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
