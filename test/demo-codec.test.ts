import { describe, it, expect } from 'vitest';
import {
  unwrapOpt,
  optText,
  decodeNonce,
  decodeInlineBlob,
  formatUsdc,
} from '../example/client/src/codec';
import { demoPayer, signTransferWithAuthorization, recoverSigner } from '../example/client/src/evm';

describe('codec.unwrapOpt', () => {
  it('unwraps a present Candid opt [value]', () => {
    expect(unwrapOpt(['x'])).toBe('x');
    expect(unwrapOpt([0])).toBe(0); // falsy-but-present
  });
  it('returns undefined for an absent opt []', () => {
    expect(unwrapOpt([])).toBeUndefined();
  });
  it('tolerates a bare (non-array) value', () => {
    expect(unwrapOpt('bare')).toBe('bare');
  });
  it('returns undefined for null/undefined', () => {
    expect(unwrapOpt(null)).toBeUndefined();
    expect(unwrapOpt(undefined)).toBeUndefined();
  });
});

describe('codec.optText', () => {
  it('returns the string for [value] / bare', () => {
    expect(optText(['hi'])).toBe('hi');
    expect(optText('hi')).toBe('hi');
  });
  it("returns '' for absent, blank, or non-string", () => {
    expect(optText([])).toBe('');
    expect(optText([''])).toBe('');
    expect(optText([123])).toBe('');
    expect(optText(null)).toBe('');
  });
});

describe('codec.decodeNonce', () => {
  it('passes through a Candid vec nat8 (number[])', () => {
    expect(decodeNonce([1, 2, 3])).toEqual([1, 2, 3]);
  });
  it('hex-decodes a string (MCP call-tool serialization)', () => {
    // "48…" must decode byte-wise, NOT split into hex characters
    expect(decodeNonce('48656c6c6f')).toEqual([0x48, 0x65, 0x6c, 0x6c, 0x6f]);
  });
  it('returns [] for null/undefined', () => {
    expect(decodeNonce(undefined)).toEqual([]);
    expect(decodeNonce(null)).toEqual([]);
  });
});

describe('codec.decodeInlineBlob', () => {
  it('hex-decodes a string blob', () => {
    expect([...decodeInlineBlob('deadbeef')]).toEqual([0xde, 0xad, 0xbe, 0xef]);
  });
  it('decodes a vec nat8 (number[]) blob', () => {
    expect([...decodeInlineBlob([1, 2, 3])]).toEqual([1, 2, 3]);
  });
  it('returns an empty Buffer for anything else', () => {
    expect(decodeInlineBlob(undefined).length).toBe(0);
    expect(decodeInlineBlob({}).length).toBe(0);
  });
});

describe('codec.formatUsdc', () => {
  it('formats atomic units (6 decimals) with fixed precision', () => {
    expect(formatUsdc(1_000_000)).toBe('1.000000');
    expect(formatUsdc(1_500_000)).toBe('1.500000');
    expect(formatUsdc(0)).toBe('0.000000');
    expect(formatUsdc(1)).toBe('0.000001');
  });
  it('accepts bigint', () => {
    expect(formatUsdc(2_000_000n)).toBe('2.000000');
  });
});

describe('evm.demoPayer', () => {
  it('derives the deterministic demo EOA when no env key is set', () => {
    const saved = process.env.IC402_DEMO_EVM_KEY;
    delete process.env.IC402_DEMO_EVM_KEY;
    try {
      const p = demoPayer();
      expect(p.address).toBe('0x26e42bf529b41bda6e5b587e57680949ac739e86');
      expect(p.fromEnv).toBe(false);
    } finally {
      if (saved !== undefined) process.env.IC402_DEMO_EVM_KEY = saved;
    }
  });
  it('uses IC402_DEMO_EVM_KEY when set (0x-prefixed tolerated) and flags fromEnv', () => {
    const saved = process.env.IC402_DEMO_EVM_KEY;
    // The deterministic key, supplied explicitly with a 0x prefix -> same address.
    process.env.IC402_DEMO_EVM_KEY =
      '0x6d4d19a8eccd95b85c7a6ecbd22251496a3ff7bc45488d322146f09a71bcdfdc';
    try {
      const p = demoPayer();
      expect(p.address).toBe('0x26e42bf529b41bda6e5b587e57680949ac739e86');
      expect(p.fromEnv).toBe(true);
    } finally {
      if (saved === undefined) delete process.env.IC402_DEMO_EVM_KEY;
      else process.env.IC402_DEMO_EVM_KEY = saved;
    }
  });
});

describe('evm.signTransferWithAuthorization', () => {
  // Base Sepolia USDC domain + a fixed authorization -> a pinned EIP-712 result.
  // Guards the domain-separator / struct-hash / 0x1901 encoding against drift.
  const key = Buffer.from(
    '6d4d19a8eccd95b85c7a6ecbd22251496a3ff7bc45488d322146f09a71bcdfdc',
    'hex',
  );
  const from = '0x26e42bf529b41bda6e5b587e57680949ac739e86';
  const to = '0x000000000000000000000000000000000000dEaD';
  const nonce = new Uint8Array(32).fill(7);
  const domain = {
    name: 'USDC',
    version: '2',
    chainId: 84532,
    verifyingContract: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
  };
  const auth = { from, to, value: 1_000_000, validAfter: 0, validBefore: 1_893_456_000, nonce };

  it('produces the pinned EIP-712 digest and v/r/s', () => {
    const sig = signTransferWithAuthorization(key, domain, auth);
    expect(Buffer.from(sig.digest).toString('hex')).toBe(
      '2b676d2ee1cf21b551885e9d22bc68c688d3f74231b5dd1d3926c1db2e2d2cd3',
    );
    expect(sig.v).toBe(27);
    expect(Buffer.from(sig.r).toString('hex')).toBe(
      '5a6d19272f3b6c0fd5aca44a1ccf42687cfbf26dd0dc7539b00ed2c1bb99b572',
    );
    expect(Buffer.from(sig.s).toString('hex')).toBe(
      '787b3f28aef9adb0e083d2537a1b634d4464dbd790cc9bcc1baceb9ffad478e6',
    );
  });

  it('signature recovers to the signer address (ecrecover round-trip)', () => {
    const sig = signTransferWithAuthorization(key, domain, auth);
    expect(recoverSigner(sig.digest, sig)).toBe(from.toLowerCase());
  });

  it('a different chainId changes the digest (domain is bound)', () => {
    const a = signTransferWithAuthorization(key, domain, auth);
    const b = signTransferWithAuthorization(key, { ...domain, chainId: 1 }, auth);
    expect(Buffer.from(a.digest).toString('hex')).not.toBe(Buffer.from(b.digest).toString('hex'));
  });
});
