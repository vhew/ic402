import { describe, it, expect } from 'vitest';
import { encodeVoucherPayload, signVoucher, type VoucherSigner } from '../src/voucher.js';

describe('encodeVoucherPayload', () => {
  it('produces CBOR output starting with array marker 0x83', () => {
    const payload = encodeVoucherPayload('sess-1', 100n, 1n);
    expect(payload[0]).toBe(0x83); // CBOR array(3)
  });

  it('produces deterministic output', () => {
    const a = encodeVoucherPayload('sess-1', 100n, 1n);
    const b = encodeVoucherPayload('sess-1', 100n, 1n);
    expect(a).toEqual(b);
  });

  it('different inputs produce different output', () => {
    const a = encodeVoucherPayload('sess-1', 100n, 1n);
    const b = encodeVoucherPayload('sess-1', 200n, 1n);
    expect(a).not.toEqual(b);
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

    const signature = await signVoucher(mockSigner, 'sess-1', 100n, 1n);
    expect(signature).toHaveLength(64);
    expect(receivedPayload).not.toBeNull();
    // The payload should be valid CBOR starting with array(3)
    expect(receivedPayload![0]).toBe(0x83);
  });

  it('encodes sessionId, cumulativeAmount, and sequence into payload', async () => {
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

    await signVoucher(mockSigner, 'sess-1', 100n, 1n);
    const expected = encodeVoucherPayload('sess-1', 100n, 1n);
    expect(receivedPayload).toEqual(expected);
  });
});
