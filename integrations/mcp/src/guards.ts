/**
 * Spend caps, config-escalation guard, dangerous-tool gate, and safe amount parsing
 * for the ic402 MCP server.
 *
 * Extracted from index.ts so the security-critical decisions are pure and unit-testable
 * (see test/mcp-guards.test.ts). The MCP is driven by a possibly prompt-injected LLM
 * while holding a controller identity, so these guards are the last line between the
 * model and value movement.
 */

export interface SpendCaps {
  perCallMaxAtomic: bigint;
  sessionMaxAtomic: bigint;
}

export interface SecurityConfig extends SpendCaps {
  localDev: boolean;
  autoPayment: boolean;
}

export interface ConfigureRequest {
  localDev?: boolean;
  autoPayment?: boolean;
  perCallMaxAtomic?: string;
  sessionMaxAtomic?: string;
}

/**
 * Parse a token amount (atomic units) from untrusted input into a bigint, REJECTING
 * floats and JS numbers that have already lost precision. C5: `value: z.number()`
 * silently truncated uint256 amounts above 2^53; callers must pass amounts as decimal
 * strings, and an unsafe number is rejected (not silently used).
 */
export function parseAtomicAmount(input: unknown, field = 'amount'): bigint {
  if (typeof input === 'bigint') {
    if (input < 0n) throw new Error(`Invalid negative ${field}: ${input}`);
    return input;
  }
  if (typeof input === 'string') {
    const t = input.trim();
    if (!/^\d+$/.test(t)) {
      throw new Error(
        `Invalid ${field}: ${JSON.stringify(input)} (expected a non-negative integer string)`,
      );
    }
    return BigInt(t);
  }
  if (typeof input === 'number') {
    if (!Number.isSafeInteger(input) || input < 0) {
      throw new Error(
        `Unsafe numeric ${field}: ${input}. Pass token amounts as decimal STRINGS — ` +
          `a JS number cannot represent a uint256 without precision loss.`,
      );
    }
    return BigInt(input);
  }
  throw new Error(`Invalid ${field}: ${JSON.stringify(input)}`);
}

/**
 * Enforce the per-call and cumulative session spend caps. Throws on violation; never
 * mutates state. (S1/S9 — the cap logic that every value-moving tool must pass.)
 */
export function checkSpend(
  amountAtomic: bigint,
  caps: SpendCaps,
  sessionSpentAtomic: bigint,
): void {
  if (amountAtomic < 0n) {
    throw new Error(`Invalid negative amount: ${amountAtomic}`);
  }
  if (amountAtomic > caps.perCallMaxAtomic) {
    throw new Error(
      `Amount ${amountAtomic} exceeds per-call cap ${caps.perCallMaxAtomic} (atomic units). ` +
        `Raise perCallMaxAtomic via "configure" (only if the operator enabled security changes).`,
    );
  }
  if (sessionSpentAtomic + amountAtomic > caps.sessionMaxAtomic) {
    throw new Error(
      `Amount ${amountAtomic} would exceed the cumulative session cap ${caps.sessionMaxAtomic} ` +
        `(already spent ${sessionSpentAtomic} atomic units).`,
    );
  }
}

/**
 * S8: Resolve the effective security config from an LLM-supplied `configure` request.
 * The caps / localDev / autoPayment knobs loosen the server's security posture, so the
 * LLM may only change them when the OPERATOR opted in at startup (allowSecurityChanges).
 * Otherwise the request's security fields are IGNORED and the operator/default config
 * stands — a prompt-injected model cannot raise its own caps or enable localDev.
 * Returns the resolved config and the list of fields that were ignored (for reporting).
 */
