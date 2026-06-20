# Changelog

## v2.2.3 — 2026-06-19

Patch release. CI/test infrastructure only — no wire/HTTP or `@ic402/client` API
changes. Closes **B3**, the last production-readiness hermeticity gap: the EVM
**outbound** rail (sign → broadcast → confirm / park) is now gated in CI without a
funded testnet or any network egress.

### Added

- **Hermetic EVM-outbound CI gate (B3).** A scriptable Motoko mock of the DFINITY
  EVM-RPC canister (`example/evm-rpc-mock/`) implements the exact
  `EvmRpc.EvmRpcCanister` interface and answers every RPC round-trip with canned,
  controllable data, so the whole outbound state machine runs on a plain local
  replica. The canister under test still does **real tECDSA signing + RLP encoding** —
  only the broadcast/confirm leg is mocked, and the mock records each raw tx it was
  asked to broadcast so a test can assert the bytes went out exactly once.
  `scripts/setup-evm-outbound.sh` re-points the example at the mock, and
  `test/evm-outbound.test.ts` drives the controller-only `sweepEvm` through
  confirmed / reverted / never-mined / pending-then-mined / inconsistent-fee
  outcomes — including ones a live testnet won't produce on demand. A new
  `test-evm-outbound` CI job enforces it (`IC402_REQUIRE_EVM_OUTBOUND=1`).

### Notes

