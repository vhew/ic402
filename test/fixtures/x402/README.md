# x402 v2 wire-conformance golden fixtures

Golden wire vectors pinned against the OFFICIAL x402 reference implementation
(github.com/x402-foundation/x402 — the current home of Coinbase's x402 project):
`@x402/core@2.17.0` + `@x402/evm@2.17.0` + `@x402/fetch@2.17.0`, signing via `viem@2.55.0`.

Consumed by BOTH test suites — change any fixture and both must be updated together:

- `test/httphandler.test.mo` suite **"x402 v2 wire goldens"** pins the same bytes as
  Motoko string literals (outbound 402 emission) and parses `payment-header.golden.txt`
  through the real inbound path (`HttpHandler.parseX402PaymentHeader`).
- `test/x402-conformance.test.ts` validates these fixtures against the official
  `@x402/core` v2 zod schemas (`PaymentRequiredV2Schema`, `PaymentRequirementsV2Schema`,
  `PaymentPayloadV2Schema`) — no replica, no network.

## Files

- `payment-required.golden.json` — the exact 402 `PaymentRequired` object
  `HttpHandler.paymentRequiredJson` emits for the pinned live-challenge inputs
  (Base Sepolia USDC, amount 10000, server nonce `a1b2…8f90`, expiry 300_000_000_042 ns =
  fake-now + 300 s at the `mops test` constant fake clock `Time.now() == 42`, which is why
  `maxTimeoutSeconds` is exactly 300). Must match the `GOLDEN_402_LIVE` literal in
  `test/httphandler.test.mo` suite "x402 v2 wire goldens". The wire bytes are the COMPACT
  form: `JSON.stringify(JSON.parse(file))` reproduces them byte-for-byte (the file itself
  is prettier-formatted because repo CI runs `prettier --check` on all JSON).
- `payment-header.golden.txt` — the REAL base64 `PAYMENT-SIGNATURE` header produced by the
  official client (`@x402/core` `x402Client.createPaymentPayload` + `@x402/evm`
  `ExactEvmScheme`, EIP-3009 typed data signed by the all-`0x07` test key → payer
  `0x4a62316623ad457F02cDC5D997deD67a383EC569`). Determinism pinned at generation time:
  `Date.now() = 1750000000000` and `crypto.getRandomValues = 0x42-fill`, so
  `validBefore = 1750000300` and `authorization.nonce = 0x42×32` are stable.
- `payment-payload.golden.json` — the decoded JSON of that header (745 bytes compact);
  same prettier-vs-compact convention as above.

Generator scripts (official packages, pinned clocks) are documented in the two test files'
doc comments; the settlement-response shape `HttpHandler.settlementResponseJson` emits was
verified against the official `settleResponseSchema` key set in the same generation run.
