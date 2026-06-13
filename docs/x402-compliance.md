# ic402 ↔ x402 compliance

**Target: x402 v2** (the launched current spec, 2025‑12‑11). This document is both the
design spec and the live status of bringing ic402's **EVM rail** to genuine v2 conformance,
and the explicit statement of what stays non‑standard by nature.

> Sources: `github.com/coinbase/x402` — `specs/x402-specification-v2.md`,
> `specs/schemes/exact/scheme_exact_evm.md`, `specs/transports-v2/http.md`; `x402.org`
> (v2 launch). Cross‑checked against the ic402 code in this repo.

---

## TL;DR

- **The EVM (`eip155:*`, `exact` scheme) rail is what can be made x402‑compliant**, and is the
  focus here.
- **The ICP / ckUSDC (ICRC‑2) rail and the streaming‑session / voucher subsystem cannot be
  "compliant"** — no x402 scheme exists for them (the community ICP scheme PR #543
  `scheme_exact_icp.md` was closed *unmerged* 2026‑02‑16). They are kept as clearly‑labelled
  non‑standard extensions and are gated so they don't break a strict v2 client.
- ic402 is a **resource server that self‑hosts the facilitator role** (it verifies the EIP‑712
  signature and broadcasts `transferWithAuthorization` itself, via threshold‑ECDSA). The spec
  explicitly blesses "server‑as‑its‑own‑facilitator", so the fused `Gateway.settle` model is
  conformant. The standalone facilitator HTTP API (`/verify`, `/settle`, `/supported`) and the
  discovery Bazaar were **optional** for resource‑server compliance (they make ic402 callable
  *by third parties* as a facilitator) — these are **now implemented** as well (see Status).

## Why this was more than a rename

Before this work ic402 was a v1/v2 hybrid that **no off‑the‑shelf v2 client could actually
pay**, for two architectural reasons beyond field names:

1. The server read only the `x-payment` header; a stock v2 client sends **`PAYMENT-SIGNATURE`**.
2. Settlement was keyed on a **server‑minted nonce** the client had to echo back as a
   non‑standard `ic402Nonce` field. A conformant client never sends it, so `nonceManager.lock`
   returned `#expired` and **every** stock payment was rejected. (That echo was the v2.0.0 H‑10
   amount‑binding fix — and it is exactly what made the rail non‑standard.)

The clean resolution: **v2's exact‑equality rule (`value == amount`)** is what lets us drop the
server nonce on the EVM rail. With the amount advertised per‑resource and `value == amount`
enforced, amount‑binding is structural and replay protection comes from the EIP‑3009
`authorization.nonce` plus the on‑chain single‑use `transferWithAuthorization`. Adopting v2
*removes* the non‑standard machinery rather than adding more.

---

## v2 wire format (what ic402 now emits)

### 402 challenge — `PaymentRequired`

Transport is **headers**: the 402 carries a base64 `PAYMENT-REQUIRED` header (the JSON body is
served too, as an implementation convenience / for non‑browser tooling).

```jsonc
{
  "x402Version": 2,
  "error": "PAYMENT-SIGNATURE header is required",   // on the initial challenge
  "resource": { "url": "https://<host>/content/<id>", "description": "...", "mimeType": "..." },
  "accepts": [
    {
      "scheme": "exact",
      "network": "eip155:84532",          // CAIP-2
      "amount": "5000",                    // renamed from maxAmountRequired
      "asset": "0x036CbD…",                // token address
      "payTo": "0x…canister EVM address…",
      "maxTimeoutSeconds": 120,            // derived from the real challenge expiry
      "extra": {
        "name": "USDC", "version": "2",    // EIP-712 domain (load-bearing for sig verify)
        "assetTransferMethod": "eip3009",  // default method
        "ic402": { "nonce": "…", "expiry": … }   // NON-STANDARD: ic402-only, ignored by stock clients
      }
    }
    // …one entry per configured EVM chain; the ICP entry is gated (see below)
  ]
}
```

Notes:
- `ResourceInfo.url` is built from the request `Host` header + path (ICP `request.url` is
  path‑only). `description`/`mimeType` are optional.
- The non‑standard `ic402Nonce`/`expiry` no longer sit as bare top‑level `PaymentRequirements`
  fields — they live under `extra.ic402` (the only spec‑sanctioned bag), so a stock client
  ignores them and is unaffected.

### Retry — `PAYMENT-SIGNATURE` header (base64 `PaymentPayload`)

```jsonc
{
  "x402Version": 2,
  "accepted": { /* the chosen PaymentRequirements echoed back verbatim */ },
  "payload": {
    "signature": "0x…",
    "authorization": { "from","to","value","validAfter","validBefore","nonce" }
  }
}
```

The server reads `PAYMENT-SIGNATURE` (case‑insensitive) as the primary header and still accepts
the legacy `x-payment` as a fallback.

### Success — `PAYMENT-RESPONSE` header (base64 `SettlementResponse`)

```jsonc
{ "success": true, "transaction": "0x…txhash", "network": "eip155:84532",
  "payer": "0x…", "amount": "5000" }
// failure: { "success": false, "errorReason": "<v2 code>", "transaction": "", "network": "…" }
```

### exact‑EVM verify rule

