/// Voucher signing for ic402 sessions.
/// Signs cumulative voucher payloads using Ed25519.

import { encode } from 'cborg';

/**
 * CBOR-encode a voucher payload for signing.
 * Produces canonical CBOR: array(3) of [sessionId, cumulativeAmount, sequence]
 */
function encodeVoucherPayload(
  sessionId: string,
  cumulativeAmount: bigint,
  sequence: bigint,
): Uint8Array {
  return encode([sessionId, cumulativeAmount, sequence]);
}

export interface VoucherSigner {
  sign(payload: Uint8Array): Promise<Uint8Array>;
  getPublicKey(): Promise<Uint8Array>;
}

/**
 * Sign a cumulative voucher for a session.
 *
 * @param signer - An object with a sign method (e.g., Ed25519KeyIdentity)
 * @param sessionId - The session to sign for
 * @param cumulativeAmount - Total amount consumed so far
 * @param sequence - Monotonically increasing sequence number
 * @returns The signed voucher blob
 */
export async function signVoucher(
  signer: VoucherSigner,
  sessionId: string,
  cumulativeAmount: bigint,
  sequence: bigint,
): Promise<Uint8Array> {
  const payload = encodeVoucherPayload(sessionId, cumulativeAmount, sequence);
  return signer.sign(payload);
}

export { encodeVoucherPayload };
