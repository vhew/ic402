import { describe, it, expect } from 'vitest';
import { encodeVoucherPayload, signVoucher, type VoucherSigner } from '../src/voucher.js';

// M-7: voucher payload is CBOR array(4) [canisterId, sessionId, cumulativeAmount, sequence].

describe('encodeVoucherPayload', () => {
  it('produces CBOR output starting with array marker 0x84', () => {
    const payload = encodeVoucherPayload('cid-1', 'sess-1', 100n, 1n);
    expect(payload[0]).toBe(0x84); // CBOR array(4)
  });

  it('produces deterministic output', () => {
    const a = encodeVoucherPayload('cid-1', 'sess-1', 100n, 1n);
    const b = encodeVoucherPayload('cid-1', 'sess-1', 100n, 1n);
    expect(a).toEqual(b);
  });

  it('different inputs produce different output', () => {
    const a = encodeVoucherPayload('cid-1', 'sess-1', 100n, 1n);
    const b = encodeVoucherPayload('cid-1', 'sess-1', 200n, 1n);
    expect(a).not.toEqual(b);
  });

  it('different canisterId produces different output (cross-canister binding)', () => {
    const a = encodeVoucherPayload('cid-1', 'sess-1', 100n, 1n);
    const b = encodeVoucherPayload('cid-2', 'sess-1', 100n, 1n);
    expect(a).not.toEqual(b);
  });

  // CROSS-BOUNDARY GOLDEN VECTOR. The canister rebuilds and Ed25519-verifies this exact byte string
  // in Sessions.encodeVoucherPayload; test/sessions.test.mo asserts the SAME vector on the mo:cbor
  // side. If cborg (here) and mo:cbor (canister) ever diverge, one of the two tests fails — the
  // client↔canister check that was missing when a voucher-payload mismatch could only surface on a
  // live session (a signed voucher that "does not verify against the registered public key").
  it('matches the canister golden vector byte-for-byte (aaaaa-aa / sess-1 / 1000 / 2)', () => {
    const payload = encodeVoucherPayload('aaaaa-aa', 'sess-1', 1000n, 2n);
    // prettier-ignore
    expect(Array.from(payload)).toEqual([
      132, 104, 97, 97, 97, 97, 97, 45, 97, 97, 102, 115, 101, 115, 115, 45, 49, 25, 3, 232, 2,
    ]);
  });
});

describe('signVoucher', () => {
  it('passes encoded payload to signer', async () => {
    let receivedPayload: Uint8Array | null = null;

    const mockSigner: VoucherSigner = {
      async sign(payload: Uint8Array): Promise<Uint8Array> {
        receivedPayload = payload;
        return new Uint8Array(64); // mock 64-byte signature
      },
      async getPublicKey(): Promise<Uint8Array> {
        return new Uint8Array(32);
      },
    };

    const signature = await signVoucher(mockSigner, 'cid-1', 'sess-1', 100n, 1n);
    expect(signature).toHaveLength(64);
    expect(receivedPayload).not.toBeNull();
    // The payload should be valid CBOR starting with array(4)
    expect(receivedPayload![0]).toBe(0x84);
  });

  it('encodes canisterId, sessionId, cumulativeAmount, and sequence into payload', async () => {
    let receivedPayload: Uint8Array | null = null;

    const mockSigner: VoucherSigner = {
      async sign(payload: Uint8Array): Promise<Uint8Array> {
        receivedPayload = payload;
        return new Uint8Array(64);
      },
      async getPublicKey(): Promise<Uint8Array> {
        return new Uint8Array(32);
      },
    };

    await signVoucher(mockSigner, 'cid-1', 'sess-1', 100n, 1n);
    const expected = encodeVoucherPayload('cid-1', 'sess-1', 100n, 1n);
    expect(receivedPayload).toEqual(expected);
  });
});
