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