export function resolveSecurityConfig(
  base: SecurityConfig,
  req: ConfigureRequest,
  allowSecurityChanges: boolean,
): { config: SecurityConfig; ignored: string[] } {
  if (allowSecurityChanges) {
    return {
      config: {
        localDev: req.localDev ?? base.localDev,
        autoPayment: req.autoPayment ?? base.autoPayment,
        perCallMaxAtomic:
          req.perCallMaxAtomic !== undefined
            ? parseAtomicAmount(req.perCallMaxAtomic, 'perCallMaxAtomic')
            : base.perCallMaxAtomic,
        sessionMaxAtomic:
          req.sessionMaxAtomic !== undefined
            ? parseAtomicAmount(req.sessionMaxAtomic, 'sessionMaxAtomic')
            : base.sessionMaxAtomic,
      },
      ignored: [],
    };
  }
  const ignored: string[] = [];
  if (req.localDev) ignored.push('localDev');
  if (req.autoPayment) ignored.push('autoPayment');
  if (req.perCallMaxAtomic !== undefined) ignored.push('perCallMaxAtomic');
  if (req.sessionMaxAtomic !== undefined) ignored.push('sessionMaxAtomic');
  return { config: { ...base }, ignored };
}

/**
 * S1/S9: Tools that are dangerous primitives — the raw EIP-712 signing oracle
 * (`sign_typed_data`, which can authorize an arbitrary-value transfer and bypasses the
 * spend caps) and destructive `delete_content` — are DEFAULT-DENIED so a prompt-injected
 * LLM cannot reach them. An operator enables them explicitly at startup.
 */
const DANGEROUS_TOOLS = new Set(['sign_typed_data', 'delete_content']);

/**
 * SEC-3: state-changing ADMIN tools — registering/enabling services, claiming + submitting job
 * results, uploading content. They mutate canister state (and drive the value-moving job lifecycle),
 * so like the dangerous primitives they are now DEFAULT-DENIED and require an explicit operator
 * opt-in at startup. An in-band `confirm` flag alone is NOT sufficient — a prompt-injected LLM can
 * set it. (`delete_content` is already covered by DANGEROUS_TOOLS.)
 */
const ADMIN_TOOLS = new Set([
  'register_service',
  'enable_service',
  'claim_job',
  'submit_job_result',
  'upload_content',
]);

export function isToolAllowed(
  toolName: string,
  allowDangerousTools: boolean,
  allowAdminTools: boolean,
): boolean {
  if (DANGEROUS_TOOLS.has(toolName)) return allowDangerousTools;
  if (ADMIN_TOOLS.has(toolName)) return allowAdminTools;
  return true;
}

/**
 * 2.22.0 (I8, owner decision D3): where the server connects and as whom. Fixed by the OPERATOR at
 * startup (env / config file); `configure` may change them only under allowSecurityChanges.
 */
export interface ConnectionConfig {
  host: string;
  canisterId?: string;
  identityPem?: string;
}

/** The replica host used when the operator sets none (a local replica, as before 2.22.0). */
export const DEFAULT_HOST = 'http://localhost:4944';

export interface OperatorConfig {
  security: SecurityConfig;
  connection: ConnectionConfig;
  allowSecurityChanges: boolean;
  allowDangerousTools: boolean;
  allowAdminTools: boolean;
}

/**
 * 2.22.0 (I8/D3): resolve the connection from a `configure` request. Like the security knobs
 * (resolveSecurityConfig), a requested host / canisterId / identityPem that differs from the
 * operator's value is IGNORED (and reported) unless the operator set allowSecurityChanges — a
 * prompt-injected model cannot point the server at another replica, canister or key file.
 */
export function resolveConnection(
  base: ConnectionConfig,
  req: Partial<ConnectionConfig>,
  allowSecurityChanges: boolean,
): { config: ConnectionConfig; ignored: string[] } {
  const config: ConnectionConfig = { ...base };
  const ignored: string[] = [];
  for (const key of ['host', 'canisterId', 'identityPem'] as const) {
    const v = req[key];
    if (v === undefined || v === '' || v === base[key]) continue;
    if (allowSecurityChanges) config[key] = v;
    else ignored.push(key);
  }
  return { config, ignored };
}

/**
 * 2.22.0 (I8/D3): a tool's per-call `canisterId` may only name the configured canister unless the
 * operator set allowSecurityChanges — otherwise the pinned canister could be bypassed per call
 * (e.g. open_session approving an attacker's canister as the spender). Throws on refusal.
 */
