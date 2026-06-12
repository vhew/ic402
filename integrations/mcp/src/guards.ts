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

export function dangerousTools(): string[] {
  return [...DANGEROUS_TOOLS];
}

export function isToolAllowed(toolName: string, allowDangerousTools: boolean): boolean {
  if (DANGEROUS_TOOLS.has(toolName)) return allowDangerousTools;
  return true;
}
