import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { secp256k1 } from '@noble/curves/secp256k1.js';

/**
 * Cross-checks the `ecrecover` expectations in test/fixtures/secp256k1/Vectors.mo against
 * @noble/curves, on every CI run.
 *
 * scripts/gen-secp256k1-fixtures.mjs computes them with its own small BigInt model of Ethereum's
 * `ecrecover` (it stays dependency-free so its CI job needs no install). test/secp256k1.test.mo
 * then holds EvmAddress.ecRecoverEvm to them. This file makes sure the model is right: noble's
 * `recoverPublicKey` with recovery bit 0/1 (x = r only, that parity) must give the same key, or
 * fail where the model says none, for both v of every Wycheproof vector and policy vector.
 */

const src = readFileSync(new URL('./fixtures/secp256k1/Vectors.mo', import.meta.url), 'utf8');
const unblob = (b: string) => b.replace(/\\/g, '');
const opt = (x: string) => (x === 'null' ? null : unblob(x.slice(2, -1)));

function nobleRecover(hashHex: string, sigHex: string, bit: number): string | null {
  if (sigHex.length !== 128) return null;
  try {
    const sig = Buffer.concat([Buffer.from([bit]), Buffer.from(sigHex, 'hex')]);
    const key = secp256k1.recoverPublicKey(sig, Buffer.from(hashHex, 'hex'), { prehash: false });
    return Buffer.from(key).toString('hex');
  } catch {
    return null;
  }
}

describe('secp256k1 fixtures: ecrecover expectations match @noble/curves', () => {
  it('all 252 Wycheproof vectors, both v (504 recoveries: 360 keys, 144 none)', () => {
    const re =
      /tcId = (\d+);.*?hash = "([^"]*)"; sig = "([^"]*)";.*?evm0 = (null|\?"[^"]*"); evm1 = (null|\?"[^"]*")/g;
    let vectors = 0;
    let keys = 0;
    const mismatches: string[] = [];
    for (const [, tcId, h, sig, e0, e1] of src.matchAll(re)) {
      vectors++;
      for (const [bit, want] of [
        [0, opt(e0)],
        [1, opt(e1)],
      ] as const) {
        const got = nobleRecover(unblob(h), unblob(sig), bit);
        if (got !== null) keys++;
        if (got !== want) mismatches.push(`tcId ${tcId} v ${bit}`);
      }
    }
    expect(mismatches).toEqual([]);
    expect(vectors).toBe(252);
    expect(keys).toBe(360);
  });

  it('both policy vectors, both v', () => {
    const re =
      /name = "([^"]*)";.*?hash = "([^"]*)"; r = "([^"]*)"; s = "([^"]*)";.*?evm0 = (null|\?"[^"]*"); evm1 = (null|\?"[^"]*")/g;
    const policy = src.slice(src.indexOf('public let policy'));
    let n = 0;
    for (const [, name, h, r, s, e0, e1] of policy.matchAll(re)) {
      n++;
      const sig = unblob(r) + unblob(s);
      expect(nobleRecover(unblob(h), sig, 0), name).toBe(opt(e0));
      expect(nobleRecover(unblob(h), sig, 1), name).toBe(opt(e1));
    }
    expect(n).toBe(2);
  });
});
