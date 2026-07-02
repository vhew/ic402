import { describe, it, expect } from 'vitest';
import { IDL } from '@icp-sdk/core/candid';
import {
  PaymentSignature,
  Eip3009Authorization,
  Voucher,
  type PaymentSignatureArg,
  type Eip3009AuthorizationArg,
} from '../packages/client/src/idl.js';

// Schema-evolution drift guard (replica-free). A client-built wire payload that omits a field the
// Candid record requires — e.g. v2.5.0's PaymentSignature.asset opt — fails agent-js encoding, but
// only at RUNTIME against a live replica, which the fast suites never start. Round-tripping the
// representative payloads through the ACTUAL exported record IDLs surfaces that drift HERE, on
// every push. This is precisely the class that slipped through after ded7ffb (4 integration
// payloads left without `asset`, invisible until run against a replica).

const auth: Eip3009AuthorizationArg = {
  from: '0x0000000000000000000000000000000000000001',
  to: '0x0000000000000000000000000000000000000002',
  value: 1_000n,
  validAfter: 0n,
  validBefore: 1_900_000_000n,
  nonce: new Uint8Array(32),
  v: 27,
  r: new Uint8Array(32),
  s: new Uint8Array(32),
};

describe('IDL encode contract — client-built message records', () => {
  it('PaymentSignature (ICP) encodes with every wire field present', () => {
    const sig: PaymentSignatureArg = {
      scheme: 'exact',
      network: 'icp:1',
      signature: new Uint8Array(0),
      publicKey: [],
      sender: 'aaaaa-aa',
      nonce: new Uint8Array(32),
      authorization: [],
      asset: [],
    };
    expect(() => IDL.encode([PaymentSignature], [sig])).not.toThrow();
  });

  it('PaymentSignature (EVM) encodes with a nested authorization + asset', () => {
    const sig: PaymentSignatureArg = {
      scheme: 'exact',
      network: 'eip155:84532',
      signature: new Uint8Array(0),
      publicKey: [],
      sender: '0x0000000000000000000000000000000000000001',
      nonce: new Uint8Array(32),
      authorization: [auth],
      asset: ['0x036CbD53842c5426634e7929541eC2318f3dCF7e'],
    };
    expect(() => IDL.encode([PaymentSignature], [sig])).not.toThrow();
  });

  it('a payload that omits the `asset` opt fails to encode (the ded7ffb drift)', () => {
    // Deliberately untyped so the omission compiles — this is the runtime shape a stale client
    // (or a not-yet-updated test) sends, and exactly what broke the integration suite.
    const stale: Record<string, unknown> = {
      scheme: 'exact',
      network: 'icp:1',
      signature: new Uint8Array(0),
      publicKey: [],
      sender: 'aaaaa-aa',
      nonce: new Uint8Array(32),
      authorization: [],
      // asset intentionally MISSING
    };
    expect(() => IDL.encode([PaymentSignature], [stale])).toThrow();
  });

  it('Eip3009Authorization encodes with all 9 fields', () => {
    expect(() => IDL.encode([Eip3009Authorization], [auth])).not.toThrow();
  });

  it('Voucher encodes with all fields', () => {
    const voucher = {
      sessionId: 's',
      cumulativeAmount: 1_000n,
      sequence: 1n,
      signature: new Uint8Array(64),
    };
    expect(() => IDL.encode([Voucher], [voucher])).not.toThrow();
  });
});