- With B3 closed, the remaining production-readiness items are NEW-5 (confirmation
  depth, deferred — low practical risk on optimistic L2s) and an optional external
  audit / periodic live-testnet smoke (the funded leg can't be hermetic). B1 waived.
  `docs/production-readiness.md` is the source of truth.

## v2.2.2 — 2026-06-19

Patch release. Fixes a `@ic402/client` packaging bug and trims dead code/deps
(supply-chain cleanup). No wire/HTTP or API changes.

### Fixed

- **`@ic402/client` was mis-packaged.** It imported `@icp-sdk/core` without
  declaring it — so a clean `npm install @ic402/client@2.2.1` is broken
  (`MODULE_NOT_FOUND`) — and declared three deps it never imports
  (`@canister-software/x402-icp`, `@x402/core`, `@x402/fetch`), which dragged in
  the legacy `@dfinity/*` tree (the source of most supply-chain-scan alerts). Now
  `@icp-sdk/core` is declared and the three dead deps are removed. **Republish from
  2.2.2 to fix the live package.**

### Removed (dead code)

- `client.ts` unused `SignedTransaction` import; `guards.ts` unused
  `dangerousTools()` export; demo `versus()` helper and two unused constants.
  Verified with depcheck / ts-prune / eslint; build + 72 client tests pass.

### Notes

- The transitive advisories a supply-chain scan flags — `ws` (via viem's WebSocket
  transport) and `hono`/`path-to-regexp`/`fast-uri` (via the MCP SDK's HTTP/SSE
  transports) — are **not reachable**: ic402 uses viem `http()` and a stdio-only
  MCP server, so neither transport runs. The fixes are upstream. See
  `docs/security-model.md` §5.

## v2.2.1 — 2026-06-19

Security release. A composed-system adversarial security audit (SEC-0) plus two
re-attack rounds found and fixed six issues. No wire/HTTP or `@ic402/client` breaking
changes; two additive Motoko methods (below).

### Security (SEC-0)

- **[critical] Marketplace double-refund.** The ServiceRegistry ZkGroth16 `#err`
  branch wrote `#Disputed` unconditionally, clobbering a terminal `#Settled`/`#Refunded`/
  `#Expired` set during the verifier await → the next `expireJobs` tick re-refunded the
  job. Now status-guarded (only `#Computing` → `#Disputed`, mirroring the `#ok` branch).
- **[high] EVM session overpayment strand.** `openEvmSession` accepted `authz.value >
  deposit`, pulling the full value on-chain but crediting only `deposit`. Now requires
  `authz.value == deposit` (mirrors the charge path).
- **[high] Unmetered-ecRecover cycle-DoS.** The expensive EIP-3009 `ecRecover` ran
  without the global rate gate on the paid `/content`/`/search` settle paths and on
  `openEvmSession`. A single global token bucket now meters `settle`/`verifyPayment`/
  `openEvmSession`; the example uses a floor-only check on `/verify`+`/settle` so the
  bucket isn't double-charged.
- **[high] EVM pool over-allocation + open-time leak.** `EvmEscrow.totalAllocated` was
  never consulted (dead code) and the session public key was validated *after*
  `allocate`. Now a live per-chain+token `poolCap` guard, and the key is validated
  before the on-chain deposit + allocation.
- **[high] MCP spend-cap TOCTOU.** Concurrent/pipelined tool calls passed the same
  stale cumulative cap. The cap is now reserved synchronously at confirm time and
  refunded on a no-money-moved failure.
- **[high] MCP DNS-rebinding SSRF.** The `fetch_x402` probe leg and `register_agent`
  rpcUrl bypassed the redirect-safe fetch. Outbound hosts are now DNS-resolved and
  rejected if they resolve to a private/metadata IP, at every fetch entry point.

### Added

- `Gateway.setEvmPoolCap(cap)` — bound outstanding EVM session deposits per chain+token
  (the over-allocation guard). The example wires a ceiling.
- `Gateway.cyclesBelowFloor()` — the facilitator cycle-floor check, split out so a
  consumer doesn't double-charge the global rate bucket.

### Documented residuals

Deliberately deferred and disclosed in `docs/security-model.md` /
`docs/production-readiness.md` (SEC-0): system-wide shared-EVM-pool solvency
(marketplace/`sweepEvm` vs `totalAllocated`); the SSRF connect-time re-resolve window
(no undici IP-pinning yet); and the ungated-but-unwired `recoverBuyerActionSigner`.

## v2.2.0 — 2026-06-18

Minor release. Adds a recovery/observability suite and a facilitator DoS gate,
fixes a latent EVM-RPC decode trap that could hit any EVM operation, and bumps
the Motoko crypto/IC dependencies. No wire/HTTP or `@ic402/client` breaking
changes; one Motoko-library breaking change for direct `EvmRpc` consumers (below).

### Added

- **Recovery & observability** (controller-only via the consumer). Escape hatches
  for funds parked mid-settlement: `health()` (cycle balance + job/session counts),
  `listJobs`, manual `resolveJob` / `reconcileJob` / `reconcileSession` /
  `forceResolveSession`, and `sweepEvm(chainId, token, to, amount)`. Auto
  confirm-only reconcile timers for marketplace jobs and streaming EVM sessions
  re-poll a STORED tx and finalize when confirmed — they never re-broadcast.
- **SEC-1 — facilitator DoS gate.** The unauthenticated `/verify` + `/settle`
  update endpoints now run behind a global token-bucket rate limit and a
  500B-cycle floor, evaluated before any attacker-controlled parsing / `ecRecover`
  / RPC / signing work.
- **Pre-broadcast cycle guard.** `EvmSender.sendTransaction` refuses to broadcast
  below `MIN_BROADCAST_CYCLES` (120B), so it never strands a half-sent EVM tx.
- **RPC resilience.** Added a verified 3rd RPC provider to the testnet chains that
  previously had only two, so one flaky endpoint no longer parks settlement.

### Fixed

- **EVM-RPC decode trap (`openSession`, and any EVM op).** `EvmRpc.RpcError`
  mis-modeled three of its four arms versus `evm_rpc.did` — `ProviderError`,
  `HttpOutcallError`, and `ValidationError` are variants on the wire, not flat
  `{ code; message }` records. A multi-provider response is Candid-decoded *whole*
  before consensus runs, so a single provider returning one of those (a common
  transient testnet failure) trapped the entire call. Now mirrors the canister
  candid exactly. Surfaced as a Step-7 session-open failure but could hit
  settle/verify/identity too.
- **All compiler warnings cleared.** `M0155` (Nat-subtraction trap risk, 7 sites,
  all provably guarded → `Utils.satSub`) and `M0194` (unused, 4 sites) removed; the
  build is warning-free.

### Breaking (Motoko library — direct consumers only)

- **`EvmRpc.RpcError`** arms changed shape to match `evm_rpc.did`: `ProviderError`,
  `HttpOutcallError`, and `ValidationError` are now variants (with their real
  sub-types), not `{ code : Int32; message : Text }` records; `JsonRpcError` is
  unchanged. Code that pattern-matches these arms directly must update — consumers
  using `EvmRpc.rpcErrorToText` (the normal path) are unaffected.

### Dependencies

- `mo:ic` 4.0.0 → **4.1.0**
- `mo:sha2` 0.2.1 → **0.2.4** — SHA-256 output unchanged (hash-dependent suites
  green; the tECDSA EVM address derives identically), and it stays under the
  IC0505 Wasm-locals limit after `wasm-opt -O` (96/1900).

### Docs

- **`docs/costs-and-rails.md`** — measured per-operation cycle costs (a single EVM
  settle nets ~17B cycles locally, not the ~100B *reserve* in code comments), the
  cycle buffer operators must hold, and rail selection by payment size.
- **`docs/security-model.md`** — what's defended by default, the secure-by-default
  integration checklist (the four guards that live only in `example/main.mo`), and
  the key-custody / blast-radius model.

### Tooling

- Replica-backed integration CI job (B4) with a `.did`-sync gate; the ckUSDC ledger
  is now mintable on a fresh `local-dev` (CI funding fix).

## v2.1.1 — 2026-06-17

Patch release. Makes the example canister installable on the current IC (the
critical fix), confirms outbound EVM transfers before finalizing, fixes four
issues found running the demo end-to-end on Base Sepolia, and surfaces on-chain
settlement proof on content delivery. No wire/HTTP or `@ic402/client` breaking
changes; two Motoko-library breaking changes for direct consumers (below).

### Breaking (Motoko library — direct consumers only)

- **`ServiceRegistry.EvmTransferFn`** return type widened from `{#ok; #err}` to
  `{#confirmed; #reverted; #pending; #err}` (the B2 confirmation fix). A canister
  that wires the marketplace EVM-transfer hook via `setEvmTransfer` must update
  its callback's return type — no shim. `Gateway`/`EvmSender` gained a matching
  `sendErc20TransferConfirmed` (tri-state); the old `sendErc20Transfer` is retained.
- **`Types.ContentDelivery`** gained a `settlementTxHash : ?Text` field, so Motoko
  code *constructing* a `ContentDelivery` must supply it. Readers are unaffected,
  and the Candid / `@ic402/client` decoders treat it as additive.

### Fixed

- **Installability (critical):** the example WASM was rejected at install time —
  `moc` unrolls `mo:sha2`'s SHA-256 compressor into **2081 Wasm locals** in one
  function, over the IC's 2000-locals-per-function limit (IC0505). The build now
  runs `wasm-opt -O` (binaryen ≥ v130) to coalesce them (2081 → 96 locals);
  `setup.sh` installs the optimized module, and a `wasm-locals` CI job +
  `scripts/check-wasm-locals.js` gate it. No crypto rewrite. (B0)
- **Outbound settlement confirmation:** marketplace `settleJob`/`refundOnRail`
  and EVM session close now confirm the transfer mined (`status==1`) before
  finalizing `#Settled`/`#Refunded`/`#closed` — an unconfirmed or reverted
  broadcast no longer marks a job/session paid. `EvmSender.sendTransaction`
  distinguishes maybe-broadcast from pre-broadcast failure to avoid double-pay. (B2)
- **Demo Step 8 (Agent Identity):** raised the ERC-8004 register gas limit
  (350k → 600k; a real mint needs ~396k) so it no longer reverts out-of-gas, and
  the client SDK now throws on a reverted receipt so a revert is reported
  honestly instead of as `register_agent succeeded / Awaiting confirmation`.
- **Demo Step 4 (delete):** the post-delete payment probe encoded the nonce as
  hex *characters* (Candid `Invalid vec nat8`) and mislabeled the result as a
  replica outage; decode the nonce to bytes (clean rejection, no charge) and
  report a paid-endpoint 402 as the expected gated response, not a warning.
- **Demo Step 2:** corrected the content-encryption label to **ChaCha20-Poly1305
  AEAD (RFC 8439)** — it had incorrectly said "SHA-256-CTR".
- Integration test suite made deterministic vs replica state (binds to its own
  registered service id, not a hardcoded `svc-1`). (P0)

### Added

- **`ContentDelivery.settlementTxHash : ?Text`** — `getContent` now returns the
  on-chain settlement proof (EVM tx hash / ICP ledger block index) of the payment
  that unlocked the content; the demo's Step 3 prints it. Added to the Motoko
  library type (constructors must supply it — see Breaking), the `@ic402/client`
  IDL/TS type, and the example `.did`.

### Changed

- Non-interactive demo (`IC402_DEMO_CI=1`) exercises the Base Sepolia EVM path by
  default (override with `IC402_DEMO_DEFAULT_CHOICE=1`).
- zk-verifier: the prebuilt deploy artifact moved to
  `example/zk-verifier/prebuilt/zk_verifier.wasm.gz`; the Rust `target/` build
  tree is no longer tracked (gitignored), so local builds stop dirtying the tree.
- Docs: reconciled `AUDIT.md`, brought `README.md` current, added
  `integrations/mcp/README.md`, `SECURITY.md`, and a production-readiness backlog
  (`docs/production-readiness.md`).

> **Not production-ready yet.** This patch closes B0/B2 and the demo issues, and
> a funded Base Sepolia run now completes end-to-end (real `status==1` settle,
> session close+refund, and an ERC-721 mint). Remaining blockers — B1 (upgrade
> migration from v2.0.0), a Foundry-fork/CI replay for the EVM rail (B3), a
> replica-backed CI job (B4), and the composed-system security pass (SEC-0..4) —
> are tracked in `docs/production-readiness.md` and are **not** closed here.

## v2.1.0 — 2026-06-15

x402 **v2 compliance**, the EVM/marketplace settlement paths, live policy
introspection, and an honest interactive demo.

> ⚠️ **Contains breaking changes despite the minor version.** ic402 is early-stage and
> the minor bump is deliberate — but
> if you consume the Motoko library, the `@ic402/client` types, or talk to the canister
> with a **v1** x402 client, treat this as a breaking upgrade and read the section below.

### Breaking interface changes

- **Motoko library (no overloads/defaults to shim — direct callers must update):**
  - `Gateway.settle(signature)` → `settle(signature, expectedAmount : ?Nat)` — enforces
    per-resource exact-equality for nonce-less (stock EVM) clients + cross-resource guard.
  - `HttpHandler.http402(requirements)` → `http402(requirements, resourceUrl)`.
  - `HttpHandler.paymentRequiredJson(requirements)` →
    `paymentRequiredJson(requirements, resourceUrl, errorMsg : ?Text)`.
  - `Policy.releaseDaily(caller, amount)` → `releaseDaily(caller, day, amount)`.
- **`@ic402/client`:** the exported `buildX402PaymentHeader` is **removed** (it emitted a
  conflicting `x402Version:1` payload; use `fetchX402` / `applyVerbatimAccepted`).
  `X402PaymentRequirement` now **requires** `amount: string` (v2 atomic units);
  `maxAmountRequired` remains an optional **reader** alias only — constructors must supply `amount`.
- **Wire (affects a deployed v1 client):** the 402 challenge emits `amount` and no longer
  `maxAmountRequired` server-side; exact-EVM now requires `value == amount` (a prior
  **overpayment is rejected**); `ic402Nonce`/`expiry` moved under `extra`; marketplace
  buyers are charged price **+ ledger fee** so settlement can pay the operator.

### Retained for back-compat

- The canister still accepts the legacy `x-payment` header (prefers `PAYMENT-SIGNATURE`).
- The EVM rail is now payable **without** the ic402 server nonce (v2); the ICP rail still
  uses it, and an echoed nonce is still honored.
- `@ic402/mcp`: every baseline tool name + input schema is unchanged (purely additive).

### Added

- **x402 v2**: v2 wire format + header transport (`PAYMENT-REQUIRED` / `PAYMENT-SIGNATURE`
  / `PAYMENT-RESPONSE`), CORS/OPTIONS, the exact-EVM scheme; self-hosted **facilitator**
  (`GET /supported`, `POST /verify`, `POST /settle`) and discovery `GET /discovery/resources`.
  See `docs/x402-compliance.md`.
- **`getPolicyConfig`** query — read back the live global `SpendingPolicy`; the demo's
  policy step displays it live instead of hardcoding.
- Real EVM streaming sessions; on-chain marketplace settlement + refunds to the operator;
  `quoteServiceRequest` read-only price query.
- `@ic402/mcp`: 7 new dedicated operator tools (`upload_content`, `delete_content`,
  `register_service`, `enable_service`, `claim_job`, `submit_job_result`,
  `sign_typed_data`), default-denied where dangerous. `@ic402/client`: `applyVerbatimAccepted`
  and an optional `probeX402` redirect-validation option.

### Fixed

- **EVM fee data**: `getFeeData` no longer parks a session close on transient
  multi-provider `#Inconsistent` base-fee disagreement (takes the max base fee, clamped to
  a 10 000 gwei ceiling so a hostile/buggy provider can't inflate the gas reservation);
  nonce/send consensus stays strict.
- **`verifyPayment`**: resolves the EIP-712 domain from the token matching the paid `asset`
  (not `tokens[0]`) — a valid signature for a non-first token on a multi-token chain no
  longer fails; unconfigured assets are rejected.
- Demo honesty: every reported success/metric is gated on the real canister verdict — a
  reverted/failed payment no longer renders as completed, and live values replace hardcoded ones.

### Tooling

- One uniform project version: `scripts/version.sh` now bumps **every** place the
  version lives — `mops.toml` (source of truth), all four `package.json` files
  (root + `packages/client` + `integrations/mcp` + `example/client`), the
  `example/zk-verifier` `Cargo.toml` + `Cargo.lock`, and the runtime version
  literals in the MCP server and demo client (`McpServer`/`Client({ version })`),
  which had drifted to `0.1.0`. The source-literal seds are guarded (a bump fails
  loudly if the pattern moves), and a same-version run re-syncs any drifted file.

### Tests

- `mops test`: 16 suites (adds `test/gateway.test.mo` for verifyPayment asset/domain
  resolution and `test/evmsender.test.mo` for the fee math + ceiling; `getGlobalPolicy`
  round-trip in `test/policy.test.mo`). Client SDK: 72 vitest tests.

## v2.0.0 — 2026-06-08

Security release. Fixes all confirmed Critical, High, and Medium findings from the
full-codebase audit (`AUDIT.md`). **This is a breaking release** — see the
"Breaking interface changes" section before upgrading. v2 stable state is not
upgrade-compatible from v1 in all modules; treat as a fresh deploy or migrate
deliberately (see "Migration").

### Critical fixes

- **C1 — EVM settlement now validates the payment recipient.** `Gateway.settle`
  and `Sessions.openEvmSession` now require the EIP-3009 `authorization.to` to equal
  the canister's own derived EVM address. Previously a payer could sign a
  self-transfer (`to` = an address they control), pass signature verification, have
  the canister pay gas to broadcast it, and still receive a valid receipt / funded
  session — a complete payment bypass and (for sessions) a treasury-drain vector.
- **C2 / C3 — MCP server no longer exposes the controller signing key to the LLM.**
  The generic `call` tool is restricted to a read-only/query allowlist; `fetch_x402`
  enforces a URL allowlist (SSRF), per-call + cumulative spend caps, and explicit
  confirmation before signing. (`integrations/mcp`.)
- **C4 — Service-marketplace escrow custody fixed.** `ServiceRegistry.settleJob` /
  `expireJobs` now pay the operator and refund the buyer from the platform recipient
  account (where the payment actually lands) instead of an unfunded per-job
  subaccount, so settlements/refunds no longer fail with `InsufficientFunds`.
- **C5 — EVM service-over-HTTP no longer traps after payment.** The example passes
  `receipt.sender` to the registry as `Text` instead of `Principal.fromText(...)`,
  which trapped for 0x EVM senders *after* the on-chain transfer had executed.

### High fixes

- **H1** — EVM settlement waits for on-chain confirmation (`eth_getTransactionReceipt`,
  status == 1) before issuing a receipt; reverted/never-mined transfers no longer
  yield a "paid" receipt. New `PaymentResult` variant `#settlementPending`.
- **H2** — `EvmSender` reads the `#Pending` chain nonce before every send (removed the
  stale in-memory nonce cache that desynced against `EvmSigner` on the shared address).
- **H3** — `EvmSender` no longer broadcasts with a fabricated ~0.1 gwei fee when fee
  data is unavailable; it returns an error so the caller can retry.
- **H4** — Daily spending limit is reserved *before* the settlement await
  (`Policy.reserveCharge` / `reserveSessionOpen` + `releaseDaily`), closing the
  concurrent-charge bypass.
- **H5** — `ServiceRegistry` settlement uses a synchronous `#Settling` reservation to
  prevent double-settle/double-refund via racing `confirmJob`.
- **H6 / H7** — `ContentStore` requires external-randomness seeding (no more
  deterministic key from the public principal) and persists the key across upgrades.
- **H8** — Access grants are non-transferable: `verifyGrant` now takes the caller and
  requires `caller == grant.grantee`.
- **H9 / H10** — The HTTP x402 flow works end-to-end: paid GETs upgrade to update
  context so the 402 nonce is persisted, and the 402 response now carries the server
  nonce (`ic402Nonce`) for EVM clients to echo and bind the amount.
- **H11 / H12 / H13** — MCP `fetch_content` validates delivery targets (SSRF), and all
  money-moving tools enforce spend caps + confirmation.
- **H14** — Prebuilt ledger/EVM-RPC WASMs are verified against pinned SHA-256 hashes
  before deploy (`scripts/prebuilt.sha256`).

### Medium fixes

- **M1 / M8** — HMAC grant key uses the full 256-bit seed (was truncated to 64 bits).
- **M2** — `ContentStore` mixes a per-entry salt into key/nonce derivation, so
  delete + re-put of the same id never reuses a (key, nonce) pair.
- **M5** — `NonceManager` enforces a hard cap (oldest unlocked nonces evicted),
  bounding memory under 402-challenge spam.
- **M6** — `ServiceRegistry` adds `resolveDispute` and auto-expires stuck
  `#Submitted`/`#Disputed` jobs, so escrow can never be locked permanently.
- **M7** — Voucher signatures bind the verifying canister's principal (cross-canister
  replay protection on Ed25519 key reuse).
- **M9** — Session deposits are counted against the daily limit once and credited back
  on close (was double-counted: deposit + every voucher delta, never refunded).
- **M10 / M11** — Deploy scripts can't poison the source backup with testnet-patched
  content, and backups are gitignored / mainnet markers re-verified after restore.

### Breaking interface changes

**Motoko library API (recompile required):**
- `Gateway.verifyGrant(grant)` → `verifyGrant(caller : Principal, grant)`.
- `Grants.verifyGrant(grant)` → `verifyGrant(caller : Principal, grant)`.
- `Sessions.encodeVoucherPayload(sessionId, amount, sequence)` →
  `encodeVoucherPayload(canisterId : Text, sessionId, amount, sequence)`.
- `ServiceRegistry.submitRequest(buyer : Principal, …)` → `submitRequest(buyer : Text, …)`.
- `ServiceRegistry` no longer settles to an escrow subaccount; new
  `resolveDispute(jobId, refundBuyer : Bool)`.
- `EvmSender.getFeeData` is internal and now returns `?(Nat, Nat)`; new public
  `EvmSender.confirmTransaction(chainId, txHash, maxPolls)`.
- New `Policy` methods: `reserveCharge`, `reserveSessionOpen`, `releaseDaily`.
- `ContentStore` requires `initExternalSeed(...)` (or `startTimers()`) before any
  write — writes trap until seeded.

**Candid / wire / serialized formats (coordinate clients & upgrades):**
- `PaymentResult` gains `#settlementPending`; `JobStatus` gains `#Settling`
  (exhaustive matchers must add these variants).
- Voucher signed payload is now CBOR array(4) `[canisterId, sessionId, cumulativeAmount,
  sequence]` (was array(3)). **Client and canister must be upgraded together; in-flight
  vouchers are invalidated.** `@ic402/client` `signVoucher` gains a `canisterId` argument
  (handled automatically by the session handle).
- The 402 response JSON now includes `ic402Nonce` and `expiry`; EVM-over-HTTP clients
  must echo `ic402Nonce` in the X-PAYMENT payload (the `@ic402/client` `fetchX402`
  helper does this automatically).
- Stable schemas changed: `StableContentStoreState` (+`masterKey`, `seedInitialized`,
  `saltCounter`), `StableContentEntry` (+`salt`). New fields are optional so the
  upgrade decodes, but pre-v2 deterministic-key content is not decryptable under the
  v2 required-seed model.

**MCP server behavior (intended):**
- `autoPayment` defaults to **off**; money-moving/signing tools require `confirm: true`
  and enforce `perCallMaxAtomic` / `sessionMaxAtomic` caps; the generic `call` tool is
  read-only.

### Dependencies

- `ic` 3.2.0 → **4.0.0** (major). Canister types moved from the top-level `mo:ic`
  module to `mo:ic/Types`; `lib.mo` updated accordingly (`HttpResponse_` now aliases
  `ICTypes.HttpRequestResult`).
- `ecdsa` 7.1.0 → **8.0.0** (major). No source changes required (`mo:ecdsa/Curve` API
  compatible).
- `sha2` 0.1.14 → **0.2.1** (minor). No source changes required.
- **Toolchain:** `moc` 1.3.0 → **1.9.0** (required by `ic@4.0.0` / `ecdsa@8.0.0`, which
  need moc ≥ 1.4.0). Integrators must build with moc ≥ 1.4.0.

### Migration

- **EVM identity unchanged:** the canister's EVM address is the same (H2 reads the
  pending nonce rather than changing derivation paths), so no re-funding is needed.
