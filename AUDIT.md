# ic402 — Security Audit & Code Review

**Target:** ic402 v1.0.0 (production Motoko payment library for ICP)
**Commit:** `9cd7db3` · working tree clean
**Scope:** `src/ic402/**` (6.7k LOC Motoko), `packages/client/**` (TS SDK), `integrations/mcp/**` (MCP server), `example/main.mo`, `scripts/**`
**Status:** review only — no source files were modified.

> ⚠️ **Two issues are exploitable today and lead to fund theft / free service: C1 (`authz.to` not validated) and C3 (MCP `call` tool). Treat C1–C5 as release blockers.**

---

## Methodology

A multi-agent review: **12 domain reviewers** (one per module/subsystem) plus **3 cross-cutting Motoko-hazard sweeps** (async/await interleaving; arithmetic + upgrade safety; secrets/key-management + randomness). Every raw finding was then **adversarially re-verified against the source** — critical/high findings received two independent lenses (one attempting to *refute*, one attempting to construct the *exploit*); the rest received a single skeptic. Findings that did not survive verification were dropped.

| | Count |
|---|---|
| Raw findings | 94 |
| **Confirmed** | **51** |
| Uncertain (needs human judgement) | 32 |
| Refuted (false positives, excluded) | 11 |

### Confirmed by severity

| Severity | Distinct issues |
|---|---|
| 🔴 Critical | 5 |
| 🟠 High | ~14 |
| 🟡 Medium | 11 |
| ⚪ Low | 11 |
| ⚫ Info | 6 |

**Overall assessment:** the cryptographic primitives are largely sound — EIP-712 recovery, constant-time byte comparison (`Eip712.mo:207`), and AEAD with constant-time tag comparison (`ContentStore.mo:58-84`) all check out. The risk concentrates in the **orchestration layer**: what the settlement code *fails to verify* between a valid signature and a value transfer, the **concurrency** of check-then-await-then-act sequences, and an **MCP server that exposes the canister's controller key to an LLM**.

---

## 🔴 Critical

### C1 — EVM settlement never validates the payment recipient (`authz.to`)
**`src/ic402/Gateway.mo:308-396`, `src/ic402/Sessions.mo:387-441`** · security · confirmed 3× (incl. firsthand)

The EIP-3009 branch verifies the signature is valid for `(from, to, value, …)` and that `recovered == from` (`Eip712.mo:176`) — but **never checks that `authz.to` is the canister's own EVM address**. `canisterEvmAddr` is derived (`Gateway.mo:308`) and used *only* to populate the receipt (`:383`); `authz.to` is passed verbatim to the on-chain transfer (`:365-372`). The `Sessions` constructor is even handed `evmRecipientAddress` (`Sessions.mo:62`) but never reads it — evidence the intended check was dropped.

- **Charge path (free service + gas drain):** attacker signs a self-transfer (`from = to = their own address`, `value ≥ amount`) and submits it as the x402 payment. Signature verifies, the **canister pays the gas**, USDC moves attacker→attacker (no-op), and a valid `PaymentReceipt` + access grant is issued while **zero funds reach the merchant**. Repeatable cycle/gas-drain DoS.
- **Session path (treasury theft):** `openEvmSession` does the same self-transfer, then `evmEscrowManager.allocate(...)` credits the attacker a `deposit` they never paid. On close, the refund is paid from the canister's **own pooled USDC** → drains other users' deposits.

**Fix:** before verify/execute in **both** paths, require `EvmUtils`-normalized `authz.to == evmRecipient` (case-insensitive 20-byte compare); reject with `#invalidSignature`/`#settlementFailed` otherwise. Add a regression test asserting a validly-signed authorization with a non-canister `to` is rejected.

### C2 — MCP `fetch_x402` SSRF → canister signs an attacker-chosen USDC transfer
**`integrations/mcp/src/index.ts:616-672`** · security · confirmed

