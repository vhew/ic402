import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import {
  PaymentRequiredV2Schema,
  PaymentRequirementsV2Schema,
  PaymentPayloadV2Schema,
} from '@x402/core/schemas';

/**
 * x402 v2 wire-conformance tests — pure schema validation, NO replica, NO network.
 *
 * Validates the golden wire fixtures in test/fixtures/x402/ against the OFFICIAL x402
 * v2 zod schemas from @x402/core@2.17.0 (github.com/x402-foundation/x402 — the current
 * home of Coinbase's x402 project). The fixtures are pinned on the Motoko side too:
 * test/httphandler.test.mo suite "x402 v2 wire goldens" asserts HttpHandler emits
 * payment-required.golden.json byte-for-byte and parses payment-header.golden.txt
 * field-for-field — so this suite proves the SAME bytes the canister speaks are what a
 * stock v2 client accepts and sends.
 *
 * Provenance of the header fixture: produced by the official client packages
 * @x402/core@2.17.0 (x402Client.createPaymentPayload) + @x402/evm@2.17.0
 * (ExactEvmScheme, EIP-3009 typed data) signed via viem@2.55.0 with the test key
 * 0x0707…07 (payer 0x4a62316623ad457F02cDC5D997deD67a383EC569); generation pinned
 * Date.now()=1750000000000 and crypto.getRandomValues=0x42-fill for determinism.
 */

const fixture = (name: string): string =>
  readFileSync(new URL(`./fixtures/x402/${name}`, import.meta.url), 'utf8');

// Must match the GOLDEN_402_LIVE literal in test/httphandler.test.mo suite
// "x402 v2 wire goldens" — the exact compact bytes HttpHandler.paymentRequiredJson emits
// (the .json fixture stores the same object prettier-formatted; compacting restores it).
const GOLDEN_402_COMPACT =
  '{"x402Version":2,"error":"PAYMENT-SIGNATURE header is required","resource":{"url":"https://example-canister.icp0.io/content/premium-1"},"accepts":[{"scheme":"exact","network":"eip155:84532","amount":"10000","asset":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","payTo":"0x99C851eaa3c3976914D63b822C67e201EC0BFBb8","maxTimeoutSeconds":300,"extra":{"name":"USDC","version":"2","assetTransferMethod":"eip3009","ic402Nonce":"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90","ic402Expiry":300000000042}}]}';

describe('x402 v2 wire conformance (official @x402/core@2.17.0 schemas)', () => {
  const paymentRequired = JSON.parse(fixture('payment-required.golden.json'));

  it('402 PaymentRequired golden passes the official PaymentRequiredV2Schema', () => {
    const res = PaymentRequiredV2Schema.safeParse(paymentRequired);
    expect(res.success, JSON.stringify(res.success ? undefined : res.error.issues)).toBe(true);
  });

  it('every accepts[] entry passes the official PaymentRequirementsV2Schema', () => {
    expect(paymentRequired.accepts.length).toBeGreaterThan(0);
    for (const entry of paymentRequired.accepts) {
      const res = PaymentRequirementsV2Schema.safeParse(entry);
      expect(res.success, JSON.stringify(res.success ? undefined : res.error.issues)).toBe(true);
    }
  });

  it('402 golden compacts to the exact bytes pinned in test/httphandler.test.mo', () => {
    // JSON.stringify(JSON.parse(...)) reproduces the wire bytes (compact, key order kept):
    // the same string the Motoko suite asserts HttpHandler.paymentRequiredJson emits.
    expect(JSON.stringify(paymentRequired)).toBe(GOLDEN_402_COMPACT);
  });

  it('PAYMENT-SIGNATURE header golden base64-decodes to the pinned payload JSON', () => {
    const header = fixture('payment-header.golden.txt').trim();
    const decodedBytes = Buffer.from(header, 'base64');
    expect(decodedBytes.length).toBe(745); // byte-exact vs the official encoder output
    const decoded = decodedBytes.toString('utf8');
    const payload = JSON.parse(decoded);
    // decoded header is canonical compact JSON, and matches the decoded-payload fixture
    expect(JSON.stringify(payload)).toBe(decoded.trim());
    expect(payload).toEqual(JSON.parse(fixture('payment-payload.golden.json')));
  });

  it('decoded payment payload passes the official PaymentPayloadV2Schema', () => {
    const payload = JSON.parse(fixture('payment-payload.golden.json'));
    const res = PaymentPayloadV2Schema.safeParse(payload);
    expect(res.success, JSON.stringify(res.success ? undefined : res.error.issues)).toBe(true);
    // the EIP-3009 authorization the canister settles from
    expect(payload.payload.authorization.from).toBe('0x4a62316623ad457F02cDC5D997deD67a383EC569');
    expect(payload.payload.authorization.validBefore).toBe('1750000300');
    expect(payload.accepted.network).toBe('eip155:84532');
  });

  // ── Labeled regression checks for the 2026-07-10 HttpHandler fixes ──

  it('REGRESSION (maxTimeoutSeconds > 0): the official schema rejects 0, ic402 never emits it', () => {
    // HttpHandler.acceptsArrayJson: expiry==0 (discovery/describe) -> 300; expired or
    // sub-second window -> 1. Emitting 0 made strict v2 clients reject the whole 402.
    for (const entry of paymentRequired.accepts) {
      expect(entry.maxTimeoutSeconds).toBeGreaterThan(0);
    }
    // Prove the constraint is real: the pre-fix output (maxTimeoutSeconds: 0) must fail.
    const preFix = { ...paymentRequired.accepts[0], maxTimeoutSeconds: 0 };
    expect(PaymentRequirementsV2Schema.safeParse(preFix).success).toBe(false);
  });

  it('REGRESSION (extra.name): Base Sepolia USDC advertises EIP-712 domain name "USDC"', () => {
    // The EIP-712 domain name is load-bearing (it enters the domain separator the payer
    // signs and the token verifies on-chain). Base Sepolia USDC (FiatToken v2.2) is
    // "USDC" — the old blanket "USD Coin" fallback made every transferWithAuthorization
    // revert with an invalid signature when tokenName was left unconfigured.
    const entry = paymentRequired.accepts[0];
    expect(entry.network).toBe('eip155:84532');
    expect(entry.asset.toLowerCase()).toBe('0x036cbd53842c5426634e7929541ec2318f3dcf7e');
    expect(entry.extra.name).toBe('USDC');
    expect(entry.extra.version).toBe('2');
  });
});