`authorization.value == amount` (exact equality, v2 §6.1.2) and `authorization.to == payTo`
(the canister's own EVM address — this is also the C‑1 payment‑bypass guard). On mismatch the
error reason maps to the v2 vocabulary (`invalid_exact_evm_payload_authorization_value_mismatch`,
`recipient_mismatch`, …).

---

## The ICP rail & sessions (non‑standard by design)

- The ckUSDC / ICRC‑2 rail emits a clearly non‑standard scheme and **is gated behind a
  non‑strict mode** so a strict v2 client only sees the `eip155:*` `exact` option it can pay.
  It is documented as an ic402 extension, never claimed as x402‑conformant.
- The Ed25519 cumulative‑voucher streaming‑session subsystem has no x402 message type and is
  invoked over Candid, **outside** the x402 `accepts[]` envelope. It stays there. v2
  exact‑equality does **not** apply to session cap‑deposits.

---

## Status

| Area | Item | Status |
|---|---|---|
| Wire | `x402Version` → 2, `PaymentRequired` + `ResourceInfo`, `amount` rename, `extra.assetTransferMethod` | ✅ done |
| Wire | `PAYMENT-SIGNATURE` read (primary) + `x-payment` fallback | ✅ done |
| Wire | `SettlementResponse` + `PAYMENT-RESPONSE` header on success | ✅ done |
| Wire | relocate `ic402Nonce`/`expiry` → `extra.ic402`; `maxTimeoutSeconds` from real expiry | ✅ done |
| CORS | `Access-Control-Expose-Headers`, `Allow-Headers`, `OPTIONS` preflight | ✅ done |
| Scheme | `value >= amount` → `value == amount`; v2 error‑reason codes | ✅ done |
| Scheme | EVM rail payable without the server nonce (EIP‑3009 nonce replay + per‑resource amount) | ✅ done |
| Client | real `resource` (drop empty `{}`), `ic402Nonce` under `extra`, remove dead v1 helper | ✅ done |
| Client | echo the advertised `accepts[]` entry *verbatim* as `accepted` | ✅ done (client rewrites the canister-built header post-signing; `applyVerbatimAccepted`) |
| Hardening | cross‑resource amount check on the **HTTP** handlers + at the gateway (before funds move) | ✅ done |
| Facilitator | `GET /supported` (kinds + signers) | ✅ done |
| Facilitator | `POST /verify` (off‑chain) + `POST /settle` (v2 `SettlementResponse`) | ✅ done |
| Discovery | `GET /discovery/resources` (Bazaar) | ✅ done |
| Wire | HTTP settlement *failures* return a v2 `SettlementResponse` + error‑reason codes | ✅ done |
| N/A | fiat ISO‑4217 `asset` / role‑constant `payTo` | **unsupported** (ic402 settles concrete on‑chain transfers — no settlement path) |
| Deferred | `permit2` / `erc7710` asset‑transfer methods | **not implemented — intentionally.** Only `eip3009` (the v2 default, declared in `extra.assetTransferMethod`) is implemented. permit2/erc7710 are large, security‑sensitive on‑chain calldata encoders (Permit2 `permitWitnessTransferFrom` via the `x402ExactPermit2Proxy`; ERC‑7710 `redeemDelegations`) that **cannot be verified on‑chain in this environment** (the only available testnet USDC reverts EIP‑3009 — see B1). Shipping unverified transfer encoders would be irresponsible; deferred until a chain whose USDC honours these is available. |

> The two former "Minor" items (HTTP failure SettlementResponse, full error‑reason mapping) are
> now done. `dual X-Payment + PAYMENT-SIGNATURE` request headers are still sent by the client —
> intentionally, as a v1 back‑compat alias; the server reads `PAYMENT-SIGNATURE` first.

### IC boundary-node CORS caveat

The canister sets `Access-Control-Expose-Headers: PAYMENT-REQUIRED, PAYMENT-RESPONSE`,
`Access-Control-Allow-Headers: PAYMENT-SIGNATURE, …`, and answers `OPTIONS` (204). In practice
the **IC HTTP boundary node manages edge CORS** and overrides parts of this: it answers the
`OPTIONS` preflight itself with its own (permissive) header list, and replaces the
`Access-Control-Expose-Headers` value. The custom `PAYMENT-REQUIRED`/`PAYMENT-RESPONSE` headers
are still delivered on the response. Consequences:

- **Non-browser x402 clients** (server-side `fetch`, curl, agents) read all headers regardless of
  CORS — fully unaffected.
- **Browser clients** are subject to the boundary node's CORS policy, not the canister's, for
  reading the custom headers. This is an IC-platform behavior, not an ic402 gap; the canister
  emits the correct headers.

### Verification limitation (be honest about it)

A *successful end‑to‑end* EVM HTTP payment by a stock v2 client **cannot be verified in this
environment**: the only available testnet USDC (Base Sepolia `0x036CbD…`) rejects canonical
EIP‑3009 `transferWithAuthorization` on‑chain — a contract‑side issue, not ic402 (see the B1
investigation: the demo's signature recovers to the funded payer and the EIP‑712 domain matches
the contract byte‑for‑byte, yet a direct `eth_call` still reverts). So:

- The **v2 wire format, header transport, CORS/OPTIONS, and `PAYMENT-SIGNATURE` reading** are
  verified over HTTP against the local replica.
- The **exact‑EVM scheme logic** (`value == amount`, EIP‑3009‑nonce replay, error mapping) is
  unit‑tested.
- A **live successful stock‑client EVM settle** needs a chain whose USDC honours EIP‑3009; that
  is an external dependency, not an ic402 gap.
