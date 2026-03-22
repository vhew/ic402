#!/usr/bin/env node

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { Secp256k1KeyIdentity } from '@icp-sdk/core/identity/secp256k1';
import { Ic402Client, exampleIdlFactory } from '@ic402/client';
import type { SessionHandle, PaymentReceipt } from '@ic402/client';
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

/** Serialize a value for JSON, handling bigint and Uint8Array. */
function serialize(value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString();
  if (value instanceof Uint8Array) return Buffer.from(value).toString('hex');
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
    identityPem: z.string().optional().describe('Path to a secp256k1 PEM file for signing (e.g. identity.pem)'),
    maxPerRequest: z.string().optional().describe('Max tokens per charge (e.g. "100000")'),
    maxPerDay: z.string().optional().describe('Max tokens per day'),
    maxTotal: z.string().optional().describe('Max tokens total across all calls'),
    maxSessionDeposit: z.string().optional().describe('Max session escrow deposit'),
  },
  async ({ canisterId, host, network, identityPem, maxPerRequest, maxPerDay, maxTotal, maxSessionDeposit }) => {
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
          // PKCS#8 DER: extract the 32-byte secp256k1 secret key
          const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
          const der = Buffer.from(b64, 'base64');
          // secp256k1 PKCS#8 key: the raw 32-byte key starts at offset 33
          // (after ASN.1 SEQUENCE + INTEGER + OID headers)
          const secretKey = der.slice(33, 65);
          if (secretKey.length === 32) {
            identity = Secp256k1KeyIdentity.fromSecretKey(new Uint8Array(secretKey));
          }
        }
      } catch (e) {
        // Log error but fall back to anonymous
        console.error('Identity load failed:', e instanceof Error ? e.message : String(e));
      }
    }

    agent = await HttpAgent.create({
      host,
      shouldFetchRootKey: host.includes('localhost'),
      identity: identity ?? undefined,
    });

    client = new Ic402Client({
      identity,
      network,
      autoPayment: true,
      budget: {
        maxPerRequest: maxPerRequest ? BigInt(maxPerRequest) : undefined,
        maxPerDay: maxPerDay ? BigInt(maxPerDay) : undefined,
        maxTotal: maxTotal ? BigInt(maxTotal) : undefined,
        maxSessionDeposit: maxSessionDeposit ? BigInt(maxSessionDeposit) : undefined,
      },
    });

    defaultCanisterId = canisterId;

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
    canisterId: z.string().optional().describe('Canister to call (defaults to configured canister)'),
  },
  async ({ query, canisterId }) => {
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID. Configure first or pass canisterId.');
    requireAgent();

    const actor = actorFactory(cid);
    const result = await actor.search(query, []) as Record<string, unknown>;

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
        content: [{ type: 'text' as const, text: JSON.stringify({ status: 'ok', results: result.ok }) }],
      };
    }

    return {
      content: [{ type: 'text' as const, text: JSON.stringify({ status: 'error', detail: serialize(result) }) }],
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
    canisterId: z.string().optional().describe('Canister to query (defaults to configured canister)'),
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
  'Open a streaming micropayment session with escrow deposit. Returns a session ID for subsequent calls.',
  {
    canisterId: z.string().optional().describe('Canister to open session on'),
    maxDeposit: z.string().optional().describe('Max deposit in token units (defaults to canister suggestion)'),
  },
  async ({ canisterId, maxDeposit }) => {
    const c = requireClient();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    const session = await c.openSession(
      cid,
      maxDeposit ? { maxDeposit: BigInt(maxDeposit) } : {},
      actorFactory,
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
    canisterId: z.string().optional().describe('Canister ID for canisterQuery delivery (defaults to configured canister)'),
  },
  async ({ delivery: deliveryJson, canisterId }) => {
    const parsed = JSON.parse(deliveryJson);
    const grant = parsed.grant;
    const del = parsed.delivery;

    let resultText: string;

    if ('inline' in del) {
      const buf = typeof del.inline === 'string'
        ? Buffer.from(del.inline, 'hex')
        : Buffer.from(del.inline);
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
      content: [{
        type: 'text' as const,
        text: JSON.stringify({
          contentId: grant?.contentRef?.id,
          mimeType: grant?.contentRef?.mimeType,
          content: resultText,
        }, null, 2),
      }],
    };
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
    canisterId: z.string().optional().describe('Canister to call (defaults to configured canister)'),
  },
  async ({ method, args, canisterId }) => {
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');
    requireAgent();

    const actor = actorFactory(cid);
    const parsedArgs = JSON.parse(args);
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