- **ContentStore:** call `store.startTimers<system>()` (or `initExternalSeed(await
  raw_rand())`) once after deploy. Content stored under the pre-v2 deterministic key
  must be re-uploaded.
- **Sessions/vouchers:** upgrade `@ic402/client` and the canister together.
- **Service marketplace:** the platform recipient account custodies funds; operator
  payouts and buyer refunds now transfer from it.

## v1.0.0 — 2026-04-05

### Breaking Changes

- **X402Client removed**: Outbound x402 payments now use EvmSigner (canister signs) + client library (probes URL, broadcasts tx). The canister no longer makes EVM RPC outcalls for outbound operations, reducing cycles cost 40-85%.
- **Identity stripped to metadata**: `registerAgent()`, `getEvmNonce()`, `getFeeData()`, `buildRegisterCalldata()`, `parseAgentRegisteredEvent()` removed. Registration now uses `EvmSigner.signRegistration()` + client-side broadcast.
- **EvmSender is internal-only**: No longer exported from `lib.mo`. Used internally by Gateway for inbound settlement.
- **Client BudgetConfig removed**: Client-side budget tracking was advisory only (not enforceable by a compromised client). Canister-side SpendingPolicy is the enforcement point.
- **ServiceRegistry buyer parameter**: `submitRequest`, `confirmJob`, `disputeJob` now take `Principal` instead of `Text`.

