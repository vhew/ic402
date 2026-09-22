import { describe, it, expect, beforeAll } from 'vitest';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import type { HttpAgent } from '@icp-sdk/core/agent';
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { keccak_256 } from '@noble/hashes/sha3.js';

/**
 * Replica-backed tests for EvmSigner's derivation path (2.15.0).
 *
 * WHY HERE AND NOT IN `mops test`. Deriving an address or signing needs
 * `ecdsa_public_key` / `sign_with_ecdsa`, which the Motoko interpreter cannot reach —
 * the same limit that forces the Schnorr suite onto a replica. The construction and
 * validation half lives in `test/evmsigner-path.test.mo`; the address and signature
 * guarantees are proven here, against real tECDSA.
 *
 * Signatures are recovered INDEPENDENTLY with @noble/curves from the returned digest and
 * r/s/v, not read off the canister's own `signer` field — otherwise the test would be
 * asking the canister to confirm its own arithmetic.
 *
 * Requires a running local replica with the example canister deployed:
 *   pnpm setup:local && bash scripts/predemo.sh
 *
 * Set IC402_REQUIRE_REPLICA=1 to turn a missing replica into a hard failure rather than a
 * silent green skip. The endpoints are controller-gated, so the test-payer identity that
 * `scripts/predemo.sh` exports is required.
 */

function unwrap<T>(result: { ok?: T; err?: string }, what: string): T {
  if (result.err !== undefined) throw new Error(`${what} failed: ${result.err}`);
  if (result.ok === undefined) throw new Error(`${what} returned neither ok nor err`);
  return result.ok;
}

const hexToBytes = (h: string): Uint8Array =>
  Uint8Array.from((h.replace(/^0x/, '').match(/../g) ?? []).map((b) => parseInt(b, 16)));

/** EVM address = last 20 bytes of keccak256(uncompressed pubkey without the 0x04 prefix). */
function addressFromPublicKey(pub: Uint8Array): string {
  const body = pub.length === 65 ? pub.slice(1) : pub;
  return '0x' + Buffer.from(keccak_256(body).slice(-20)).toString('hex');
}

/** Recover the signer address from an EIP-712 digest and the returned r/s/v. */
function recoverAddress(digestHex: string, rHex: string, sHex: string, v: number): string {
  const digest = hexToBytes(digestHex);
  const recovery = v - 27; // the canister returns v already offset by 27
  const sig = secp256k1.Signature.fromBytes(
    new Uint8Array([...hexToBytes(rHex), ...hexToBytes(sHex)]),
  ).addRecoveryBit(recovery);
  return addressFromPublicKey(sig.recoverPublicKey(digest).toBytes(false));
}

const enc = (s: string): number[] => Array.from(new TextEncoder().encode(s));

