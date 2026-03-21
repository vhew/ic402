/// Voucher signing for ic402 sessions.
/// Signs cumulative voucher payloads using Ed25519.

/**
 * CBOR-encode a voucher payload for signing.
 * Uses a deterministic canonical encoding: [sessionId, cumulativeAmount, sequence]
 */
function encodeVoucherPayload(
  sessionId: string,
  cumulativeAmount: bigint,
  sequence: bigint,
): Uint8Array {
  // Simple canonical CBOR encoding of a 3-element array
  const encoder = new TextEncoder();
  const sessionIdBytes = encoder.encode(sessionId);

  // CBOR: array(3)
  const parts: number[] = [];

  // Array header (3 items)
  parts.push(0x83);

  // Text string: sessionId
  encodeCborTextString(parts, sessionIdBytes);

  // Unsigned integer: cumulativeAmount
  encodeCborUint(parts, cumulativeAmount);

  // Unsigned integer: sequence
  encodeCborUint(parts, sequence);

  return new Uint8Array(parts);
}

function encodeCborTextString(out: number[], bytes: Uint8Array): void {
  encodeCborMajor(out, 3, bytes.length); // major type 3 = text string
  for (const b of bytes) out.push(b);
}

function encodeCborUint(out: number[], value: bigint): void {
  encodeCborMajor(out, 0, Number(value)); // major type 0 = unsigned integer
}

function encodeCborMajor(out: number[], major: number, length: number): void {
  const majorShifted = major << 5;
  if (length < 24) {
    out.push(majorShifted | length);
  } else if (length < 256) {
    out.push(majorShifted | 24);
    out.push(length);
  } else if (length < 65536) {
    out.push(majorShifted | 25);
    out.push((length >> 8) & 0xff);
    out.push(length & 0xff);
  } else {
    out.push(majorShifted | 26);
    out.push((length >> 24) & 0xff);
    out.push((length >> 16) & 0xff);
    out.push((length >> 8) & 0xff);
    out.push(length & 0xff);
  }
}

export interface VoucherSigner {
  sign(payload: Uint8Array): Promise<Uint8Array>;
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