`url: z.string()` has no allowlist / scheme / IP restriction. The tool fetches the URL, then forwards the **server-returned** `recipient`/`amount`/`asset` straight into `signX402Payment` → `EvmSigner.signEip3009Authorization`, which signs **from the canister's own EVM address with no amount cap and no recipient allowlist**, gated only by `isController`. A malicious x402 endpoint — or prompt-injected web content steering the agent to one — makes the canister sign a USDC transfer payable to the attacker. **Direct theft of the canister's USDC.**

**Fix:** (1) https allowlist + block private/loopback/link-local IPs; (2) push a per-call/per-period amount cap and recipient/asset policy **into the canister** (`signEip3009Authorization`), not just `isController`; (3) require human confirmation (MCP elicitation) before signing.

### C3 — MCP generic `call` tool delegates controller authority to the LLM
**`integrations/mcp/src/index.ts:853-883`** · security · confirmed firsthand

`actor[method](...parsedArgs)` with `method: z.string()`, args parsed from JSON, **no allowlist, no confirmation**, controller identity. The LLM (or injected content) can invoke `signEthTransfer`, `signErc20Transfer`, **`signTypedData` — a universal signature-forgery primitive (sign any 32-byte digest: Permit, DEX order, cross-chain auth)** — or `setPolicy` to disable spending guards.

**Fix:** remove the generic `call` tool from production, or restrict it to an explicit allowlist of read-only/query methods and reject any signing/admin method. Never let an LLM pick an arbitrary method name when the identity is a controller.

### C4 — Marketplace example settles to the main account but refunds/pays from an *unfunded* escrow subaccount
**`example/main.mo:331-349,568-607`, `src/ic402/ServiceRegistry.mo:116-120,337-363,426-437`** · correctness · confirmed

`gate.settle()` sends the buyer's funds to the canister **main account**, but `settleJob`/`expireJobs` transfer *from* `jobSubaccount(jobId)` — which **nothing ever deposits into**. Every operator settlement and buyer refund fails with `InsufficientFunds` (and `expireJobs` swallows the error at `:435`). Buyers pay, operators are never paid, refunds never happen, funds are frozen in the main account. The reference canister teaches a custody model that does not hold — integrators copy it.

**Fix:** choose one custody model end-to-end — either deposit the buyer payment **into** `jobSubaccount(jobId)` at submit time (registry derives/returns the subaccount the Gateway settles into), or settle/refund directly from the platform recipient. Make the example, `ServiceRegistry`, and the doc comments agree. Add an integration test for submit→claim→settle (operator balance increases) and expire→refund (buyer restored).

### C5 — EVM service-over-HTTP traps on `Principal.fromText(receipt.sender)` *after* the on-chain transfer
**`example/main.mo:337-343`** · motoko-semantics · confirmed

For EVM payments `receipt.sender` is a `0x…` address. `Principal.fromText("0x…")` **traps**, *after* `gate.settle` already awaited the on-chain USDC transfer. Motoko rolls back the post-await nonce mutations but **not** the irreversible on-chain transfer — and the EIP-3009 nonce is now spent, so a retry can't re-settle. **Direct, repeatable buyer fund loss** on the HTTP service path. (The Candid `submitServiceRequest` path avoids this only because it uses `msg.caller`.)

**Fix:** don't coerce `receipt.sender` into a `Principal` for EVM payments — branch on `receipt.network`, store the EVM buyer as `Text`, or have `ServiceRegistry.submitRequest` accept a buyer identity as `Text`. At minimum wrap `Principal.fromText` non-trappingly and return 400/402 (ideally refund) instead of trapping after settlement.

---

## 🟠 High

### Settlement finality & EVM transaction mechanics