### New Modules

- **EvmSigner** (`src/ic402/EvmSigner.mo`): Remote signing module — canister holds tECDSA key and signs; client handles all RPC/HTTP. Methods: `signTransaction`, `signErc20Transfer`, `signEthTransfer`, `signEip3009Authorization`, `signRegistration`, `signTypedData`.
- **ServiceRegistry** (`src/ic402/ServiceRegistry.mo`): Paid service marketplace coordinator. Canister escrows funds, assigns jobs to operators, verifies results (AutoSettle, HashMatch, BuyerConfirm, ZkGroth16), and settles payment. Full job lifecycle: Pending → Assigned → Submitted → Verified → Settled.
- **ZK Verifier** (`example/zk-verifier/`): Reference Rust canister implementing Groth16/BN254 verification via arkworks. ~392KB WASM, ~$0.005 per proof.

### New Exports

- `EvmSigner`: the only public EVM module (remote signing)
- `ServiceRegistry`: paid service marketplace
- `Eip712`: EIP-712 hashing utilities (domainSeparator, digest)
- `EvmAddress`: keccak256 hashing
- `EvmUtils`: ABI encoding, hex conversion

### Features

- **Generic EIP-712 signing** (`signTypedData`): Universal primitive for any EIP-712 protocol — DEX agent wallets (Hyperliquid, Vertex, Aevo), permit signatures, meta-transactions.
- **HTTP 202 Accepted**: Async service requests return 202 with poll URL. HTTP `/service/*` and `/job/*` routes added.
- **x402 v2 header**: 402 responses now include base64 `payment-required` header alongside JSON body.
- **Service pricing models**: Exact (fixed price), Upto (max with refund), Session (streaming).
- **Service verification methods**: AutoSettle, HashMatch (SHA-256), BuyerConfirm (dispute window), ZkGroth16 (inter-canister Groth16 proof verification).
- **Timer-based job expiry**: Stale jobs auto-refund. Terminal jobs GC'd after 24h.

