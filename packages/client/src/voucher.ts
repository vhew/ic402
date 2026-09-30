/// Voucher signing for ic402 sessions.
/// Signs cumulative voucher payloads using Ed25519.

import { encode } from 'cborg';

/**
 * CBOR-encode a voucher payload for signing.
 * Produces canonical CBOR: array(4) of [canisterId, sessionId, cumulativeAmount, sequence]
 *
 * M-7: `canisterId` (the verifying canister's principal text) is bound into the
 * signed payload so a voucher signed for one canister cannot be replayed against
 * another when the payer reuses the same Ed25519 key. MUST match the Motoko
 * Sessions.encodeVoucherPayload() field order exactly.
 */
function encodeVoucherPayload(
  canisterId: string,
  sessionId: string,
  cumulativeAmount: bigint,
  sequence: bigint,
): Uint8Array {
  return encode([canisterId, sessionId, cumulativeAmount, sequence]);
}

export interface VoucherSigner {
  sign(payload: Uint8Array): Promise<Uint8Array>;
  getPublicKey(): Promise<Uint8Array>;
  /**
   * 2.17.0: an actor factory whose agent authenticates AS this key. When present, the SDK submits
   * every session call through it, so the canister sees the session key as `msg.caller` and needs
   * no in-canister signature check (`Gateway.consumeVoucherFrom`). When absent, calls go through
   * the client's `actorFactory` and are authenticated by the voucher signature alone (legacy —
   * needs the canister's signed-voucher fallback: on by default in the library, off in the example).
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  actorFactory?: (canisterId: string) => any;
}

/**
 * Sign a cumulative voucher for a session.
 *
 * @param signer - A VoucherSigner. NB: an @icp-sdk Ed25519KeyIdentity does NOT satisfy the
 *   interface directly (its getPublicKey() returns a PublicKey object, not raw bytes) — wrap
 *   it: `{ sign: (p) => identity.sign(p), getPublicKey: async () => identity.getPublicKey().toRaw() }`.
 *   Passing a non-raw public key would register the session under a garbage key and every
 *   voucher would be rejected with #invalidSignature.
 * @param canisterId - The verifying canister's principal text (replay binding)
 * @param sessionId - The session to sign for
 * @param cumulativeAmount - Total amount consumed so far
 * @param sequence - Monotonically increasing sequence number
 * @returns The signed voucher blob
 */
export async function signVoucher(
  signer: VoucherSigner,
  canisterId: string,
  sessionId: string,
  cumulativeAmount: bigint,
  sequence: bigint,
): Promise<Uint8Array> {
  const payload = encodeVoucherPayload(canisterId, sessionId, cumulativeAmount, sequence);
  return signer.sign(payload);
}

export { encodeVoucherPayload };