- **H1 — Mempool acceptance treated as final settlement.** `Gateway.mo:365-396`. `executeTransferWithAuthorization` returns `#ok` as soon as `eth_sendRawTransaction` is accepted into the mempool (`EvmSender.mo:142-149`), not when mined. A tx that reverts on-chain (insufficient balance, reused token nonce, paused token, validBefore) still yields a valid receipt + access grant + consumed nonce. No `eth_getTransactionReceipt` status check. **Fix:** poll `eth_getTransactionReceipt` (multi-provider) and finalize only on `status == 1`; on revert/timeout unlock the nonce and return `#settlementFailed`.
- **H2 — `EvmSigner` and `EvmSender` share one EVM address but keep independent nonces.** Both derive with empty derivation path; `EvmSender` caches an in-memory `localNonce` while `EvmSigner` signs with a client-supplied nonce. Guaranteed collisions → stuck/replaced txs, possibly dropped refunds. **Fix:** distinct derivation paths (distinct addresses) **or** read the chain nonce with `#Pending` immediately before each send. (Note the derivation-path option changes the canister's EVM identity — see breaking-change matrix.)
- **H3 — `getFeeData` RPC-failure fallback returns ~0.1 gwei** (`EvmSender.mo:222-248`), far below mainnet base fee, and the doomed tx is still broadcast and **bumps `localNonce`**, wedging the whole outbound pipeline. Also fires on routine `#Inconsistent` results. **Fix:** return `#err` instead of broadcasting when fee data is unavailable; if a fallback is kept, derive it from a fresh base fee × safety multiplier, per-chain.

### Concurrency — check-then-await-then-act

- **H4 — Daily spending limit bypassable via concurrent charges.** `Policy.mo:172-184` + `Gateway.mo:423-456`. `checkDailyLimit` reads before the settlement `await`; `recordSpend` writes after. N concurrent charges (distinct nonces) all read the same stale total and all pass. A `$100/day` agent cap can be blown several times over. Same shape on the EVM path (`:302/:377/:365`). **Fix:** add an atomic `reserveDaily(caller, amount)` that checks-and-increments synchronously *before* the await, with `releaseDaily` rollback on failure.
- **H5 — Double-settle / double-refund of a job.** `ServiceRegistry.mo:300-367`. Terminal `#Settled` is written only after the awaits; two concurrent `confirmJob` calls both pass the `#Verified` guard and both pay out. No in-progress lock. **Fix:** synchronously set a non-reentrant `#Settling` state before the first await; reject entry unless `#Verified`.

### Content encryption

- **H6 — Encryption key is fully deterministic from the (public) canister principal.** `ContentStore.mo:95-122`. Key = `SHA-256(principal ++ "ic402-content-key")`; the `raw_rand` path (`initExternalSeed`) is **unreachable dead code** (`seedInitialized` defaults `true`; never called anywhere). Anyone who knows the principal + exfiltrates stable memory can decrypt all content. **Fix:** make external seeding the required path (`seedInitialized=false` by default; seed via `raw_rand` after deploy), then persist the key (H7).
- **H7 — `masterKey`/`seedInitialized` are not in stable state.** `ContentStore.mo:97-122,291-326`. The moment anyone follows the documented `initExternalSeed(raw_rand())` advice, the next upgrade **permanently destroys access to all stored content** (chunks persist, key doesn't). The "stable key bytes are restored" comment is false. **Fix:** persist `masterKey` + `seedInitialized` in `StableContentStoreState`, restore in `loadStable` (guard absent fields); add an upgrade round-trip test.

### Access control

- **H8 — Access grants are transferable bearer tokens.** `Grants.mo:99-116`. `verifyGrant`/`getChunk` never check `caller == grant.grantee`; the whole grant (incl. its HMAC) is a call argument. Anyone who obtains the grant blob (shared link, logs, relay) gets the paid content free for the TTL. **Fix:** make verification caller-aware — `verifyGrant(caller, grant)` rejects unless `Principal.equal(caller, grant.grantee)`; pass `msg.caller` from delivery endpoints. (Or explicitly document bearer semantics and drop `grantee` from the security model.)

### HTTP x402 flow — broken *and* skips the nonce binding

- **H9 — 402 nonces are generated inside a `query` method.** `example/main.mo:193-215`. `http_request` is `public query`; `requireAll` mutates the nonce map, but the mutation is discarded, so settlement always returns `#expired`. The advertised GET→402→pay→200 journey **can never reach 200**. **Fix:** issue/persist the nonce from an update context (`httpUpgrade()` the unpaid GET).
- **H10 — Standard X-PAYMENT parser sets an empty server nonce.** `HttpHandler.mo:233-251`. `signature.nonce` = empty blob, so `lock()` always returns null *and* the server-issued nonce→amount binding is bypassed for EVM. **Fix:** decide the EVM replay model; if the server nonce is required, carry it in `parseX402PaymentHeader` and emit it in the 402 body so clients can echo it.

### MCP server (untrusted-LLM threat model)

- **H11 — `fetch_content` SSRF + arbitrary canister method.** `index.ts:504-554`. `httpUrl`/`assetCanister` (string-concatenated URL) reach `169.254.169.254`/internal hosts; `canisterQuery.method` invokes an arbitrary method on the controller-authenticated canister. **Fix:** validate every field; allowlist hosts; block private IPs; restrict `method` to a fixed content-chunk allowlist.
- **H12 — `submit_request` auto-pays whatever amount the canister demands.** `index.ts:776-799`. No cap, no confirmation, `autoPayment` hard-coded `true`. **Fix:** server-side per-call + cumulative cap; explicit confirmation above a threshold; make `autoPayment` opt-in.
- **H13 — No human-confirmation/elicitation on any money-moving or signing tool.** `index.ts` (cross-cutting). The design gap that makes C2/C3/H11/H12 exploitable end-to-end. **Fix:** confirmation step (elicitation or explicit-confirm arg) for every tool that signs/approves/pays/settles/broadcasts, displaying amount/recipient/asset/chain, plus hard caps.

### Supply chain

- **H14 — Prebuilt WASMs downloaded with no integrity check and committed to git.** `scripts/fetch-prebuilt.sh:40-77`. The ICRC-1 ledger and EVM-RPC WASMs are fetched via `curl` with no SHA-256/signature and are tracked in `.icp/`. A swapped binary deploys a trojaned ledger/RPC into every dev + CI environment (and could fabricate "successful" settlements in tests). **Fix:** pin each artifact by SHA-256 (`shasum -c` after download), don't commit the blobs, document provenance.

---

## 🟡 Medium

| # | Finding | Location | Fix summary |
|---|---|---|---|
| M1 | HMAC grant secret derived from only the **low 64 bits** of the 256-bit seed (`natToBytes8` truncation) | `Utils.mo:16-27`, `Grants.mo:29-47` | Derive the HMAC key from the full random blob; keep `natToBytes8` only for true 64-bit counters |
| M2 | `delete()` + re-`put()` of the same id **reuses (key, nonce)** → keystream reuse → plaintext recovery via XOR | `ContentStore.mo:49-54,180-192,268-273` | Mix a per-entry random salt (stored in stable state) or global epoch counter into key/nonce derivation |
| M3 | `getChunk` delivers to **any bearer** of a valid grant (no `caller == grantee`) — example-level instance of H8 | `example/main.mo:462,484-489` | Assert `Principal.equal(grant.grantee, msg.caller)` after `verifyGrant` |
| M4 | Daily-spend limit overshoot via async interleaving (example/Gateway instance of H4) | `Gateway.mo:302-305,377,423-456` | Reserve spend before the await; roll back on failure |
| M5 | Nonce store has **no hard cap** — unbounded growth under sustained 402 challenges (GC never re-enables replay) | `Nonce.mo:19,32-45,91-103` | Reject new generation when at `MAX_NONCES` after GC; track size to avoid O(n) scans |
| M6 | **Disputed / `#Submitted` jobs have no resolution path** — escrow can lock permanently | `ServiceRegistry.mo:311-322,416-439` | Add dispute/timeout expiry + admin `resolveDispute(jobId, #refund\|#settle)`; GC terminal jobs |
| M7 | Voucher signature payload has **no canister/chain/domain binding** → cross-canister replay on Ed25519 key reuse | `Sessions.mo:26-44,497-566`, `voucher.ts:10-16` | Bind `canisterPrincipal` (+ chainId/token for EVM) into the signed CBOR; update client signer in lockstep |
| M8 | HMAC grant secret has **~64 bits** entropy (sessions-domain instance of M1) | `Grants.mo:29-47`, `Gateway.mo:583-587` | Use the full 32-byte randomness; round-trip full-width seed in stable state |
| M9 | Session deposit **double-counted** against the daily limit and never credited back on refund | `Sessions.mo:287,491,563`, `Policy.mo:161-184` | Record only actual consumption (or only the deposit), and credit back unused deposit on close |
| M10 | `patch-local.sh` `backup_source` unconditionally overwrites the backup — interrupted run can **poison the backup with testnet-patched content** | `scripts/patch-local.sh:21-30,143-150` | Refuse to overwrite an existing backup; verify mainnet markers before backing up |
| M11 | Patch backup files **not gitignored** — failed restore can leave testnet-patched `main.mo` committable | `scripts/patch-local.sh:21-30` | gitignore `*.local-bak`/`*.prod-backup`; hard-fail deploy if mainnet markers absent post-restore |

## ⚪ Low

| # | Finding | Location |
|---|---|---|
| L1 | Malformed `from/to/r/s` hex in X-PAYMENT **traps** `settle` (DoS-by-trap vs clean 400) | `HttpHandler.mo:215-251`, `Eip712.mo:202-205` |
| L2 | `getQueryParam` returns raw value with **no percent-decoding** / `+` handling, truncates on `=` | `HttpHandler.mo:148-160` |
| L3 | 402 body & `PaymentRequirement` omit the **server nonce/expiry** — clients can't bind a payment to a challenge | `HttpHandler.mo:38-55`, `Types.mo:38-48` |
| L4 | Search handler maps invalid-signature / expired-nonce to a generic 402, **masking real failures** | `example/main.mo:171-181` |
| L5 | EVM receipt amount diverges from value transferred when `authz.value > amount` (accounting mismatch) | `Gateway.mo:312-315,365-390` |
| L6 | `lock()` returns null **indistinguishably** for expired/consumed vs network/token mismatch | `Nonce.mo:50-69` |
| L7 | `shouldFetchRootKey` enabled by **substring** match on host → lookalike host disables response verification | `index.ts:164-168` |
| L8 | `ServiceRegistry` enforces no spending policy; constructor **doc references removed params** | `ServiceRegistry.mo:7-11,37-41` |
| L9 | Custom service IDs allow **squatting/griefing** of auto-generated `svc-N` IDs | `ServiceRegistry.mo:51-72` |
| L10 | Fixed-window daily limit resets at **UTC midnight** → near-boundary burst ≈ 2× cap | `Policy.mo:20-28,152-184` |
| L11 | `assert_patched` only **warns**, never fails the build, when a mainnet→testnet substitution is missed | `scripts/patch-local.sh:37-43,72-74` |

## ⚫ Info

| # | Finding | Location |
|---|---|---|
| I1 | No regression test asserts the gateway rejects an EIP-3009 authorization whose `to` ≠ canister (covers C1) | `test/eip712.test.mo:37-98` |
| I2 | Free status/info endpoints served from an **uncertified query** response | `example/main.mo:193-268`, `HttpHandler.mo:76-135` |
| I3 | `blobToHex` is **dead code** in HttpHandler | `HttpHandler.mo:288-290` |
| I4 | ✅ Positive: AEAD authentication + constant-time tag comparison correctly implemented | `ContentStore.mo:58-84` |
| I5 | `ContentStore` itself exposes no auth — access control lives only in the example (integrator footgun) | `ContentStore.mo:196-228` |
| I6 | `checkRateLimit` consumes a rate-limit slot during a pre-charge check that may later fail | `Policy.mo:116-148,210-237` |

---

## 🔍 Uncertain — recommend manual investigation

The single genuinely new uncertain item (the rest duplicate confirmed findings):

- **Sessions EVM close may perform a second on-chain transfer.** `Sessions.mo:788-797,765-825`. The close path reverts to a retriable status after an *ambiguous* settle failure; since ERC-20 `settle` is not idempotent, a retry could transfer twice. The async-sweep flagged it; the exploit lens could not confirm the retry path is reachable. **Trace the close/retry state machine before relying on it.**

## ✅ Refuted (11, excluded as false positives)

The adversarial pass correctly dismissed, among others: the `Time.now()`-derived EIP-3009 nonce (collisions produce **byte-identical, harmless** authorizations); `natToBytes8` chunk-index truncation (needs 2⁶⁴ chunks); the JSON positional-parser concern (attacker only controls their **own self-signed** payload); buyer-not-bound-to-receipt (funds go to the recipient regardless); `signTypedData` "oracle" *within* the existing controller boundary; and `mops` integrity-warning suppression (mops still emits its own diagnostics).

---

## Recommended remediation order

1. **C1** — add the `authz.to == evmRecipient` check in `Gateway.settle` **and** `Sessions.openEvmSession`. Smallest fix, largest impact; this is the live payment bypass.
2. **C3 / C2 / H13** — remove/restrict the generic `call` tool; allowlist `fetch_*` URLs; gate every signing/paying MCP tool behind a hard cap + confirmation; push amount/recipient policy into the canister.
3. **H1** — confirm `eth_getTransactionReceipt status == 1` before issuing a receipt/grant (the `authz.to` fix alone does not stop revert-but-receipt).
4. **C4 / C5 / H9 / H10** — fix escrow custody + the EVM-receipt `Principal.fromText` trap + the query-context nonce generation (the HTTP service flow is currently non-functional *and* unsafe).
5. **H4 / H5** — reserve-before-await for the daily limit; `#Settling` intermediate state for job settlement.
6. **H6 / H7** — wire real `raw_rand` seeding **and** persist the key in stable state (do together or content breaks on upgrade).
7. **H14** — pin WASM artifacts by SHA-256.

---

## Breaking-change impact of the fixes

Legend — does the fix break:
**API** = a Motoko library public function signature (integrators edit call sites & recompile) ·
**Interface/wire** = Candid signatures, stable-memory schema, or a signed/serialized payload format (EIP-712 payload, voucher CBOR, x402 HTTP JSON, ledger WASM) — breaks cross-version or cross-client compatibility ·
**UX/behavioral** = observable runtime behavior changes (flows that "worked" now reject, require confirmation, run slower, or return different errors) without a signature change.

| Fix | API | Interface / wire | UX / behavioral | Notes |
|---|:--:|:--:|:--:|---|
| **C1** authz.to check | — | — | ✅ minor | Only rejects malformed/malicious payments; correct clients always set `to = canister`, so honest flows are unaffected. **Safe to ship.** |
| **C2** fetch_x402 cap/allowlist/confirm | — | ⚠️ MCP tool schema (additive) | ✅ **breaking** | Agent flows that auto-signed now require confirmation / allowlisted host. |
| **C3** remove/restrict `call` tool | — | ✅ **breaking** (MCP) | ✅ **breaking** | Removes a published MCP tool; clients using `call` for signing break (intended). |
| **C4** escrow custody | ⚠️ maybe | ⚠️ maybe (Candid + stable) | — | If deposits route into `jobSubaccount`, `ServiceRegistry.submitRequest` / Gateway settle target change. Choose the model that minimizes signature churn. |
| **C5** Principal.fromText | ⚠️ if buyer type changes | ⚠️ if Candid `submitRequest` arg changes | ✅ fixes a 500 | Internal `network` branch / non-trapping guard = **non-breaking**. Changing buyer `Principal`→`Text` = breaking API+Candid. **Prefer the guard.** |
| **H1** receipt confirmation poll | — | — | ✅ behavioral | `settle` becomes slower and surfaces `#settlementFailed` where it previously returned `#ok`. No signature change. |
| **H2** distinct nonces | ⚠️ depends | ✅ **breaking if** new derivation path | — | New derivation path **changes the canister's EVM address** (re-fund, re-register ERC-8004). The read-nonce-each-send variant is **non-breaking** — prefer it. |
| **H3** fee fallback | — | — | ✅ behavioral | `sendTransaction` returns `#err` instead of broadcasting a doomed tx. |
| **H4** reserve-before-await limit | ⚠️ additive `Policy` API | — | ✅ stricter | New `reserveDaily`/`releaseDaily`; internal call-site changes. Concurrent overspend now denied. |
| **H5** `#Settling` state | — | ⚠️ additive Candid variant | — | Adding a `JobStatus` variant can break consumers that exhaustively match the enum over Candid. |
| **H6** raw_rand seeding | — | — | ✅ **breaking** (ops) | Default `seedInitialized=false` → `put()` traps until seeded; deploy flow must call seeding. Existing deterministic-key content needs migration. |
| **H7** persist masterKey | — | ✅ stable-schema change | — | `StableContentStoreState` gains fields; handle absent fields for old state (additive, migration-safe if guarded). |
| **H8** grant caller binding | ✅ **breaking** (`verifyGrant` gains `caller`) | — | ✅ **breaking** | Grants stop being transferable — any flow that forwards a grant blob breaks (intended). |
| **H9 / H10** HTTP nonce flow | — | ✅ **breaking** (x402 HTTP wire) | ✅ **breaking** | 402 body now carries the nonce; clients must echo it; unpaid GET upgrades to update. Fixes a currently-non-functional flow, but existing HTTP clients must update. |
| **H11** fetch_content validation | — | — | ✅ behavioral | Rejects previously-accepted delivery payloads / non-allowlisted methods. |
| **H12** submit_request cap/confirm | — | ⚠️ MCP config schema | ✅ **breaking** | `autoPayment` no longer on by default; large payments need confirmation. |
| **H13** confirmation on money tools | — | ⚠️ MCP elicitation | ✅ **breaking** | All signing/paying tools now prompt for confirmation. |
| **H14** WASM checksums | — | — | — | **Dev/CI only** — no impact on library consumers. |
| **M2** content nonce salt | — | ✅ stable-schema change | ✅ behavioral | Per-entry salt stored in state; old content keeps working only if salt defaulting is handled. |
| **M7** voucher domain binding | — | ✅ **breaking** (voucher CBOR) | — | Signed payload changes; **client signer + canister verifier must update in lockstep**; in-flight vouchers invalid. |
| **M1 / M8** full-entropy HMAC key | — | ⚠️ stable seed round-trip | ✅ minor | Changing key derivation invalidates outstanding grants (5-min TTL → negligible). |
| **M6** dispute resolution | ✅ additive API | ⚠️ additive Candid | — | New `resolveDispute` admin method + possibly new `JobStatus`/error variants. |
| **L3 / L6 / L4** richer errors | — | ⚠️ additive Candid variants | ✅ better | New `PaymentResult`/`lock` variants may break exhaustive matchers; otherwise observability-only. |
| **M3–M5, M9–M11, L1–L2, L5, L7–L11, I*** | — | — | ✅ behavioral / dev-only | Internal robustness, accounting, or tooling; no signature or wire change. |

### Summary of what is *not* safe to ship silently
- **Hard API breaks (recompile required):** **H8** (`verifyGrant` signature), and **C4/C5/M6** *if* the registry/buyer-type approach is chosen over the internal-guard approach.
- **Wire / cross-client breaks (coordinate clients):** **H9/H10** (x402 HTTP format), **M7** (voucher CBOR), **C3** (MCP tool removal). EIP-712 verification itself is unchanged by these fixes.
- **Stable-memory / upgrade-migration breaks (data at risk):** **H7, M2** (schema), **H6** (key migration). Land these with explicit `loadStable` guards and an upgrade round-trip test.
- **EVM-identity break (operational):** **H2** *only if* you choose distinct derivation paths — avoidable by reading the chain nonce per send.
- **Agent UX breaks (expected & desirable):** the MCP confirmation/cap fixes (**C2, H12, H13**) intentionally change auto-pay behavior.

The remaining fixes — including **C1**, the highest-priority one — are behavioral-only or affect only malicious/broken paths, and can ship without breaking correct integrations.