### TypeScript Client (`@ic402/client`)

- **New `evm` module**: `probeX402`, `fetchX402`, `findPaymentOption`, `broadcastTransaction`, `pollReceipt`, `registerAgent`, `Ic402Error` with 11 classified error kinds and `retryable` flag.
- **Service methods**: `listServices()`, `submitServiceRequest()` (ICRC-2 auto-pay with nonce handling), `pollJobResult()`, `disputeJob()`.
- **EVM methods**: `sendErc20Transfer()`, `sendEthTransfer()`, `registerAgent()`.
- **Typed config**: `Ic402Identity` interface replaces `unknown`. Options object for `fetchX402`.
- **Fixes**: session publicKey encoding (Uint8Array), ICRC-2 approve fee buffer, EVM session authorization passthrough.

### MCP Server

- New tools: `list_services`, `submit_request`, `get_job_result`, `dispute_job`, `fetch_x402` (direct probe → sign → pay).
- ICRC-2 ledger IDL factory for auto-approval.
- 15s AbortController timeouts on HTTP requests.

### Security

- **C-1**: EVM session close leaves `#closing` (not `#closed`) when refund fails, preserving `recoverEscrow` path.
- **H-1**: `EvmSender` txInProgress lock serializes concurrent EVM transactions (prevents nonce desync).
- **H-2**: `forceCloseSession()` has WARNING doc — consuming canister MUST add access control.
- **H-5**: `recoverEscrow` restricted to unconsumed portion, always refunds to payer (removed arbitrary recipient).
- **H-6**: `ContentStore.decryptChunkData` returns `?Blob` — propagates auth failures instead of returning empty blobs.
- **M-1**: Revoked grants store timestamps, GC removes entries >7 days old (hourly timer).
- **M-2**: Policy rateLimitLog deletes empty keys after filtering.
- **M-4**: EIP-3009 validAfter/validBefore validated before expensive EVM outcall.
- **M-5**: `expireJobs()` also GCs terminal jobs >24h old.
- **M-6**: EIP-3009 nonce uses `Time.now()` nanoseconds (monotonic, survives upgrades).
- **M-8**: Client `parseAgentRegisteredEvent` checks topics[0] against keccak256 event signature.
- **CF-1**: Example canister restored to mainnet values; deploy scripts patch for local.