export function resolveTargetCanister(
  requested: string | undefined,
  configured: string | null,
  allowSecurityChanges: boolean,
): string {
  if (requested === undefined || requested === configured) {
    if (!configured) throw new Error('No canister ID. Call "configure" first.');
    return configured;
  }
  if (!allowSecurityChanges) {
    throw new Error(
      `canisterId "${requested}" refused: this server is fixed to canister ${configured ?? '(none)'} ` +
        `by its operator. Omit canisterId (the operator can allow other canisters with ` +
        `IC402_MCP_ALLOW_SECURITY_CHANGES=1).`,
    );
  }
  return requested;
}

/**
 * Resolve the operator's startup security config from an optional JSON config file and the
 * environment. BOTH are out-of-band inputs the LLM cannot influence, so the security boundary
 * stays with the operator (audit S8). Precedence: built-in defaults < config file < env vars
 * (env wins, so an operator can override a file value at launch). Unparseable values fall back
 * to the lower-precedence source rather than throwing, so a typo can't crash the server.
 */
export function resolveOperatorConfig(
  file: Record<string, unknown> | null,
  env: Record<string, string | undefined>,
  defaults: { perCallMaxAtomic: bigint; sessionMaxAtomic: bigint },
): OperatorConfig {
  const f = file ?? {};
  const isTrue = (v: string | undefined) => v === '1' || v === 'true';

  const pickBool = (fileKey: string, envKey: string): boolean => {
    if (env[envKey] !== undefined) return isTrue(env[envKey]);
    if (typeof f[fileKey] === 'boolean') return f[fileKey] as boolean;
    return false;
  };
  const pickAmount = (fileKey: string, envKey: string, dflt: bigint): bigint => {
    const raw = env[envKey] !== undefined ? env[envKey] : f[fileKey];
    if (raw === undefined) return dflt;
    try {
      return parseAtomicAmount(raw, envKey);
    } catch {
      return dflt;
    }
  };

  const pickText = (fileKey: string, envKey: string): string | undefined => {
    const raw = env[envKey] !== undefined ? env[envKey] : f[fileKey];
    return typeof raw === 'string' && raw.trim() !== '' ? raw.trim() : undefined;
  };

  return {
    connection: {
      host: pickText('host', 'IC402_MCP_HOST') ?? DEFAULT_HOST,
      canisterId: pickText('canisterId', 'IC402_MCP_CANISTER_ID'),
      identityPem: pickText('identityPem', 'ICP_IDENTITY_PEM'),
    },
    security: {
      localDev: pickBool('localDev', 'IC402_MCP_LOCAL_DEV'),
      autoPayment: pickBool('autoPayment', 'IC402_MCP_AUTO_PAYMENT'),
      perCallMaxAtomic: pickAmount(
        'perCallMaxAtomic',
        'IC402_MCP_PER_CALL_MAX_ATOMIC',
        defaults.perCallMaxAtomic,
      ),
      sessionMaxAtomic: pickAmount(
        'sessionMaxAtomic',
        'IC402_MCP_SESSION_MAX_ATOMIC',
        defaults.sessionMaxAtomic,
      ),
    },
    allowSecurityChanges: pickBool('allowSecurityChanges', 'IC402_MCP_ALLOW_SECURITY_CHANGES'),
    allowDangerousTools: pickBool('allowDangerousTools', 'IC402_MCP_ALLOW_DANGEROUS_TOOLS'),
    allowAdminTools: pickBool('allowAdminTools', 'IC402_MCP_ALLOW_ADMIN_TOOLS'),
  };
}

// ---------------------------------------------------------------------------
// Generic `call` tool method gating (C3)
//
// The generic MCP `call` tool must only reach read-only/query methods; state-changing, signing,
// payment, and admin methods have dedicated, capped, confirmation-gated tools. This logic lives
// here (not in index.ts, which boots the server on import and can't be unit-tested) so the decision
// tree can be exercised directly — see test/mcp-guards.test.ts.
// ---------------------------------------------------------------------------

/** Curated read-only allowlist — every entry is a `query` (or otherwise non-state-changing read)
 *  in the IDL. Authoritative: wins over the substring blocklist, so a genuine read-only getter
 *  whose name contains a blocked substring (e.g. getPolicyConfig contains 'policy') is still
 *  admitted. ONLY add verified non-state-changing query methods. */
