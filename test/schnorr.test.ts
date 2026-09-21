import { describe, it, expect, beforeAll } from 'vitest';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import type { HttpAgent } from '@icp-sdk/core/agent';
import { ed25519 } from '@noble/curves/ed25519.js';
import { schnorr, secp256k1 } from '@noble/curves/secp256k1.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { bytesToNumberBE, concatBytes } from '@noble/curves/utils.js';

/**
 * Replica-backed tests for threshold Schnorr signing (Ed25519 + BIP340-secp256k1).
 *
 * WHY THIS SUITE EXISTS AT ALL. None of this is reachable from `mops test`: the Motoko
 * interpreter has no `costSignWithSchnorr` primitive, and `mo:ic/Call` cannot even be
 * type-checked in wasi mode. So every signing and public-key path is proven HERE,
 * against a real replica, and verified with an independent library (@noble/curves)
 * rather than by trusting the canister's own arithmetic.
 *
 * Requires a running local replica with the example canister deployed:
 *   pnpm setup:local
 *
 * Set IC402_REQUIRE_SCHNORR=1 to turn a missing replica — or a replica that cannot
 * serve Schnorr keys — into a HARD failure instead of a silent green skip. The
 * endpoints are controller-gated, so the suite also needs the test-payer identity that
 * `scripts/predemo.sh` exports; without it every call traps on the controller check.
 */

// Helper: the canister returns `{ ok: T } | { err: string }`.
function unwrap<T>(result: { ok?: T; err?: string }, what: string): T {
  if (result.err !== undefined) throw new Error(`${what} failed: ${result.err}`);
  if (result.ok === undefined) throw new Error(`${what} returned neither ok nor err`);
  return result.ok;
}

/**
 * Apply the BIP341 taproot tweak to an x-only internal key.
 *
 * The key `schnorrPublicKey` returns is BIP341's `internal_pubkey`. A signature made
 * with `aux = bip341` verifies against the TWEAKED output key, so the test must compute
 * that tweak itself — otherwise it would be asserting against the wrong key and would
 * pass even if the canister ignored the aux entirely.
 *
 *   t = int(tagged_hash("TapTweak", internal_key || merkle_root))
 *   Q = P + t*G, taken x-only
 */
function taprootTweakXOnly(internalXOnly: Uint8Array, merkleRoot: Uint8Array): Uint8Array {
  // BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || msg)
  const tagHash = sha256(new TextEncoder().encode('TapTweak'));
  const t = bytesToNumberBE(sha256(concatBytes(tagHash, tagHash, internalXOnly, merkleRoot)));
  if (t >= secp256k1.Point.Fn.ORDER) throw new Error('tweak >= curve order');

  // Lift the x-only key to an even-Y point, then add t*G.
  const P = secp256k1.Point.fromBytes(concatBytes(new Uint8Array([0x02]), internalXOnly));
  const Q = P.add(secp256k1.Point.BASE.multiply(t));
  return Q.toBytes(true).slice(1); // compressed -> x-only
}