### Refactoring

- `Utils.mo`: extracted `isEvmNetwork()`, `extractChainId()`, `findLedger()` from Gateway/Sessions (~50 LOC dedup).
- `Policy.mo`: `warnIfInvalid()` validates invariants on `loadStable()`.
- Removed unused `ic-vetkeys` dependency.

### Testing

- **36 integration tests**: charges (ICP settlement), sessions, content, services, EVM signer, EIP-712, identity, HTTP gateway, ZK verifier, policy.
- **40 Motoko unit tests**: ServiceRegistry lifecycle, disputes, stable state round-trip, edge cases.
- **8 escrow unit tests**: subaccount derivation determinism, uniqueness, prefix isolation.
- **69 client unit tests**: fetchX402, services, polling, error classification, findPaymentOption.

### Demo

- 10-step interactive walkthrough: Configure, ADD Encrypted Content, SELL Content over x402, DELETE Content, SELL Services over x402, BUY over x402, Streaming Micropayments, Agent Identity, EIP-712 Delegate Signing, Policy + Summary.

### Tooling

- `@icp-sdk/icp-cli` upgraded 0.1.0 → 0.2.2 (fixes icp.yaml parse errors when run via pnpm).
- `icp.yaml` schema updated to v0.2.2. ZK verifier added to local environment.
- Setup/reset scripts always stop + clean before starting (port kill, cache purge, pocket-ic reset).