describe('EvmSigner derivation path', () => {
  let agent: HttpAgent;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let actor: any;
  let skip = false;
  let skipReason = '';

  // A labelled path of the shape downstream will use.
  const PATH_A: number[][] = [enc('engramx'), enc('payments'), enc('secp256k1'), enc('1')];
  const PATH_B: number[][] = [enc('engramx'), enc('identity'), enc('secp256k1'), enc('1')];

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      actor = createExampleActor(agent, getCanisterId('example'));
      const probe = await actor.evmAddressAt([]);
      if (probe.err !== undefined) {
        skip = true;
        skipReason = `replica cannot derive EVM addresses: ${probe.err}`;
      }
    } catch (e) {
      skip = true;
      skipReason = `no local replica or example canister: ${(e as Error).message}`;
    }
  });

  it('replica derives EVM addresses (enforced when IC402_REQUIRE_REPLICA=1)', () => {
    if (process.env.IC402_REQUIRE_REPLICA === '1') {
      expect(skip, skipReason).toBe(false);
    } else if (skip) {
      console.warn(`[evmsigner-path] SKIPPED — ${skipReason}`);
    }
  });

  // ── (a) different paths ⇒ different addresses, each signature recovering to its own ──

  it('two paths on the same key name derive DIFFERENT addresses', async () => {
    if (skip) return;
    const a = unwrap<string>(await actor.evmAddressAt(PATH_A), 'evmAddressAt(A)');
    const b = unwrap<string>(await actor.evmAddressAt(PATH_B), 'evmAddressAt(B)');
    expect(a).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(b).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(a.toLowerCase()).not.toEqual(b.toLowerCase());
  });

  it('a signature from each path recovers to THAT path’s own address', async () => {
    if (skip) return;
    // Independent recovery: the canister hands back digest + r/s/v, and @noble/curves
    // recovers the public key from them. If the path were ignored, both signatures would
    // recover to the same address and this fails.
    const domainSeparator = Array.from(new Uint8Array(32).fill(0xa1));
    const structHash = Array.from(new Uint8Array(32).fill(0xb2));

    for (const [label, path] of [
      ['A', PATH_A],
      ['B', PATH_B],
    ] as const) {
      const addr = unwrap<string>(await actor.evmAddressAt(path), `evmAddressAt(${label})`);
      const sig = unwrap<{ digest: string; r: string; s: string; v: number; signer: string }>(
        await actor.signTypedDataAt(path, domainSeparator, structHash),
        `signTypedDataAt(${label})`,
      );

      const recovered = recoverAddress(sig.digest, sig.r, sig.s, Number(sig.v));
      expect(recovered.toLowerCase(), `path ${label} recovery`).toEqual(addr.toLowerCase());
      // The canister's own claim should agree with independent recovery.
      expect(sig.signer.toLowerCase()).toEqual(recovered.toLowerCase());
    }
  });

  it('the two paths produce signatures recovering to different addresses', async () => {
    if (skip) return;
    const domainSeparator = Array.from(new Uint8Array(32).fill(0xc3));
    const structHash = Array.from(new Uint8Array(32).fill(0xd4));

    const sigA = unwrap<{ digest: string; r: string; s: string; v: number }>(
      await actor.signTypedDataAt(PATH_A, domainSeparator, structHash),
      'signTypedDataAt(A)',
    );
    const sigB = unwrap<{ digest: string; r: string; s: string; v: number }>(
      await actor.signTypedDataAt(PATH_B, domainSeparator, structHash),
      'signTypedDataAt(B)',
    );

    // Same message, so the digests match — only the key differs.
    expect(sigA.digest).toEqual(sigB.digest);
    const recA = recoverAddress(sigA.digest, sigA.r, sigA.s, Number(sigA.v));
    const recB = recoverAddress(sigB.digest, sigB.r, sigB.s, Number(sigB.v));
    expect(recA.toLowerCase()).not.toEqual(recB.toLowerCase());
  });

  // ── (b) the compatibility guarantee ──

  it('the one-argument form and the explicit [] form derive the SAME address', async () => {
    if (skip) return;
    // `getEvmAddress` is the 2.14.0 one-argument signer built at actor init; `evmAddressAt([])`
    // goes through EvmSignerAt with an explicit empty path. They must agree, or the upgrade
    // silently moved a published address.
    const legacy: string = await actor.getEvmAddress();
    const explicitEmpty = unwrap<string>(await actor.evmAddressAt([]), 'evmAddressAt([])');
    expect(legacy).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(explicitEmpty.toLowerCase()).toEqual(legacy.toLowerCase());
  });

  it('a labelled path does NOT collide with the default address', async () => {
    if (skip) return;
    // The other half of the compatibility story: opting into a path must actually move the
    // address, or the labelling is decorative.
    const legacy: string = await actor.getEvmAddress();
    const labelled = unwrap<string>(await actor.evmAddressAt(PATH_A), 'evmAddressAt(A)');
    expect(labelled.toLowerCase()).not.toEqual(legacy.toLowerCase());
  });

  it('the same path is deterministic across calls', async () => {
    if (skip) return;
    const first = unwrap<string>(await actor.evmAddressAt(PATH_A), 'first');
    const second = unwrap<string>(await actor.evmAddressAt(PATH_A), 'second');
    expect(second.toLowerCase()).toEqual(first.toLowerCase());
  });

  // ── (c) over-limit paths refused over the wire ──

  it('refuses a 255-element path with #err, not a trap', async () => {
    if (skip) return;
    const tooMany = Array.from({ length: 255 }, () => [0x01]);
    const res = await actor.evmAddressAt(tooMany);
    expect(res.err).toBeDefined();
    expect(res.err).toMatch(/too long/i);
    // Our validation, not the replica's Candid decoder.
    expect(res.err).not.toMatch(/candid|decoding|UserError/i);
  });

  it('refuses a path over the byte budget with #err', async () => {
    if (skip) return;
    const fat = Array.from({ length: 8192 }, () => 0x02);
    const res = await actor.evmAddressAt([fat, [0x03]]);
    expect(res.err).toBeDefined();
    expect(res.err).toMatch(/too large/i);
  });
});
