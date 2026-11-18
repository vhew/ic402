import { describe, it, expect } from 'vitest';
import {
  parseAtomicAmount,
  checkSpend,
  resolveSecurityConfig,
  resolveConnection,
  resolveTargetCanister,
  isAllowedX402Asset,
  x402TermsMismatch,
  reservationReleasable,
  icrc2PaymentCost,
  isToolAllowed,
  isCallMethodAllowed,
  resolveOperatorConfig,
  DEFAULT_HOST,
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

describe('isToolAllowed (S1/S9 + SEC-3: dangerous + admin tools default-denied)', () => {
  it('denies sign_typed_data and delete_content unless allowDangerousTools', () => {
    expect(isToolAllowed('sign_typed_data', false, false)).toBe(false);
    expect(isToolAllowed('delete_content', false, false)).toBe(false);
    expect(isToolAllowed('sign_typed_data', true, false)).toBe(true);
    expect(isToolAllowed('delete_content', true, false)).toBe(true);
    // admin opt-in does NOT enable the dangerous primitives
    expect(isToolAllowed('sign_typed_data', false, true)).toBe(false);
  });
  it('SEC-3: denies state-changing admin tools unless allowAdminTools', () => {
    for (const t of [
      'register_service',
      'enable_service',
      'claim_job',
      'submit_job_result',
      'upload_content',
    ]) {
      expect(isToolAllowed(t, false, false)).toBe(false); // default-denied
      expect(isToolAllowed(t, false, true)).toBe(true); // operator opt-in
      expect(isToolAllowed(t, true, false)).toBe(false); // dangerous flag does NOT enable admin
    }
  });
  it('always allows ordinary read/payment tools', () => {
    expect(isToolAllowed('search', false, false)).toBe(true);
    expect(isToolAllowed('open_session', false, false)).toBe(true);
    expect(isToolAllowed('fetch_x402', false, false)).toBe(true);
  });
});

describe('isCallMethodAllowed (C3: generic call is read-only)', () => {
  const ok = (m: string) => expect(isCallMethodAllowed(m).ok).toBe(true);
  const blocked = (m: string) => expect(isCallMethodAllowed(m).ok).toBe(false);

  it('admits curated read-only allowlist entries', () => {
    ok('getChunk');
    ok('listServices');
    ok('getJob');
    ok('verifyGrant');
  });

  it('allowlist beats the substring blocklist (getPolicyConfig contains "policy")', () => {
    ok('getPolicyConfig');
  });

  it('blocks signing/admin/value-moving names via substring', () => {
    blocked('signX402Payment'); // sign
    blocked('setPolicy'); // set
    blocked('submitServiceRequest'); // submit
    blocked('openSession'); // open
    blocked('closeSession'); // close
    blocked('registerService'); // register
    blocked('uploadContent'); // upload
    blocked('deleteContent'); // delete
    blocked('confirmJob'); // confirm
    blocked('sweepEvm'); // no block-substring? -> falls to prefix (not get/list/fetch/is) -> blocked
  });

  it('admits new read-only getters via the name-prefix fallback', () => {
    ok('getSomethingNew');
    ok('listWidgets');
    ok('fetchData');
    ok('isReady');
  });

  it('getContent stays reachable (dual-mode content-purchase entry — M16)', () => {
    ok('getContent');
  });

  it('rejects an unknown non-getter name', () => {
    blocked('doThing');
    blocked('frobnicate');
  });
});

// 2.22.0 (I8, owner decision D3): host, canister and identity are the operator's; `configure` and a
// per-call canisterId change them only under allowSecurityChanges.
describe('connection pinning (I8/D3)', () => {
  const base = {
    host: 'https://icp-api.io',
    canisterId: 'rrkah-fqaaa-aaaaa-aaaaq-cai',
    identityPem: '/etc/ic402/operator.pem',
  };
  const req = {
    host: 'https://localhost.evil.example',
    canisterId: 'aaaaa-aa',
    identityPem: '/home/u/.ssh/other.pem',
  };

  // Fails on: resolveConnection applying the request without the allowSecurityChanges gate.
  it('IGNORES host/canisterId/identityPem from configure unless the operator allowed changes', () => {
    const denied = resolveConnection(base, req, false);
    expect(denied.config).toEqual(base);
    expect(denied.ignored.sort()).toEqual(['canisterId', 'host', 'identityPem']);
    // repeating the operator's own values is not a change
    expect(resolveConnection(base, { ...base }, false).ignored).toEqual([]);
    const allowed = resolveConnection(base, req, true);
    expect(allowed.config).toEqual(req);
    expect(allowed.ignored).toEqual([]);
  });

  // Fails on: a per-call canisterId accepted without the gate.
  it('refuses a per-call canisterId other than the configured one unless allowed', () => {
    expect(resolveTargetCanister(undefined, 'aaaaa-aa', false)).toBe('aaaaa-aa');
    expect(resolveTargetCanister('aaaaa-aa', 'aaaaa-aa', false)).toBe('aaaaa-aa');
    expect(() => resolveTargetCanister('ryjl3-tyaaa-aaaaa-aaaba-cai', 'aaaaa-aa', false)).toThrow(
      /refused/,
    );
    expect(resolveTargetCanister('ryjl3-tyaaa-aaaaa-aaaba-cai', 'aaaaa-aa', true)).toBe(
      'ryjl3-tyaaa-aaaaa-aaaba-cai',
    );
    expect(() => resolveTargetCanister(undefined, null, true)).toThrow(/configure/);
  });

  // Fails on: the operator connection not read from env / config file (env wins).
  it('the operator sets host / canister / identity via env or config file; env wins', () => {
    const defaults = { perCallMaxAtomic: 1n, sessionMaxAtomic: 1n };
    expect(resolveOperatorConfig(null, {}, defaults).connection).toEqual({
      host: DEFAULT_HOST,
      canisterId: undefined,
      identityPem: undefined,
    });
    const c = resolveOperatorConfig(
      { host: 'https://file.example', canisterId: 'aaaaa-aa', identityPem: '/file.pem' },
      { IC402_MCP_HOST: 'https://icp-api.io', ICP_IDENTITY_PEM: '/env.pem' },
      defaults,
    );
    expect(c.connection).toEqual({
      host: 'https://icp-api.io',
      canisterId: 'aaaaa-aa',
      identityPem: '/env.pem',
    });
    expect(
      resolveOperatorConfig(
        null,
        { IC402_MCP_CANISTER_ID: 'ryjl3-tyaaa-aaaaa-aaaba-cai' },
        defaults,
      ).connection.canisterId,
    ).toBe('ryjl3-tyaaa-aaaaa-aaaba-cai');
  });
});

// 2.22.0 (I3): fetch_x402 pays only USDC on the supported chains, and only the confirmed terms.
describe('fetch_x402 payment terms (I3)', () => {
  const BASE_USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
  const SEPOLIA_USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e';

  // Fails on: isAllowedX402Asset accepting any asset (or ignoring the chain).
  it('allows only the USDC contract of the payment chain', () => {
    expect(isAllowedX402Asset(8453, BASE_USDC)).toBe(true);
    expect(isAllowedX402Asset(8453, BASE_USDC.toLowerCase())).toBe(true);
    expect(isAllowedX402Asset(84532, SEPOLIA_USDC)).toBe(true);
    expect(isAllowedX402Asset(8453, SEPOLIA_USDC)).toBe(false); // another chain's USDC
    expect(isAllowedX402Asset(8453, '0x' + '11'.repeat(20))).toBe(false); // a lookalike token
    expect(isAllowedX402Asset(56, BASE_USDC)).toBe(false); // unsupported chain
    expect(isAllowedX402Asset(8453, '')).toBe(false);
  });

  const fresh = {
    amount: 10_000n,
    recipient: '0xAbC0000000000000000000000000000000000001',
    asset: BASE_USDC,
    chain: 8453,
  };
  const confirmed = {
    amount: '10000',
    recipient: '0xabc0000000000000000000000000000000000001',
    asset: BASE_USDC.toLowerCase(),
    chain: 8453,
  };

  // Fails on: x402TermsMismatch accepting changed terms or a confirm without them.
  it('refuses a confirm whose terms differ from the fresh probe, or carries none', () => {
    expect(x402TermsMismatch(confirmed, fresh)).toBeNull(); // addresses compare case-insensitively
    expect(x402TermsMismatch({}, fresh)).toMatch(/must repeat the proposal/);
    expect(x402TermsMismatch({ ...confirmed, amount: '9999' }, fresh)).toMatch(
      /amount 9999 → 10000/,
    );
    expect(
      x402TermsMismatch(
        { ...confirmed, recipient: '0x0000000000000000000000000000000000000bad' },
        fresh,
      ),
    ).toMatch(/recipient/);
    expect(x402TermsMismatch({ ...confirmed, asset: SEPOLIA_USDC }, fresh)).toMatch(/asset/);
    expect(x402TermsMismatch({ ...confirmed, chain: 84532 }, fresh)).toMatch(/chain/);
    expect(x402TermsMismatch({ ...confirmed, amount: '1e4' }, fresh)).toMatch(/Invalid amount/);
  });
});

// 2.22.0 (I5): release a spend reservation only when the payment provably was not sent.
describe('reservationReleasable (I5)', () => {
  // Fails on: the pre-2.22 rule (release unless fundsMoved), which un-counted a transport timeout
  // or a post-payment error after the paying call went out.
  it('releases only on paymentNotSent, never on a transport error or a post-payment error', () => {
    const err = (flags: { fundsMoved?: boolean; paymentNotSent?: boolean }) =>
      Object.assign(new Error('x'), { fundsMoved: false, paymentNotSent: false, ...flags });
    expect(reservationReleasable(err({ paymentNotSent: true }))).toBe(true);
    expect(reservationReleasable(new Error('Request timed out after 300000 msec'))).toBe(false);
    expect(reservationReleasable(err({}))).toBe(false); // post-payment canister error
    expect(reservationReleasable(err({ fundsMoved: true }))).toBe(false);
    expect(reservationReleasable(err({ fundsMoved: true, paymentNotSent: true }))).toBe(false);
    expect(reservationReleasable(undefined)).toBe(false);
  });
});

// 2.22.0: the spend caps and the confirmation count what leaves the wallet, not the bare charge.
describe('icrc2PaymentCost (fee accounting)', () => {
  // Fails on: the transfer fee or the approve fee left out (the pre-2.22 cap counted the bare
  // amount, so every ICP payment spent two ledger fees the cap never saw).
  it('adds the transfer fee, and the approve fee when the payment approves', () => {
    // submit_request: canister charge 10_100 (price 100 + its fee 10_000), ckUSDC fee 10_000
    expect(icrc2PaymentCost(10_100n, 10_000n, true)).toBe(30_100n);
    // a session deposit pulled from an allowance the payer granted elsewhere (no approve here)
    expect(icrc2PaymentCost(50_000n, 10_000n, false)).toBe(60_000n);
    expect(icrc2PaymentCost(0n, 0n, true)).toBe(0n);
  });
});