---

## v0.1.5 — 2026-03-28

### Documentation

- Add `///` doc comments to all remaining public declarations across 13 internal modules (EvmRpc, Eip712, EvmVerify, Sessions, Policy, Nonce, Escrow, Grants, EvmEscrow, EvmSender, Utils, HttpHandler, Identity) — targets 100% mops documentation coverage.

### Project Structure

- Rename `integration/` → `integrations/` for consistency with engramx convention. Update all references in workspace config, package.json scripts, version.sh, docs, and example client.
- Untrack `deploy/deploy.sh` — was force-added but belongs to gitignored local-only tooling.

---

## v0.1.4 — 2026-03-28

### API

- Trim public API surface ~60% — only Gateway, ContentStore, Identity, X402Client, and HttpHandler exported from `lib.mo`. Internal modules (Sessions, Nonce, Escrow, Grants, Policy, EvmSender, EvmEscrow, EvmRpc, EvmAddress, Eip712) are no longer re-exported.
- Add `///` doc comments to all 44 public types and all exported APIs.

### Dependencies

- `ic` 2.1.0 → 3.2.0 (adds `is_replicated` field to HTTP outcalls)
- `test` 2.0.0 → 2.1.2

### Package Metadata

- Add `keywords` to `mops.toml` for registry discoverability
- Add CHANGELOG entry for mops release notes

---

## v0.1.3 — 2026-03-27

### Security Hardening

- **C-1**: `recoverEscrow` rejects when session not found (was auth bypass)
- **C-2**: Remove `Math.random()` fallback in EIP-3009 nonce generation
- **H-1**: Add session garbage collection to prevent unbounded memory growth
- **H-2**: Surface EVM address derivation errors in canister logs
- **H-3**: Inline expiry check in `consumeVoucher` (closes timer gap)
- **H-5**: Validate PKCS#8 structure in MCP PEM parsing
- **M-1**: Replace bare `assert()` with descriptive `Debug.trap()` messages
- **M-3**: Rate-limit session open attempts via policy engine
- **M-4**: Validate URL scheme and path traversal in client `fetchContent`
- **M-5**: Return error when EVM chain config missing (was silent default)
- **M-6**: Add Zod validators for EVM addresses/hashes/networks in MCP

