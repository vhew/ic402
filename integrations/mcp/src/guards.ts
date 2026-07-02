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

export interface OperatorConfig {
  security: SecurityConfig;
  allowSecurityChanges: boolean;
  allowDangerousTools: boolean;
  allowAdminTools: boolean;
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

  return {
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

// M16 (posture note): `getContent` is dual-mode — a read-only 402 challenge fetch with no
// PaymentSignature, but a SETTLING update when a signature is passed. It is the only content-
// purchase entry point over MCP, and there is no dedicated capped/confirmed purchase tool, so it
// stays reachable via the get-prefix fallback below. Settlement pays the operator's own canister
// (C-1), and spend caps are outbound-signing-only; a future `buy_content` tool is the right fix.

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