export const READONLY_CALL_ALLOWLIST = new Set<string>([
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
  'getPolicyConfig',
]);

/** Substrings that must NEVER be reachable through the generic `call` path — signing/admin/
 *  value-moving method names that have dedicated tools. */
export const CALL_BLOCK_SUBSTRINGS = [
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

// M16 / I12 (posture note): `getContent` (and getAssetContent / getExternalContent) is dual-mode —
// a 402 challenge with no PaymentSignature, but a SETTLING update when a signature is passed: it
// spends an ICRC-2 allowance the payer already granted, with no spend cap and no confirmation. It
// is the only content-purchase entry point over MCP (the demo buys content through it), so it stays
// reachable via the get-prefix fallback below, and the `call` tool description says so instead of
// claiming "no funds moved". A dedicated capped/confirmed `buy_content` tool is the right fix.

/** Decide whether a method name may be called through the generic (uncapped, unconfirmed) `call`
 *  tool. Order: allowlist (authoritative) → substring blocklist → read-only name-prefix fallback. */
export function isCallMethodAllowed(method: string): { ok: boolean; reason?: string } {
  const lower = method.toLowerCase();
  if (READONLY_CALL_ALLOWLIST.has(method)) return { ok: true };
  for (const bad of CALL_BLOCK_SUBSTRINGS) {
    if (lower.includes(bad)) {
      return {
        ok: false,
        reason: `Method "${method}" looks state-changing/signing (contains "${bad}"). Use the dedicated tool for this action.`,
      };
    }
  }
  // Forward-compat: admit new read-only getters by name prefix, only after the blocklist cleared it.
  if (/^(get|list|fetch|is)[A-Z]/.test(method) || /^(get|list|fetch|is)$/.test(method)) {
    return { ok: true };
  }
  return {
    ok: false,
    reason: `Method "${method}" is not on the read-only allowlist. The generic "call" tool only permits query/read methods; use a dedicated tool for state-changing or signing operations.`,
  };
}

// ---------------------------------------------------------------------------
// fetch_x402 payment terms (I3)
// ---------------------------------------------------------------------------

/**
 * 2.22.0 (I3): the only asset fetch_x402 pays in, per chain — USDC on the five supported chains
 * (mainnet values from example/main.mo, testnet values from scripts/patch-local.sh). The spend caps
 * count 6-decimal USDC units; a 402 naming any other token on a chain is refused.
 */
export const X402_USDC_BY_CHAIN: Readonly<Record<number, string>> = {
  8453: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // Base
  1: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', // Ethereum
  43114: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E', // Avalanche C-Chain
  10: '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85', // Optimism
  42161: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', // Arbitrum One
  84532: '0x036CbD53842c5426634e7929541eC2318f3dCF7e', // Base Sepolia
  11155111: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238', // Ethereum Sepolia
  43113: '0x5425890298aed601595a70AB815c96711a31Bc65', // Avalanche Fuji
  11155420: '0x5fd84259d66Cd46123540766Be93DFE6D43130D7', // Optimism Sepolia
  421614: '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d', // Arbitrum Sepolia
};

export function isAllowedX402Asset(chainId: number, asset: string): boolean {
  const usdc = X402_USDC_BY_CHAIN[chainId];
  return usdc !== undefined && usdc.toLowerCase() === asset.toLowerCase();
}

/** The payment terms of an x402 proposal (what the human confirms). */
export interface X402Terms {
  amount: bigint;
  recipient: string;
  asset: string;
  chain: number;
}

/**
 * 2.22.0 (I3): fetch_x402 with confirm:true re-probes the URL; it may sign only the terms the human
 * confirmed. Returns null when the fresh probe's terms equal the confirmed ones (addresses compared
 * case-insensitively), else the refusal text. Missing confirmed terms are a refusal too.
 */
export function x402TermsMismatch(
  confirmed: { amount?: string; recipient?: string; asset?: string; chain?: number },
  fresh: X402Terms,
): string | null {
  const { amount, recipient, asset, chain } = confirmed;
  if (
    amount === undefined ||
    recipient === undefined ||
    asset === undefined ||
    chain === undefined
  ) {
    return (
      'confirm:true must repeat the proposal: pass amount, recipient, asset and chain exactly as the ' +
      'confirm:false call returned them. Nothing was signed.'
    );
  }
  let confirmedAmount: bigint;
  try {
    confirmedAmount = parseAtomicAmount(amount, 'amount');
  } catch (e) {
    return `${e instanceof Error ? e.message : String(e)}. Nothing was signed.`;
  }
  const diffs: string[] = [];
  if (confirmedAmount !== fresh.amount) diffs.push(`amount ${confirmedAmount} → ${fresh.amount}`);
  if (recipient.toLowerCase() !== fresh.recipient.toLowerCase())
    diffs.push(`recipient ${recipient} → ${fresh.recipient}`);
  if (asset.toLowerCase() !== fresh.asset.toLowerCase())
    diffs.push(`asset ${asset} → ${fresh.asset}`);
  if (chain !== fresh.chain) diffs.push(`chain ${chain} → ${fresh.chain}`);
  if (diffs.length === 0) return null;
  return (
    `The server's payment terms changed since the confirmed proposal (${diffs.join('; ')}). ` +
    'Nothing was signed. Re-run with confirm:false and have the human review the new proposal.'
  );
}

// ---------------------------------------------------------------------------
// ICRC-2 payment cost (fee accounting)
// ---------------------------------------------------------------------------

/**
 * The ledger fee @ic402/client uses when the ledger actor has no icrc1_fee (Ic402Client.approvalFor);
 * the MCP's fallback when no ledger is configured.
 */
export const LEGACY_LEDGER_FEE = 100_000n;

/**
 * 2.22.0: what an ICRC-2 auto-payment of `amount` takes from the payer's account — the amount, the
 * transfer fee icrc2_transfer_from charges on top (the SDK approves amount + fee), and, when the
 * payment includes an icrc2_approve call, that call's own fee. The spend caps and the human
 * confirmation count this; before 2.22.0 they counted the bare amount and missed the fees.
 */
export function icrc2PaymentCost(amount: bigint, ledgerFee: bigint, approves: boolean): bigint {
  return amount + ledgerFee + (approves ? ledgerFee : 0n);
}

/**
 * 2.22.0: submit_request / open_session with confirm:true must repeat the amount the human
 * confirmed (from the proposal's confirmWith) and pay it only if the canister still asks exactly
 * that — the same binding fetch_x402 applies to its terms. Returns null when `confirmed` equals
 * `fresh`, else the refusal (a missing or malformed amount is refused too).
 */
export function confirmedAmountMismatch(
  field: string,
  confirmed: string | undefined,
  fresh: bigint,
): string | null {
  if (confirmed === undefined) {
    return (
      `confirm:true must repeat the proposal: pass ${field} exactly as confirmWith returned it. ` +
      'Nothing was paid.'
    );
  }
  let value: bigint;
  try {
    value = parseAtomicAmount(confirmed, field);
  } catch (e) {
    return `${e instanceof Error ? e.message : String(e)}. Nothing was paid.`;
  }
  if (value === fresh) return null;
  return (
    `The canister now asks ${fresh}, not the confirmed ${field} ${value}. Nothing was paid. ` +
    'Re-run with confirm:false and have the human review the new proposal.'
  );
}

// ---------------------------------------------------------------------------
// Spend-reservation release (I5)
// ---------------------------------------------------------------------------

/**
 * 2.22.0 (I5): a confirm-time spend reservation is released ONLY when the error proves the paying
 * call was never sent — @ic402/client sets Ic402Error.paymentNotSent for a refusal before it (price
 * above maxAmount, approve #Err, missing config, the canister refusing the unpaid request). Any other
 * error — a transport timeout or reject after the paying call went out, a post-payment error, a
 * funds-moved error — keeps the reservation: the payment may have moved
 * (docs/decisions/settled-then-job-failed.md, Option C). Duck-typed so this module stays free of the
 * client import.
 */
export function reservationReleasable(e: unknown): boolean {
  if (!e || typeof e !== 'object') return false;
  const flags = e as { paymentNotSent?: unknown; fundsMoved?: unknown };
  return flags.paymentNotSent === true && flags.fundsMoved !== true;
}