### Improvements

- Update `ic` dependency 2.1.0 → 3.2.0 (add `is_replicated` to HTTP outcalls)
- Trim public API surface ~60% — only Gateway, ContentStore, Identity, X402Client, HttpHandler exported
- Add `///` doc comments to all public types and exported APIs
- Add `keywords` to `mops.toml` for registry discoverability
- `@ic402/client` npm package: add README, LICENSE, `files` field, `peerDependencies`, `engines`
- Deploy script: selective stages (`production publish mops`, `production publish npm`, `production canister`)
- Deploy script: auto git push and GitHub release creation

### Dependencies

- `ic` 2.1.0 → 3.2.0
- `test` 2.0.0 → 2.1.2
- Zero npm audit vulnerabilities

---

## v0.2.0 — 2026-03-24

### Standard x402 Compatibility (EIP-3009)

- **EIP-3009 payment settlement**: Standard x402 clients can now pay ic402 servers. The canister acts as its own facilitator, executing `transferWithAuthorization` on USDC contracts via tECDSA.
- **EIP-712 signature verification**: On-canister verification of typed-data signatures for EVM authorization (`Eip712.mo`).
- **x402 v1 response format**: HTTP 402 responses now emit standard `asset`, `payTo`, `maxAmountRequired`, and `extra` fields.
- **Base64 X-PAYMENT header**: Standard x402 header format (base64-encoded JSON) alongside legacy ic402 format.
- **On-canister EVM signing**: RLP encoding, ABI encoding, EIP-1559 transaction construction, and EC recovery — all in pure Motoko (`EvmUtils.mo`, `EvmSender.mo`, `EvmAddress.mo`).
- **Autonomous agent registration**: Canister signs and submits its own ERC-8004 registration tx on Base via tECDSA (`Identity.mo`). No external wallet needed.
- **EVM session deposits via EIP-3009**: Session deposits on EVM chains use `transferWithAuthorization` instead of direct transfers.
- **EVM session settlement**: Close settles consumed amount and refunds remainder via tECDSA-signed ERC-20 transfers.
- **Client SDK EIP-712 helpers**: TypeScript functions for building `TransferWithAuthorization` typed data and `X-PAYMENT` headers (`eip712.ts`).

### Breaking Changes

- **EVM charge settlement requires EIP-3009**: Legacy direct ERC-20 transfer + tx hash flow removed. EVM payments must now use `transferWithAuthorization` authorization signatures.
- **`consumedTxHashes` removed from stable state**: EIP-3009 nonce-based replay protection replaces tx hash tracking.
- **`PaymentSignature.authorization`**: New optional field for EIP-3009 data.
- **`ERC8004Config` expanded**: Now requires `ecdsaKeyName`, `registryAddress`, `chainId`, `evmRpcCanister`, `gasConfig`.
- **`register-agent.ts` removed**: Agent registration is now on-canister via `registerAgent()`.

### Security Fixes

- **C-2**: EVM transfer logs filtered by contract address in `EvmVerify.findTransferLog`
- **H-1**: Grant issuance requires initialized HMAC seed
- **H-2**: Nonces bound to network + token (not just amount)
- **C-1**: Nonce lock state persisted across upgrades

---

## v0.1.0 — 2026-03-23

Initial production release.

### Features

- **x402 charges**: One-shot ICRC-2 payment gating with nonce replay protection
- **Streaming sessions**: Escrow deposits with cumulative Ed25519-signed vouchers
- **Encrypted content store**: In-canister chunked storage with HMAC-bound access grants
- **ERC-8004 identity**: On-chain agent registration on Base via EVM RPC canister
- **Cross-chain settlement**: 5 EVM chains (Base, Ethereum, Avalanche, Optimism, Arbitrum) via EVM RPC canister
- **TypeScript client SDK** (`@ic402/client`): Budget enforcement, session management, content fetching
- **MCP integration**: Model Context Protocol server for AI agent access

### Security

18-finding audit resolved (3 CRITICAL, 5 HIGH, 10 MEDIUM):

- **C-1**: EVM transaction replay prevention (consumed tx hash set)
- **C-2**: HMAC-bound access grants (contentRef.id included in HMAC)
- **C-3**: Nonce-amount binding (prevents amount manipulation)
- **H-1**: Session close authorization (only payer can close)
- **H-2**: Nat64 overflow protection in voucher encoding
- **M-4**: JSON injection prevention via `escapeJsonString`
- **M-5**: Zero-delta voucher rejection
- **M-8**: Escrow recovery authorization (only session payer)
- **M-10**: JSON unescape in `extractJsonField`

### Breaking Changes

- `closeSession` now requires caller to be the session payer (H-1)
- Access grant HMAC now binds `contentRef.id` — grants from prior versions are invalid (C-2)
- `recoverEscrow` now requires caller authorization (M-8)

### Known Limitations

- `discoverAgents()` returns empty array — ERC-8004 registries are sparse, no real data to query yet
- Ed25519 library (`mo:ed25519`) is unaudited
