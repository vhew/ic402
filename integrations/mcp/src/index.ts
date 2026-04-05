#!/usr/bin/env node

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { Secp256k1KeyIdentity } from '@icp-sdk/core/identity/secp256k1';
import { Ed25519KeyIdentity } from '@icp-sdk/core/identity';
import { Ic402Client, Ic402Error, probeX402, exampleIdlFactory } from '@ic402/client';
import type { SessionHandle, PaymentReceipt, VoucherSigner } from '@ic402/client';
import { z } from 'zod';
import { readFileSync } from 'node:fs';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let client: Ic402Client | null = null;
let agent: HttpAgent | null = null;
let defaultCanisterId: string | null = null;
const activeSessions = new Map<string, SessionHandle>();

function requireClient(): Ic402Client {
  if (!client) throw new Error('Not configured. Call the "configure" tool first.');
  return client;
}

function requireAgent(): HttpAgent {
  if (!agent) throw new Error('Not configured. Call the "configure" tool first.');
  return agent;
}

function actorFactory(canisterId: string) {
  return Actor.createActor(exampleIdlFactory, {
    agent: requireAgent(),
    canisterId,
  });
}

// Minimal ICRC-2 ledger IDL for auto-payment (approve + transfer_from)
import { IDL } from '@icp-sdk/core/candid';

const icrc2LedgerIdl = () => {
  const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });
  return IDL.Service({
    icrc2_approve: IDL.Func(
      [
        IDL.Record({
          spender: Account,
          amount: IDL.Nat,
          fee: IDL.Opt(IDL.Nat),
          memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
          from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
          created_at_time: IDL.Opt(IDL.Nat64),
          expected_allowance: IDL.Opt(IDL.Nat),
          expires_at: IDL.Opt(IDL.Nat64),
        }),
      ],
      [IDL.Variant({ Ok: IDL.Nat, Err: IDL.Text })],
      [],
    ),
  });
};

function ledgerActorFactory(ledgerCanisterId: string) {
  return Actor.createActor(icrc2LedgerIdl, {
    agent: requireAgent(),
    canisterId: ledgerCanisterId,
  });
}

/** Serialize a value for JSON, handling bigint, Uint8Array, and Error instances. */
function serialize(value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString();
  if (value instanceof Uint8Array) return Buffer.from(value).toString('hex');
  if (value instanceof Ic402Error) {
    return { kind: value.kind, message: value.message, retryable: value.retryable };
  }
  if (value instanceof Error) {
    return { message: value.message };
  }
  if (Array.isArray(value)) return value.map(serialize);
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = serialize(v);
    }
    return out;
  }
  return value;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = new McpServer({
  name: 'ic402',
  version: '0.1.0',
});

// ---------------------------------------------------------------------------
// Tool: configure
// ---------------------------------------------------------------------------

