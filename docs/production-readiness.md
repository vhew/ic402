# Production-readiness TODO (v2.1.0 → prod)

ic402 **v2.1.0** (master @ `388c473`, tagged + released) is a solid unit-tested library
with correct mainnet config and guarded money-**theft** paths, but is **not yet
deploy-to-mainnet-with-real-funds ready**. This is the tracked backlog to close the gap,
from a multi-agent readiness audit (2026-06-16). See `AUDIT.md` for the historical
security audit and `CHANGELOG.md` for what shipped.

## Blockers (must clear before a production deploy)

- [ ] **B1 — Upgrade incompatibility from v2.0.0 (undocumented).** `main.mo` is a
  `persistent actor` (EOP); v2.1.0 added stable fields (`evmRails`/`operatorPayouts`,
  optional) and a required `bindResult` to `#ZkGroth16`, so an in-place upgrade is
  rejected (M0170 — verified with `moc --stable-compatible`). No migration function; a
  fresh deploy drops all escrow/session/grant/nonce/registry state. **Do:** add a
  `migration` function **or** document a state-dropping fresh-deploy in the CHANGELOG
  (as v2.0.0 did). Under EOP you cannot add *any* stable field without a migration.
- [ ] **B2 — Unconfirmed broadcast treated as settled (H1-class, new in v2.1.0).** The
  EVM *outbound* paths (`ServiceRegistry.settleJob`/`refundOnRail`, Sessions EVM
  `closeEvmSessionInternal`) finalize state (`#Settled`/`#Refunded`/`#closed`) on mempool
  acceptance, without `confirmTransaction` — unlike the hardened inbound `Gateway.settle`.
  A reverted/never-mined transfer marks the job/session paid while no funds moved.
  **Do:** add `EvmSender.sendErc20TransferConfirmed` (tri-state confirmed/reverted/pending,
  mirroring `executeTransferWithAuthorization`), widen the `EvmTransferFn` hook, and
  finalize only on `#confirmed` (park on pending via the existing `#closing`/`#Settling`
  idiom; reuse `#settlementPending`; **no new stable field/variant** — EOP-safe).
- [ ] **B3 — EVM rail never verified end-to-end.** No funded on-chain settle/close has
  ever completed through ic402's tECDSA sender. **Do:** one observed green settle + one
  green session close+refund on a funded clean-EOA payer (Base Sepolia), capturing mined
  `status==1` tx hashes; plus a Foundry-fork replay for CI/offline.
- [ ] **B4 — CI green is hollow for the substance.** The only e2e suite
  (`test/integration.test.ts`, 49 cases) **always skips in CI** (no replica) and **fails
  3/49 locally** (hardcoded `svc-1`/price assumptions). **Do:** make the suite
  deterministic (bind to its own registered service id, not `svc-1`) and add a
  replica-backed CI job that fails if skipped.

## Security (fresh composed-system pass before tagging "production-ready")

- [ ] **SEC-0 — Commission ONE fresh adversarial security pass over the entire v2.1.0
  surface AS A COMPOSED SYSTEM.** The pieces were reviewed per-commit, but the new surface
  has never been audited end-to-end together: the unauthenticated facilitator endpoints
  (`/verify`, `/settle`, `/supported`, `/discovery`), the marketplace cross-rail
  settle/refund, the EVM session close, and the 7 new MCP admin tools. *(Requested
  explicitly.)* Specifically cover SEC-1..3 below as part of it.
- [ ] **SEC-1** — Rate-limit/gate the unauthenticated facilitator **update** endpoints
  (`POST /verify`, `/settle`): they run in `http_request_update` (cost the canister
  cycles) and parse attacker JSON before any policy rate-limit → **cycle/DoS** surface.
  (No theft — C-1 binding holds — but spam is unmetered.)
- [ ] **SEC-2** — `getFeeData` hostile-RPC grief-park: one persistently bad provider can
  park every EVM close/settle (max-base-fee picks the outlier; the 10k-gwei ceiling
  bounds but doesn't eliminate). Ship a recovery path (`recoverEscrow`/confirm-only
  re-poll) — the example currently exposes none.
- [ ] **SEC-3** — MCP admin tools (`register_service`, `enable_service`, `claim_job`,
  `submit_job_result`, `upload_content`) are **default-enabled**, gated only by an in-band
  `confirm` flag a prompt-injected LLM can set. Re-examine the trust model.
- [ ] **SEC-4** — `getPolicyConfig` is a public query returning the full `SpendingPolicy`
  incl. `allowedCallers`/`blockedCallers`; decide whether to redact the access-control
  roster (null in the example, but a footgun for real operators).

## Docs (some stale / missing)

- [x] AUDIT.md reconciled (header/banner/remediation-status — 2026-06-16).
- [x] CHANGELOG.md:9 false "root still 0.1.0" claim corrected.
- [ ] **README.md** API tables are stale (`settle(signature)` → `settle(signature,
  expectedAmount?)`; `http402(requirements)` → `+resourceUrl`) and omit every v2.1.0
  feature (facilitator endpoints, `getPolicyConfig`, `verifyPayment`, new HttpHandler
  helpers). No test-running section.
- [ ] Add **`integrations/mcp/README.md`** (tool inventory + security model) and a
  top-level **`SECURITY.md`** (remediation status, WASM pinning, disclosure contact).
- [ ] Add per-finding `STATUS:` annotations inline in AUDIT.md (currently summarized in
  the Remediation-status table only).

## Tests / CI gates to add

- [ ] Extract the `getFeeData` `#Inconsistent` max-base fold to a pure helper + unit-test
  it (only `feeFromBase`/`latestBaseFee` are covered today).
- [ ] Always-on unit tests for the facilitator HTTP shapers + error-reason codes
  (`HttpHandler` `verifyResponseJson`/`settlementResponseJson`/`http402WithSettlement`).
- [ ] Unit-test the marketplace settle/refund EVM hooks via an injected mock
  `EvmTransferFn`.
- [ ] CI gates: replica-backed integration job (fail if skipped); `moc
  --stable-compatible` vs the previous release `.most`; `.did` sync (`gen-did.sh` +
  `git diff --exit-code`); deploy smoke test; version-literal sync.

## What is already solid (verified)

Mainnet constants correct (chain IDs, 5 USDC addresses, ckUSDC ledger, `key_1`, EVM RPC
canister); money-**theft** paths guarded (C-1 recipient binding, `value==amount`, local
EIP-712 verify before broadcast, H-4 synchronous daily reservation, S-3 terminal close);
unit-level math/guards well-pinned (16 mops + 72 client + MCP guard/security tests);
cycles attached, timers/GC bounded; `.did` in sync; versions uniform at 2.1.0.
