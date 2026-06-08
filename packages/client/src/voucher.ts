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
}

/**
 * Sign a cumulative voucher for a session.
 *
 * @param signer - An object with a sign method (e.g., Ed25519KeyIdentity)
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