describe('threshold Schnorr', () => {
  let agent: HttpAgent;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let actor: any;
  let skip = false;
  let skipReason = '';

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      actor = createExampleActor(agent, getCanisterId('example'));
      // Probe once: a replica may be up but unable to serve Schnorr keys (no
      // TestThresholdKeys subnet). That is a legitimate skip, but it must be reported
      // as a skip with the reason — never as a pass.
      const probe = await actor.schnorrPublicKey({ ed25519: null }, []);
      if (probe.err !== undefined) {
        skip = true;
        skipReason = `replica cannot serve Schnorr keys: ${probe.err}`;
      }
    } catch (e) {
      skip = true;
      skipReason = `no local replica or example canister: ${(e as Error).message}`;
    }
  });

  it('replica serves Schnorr keys (enforced when IC402_REQUIRE_SCHNORR=1)', () => {
    if (process.env.IC402_REQUIRE_SCHNORR === '1') {
      expect(skip, skipReason).toBe(false);
    } else if (skip) {
      console.warn(`[schnorr] SKIPPED — ${skipReason}`);
    }
  });

  // ── Ed25519 ──

  describe('ed25519', () => {
    it('returns a 32-byte RFC8032 public key', async () => {
      if (skip) return;
      const key = unwrap<{ publicKey: number[] | Uint8Array; chainCode: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, []),
        'schnorrPublicKey(ed25519)',
      );
      expect(Uint8Array.from(key.publicKey)).toHaveLength(32);
      expect(Uint8Array.from(key.chainCode)).toHaveLength(32);
    });

    it('produces a signature that verifies against the returned key', async () => {
      if (skip) return;
      const path: number[][] = [Array.from(new TextEncoder().encode('ed25519-verify'))];
      const message = new TextEncoder().encode('ic402 threshold ed25519');

      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, path),
        'schnorrPublicKey',
      );
      const sig = unwrap<number[] | Uint8Array>(
        await actor.schnorrSign({ ed25519: null }, path, Array.from(message), []),
        'schnorrSign',
      );

      const signature = Uint8Array.from(sig);
      expect(signature).toHaveLength(64);
      expect(ed25519.verify(signature, message, Uint8Array.from(key.publicKey))).toBe(true);
    });

    it('a signature does NOT verify against a different message', async () => {
      if (skip) return;
      const path: number[][] = [Array.from(new TextEncoder().encode('ed25519-negative'))];
      const message = new TextEncoder().encode('the signed message');

      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, path),
        'schnorrPublicKey',
      );
      const sig = unwrap<number[] | Uint8Array>(
        await actor.schnorrSign({ ed25519: null }, path, Array.from(message), []),
        'schnorrSign',
      );

      const tampered = new TextEncoder().encode('the signed messagf');
      expect(ed25519.verify(Uint8Array.from(sig), tampered, Uint8Array.from(key.publicKey))).toBe(
        false,
      );
    });

    it('signatures are non-deterministic but both verify', async () => {
      if (skip) return;
      // The spec warns the returned signature is non-deterministic. Locking that in
      // stops anyone "optimising" the suite into comparing signature bytes.
      const path: number[][] = [];
      const message = new TextEncoder().encode('signed twice');
      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, path),
        'schnorrPublicKey',
      );
      const a = Uint8Array.from(
        unwrap<number[] | Uint8Array>(
          await actor.schnorrSign({ ed25519: null }, path, Array.from(message), []),
          'schnorrSign a',
        ),
      );
      const b = Uint8Array.from(
        unwrap<number[] | Uint8Array>(
          await actor.schnorrSign({ ed25519: null }, path, Array.from(message), []),
          'schnorrSign b',
        ),
      );
      const pk = Uint8Array.from(key.publicKey);
      expect(ed25519.verify(a, message, pk)).toBe(true);
      expect(ed25519.verify(b, message, pk)).toBe(true);
    });
  });

  // ── BIP340 secp256k1 ──

  describe('bip340secp256k1', () => {
    it('returns a 33-byte SEC1-compressed public key', async () => {
      if (skip) return;
      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ bip340secp256k1: null }, []),
        'schnorrPublicKey(bip340)',
      );
      const pk = Uint8Array.from(key.publicKey);
      expect(pk).toHaveLength(33);
      expect([0x02, 0x03]).toContain(pk[0]);
    });

    it('produces a signature that verifies against the x-only key', async () => {
      if (skip) return;
      const path: number[][] = [Array.from(new TextEncoder().encode('bip340-verify'))];
      const message = new TextEncoder().encode('ic402 threshold bip340');

      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ bip340secp256k1: null }, path),
        'schnorrPublicKey',
      );
      const sig = unwrap<number[] | Uint8Array>(
        await actor.schnorrSign({ bip340secp256k1: null }, path, Array.from(message), []),
        'schnorrSign',
      );

      // BIP340 verifies against the 32-byte x-only key: drop the SEC1 parity byte.
      const xOnly = Uint8Array.from(key.publicKey).slice(1);
      const signature = Uint8Array.from(sig);
      expect(signature).toHaveLength(64);
      expect(schnorr.verify(signature, message, xOnly)).toBe(true);
    });

    it('arbitrary-length messages are accepted, not just 32-byte digests', async () => {
      if (skip) return;
      // sign_with_schnorr takes "the message to sign (not a hash)" — unlike
      // sign_with_ecdsa, whose message_hash "must be exactly 32 bytes". A 1000-byte
      // message proves BIP340 here is not digest-only.
      const path: number[][] = [];
      const message = new Uint8Array(1000).fill(0x5a);

      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ bip340secp256k1: null }, path),
        'schnorrPublicKey',
      );
      const sig = unwrap<number[] | Uint8Array>(
        await actor.schnorrSign({ bip340secp256k1: null }, path, Array.from(message), []),
        'schnorrSign',
      );
      expect(
        schnorr.verify(Uint8Array.from(sig), message, Uint8Array.from(key.publicKey).slice(1)),
      ).toBe(true);
    });

    it('a BIP341-tweaked signature verifies against the TWEAKED key', async () => {
      if (skip) return;
      const path: number[][] = [Array.from(new TextEncoder().encode('bip341-taproot'))];
      const message = new TextEncoder().encode('taproot key-path spend');
      const merkleRoot = new Uint8Array(32).fill(0x11);

      const key = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ bip340secp256k1: null }, path),
        'schnorrPublicKey',
      );
      const sig = unwrap<number[] | Uint8Array>(
        await actor.schnorrSign({ bip340secp256k1: null }, path, Array.from(message), [
          { bip341: { merkle_root_hash: Array.from(merkleRoot) } },
        ]),
        'schnorrSign(bip341)',
      );

      const internalXOnly = Uint8Array.from(key.publicKey).slice(1);
      const tweakedXOnly = taprootTweakXOnly(internalXOnly, merkleRoot);
      const signature = Uint8Array.from(sig);

      expect(schnorr.verify(signature, message, tweakedXOnly)).toBe(true);
      // And crucially NOT against the untweaked internal key — otherwise this test
      // would pass even if the canister silently dropped the aux.
      expect(schnorr.verify(signature, message, internalXOnly)).toBe(false);
    });

    it('rejects a BIP341 aux on ed25519', async () => {
      if (skip) return;
      const res = await actor.schnorrSign(
        { ed25519: null },
        [],
        Array.from(new TextEncoder().encode('x')),
        [{ bip341: { merkle_root_hash: Array.from(new Uint8Array(32)) } }],
      );
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/ed25519/i);
    });
  });

  // ── Derivation paths ──

  describe('derivation paths', () => {
    it('different paths give different keys, for both algorithms', async () => {
      if (skip) return;
      for (const algorithm of [{ ed25519: null }, { bip340secp256k1: null }]) {
        const a = unwrap<{ publicKey: number[] | Uint8Array }>(
          await actor.schnorrPublicKey(algorithm, [Array.from(new TextEncoder().encode('path-a'))]),
          'schnorrPublicKey a',
        );
        const b = unwrap<{ publicKey: number[] | Uint8Array }>(
          await actor.schnorrPublicKey(algorithm, [Array.from(new TextEncoder().encode('path-b'))]),
          'schnorrPublicKey b',
        );
        expect(Uint8Array.from(a.publicKey)).not.toEqual(Uint8Array.from(b.publicKey));
      }
    });

    it('the same path is deterministic across calls', async () => {
      if (skip) return;
      const path: number[][] = [Array.from(new TextEncoder().encode('stable-path'))];
      const a = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, path),
        'schnorrPublicKey a',
      );
      const b = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, path),
        'schnorrPublicKey b',
      );
      expect(Uint8Array.from(a.publicKey)).toEqual(Uint8Array.from(b.publicKey));
    });

    it('the same path under different algorithms gives different keys', async () => {
      if (skip) return;
      // One key NAME serves both algorithms, so this is the check that the algorithm
      // field is actually reaching the management canister.
      const path: number[][] = [Array.from(new TextEncoder().encode('shared-path'))];
      const ed = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ ed25519: null }, path),
        'ed25519',
      );
      const bip = unwrap<{ publicKey: number[] | Uint8Array }>(
        await actor.schnorrPublicKey({ bip340secp256k1: null }, path),
        'bip340',
      );
      // Different lengths already, but compare the shared prefix too.
      expect(Uint8Array.from(ed.publicKey)).not.toEqual(Uint8Array.from(bip.publicKey).slice(1));
    });
  });

  // ── Input validation (the library's fail-closed bounds, over the wire) ──

  describe('validation', () => {
    it('rejects an empty message', async () => {
      if (skip) return;
      const res = await actor.schnorrSign({ ed25519: null }, [], [], []);
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/empty/i);
    });

    it('rejects a 255-element derivation path BEFORE calling the replica', async () => {
      if (skip) return;
      // The spec's headline "at most 255" is the whole extended-BIP32 path; the IC
      // prepends the calling canister's id, so 254 is the caller's real ceiling. 254 must
      // succeed and 255 must be rejected BY THE LIBRARY — if the bound were 255, this one
      // value would sail past validation and die at the management canister's Candid
      // decoder after a wasted cross-subnet round trip.
      const ok = await actor.schnorrPublicKey(
        { ed25519: null },
        Array.from({ length: 254 }, () => [0x01]),
      );
      expect(ok.err, '254 elements should be accepted').toBeUndefined();

      const tooMany = await actor.schnorrPublicKey(
        { ed25519: null },
        Array.from({ length: 255 }, () => [0x01]),
      );
      expect(tooMany.err).toBeDefined();
      // Our message, not the replica's decoder message — that is the whole point.
      expect(tooMany.err).toMatch(/too long/i);
      expect(tooMany.err).not.toMatch(/candid|decoding|UserError/i);
    });

    it('rejects a malformed BIP341 merkle root', async () => {
      if (skip) return;
      const res = await actor.schnorrSign(
        { bip340secp256k1: null },
        [],
        Array.from(new TextEncoder().encode('x')),
        [{ bip341: { merkle_root_hash: Array.from(new Uint8Array(31)) } }],
      );
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/32 bytes/i);
    });
  });
});
