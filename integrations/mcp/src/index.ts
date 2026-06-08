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

// ---------------------------------------------------------------------------
// Security config & spend tracking
//
// This server is driven by an LLM whose inputs may be influenced by untrusted
// web content (prompt injection) while it holds a controller identity capable
// of signing value transfers from the canister's own EVM address. Every
// money-moving or signing path is therefore capped, SSRF-guarded, and gated
// behind an explicit confirmation.
// ---------------------------------------------------------------------------

interface SecurityConfig {
  /** Allow http://localhost / 127.0.0.1 fetch targets (local development only). */
  localDev: boolean;
  /** Per-call maximum spend in atomic token units. Caps a single signed transfer. */
  perCallMaxAtomic: bigint;
  /** Cumulative session maximum spend in atomic token units across all signed transfers. */
  sessionMaxAtomic: bigint;
  /** Whether paid endpoints may auto-approve/pay without an explicit confirm. */
  autoPayment: boolean;
}

// Conservative defaults: a tiny per-call cap and a small cumulative cap. These
// force the LLM to either stay within a trivial budget or have the human raise
// the caps explicitly via the `configure` tool. USDC has 6 decimals, so
// 1_000_000 atomic = 1.00 USDC.
const DEFAULT_PER_CALL_MAX_ATOMIC = 1_000_000n; // 1.00 USDC
const DEFAULT_SESSION_MAX_ATOMIC = 5_000_000n; // 5.00 USDC

const securityConfig: SecurityConfig = {
  localDev: false,
  perCallMaxAtomic: DEFAULT_PER_CALL_MAX_ATOMIC,
  sessionMaxAtomic: DEFAULT_SESSION_MAX_ATOMIC,
  autoPayment: false,
};

/** Running total of atomic units spent (signed/approved) this server session. */
let sessionSpentAtomic = 0n;

/**
 * Enforce the per-call and cumulative session spend caps. Does NOT mutate the
 * running total — call commitSpend() only after the spend actually succeeds, or
 * pass commit:true to reserve up-front. Throws on violation.
 */
function spendGuard(amountAtomic: bigint, opts: { commit?: boolean } = {}): void {
  if (amountAtomic < 0n) {
    throw new Error(`Invalid negative amount: ${amountAtomic}`);
  }
  if (amountAtomic > securityConfig.perCallMaxAtomic) {
    throw new Error(
      `Amount ${amountAtomic} exceeds per-call cap ${securityConfig.perCallMaxAtomic} (atomic units). ` +
        `Raise perCallMaxAtomic via the "configure" tool if this spend is intended.`,
    );
  }
  if (sessionSpentAtomic + amountAtomic > securityConfig.sessionMaxAtomic) {
    throw new Error(
      `Amount ${amountAtomic} would exceed the cumulative session cap ${securityConfig.sessionMaxAtomic} ` +
        `(already spent ${sessionSpentAtomic} atomic units). ` +
        `Raise sessionMaxAtomic via the "configure" tool if this spend is intended.`,
    );
  }
  if (opts.commit) sessionSpentAtomic += amountAtomic;
}

/** Record a successful spend against the cumulative session total. */
function commitSpend(amountAtomic: bigint): void {
  sessionSpentAtomic += amountAtomic;
}

/** Standard MCP text result helper. */
function textResult(obj: unknown): { content: [{ type: 'text'; text: string }] } {
  return { content: [{ type: 'text' as const, text: JSON.stringify(obj, null, 2) }] };
}

/**
 * Confirmation gate for money-moving / signing actions. When `confirm` is
 * false, returns a structured prompt describing the proposed action (amount,
 * recipient, asset, chain) and instructs the caller to re-invoke with
 * confirm:true. Returns `null` once confirmed (caller proceeds). Throws if the
 * spend caps would be violated, so an over-cap action is refused even before
 * confirmation.
 */