server.tool(
  'configure',
  'Connect to an ic402-enabled ICP canister. Must be called before any other tool.',
  {
    canisterId: z.string().describe('Principal of the canister to interact with'),
    host: z.string().default('http://localhost:4944').describe('ICP replica URL'),
    network: z.string().default('icp:1').describe('CAIP-2 network identifier'),
    identityPem: z
      .string()
      .optional()
      .describe('Path to a secp256k1 PEM file for signing (e.g. identity.pem)'),
    ledger: z
      .string()
      .optional()
      .describe('ICRC-2 ledger canister ID for auto-payment (e.g. ckUSDC)'),
  },
  async ({ canisterId, host, network, identityPem, ledger }) => {
    // Load identity from PEM if provided, otherwise check env, otherwise anonymous.
    // icp identity export outputs PKCS#8 ("BEGIN PRIVATE KEY"), but
    // Secp256k1KeyIdentity.fromPem expects SEC1 ("BEGIN EC PRIVATE KEY").
    // We handle both by extracting the raw 32-byte secret key from PKCS#8.
    let identity: Secp256k1KeyIdentity | null = null;
    const pemPath = identityPem || process.env.ICP_IDENTITY_PEM;
    if (pemPath) {
      try {
        const pem = readFileSync(pemPath, 'utf-8');
        if (pem.includes('BEGIN EC PRIVATE KEY')) {
          identity = Secp256k1KeyIdentity.fromPem(pem);
        } else if (pem.includes('BEGIN PRIVATE KEY')) {
          // H-5: PKCS#8 DER — validate structure before extracting secp256k1 secret key.
          const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
          const der = Buffer.from(b64, 'base64');
          // Validate minimum length for secp256k1 PKCS#8 (header + 32-byte key)
          if (der.length < 65) {
            throw new Error('PKCS#8 DER too short: expected at least 65 bytes');
          }
          // Validate secp256k1 OID (1.3.132.0.10) is present in the DER
          const secp256k1Oid = Buffer.from([0x2b, 0x81, 0x04, 0x00, 0x0a]);
          if (!der.includes(secp256k1Oid)) {
            throw new Error(
              'PKCS#8 key does not contain secp256k1 OID — expected secp256k1 identity',
            );
          }
          const secretKey = der.slice(33, 65);
          if (secretKey.length !== 32) {
            throw new Error(`Expected 32-byte secret key, got ${secretKey.length}`);
          }
          identity = Secp256k1KeyIdentity.fromSecretKey(new Uint8Array(secretKey));
        } else {
          throw new Error('Unsupported PEM format: expected EC PRIVATE KEY or PRIVATE KEY');
        }
      } catch (e) {
        // Surface error clearly — do NOT silently fall back to anonymous for PEM files
        const msg = e instanceof Error ? e.message : String(e);
        console.error('Identity load failed:', msg);
        throw new Error(`Failed to load identity from ${pemPath}: ${msg}`);
      }
    }

    agent = await HttpAgent.create({
      host,
      shouldFetchRootKey: host.includes('localhost'),
      identity: identity ?? undefined,
    });

    defaultCanisterId = canisterId;

    client = new Ic402Client({
      canisterId,
      actorFactory,
      identity,
      network,
      autoPayment: true,
      ledger: ledger ?? undefined,
      ledgerActorFactory: ledger ? ledgerActorFactory : undefined,
    });

    return {
      content: [
        {
          type: 'text' as const,
          text: `Connected to ${canisterId} at ${host} (network: ${network}, identity: ${identity ? identity.getPrincipal().toText() : 'anonymous'})`,
        },
      ],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: search
// ---------------------------------------------------------------------------

server.tool(
  'search',
  'Call the search endpoint on an ic402 canister (x402 charge flow). Returns results or a payment requirement.',
  {
    query: z.string().describe('Search query text'),
    canisterId: z
      .string()
      .optional()
      .describe('Canister to call (defaults to configured canister)'),
  },
  async ({ query, canisterId }) => {
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID. Configure first or pass canisterId.');
    requireAgent();

    const actor = actorFactory(cid);
    const result = (await actor.search(query, [])) as Record<string, unknown>;

    if ('paymentRequired' in result) {
      const requirements = result.paymentRequired;
      return {
        content: [
          {
            type: 'text' as const,
            text: JSON.stringify(
              { status: 'payment_required', requirements: serialize(requirements) },
              null,
              2,
            ),
          },
        ],
      };
    }

    if ('ok' in result) {
      return {
        content: [
          { type: 'text' as const, text: JSON.stringify({ status: 'ok', results: result.ok }) },
        ],
      };
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: JSON.stringify({ status: 'error', detail: serialize(result) }),
        },
      ],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: request_session
// ---------------------------------------------------------------------------

server.tool(
  'request_session',
  'Request a session intent from a canister — returns pricing (suggestedDeposit, costPerCall) without opening a session.',
  {
    canisterId: z
      .string()
      .optional()
      .describe('Canister to query (defaults to configured canister)'),
  },
  async ({ canisterId }) => {
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');
    requireAgent();

    const actor = actorFactory(cid);
    const intent = await actor.requestSession();

    return {
      content: [{ type: 'text' as const, text: JSON.stringify(serialize(intent), null, 2) }],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: open_session
// ---------------------------------------------------------------------------

server.tool(
  'open_session',
  'Open a streaming micropayment session. For ICP: uses ICRC-2 escrow. For EVM: pass evmTxHash proving the USDC deposit.',
  {
    canisterId: z.string().optional().describe('Canister to open session on'),
    maxDeposit: z
      .string()
      .optional()
      .describe('Max deposit in token units (defaults to canister suggestion)'),
    evmTxHash: z
      .string()
      .regex(/^0x[0-9a-fA-F]{64}$/, 'Must be a 0x-prefixed 32-byte hex hash')
      .optional()
      .describe('EVM tx hash proving USDC deposit (for EVM sessions)'),
    evmNetwork: z
      .string()
      .regex(/^eip155:\d+$/, 'Must be CAIP-2 format: eip155:<chainId>')
      .optional()
      .describe('CAIP-2 network, e.g., "eip155:84532" (for EVM sessions)'),
    evmSender: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/, 'Must be a 0x-prefixed 20-byte EVM address')
      .optional()
      .describe('Payer EVM address for refund (for EVM sessions)'),
    evmToken: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/, 'Must be a 0x-prefixed 20-byte EVM address')
      .optional()
      .describe('ERC-20 token contract address (for EVM sessions)'),
    evmRecipient: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/, 'Must be a 0x-prefixed 20-byte EVM address')
      .optional()
      .describe('Canister EVM address for settlement (for EVM sessions)'),
    authorization: z
      .object({
        from: z.string(),
        to: z.string(),
        value: z.number(),
        validAfter: z.number(),
        validBefore: z.number(),
        nonce: z.array(z.number()),
        v: z.number(),
        r: z.array(z.number()),
        s: z.array(z.number()),
      })
      .optional()
      .describe('EIP-3009 authorization for EVM session deposit'),
  },
  async ({
    canisterId,
    maxDeposit,
    evmTxHash,
    evmNetwork,
    evmSender,
    evmToken,
    evmRecipient,
    authorization,
  }) => {
    const c = requireClient();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    const prefs: Record<string, unknown> = {};
    if (maxDeposit) prefs.maxDeposit = BigInt(maxDeposit);
    if (evmTxHash) prefs.evmTxHash = evmTxHash;
    // If authorization is provided, this is an EVM session — set evmTxHash to trigger EVM path
    if (authorization && !evmTxHash) prefs.evmTxHash = 'eip3009-deposit';
    if (evmNetwork) prefs.evmNetwork = evmNetwork;
    if (evmSender) prefs.evmSender = evmSender;
    if (evmToken) prefs.evmToken = evmToken;
    if (evmRecipient) prefs.evmRecipient = evmRecipient;
    if (authorization) prefs.authorization = authorization;

    // Generate Ed25519 keypair for voucher signing
    const voucherIdentity = Ed25519KeyIdentity.generate();
    const voucherSigner: VoucherSigner = {
      async sign(payload: Uint8Array): Promise<Uint8Array> {
        return new Uint8Array(await voucherIdentity.sign(payload));
      },
      async getPublicKey(): Promise<Uint8Array> {
        return new Uint8Array(voucherIdentity.getPublicKey().toRaw());
      },
    };

    const session = await c.openSession(
      prefs,
      voucherSigner,
      cid !== defaultCanisterId ? cid : undefined,
    );

    activeSessions.set(session.id, session);

    return {
      content: [
        {
          type: 'text' as const,
          text: JSON.stringify(
            {
              sessionId: session.id,
              deposited: session.deposited.toString(),
              remaining: session.remaining.toString(),
            },
            null,
            2,
          ),
        },
      ],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: session_query
// ---------------------------------------------------------------------------

server.tool(
  'session_query',
  'Send a query through an open session (auto-signs a voucher). Each call consumes costPerCall from the deposit.',
  {
    sessionId: z.string().describe('Session ID from open_session'),
    question: z.string().describe('Question or query text'),
  },
  async ({ sessionId, question }) => {
    const session = activeSessions.get(sessionId);
    if (!session) throw new Error(`No active session: ${sessionId}`);

    const answer = await session.call('sessionQuery', [question]);

    return {
      content: [
        {
          type: 'text' as const,
          text: JSON.stringify({
            answer,
            consumed: session.consumed.toString(),
            remaining: session.remaining.toString(),
          }),
        },
      ],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: get_session
// ---------------------------------------------------------------------------

server.tool(
  'get_session',
  'Get the current state of an active session (consumed, remaining, voucher count).',
  {
    sessionId: z.string().describe('Session ID'),
  },
  async ({ sessionId }) => {
    const session = activeSessions.get(sessionId);
    if (!session) throw new Error(`No active session: ${sessionId}`);

    return {
      content: [
        {
          type: 'text' as const,
          text: JSON.stringify({
            sessionId: session.id,
            deposited: session.deposited.toString(),
            consumed: session.consumed.toString(),
            remaining: session.remaining.toString(),
          }),
        },
      ],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: close_session
// ---------------------------------------------------------------------------

server.tool(
  'close_session',
  'Close a session — settles consumed amount on-chain and refunds the remainder. Returns a payment receipt.',
  {
    sessionId: z.string().describe('Session ID to close'),
  },
  async ({ sessionId }) => {
    const session = activeSessions.get(sessionId);
    if (!session) throw new Error(`No active session: ${sessionId}`);

    const receipt: PaymentReceipt = await session.close();
    activeSessions.delete(sessionId);

    return {
      content: [{ type: 'text' as const, text: JSON.stringify(serialize(receipt), null, 2) }],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: list_sessions
// ---------------------------------------------------------------------------

server.tool(
  'list_sessions',
  'List all active sessions managed by this MCP server.',
  {},
  async () => {
    const sessions = Array.from(activeSessions.entries()).map(([id, s]) => ({
      sessionId: id,
      deposited: s.deposited.toString(),
      consumed: s.consumed.toString(),
      remaining: s.remaining.toString(),
    }));

    return {
      content: [{ type: 'text' as const, text: JSON.stringify(sessions, null, 2) }],
    };
  },
);

// ---------------------------------------------------------------------------
// Tool: fetch_content
// ---------------------------------------------------------------------------

server.tool(
  'fetch_content',
  'Fetch content from a ContentDelivery response. Supports inline, httpUrl, assetCanister, and canisterQuery delivery methods.',
  {
    delivery: z.string().describe('ContentDelivery JSON string (as returned by content endpoints)'),
    canisterId: z
      .string()
      .optional()
      .describe('Canister ID for canisterQuery delivery (defaults to configured canister)'),
  },
  async ({ delivery: deliveryJson, canisterId }) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let parsed: any;
    try {
      parsed = JSON.parse(deliveryJson);
    } catch {
      throw new Error('Invalid JSON in delivery parameter');
    }
    const grant = parsed.grant;
    const del = parsed.delivery;

    let resultText: string;

    if ('inline' in del) {
      const buf =
        typeof del.inline === 'string' ? Buffer.from(del.inline, 'hex') : Buffer.from(del.inline);
      resultText = buf.toString('utf-8');
    } else if ('httpUrl' in del) {
      const resp = await globalThis.fetch(del.httpUrl);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
      resultText = await resp.text();
    } else if ('assetCanister' in del) {
      const url = `https://${del.assetCanister.canisterId}.icp0.io${del.assetCanister.path}`;
      const resp = await globalThis.fetch(url);
      if (!resp.ok) throw new Error(`Asset fetch ${resp.status}: ${resp.statusText}`);
      resultText = await resp.text();
    } else if ('canisterQuery' in del) {
      const cid = canisterId ?? defaultCanisterId;
      if (!cid) throw new Error('canisterId required for canisterQuery delivery');
      requireAgent();
      const actor = actorFactory(cid);
      const { method, chunkCount } = del.canisterQuery;
      const chunks: string[] = [];
      for (let i = 0; i < Number(chunkCount); i++) {
        const chunk = await actor[method](grant, i);
        chunks.push(Buffer.from(chunk as ArrayBuffer).toString('utf-8'));
      }
      resultText = chunks.join('');
    } else {
      throw new Error('Unknown delivery method in ContentDelivery');
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: JSON.stringify(
            {
              contentId: grant?.contentRef?.id,
              mimeType: grant?.contentRef?.mimeType,
              content: resultText,
            },
            null,
            2,
          ),
        },
      ],
    };
  },
);

/** Serialize an Ic402Error (or any error) into a structured result the demo can render. */
function errorResult(e: unknown): { content: [{ type: 'text'; text: string }] } {
  if (e instanceof Ic402Error) {
    return {
      content: [
        {
          type: 'text' as const,
          text: JSON.stringify(
            {
              status: 'error',
              error: { kind: e.kind, message: e.message, retryable: e.retryable },
            },
            null,
            2,
          ),
        },
      ],
    };
  }
  const msg = e instanceof Error ? e.message : String(e);
  return {
    content: [
      {
        type: 'text' as const,
        text: JSON.stringify(
          {
            status: 'error',
            error: { kind: 'unknown', message: msg, retryable: false },
          },
          null,
          2,
        ),
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// Tool: fetch_x402
// ---------------------------------------------------------------------------

server.tool(
  'fetch_x402',
  'Fetch from an x402-gated URL. Full flow: probe URL → canister signs payment → retry with payment header.',
  {
    url: z.string().describe('The x402-gated URL to fetch'),
    chainId: z.number().default(84532).describe('EVM chain ID (default: Base Sepolia 84532)'),
    canisterId: z.string().optional().describe('Canister to sign with (defaults to configured)'),
  },
  async ({ url, chainId, canisterId }) => {
    requireClient();
    requireAgent();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    try {
      // 1. Probe (client-side HTTP)
      const probeResult = await probeX402(url, chainId);
      if (probeResult.status === 'free') {
        return {
          content: [
            { type: 'text' as const, text: JSON.stringify(serialize(probeResult), null, 2) },
          ],
        };
      }
      if (probeResult.status === 'error') {
        return {
          content: [
            { type: 'text' as const, text: JSON.stringify(serialize(probeResult), null, 2) },
          ],
        };
      }
      const opt = probeResult.paymentOption;

      // 2. Sign via canister (direct actor call)
      const actor = actorFactory(cid);
      const optionChainId = parseInt(opt.network.replace('eip155:', ''), 10) || chainId;
      const signResult = (await actor.signX402Payment(
        optionChainId,
        opt.asset,
        opt.recipient,
        opt.amount,
        opt.tokenName,
        opt.tokenVersion,
      )) as Record<string, unknown>;
      if (!signResult || 'err' in signResult) {
        return errorResult(
          new Ic402Error('sign_failed', String(signResult?.err ?? 'Signing failed')),
        );
      }
      const signed = signResult.ok as { header: string; paidAmount: bigint };

      // 3. Retry with payment header (client-side HTTP)
      const headers: Record<string, string> = {
        'X-Payment': signed.header,
        'Payment-Signature': signed.header,
      };
      const paidResponse = await globalThis.fetch(url, { headers });
      const body = await paidResponse.text();

      if (paidResponse.ok) {
        return {
          content: [
            {
              type: 'text' as const,
              text: JSON.stringify(
                {
                  status: 'ok',
                  code: paidResponse.status,
                  body,
                  paidAmount: serialize(signed.paidAmount),
                },
                null,
                2,
              ),
            },
          ],
        };
      }
      if (paidResponse.status === 402) {
        return errorResult(new Ic402Error('settlement_failed', body.slice(0, 200)));
      }
      return errorResult(
        new Ic402Error('http_error', `HTTP ${paidResponse.status}: ${body.slice(0, 200)}`),
      );
    } catch (e) {
      return errorResult(e);
    }
  },
);

// ---------------------------------------------------------------------------
// Tool: register_agent
// ---------------------------------------------------------------------------

server.tool(
  'register_agent',
  'Register the canister as an ERC-8004 agent on-chain. Full flow: get nonce+gas → canister signs → broadcast → poll receipt.',
  {
    chainId: z.number().default(84532).describe('EVM chain ID (default: Base Sepolia 84532)'),
    canisterId: z.string().optional().describe('Canister to register (defaults to configured)'),
    rpcUrl: z.string().optional().describe('Custom EVM RPC URL (defaults to public RPC)'),
  },
  async ({ chainId, canisterId, rpcUrl }) => {
    const c = requireClient();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    try {
      const result = await c.registerAgent(rpcUrl, chainId);
      return {
        content: [
          {
            type: 'text' as const,
            text: JSON.stringify(
              {
                status: 'ok',
                tokenId: result.tokenId?.toString() ?? null,
                txHash: result.txHash,
              },
              null,
              2,
            ),
          },
        ],
      };
    } catch (e) {
      return errorResult(e);
    }
  },
);

// ---------------------------------------------------------------------------
// Tool: list_services
// ---------------------------------------------------------------------------

server.tool('list_services', 'List available paid services from the canister.', {}, async () => {
  const c = requireClient();
  const services = await c.listServices();
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(serialize(services), null, 2) }],
  };
});

// ---------------------------------------------------------------------------
// Tool: submit_request
// ---------------------------------------------------------------------------

server.tool(
  'submit_request',
  'Submit a paid service request. Handles x402 payment automatically. Returns a job ID for polling.',
  {
    serviceId: z.string().describe('Service ID to request'),
    params: z.string().default('').describe('Job parameters (UTF-8 string, sent as bytes)'),
  },
  async ({ serviceId, params }) => {
    const c = requireClient();
    try {
      const result = await c.submitServiceRequest(serviceId, new TextEncoder().encode(params));
      return {
        content: [
          {
            type: 'text' as const,
            text: JSON.stringify({ status: 'ok', jobId: result.jobId }, null, 2),
          },
        ],
      };
    } catch (e) {
      return errorResult(e);
    }
  },
);

// ---------------------------------------------------------------------------
// Tool: get_job_result
// ---------------------------------------------------------------------------

server.tool(
  'get_job_result',
  'Poll for a job result. Waits until the job completes or times out.',
  {
    jobId: z.string().describe('Job ID from submit_request'),
    maxAttempts: z.number().default(15).describe('Max poll attempts'),
  },
  async ({ jobId, maxAttempts }) => {
    const c = requireClient();
    try {
      const job = await c.pollJobResult(jobId, maxAttempts);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify(serialize(job), null, 2) }],
      };
    } catch (e) {
      return errorResult(e);
    }
  },
);

// ---------------------------------------------------------------------------
// Tool: dispute_job
// ---------------------------------------------------------------------------

server.tool(
  'dispute_job',
  'Dispute a job result (for BuyerConfirm verification services).',
  {
    jobId: z.string().describe('Job ID to dispute'),
    reason: z.string().describe('Reason for dispute'),
  },
  async ({ jobId, reason }) => {
    const c = requireClient();
    try {
      await c.disputeJob(jobId, reason);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({ status: 'ok' }, null, 2) }],
      };
    } catch (e) {
      return errorResult(e);
    }
  },
);

// ---------------------------------------------------------------------------
// Tool: call
// ---------------------------------------------------------------------------

server.tool(
  'call',
  'Call any method on the configured canister. For paid endpoints, returns the payment requirement.',
  {
    method: z.string().describe('Canister method name'),
    args: z.string().default('[]').describe('JSON array of arguments'),
    canisterId: z
      .string()
      .optional()
      .describe('Canister to call (defaults to configured canister)'),
  },
  async ({ method, args, canisterId }) => {
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');
    requireAgent();

    const actor = actorFactory(cid);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let parsedArgs: any;
    try {
      parsedArgs = JSON.parse(args);
    } catch {
      throw new Error('Invalid JSON in args parameter');
    }
    const result = await actor[method](...(Array.isArray(parsedArgs) ? parsedArgs : [parsedArgs]));

    return {
      content: [{ type: 'text' as const, text: JSON.stringify(serialize(result), null, 2) }],
    };
  },
);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error('ic402 MCP server failed:', err);
  process.exit(1);
});
