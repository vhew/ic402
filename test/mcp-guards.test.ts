import { describe, it, expect } from 'vitest';
import {
  parseAtomicAmount,
  checkSpend,
  resolveSecurityConfig,
  isToolAllowed,
  resolveOperatorConfig,
  type SecurityConfig,
} from '../integrations/mcp/src/guards';

describe('parseAtomicAmount (C5: no silent uint256 truncation)', () => {
  it('passes through a non-negative bigint', () => {
    expect(parseAtomicAmount(123n)).toBe(123n);
  });
  it('parses a decimal string exactly, beyond 2^53', () => {
    expect(parseAtomicAmount('10000000000000000000')).toBe(10_000_000_000_000_000_000n);
  });
  it('accepts a safe small JS number', () => {
    expect(parseAtomicAmount(1000)).toBe(1000n);
  });
  it('REJECTS a JS number above 2^53 (would have truncated)', () => {
    expect(() => parseAtomicAmount(10_000_000_000_000_000_000)).toThrow(
      /Unsafe numeric|decimal STRING/,
    );
  });
  it('rejects floats, negatives, and non-integer strings', () => {
    expect(() => parseAtomicAmount(1.5)).toThrow();
    expect(() => parseAtomicAmount(-1)).toThrow();
    expect(() => parseAtomicAmount(-5n)).toThrow();
    expect(() => parseAtomicAmount('12.3')).toThrow();
    expect(() => parseAtomicAmount('0x10')).toThrow();
    expect(() => parseAtomicAmount(null)).toThrow();
  });
});

describe('checkSpend (S1/S9: per-call + cumulative caps)', () => {
  const caps = { perCallMaxAtomic: 1_000n, sessionMaxAtomic: 2_500n };
  it('allows a spend within both caps', () => {
    expect(() => checkSpend(1_000n, caps, 0n)).not.toThrow();
  });
  it('rejects a spend over the per-call cap', () => {
    expect(() => checkSpend(1_001n, caps, 0n)).toThrow(/per-call cap/);
  });
  it('rejects a spend that would exceed the cumulative session cap', () => {
    expect(() => checkSpend(1_000n, caps, 2_000n)).toThrow(/cumulative session cap/);
  });
  it('rejects a negative amount', () => {
    expect(() => checkSpend(-1n, caps, 0n)).toThrow(/negative/);
  });
});

describe('resolveSecurityConfig (S8: LLM cannot loosen security knobs by default)', () => {
  const base: SecurityConfig = {
    localDev: false,
    autoPayment: false,
    perCallMaxAtomic: 1_000_000n,
    sessionMaxAtomic: 5_000_000n,
  };

  it('IGNORES localDev/autoPayment/caps from the request when changes are not allowed', () => {
    const { config, ignored } = resolveSecurityConfig(
      base,
      {
        localDev: true,
        autoPayment: true,
        perCallMaxAtomic: '999999999999',
        sessionMaxAtomic: '999999999999',
      },
      false,
    );
    expect(config).toEqual(base); // operator/default config stands
    expect(ignored.sort()).toEqual([
      'autoPayment',
      'localDev',
      'perCallMaxAtomic',
      'sessionMaxAtomic',
    ]);
  });

  it('applies the request (parsing cap strings) when the operator allowed changes', () => {
    const { config, ignored } = resolveSecurityConfig(
      base,
      { localDev: true, perCallMaxAtomic: '2000000' },
      true,
    );
    expect(config.localDev).toBe(true);
    expect(config.perCallMaxAtomic).toBe(2_000_000n);
    expect(config.sessionMaxAtomic).toBe(base.sessionMaxAtomic); // untouched fields keep base
    expect(ignored).toEqual([]);
  });

  it('does not flag a request that sets nothing sensitive', () => {
    const { ignored } = resolveSecurityConfig(base, {}, false);
    expect(ignored).toEqual([]);
  });
});

describe('resolveOperatorConfig (operator config file + env; env wins; LLM cannot touch either)', () => {
  const defaults = { perCallMaxAtomic: 1_000_000n, sessionMaxAtomic: 5_000_000n };

  it('uses conservative defaults when neither file nor env set anything', () => {
    const c = resolveOperatorConfig(null, {}, defaults);
    expect(c.security.perCallMaxAtomic).toBe(1_000_000n);
    expect(c.security.localDev).toBe(false);
    expect(c.security.autoPayment).toBe(false);
    expect(c.allowSecurityChanges).toBe(false);
    expect(c.allowDangerousTools).toBe(false);
  });

  it('applies config-file values', () => {
    const c = resolveOperatorConfig(
      { perCallMaxAtomic: '2000000', localDev: true, allowDangerousTools: true },
      {},
      defaults,
    );
    expect(c.security.perCallMaxAtomic).toBe(2_000_000n);
    expect(c.security.localDev).toBe(true);
    expect(c.allowDangerousTools).toBe(true);
  });

  it('env overrides the config file', () => {
    const c = resolveOperatorConfig(
      { perCallMaxAtomic: '2000000', allowDangerousTools: true },
      { IC402_MCP_PER_CALL_MAX_ATOMIC: '9000000', IC402_MCP_ALLOW_DANGEROUS_TOOLS: '0' },
      defaults,
    );
    expect(c.security.perCallMaxAtomic).toBe(9_000_000n); // env wins
    expect(c.allowDangerousTools).toBe(false); // env '0' overrides file true
  });

  it('falls back rather than throwing on an unparseable amount', () => {
    const c = resolveOperatorConfig({ perCallMaxAtomic: 'not-a-number' }, {}, defaults);
    expect(c.security.perCallMaxAtomic).toBe(1_000_000n);
  });
});

describe('isToolAllowed (S1/S9: dangerous tools default-denied)', () => {
  it('denies sign_typed_data and delete_content unless explicitly enabled', () => {
    expect(isToolAllowed('sign_typed_data', false)).toBe(false);
    expect(isToolAllowed('delete_content', false)).toBe(false);
    expect(isToolAllowed('sign_typed_data', true)).toBe(true);
    expect(isToolAllowed('delete_content', true)).toBe(true);
  });
  it('always allows ordinary tools', () => {
    expect(isToolAllowed('search', false)).toBe(true);
    expect(isToolAllowed('open_session', false)).toBe(true);
    expect(isToolAllowed('register_service', false)).toBe(true);
  });
});