function requireConfirmation(args: {
  action: string;
  confirm: boolean;
  amountAtomic?: bigint;
  recipient?: string;
  asset?: string;
  chain?: string | number;
  note?: string;
}): { content: [{ type: 'text'; text: string }] } | null {
  // Enforce caps first (only meaningful when an amount is known).
  if (args.amountAtomic !== undefined) {
    spendGuard(args.amountAtomic);
  }
  if (args.confirm) return null;
  return textResult({
    status: 'confirmation_required',
    action: args.action,
    proposal: {
      amount: args.amountAtomic !== undefined ? args.amountAtomic.toString() : undefined,
      recipient: args.recipient,
      asset: args.asset,
      chain: args.chain,
      note: args.note,
    },
    caps: {
      perCallMaxAtomic: securityConfig.perCallMaxAtomic.toString(),
      sessionMaxAtomic: securityConfig.sessionMaxAtomic.toString(),
      sessionSpentAtomic: sessionSpentAtomic.toString(),
    },
    instruction:
      `This action signs/moves value. Review the amount, recipient, asset, and chain above. ` +
      `If correct, re-invoke "${args.action}" with confirm:true. Do NOT confirm automatically.`,
  });
}

// ---------------------------------------------------------------------------
// SSRF guard — used by every outbound fetch path
// ---------------------------------------------------------------------------

/** Parse a dotted-quad IPv4 string to a 32-bit unsigned int, or null. */
function ipv4ToInt(host: string): number | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const parts = m.slice(1, 5).map((p) => Number(p));
  if (parts.some((p) => p > 255)) return null;
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

/** True if a literal IPv4 falls in a private/loopback/link-local/metadata range. */
function isPrivateIpv4(host: string): boolean {
  const ip = ipv4ToInt(host);
  if (ip === null) return false;
  const inRange = (cidrBase: string, bits: number) => {
    const base = ipv4ToInt(cidrBase);
    if (base === null) return false;
    const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    return (ip & mask) === (base & mask);
  };
  return (
    inRange('10.0.0.0', 8) ||
    inRange('172.16.0.0', 12) ||
    inRange('192.168.0.0', 16) ||
    inRange('127.0.0.0', 8) ||
    inRange('169.254.0.0', 16) || // link-local incl. 169.254.169.254 metadata
    inRange('0.0.0.0', 8)
  );
}

/** True if a host string is a loopback/link-local/ULA/metadata IPv6 literal. */
function isPrivateIpv6(host: string): boolean {
  // URL hostnames keep IPv6 in brackets; strip them.
  let h = host;
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  h = h.toLowerCase();
  if (h === '::1' || h === '::') return true;
  // Unique-local fc00::/7 → first byte 0xfc or 0xfd.
  if (h.startsWith('fc') || h.startsWith('fd')) return true;
  // Link-local fe80::/10.
  if (h.startsWith('fe8') || h.startsWith('fe9') || h.startsWith('fea') || h.startsWith('feb'))
    return true;
  // IPv4-mapped (::ffff:a.b.c.d) — extract and re-check.
  const mapped = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(h);
  if (mapped && isPrivateIpv4(mapped[1])) return true;
  return false;
}

/**
 * Validate an outbound fetch URL against SSRF. Requires https: (or
 * http://localhost|127.0.0.1 when securityConfig.localDev is set) and rejects
 * hosts that are literal/internal private, loopback, link-local, or metadata
 * addresses, plus obvious internal TLDs. Returns the parsed URL or throws.
 */
function validateFetchUrl(raw: string): URL {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`Invalid URL: ${raw}`);
  }
  const host = parsed.hostname.toLowerCase();
  const isLocalHost =
    host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]';

  if (parsed.protocol === 'http:') {
    if (!(securityConfig.localDev && isLocalHost)) {
      throw new Error(
        `Refusing http:// URL (${raw}). Only https:// is allowed; ` +
          `http://localhost is permitted only when localDev is enabled via "configure".`,
      );
    }
    return parsed;
  }
  if (parsed.protocol !== 'https:') {
    throw new Error(`Refusing non-http(s) URL scheme "${parsed.protocol}" (${raw}).`);
  }

  // https path — still block internal targets unless explicitly local-dev'd.
  if (isLocalHost && !securityConfig.localDev) {
    throw new Error(`Refusing localhost/loopback target (${raw}). Enable localDev to allow it.`);
  }
  // Literal IP checks.
  if (isPrivateIpv4(host) && !securityConfig.localDev) {
    throw new Error(`Refusing private/loopback/link-local/metadata IPv4 target (${raw}).`);
  }
  if (host === '169.254.169.254') {
    throw new Error(`Refusing cloud metadata endpoint (${raw}).`);
  }
  if (isPrivateIpv6(host) && !securityConfig.localDev) {
    throw new Error(`Refusing private/loopback/link-local IPv6 target (${raw}).`);
  }
  // Internal TLDs.
  if (host.endsWith('.local') || host.endsWith('.internal')) {
    throw new Error(`Refusing internal TLD host (${raw}).`);
  }
  return parsed;
}

/**
 * Validate an ICP canister principal text. Principal text is groups of
 * lowercase base32 [a-z0-9] separated by single dashes (e.g.
 * "rrkah-fqaaa-aaaaa-aaaaq-cai"). Reject anything with path/scheme/host
 * separators so it can't be smuggled into a URL.
 */
function validateCanisterId(id: string): string {
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(id)) {
    throw new Error(`Invalid canister id format: ${JSON.stringify(id)}`);
  }
  if (/[/@:.\\]/.test(id)) {
    throw new Error(`Canister id contains illegal characters: ${JSON.stringify(id)}`);
  }
  return id;
}

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
    autoPayment: z
      .boolean()
      .default(false)
      .describe(
        'Allow paid endpoints to auto-approve/pay (opt-in). Even when true, spends are capped and confirmation-gated. Default false.',
      ),
    localDev: z
      .boolean()
      .default(false)
      .describe(
        'Allow http://localhost and private/loopback fetch targets (local development only). Default false.',
      ),
    perCallMaxAtomic: z
      .string()
      .optional()
      .describe(
        'Per-call max spend in atomic token units (caps a single signed transfer). Defaults to a small value.',
      ),
    sessionMaxAtomic: z
      .string()
      .optional()
      .describe(
        'Cumulative session max spend in atomic token units across all signed transfers. Defaults to a small value.',
      ),
  },
  async ({
    canisterId,
    host,
    network,
    identityPem,
    ledger,
    autoPayment,
    localDev,
    perCallMaxAtomic,
    sessionMaxAtomic,
  }) => {
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

    // Apply security config (caps, localDev, opt-in auto-payment).
    securityConfig.localDev = localDev;
    securityConfig.autoPayment = autoPayment;
    if (perCallMaxAtomic !== undefined) {
      try {
        securityConfig.perCallMaxAtomic = BigInt(perCallMaxAtomic);
      } catch {
        throw new Error(`Invalid perCallMaxAtomic: ${perCallMaxAtomic}`);
      }
    }
    if (sessionMaxAtomic !== undefined) {
      try {
        securityConfig.sessionMaxAtomic = BigInt(sessionMaxAtomic);
      } catch {
        throw new Error(`Invalid sessionMaxAtomic: ${sessionMaxAtomic}`);
      }
    }

    client = new Ic402Client({
      canisterId,
      actorFactory,
      identity,
      network,
      // Auto-payment is opt-in. Even when enabled, the MCP tools enforce
      // per-call/cumulative caps and a confirmation gate around it.
      autoPayment: securityConfig.autoPayment,
      ledger: ledger ?? undefined,
      ledgerActorFactory: ledger ? ledgerActorFactory : undefined,
    });

    return {
      content: [
        {
          type: 'text' as const,
          text:
            `Connected to ${canisterId} at ${host} (network: ${network}, identity: ${identity ? identity.getPrincipal().toText() : 'anonymous'}). ` +
            `autoPayment=${securityConfig.autoPayment}, localDev=${securityConfig.localDev}, ` +
            `perCallMaxAtomic=${securityConfig.perCallMaxAtomic}, sessionMaxAtomic=${securityConfig.sessionMaxAtomic}.`,
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
    confirm: z
      .boolean()
      .default(false)
      .describe(
        'Authorize the escrow deposit. Returns the proposed deposit for review when false.',
      ),
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
    confirm,
  }) => {
    const c = requireClient();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    // H13: opening a session escrows/deposits funds — cap + confirm it.
    // Determine the deposit amount: explicit maxDeposit, else the canister's
    // suggested deposit from the session intent.
    let depositAtomic: bigint;
    if (maxDeposit) {
      depositAtomic = BigInt(maxDeposit);
    } else {
      const intent = (await actorFactory(cid).requestSession()) as Record<string, unknown>;
      const suggested = intent.suggestedDeposit ?? intent.maxDeposit ?? 0n;
      depositAtomic = BigInt(String(suggested));
    }
    const gate = requireConfirmation({
      action: 'open_session',
      confirm,
      amountAtomic: depositAtomic,
      recipient: evmRecipient ?? cid,
      asset: evmToken,
      chain: evmNetwork,
      note: 'Escrow deposit for a streaming micropayment session',
    });
    if (gate) return gate;

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

    // Record the escrowed deposit against the cumulative session cap.
    commitSpend(session.deposited);

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
  'Close a session — settles consumed amount on-chain and refunds the remainder. Returns a payment receipt. Settles value: pass confirm:true after reviewing the consumed amount.',
  {
    sessionId: z.string().describe('Session ID to close'),
    confirm: z
      .boolean()
      .default(false)
      .describe(
        'Authorize the on-chain settlement. Returns the consumed amount for review when false.',
      ),
  },
  async ({ sessionId, confirm }) => {
    const session = activeSessions.get(sessionId);
    if (!session) throw new Error(`No active session: ${sessionId}`);

    // H13: settling/broadcasting moves value — confirm the consumed amount.
    // The consumed amount was already counted against the cumulative cap at
    // deposit time, so we do not re-charge spendGuard here (no amountAtomic).
    if (!confirm) {
      return textResult({
        status: 'confirmation_required',
        action: 'close_session',
        proposal: {
          sessionId: session.id,
          consumed: session.consumed.toString(),
          remainingToRefund: session.remaining.toString(),
          note: 'Closing settles the consumed amount on-chain and refunds the remainder.',
        },
        instruction: 'Re-invoke "close_session" with confirm:true to settle.',
      });
    }

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
      // H11: SSRF guard — httpUrl comes from an untrusted ContentDelivery payload.
      const target = validateFetchUrl(String(del.httpUrl));
      const resp = await globalThis.fetch(target.toString());
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
      resultText = await resp.text();
    } else if ('assetCanister' in del) {
      // H11: validate the canister id and build the URL via the URL API (no
      // string concatenation of untrusted fields into host/path).
      const assetId = validateCanisterId(String(del.assetCanister.canisterId));
      const url = new URL(`https://${assetId}.icp0.io`);
      // Treat the supplied path as a path only; URL() resolves/normalizes it
      // and cannot change the origin we constructed above.
      url.pathname = String(del.assetCanister.path ?? '/');
      validateFetchUrl(url.toString());
      const resp = await globalThis.fetch(url.toString());
      if (!resp.ok) throw new Error(`Asset fetch ${resp.status}: ${resp.statusText}`);
      resultText = await resp.text();
    } else if ('canisterQuery' in del) {
      const cid = validateCanisterId(canisterId ?? defaultCanisterId ?? '');
      requireAgent();
      const actor = actorFactory(cid);
      const { method, chunkCount } = del.canisterQuery;
      // H11: restrict to a fixed allowlist of content-chunk query methods.
      const CONTENT_QUERY_METHODS = new Set(['getChunk', 'getContent']);
      if (!CONTENT_QUERY_METHODS.has(String(method))) {
        throw new Error(
          `Disallowed canisterQuery method "${method}". Allowed: ${[...CONTENT_QUERY_METHODS].join(', ')}.`,
        );
      }
      const chunks: string[] = [];
      for (let i = 0; i < Number(chunkCount); i++) {
        const chunk = await actor[method as string](grant, i);
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
  'Fetch from an x402-gated URL. Full flow: probe URL → canister signs payment → retry with payment header. Signing moves value: pass confirm:true to authorize after reviewing the proposed amount/recipient.',
  {
    url: z.string().describe('The x402-gated URL to fetch'),
    chainId: z.number().default(84532).describe('EVM chain ID (default: Base Sepolia 84532)'),
    canisterId: z.string().optional().describe('Canister to sign with (defaults to configured)'),
    confirm: z
      .boolean()
      .default(false)
      .describe('Authorize signing the proposed payment. Probe-only (no signing) when false.'),
  },
  async ({ url, chainId, canisterId, confirm }) => {
    requireClient();
    requireAgent();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    // C2: SSRF guard — the URL is attacker-influenceable. Validate before any fetch.
    let target: URL;
    try {
      target = validateFetchUrl(url);
    } catch (e) {
      return errorResult(e);
    }
    const safeUrl = target.toString();

    try {
      // 1. Probe (client-side HTTP, with 15s timeout)
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 15_000);
      let probeResult;
      try {
        probeResult = await probeX402(safeUrl, chainId, { signal: controller.signal });
      } finally {
        clearTimeout(timeout);
      }
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
      const optionChainId = parseInt(opt.network.replace('eip155:', ''), 10) || chainId;

      // C2 + H13: cap + confirmation gate BEFORE signing. The canister signs
      // from its own EVM address, so an attacker-chosen recipient/amount must
      // be capped and explicitly confirmed by the human.
      const gate = requireConfirmation({
        action: 'fetch_x402',
        confirm,
        amountAtomic: opt.amount,
        recipient: opt.recipient,
        asset: opt.asset,
        chain: optionChainId,
        note: `Signing an x402 payment for ${safeUrl}`,
      });
      if (gate) return gate;

      // 2. Sign via canister (direct actor call)
      const actor = actorFactory(cid);
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

      // Record the spend against the cumulative session cap now that signing
      // succeeded.
      commitSpend(opt.amount);

      // 3. Retry with payment header (client-side HTTP, 15s timeout)
      const retryController = new AbortController();
      const retryTimeout = setTimeout(() => retryController.abort(), 15_000);
      let paidResponse: Response;
      try {
        paidResponse = await globalThis.fetch(safeUrl, {
          headers: { 'X-Payment': signed.header, 'Payment-Signature': signed.header },
          signal: retryController.signal,
        });
      } finally {
        clearTimeout(retryTimeout);
      }
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
  'Register the canister as an ERC-8004 agent on-chain. Full flow: get nonce+gas → canister signs → broadcast → poll receipt. Broadcasts a signed tx (spends gas): pass confirm:true to authorize.',
  {
    chainId: z.number().default(84532).describe('EVM chain ID (default: Base Sepolia 84532)'),
    canisterId: z.string().optional().describe('Canister to register (defaults to configured)'),
    rpcUrl: z.string().optional().describe('Custom EVM RPC URL (defaults to public RPC)'),
    confirm: z
      .boolean()
      .default(false)
      .describe('Authorize signing and broadcasting the registration tx (spends gas).'),
  },
  async ({ chainId, canisterId, rpcUrl, confirm }) => {
    const c = requireClient();
    const cid = canisterId ?? defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');

    // H13: register_agent signs + broadcasts a tx from the canister's EVM
    // address (spends native gas). Validate any custom RPC URL against SSRF
    // and require explicit confirmation. No USDC amount, so no spend cap.
    if (rpcUrl !== undefined) {
      try {
        validateFetchUrl(rpcUrl);
      } catch (e) {
        return errorResult(e);
      }
    }
    const gate = requireConfirmation({
      action: 'register_agent',
      confirm,
      chain: chainId,
      note: 'Signs and broadcasts an ERC-8004 registration tx (spends native gas).',
    });
    if (gate) return gate;

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
  'Submit a paid service request. If the service demands payment, you must opt into autoPayment (via "configure") and pass confirm:true after reviewing the amount/recipient. Returns a job ID for polling.',
  {
    serviceId: z.string().describe('Service ID to request'),
    params: z.string().default('').describe('Job parameters (UTF-8 string, sent as bytes)'),
    confirm: z
      .boolean()
      .default(false)
      .describe('Authorize auto-payment of the amount the canister demands.'),
  },
  async ({ serviceId, params, confirm }) => {
    const c = requireClient();
    const cid = defaultCanisterId;
    if (!cid) throw new Error('No canister ID.');
    const encoded = new TextEncoder().encode(params);

    try {
      // H12: dry-run with no payment signature to discover whether payment is
      // required and, if so, how much / to whom — BEFORE auto-paying.
      const actor = actorFactory(cid);
      const probe = (await actor.submitServiceRequest(
        serviceId,
        Array.from(encoded),
        [],
      )) as Record<string, unknown>;

      // Free / already-accepted path: no payment needed.
      if (probe && typeof probe === 'object' && 'ok' in probe) {
        const ok = probe.ok as { jobId: string };
        return textResult({ status: 'ok', jobId: ok.jobId });
      }
      if (probe && typeof probe === 'object' && 'error' in probe) {
        return errorResult(new Ic402Error('sign_failed', String(probe.error)));
      }

      if (probe && typeof probe === 'object' && 'paymentRequired' in probe) {
        // H12: auto-payment must be opt-in.
        if (!securityConfig.autoPayment) {
          return textResult({
            status: 'payment_required',
            serviceId,
            requirements: serialize(probe.paymentRequired),
            instruction:
              'This service requires payment. Auto-payment is disabled. Re-run "configure" with autoPayment:true to enable it, then re-invoke with confirm:true.',
          });
        }

        const reqs = probe.paymentRequired as Array<Record<string, unknown>>;
        const req = Array.isArray(reqs) && reqs.length > 0 ? reqs[0] : undefined;
        const amountAtomic = req?.amount !== undefined ? BigInt(String(req.amount)) : 0n;
        const recipient = req?.recipient !== undefined ? String(req.recipient) : cid;
        const asset = req?.token !== undefined ? String(req.token) : undefined;

        // H12 + H13: cap + confirmation before any auto-approval/payment.
        const gate = requireConfirmation({
          action: 'submit_request',
          confirm,
          amountAtomic,
          recipient,
          asset,
          note: `Auto-pay for service "${serviceId}" on canister ${cid}`,
        });
        if (gate) return gate;

        // Confirmed and within caps — let the client perform approve + retry.
        const result = await c.submitServiceRequest(serviceId, encoded);
        commitSpend(amountAtomic);
        return textResult({
          status: 'ok',
          jobId: result.jobId,
          paidAmount: amountAtomic.toString(),
        });
      }

      return errorResult(
        new Ic402Error('unknown', `Unexpected response: ${JSON.stringify(serialize(probe))}`),
      );
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

// C3: explicit allowlist of READ-ONLY / query methods callable via the generic
// `call` tool. Every entry here is a `query` (or otherwise non-state-changing
// read) in the IDL. Anything not listed is rejected; the LLM must use the
// dedicated, capped, confirmation-gated tool for state-changing/signing calls.
const READONLY_CALL_ALLOWLIST = new Set<string>([
  'listContent',
  'getChunk',
  'getAgentCard',
  'getAgentId',
  'verifyGrant',
  'listServices',
  'getJobStatus',
  'getJob',
  'getJobResult',
  'keccak256',
]);

// Substrings that must NEVER be reachable through the generic `call` path —
// these denote signing/admin/value-moving methods with dedicated tools.
const CALL_BLOCK_SUBSTRINGS = [
  'sign',
  'set',
  'submit',
  'open',
  'close',
  'transfer',
  'register',
  'pay',
  'approve',
  'policy',
  'upload',
  'delete',
  'claim',
  'confirm',
  'dispute',
  'enable',
  'disable',
  'end',
];

function isCallMethodAllowed(method: string): { ok: boolean; reason?: string } {
  const lower = method.toLowerCase();
  // Hard block on any signing/admin/value-moving name, even if it would
  // otherwise match a read-only prefix.
  for (const bad of CALL_BLOCK_SUBSTRINGS) {
    if (lower.includes(bad)) {
      return {
        ok: false,
        reason: `Method "${method}" looks state-changing/signing (contains "${bad}"). Use the dedicated tool for this action.`,
      };
    }
  }
  if (READONLY_CALL_ALLOWLIST.has(method)) return { ok: true };
  // Fall back to read-only name prefixes for forward-compat with new query
  // getters, but only after the blocklist above has cleared the name.
  if (/^(get|list|fetch|is)[A-Z]/.test(method) || /^(get|list|fetch|is)$/.test(method)) {
    return { ok: true };
  }
  return {
    ok: false,
    reason: `Method "${method}" is not on the read-only allowlist. The generic "call" tool only permits query/read methods; use a dedicated tool for state-changing or signing operations.`,
  };
}

server.tool(
  'call',
  'Call a READ-ONLY/query method on the configured canister (allowlisted getters only). State-changing, signing, payment, and admin methods are blocked here — use their dedicated tools.',
  {
    method: z.string().describe('Canister query/read method name (allowlisted getters only)'),
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

    // C3: restrict the generic call path to read-only / query methods.
    const verdict = isCallMethodAllowed(method);
    if (!verdict.ok) {
      throw new Error(verdict.reason);
    }

    const actor = actorFactory(cid);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let parsedArgs: any;
    try {
      parsedArgs = JSON.parse(args);
    } catch {
      throw new Error('Invalid JSON in args parameter');
    }
    if (typeof actor[method] !== 'function') {
      throw new Error(`Unknown method "${method}" on canister ${cid}.`);
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
