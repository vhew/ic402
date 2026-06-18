# Production-readiness TODO (v2.1.0 → prod)

ic402 **v2.1.0** (master @ `388c473`, tagged + released) is a solid unit-tested library
with correct mainnet config and guarded money-**theft** paths, but is **not yet
deploy-to-mainnet-with-real-funds ready**. This is the tracked backlog to close the gap,
from a multi-agent readiness audit (2026-06-16). See `AUDIT.md` for the historical
security audit and `CHANGELOG.md` for what shipped.

## Blockers (must clear before a production deploy)

- [x] **B0 — Canister WASM was un-installable on the current IC (IC0505) — FIXED + VERIFIED.**
  `icp deploy example` is rejected: *"Wasm module contains a function at index 35 with
  **2081 locals** that exceeds the maximum allowed number of locals **2000**."* The 2000-locals
  cap is a standard IC replica validation limit (mainnet too), not a local quirk. Root cause:
  the fully-unrolled SHA-256 compressor in `mo:sha2` (`process_blocks_from_iter`), compiled by
  the pinned moc 1.9.0 which unrolls it; sibling `mo:sha2`/`mo:sha3` functions sit near the cap
  too (sha512 `process` ≈ 1846), and `keccak256` (`mo:sha3`, used by `EvmAddress`/`Eip712`) may
  also be over once sha2 is fixed. This is why `setup:local` fails here and why **B3 can't run**
  — the canister has no installed module. **This supersedes the other blockers: the canister
  currently deploys nowhere.** Verified by reproducing IC0505 locally (2026-06-16).
  **FIX FOUND + PROVEN (no crypto rewrite):** a `wasm-opt -O --all-features` build step takes the
  SHA-256 function from **2081 → 96 locals**; the optimized wasm **installs successfully and runs**
  (Candid intact, `getPolicyConfig` returns the real policy). The unrolled schedule coalesces
  because only ~16 words are live at once. ⚠️ Needs binaryen **≥ v130** — `ic-wasm`'s bundled
  wasm-opt is too old (fails on moc's 64-bit table). **LANDED + VERIFIED:** (1) `scripts/build-example.sh`
  runs `moc → wasm-opt -O → check-wasm-locals.js` and `setup.sh` installs that optimized module
  (`icp canister install --wasm`); (2) `scripts/fetch-binaryen.sh` pins binaryen v130 (SHA-checked,
  mac+linux); (3) a `wasm-locals` CI job builds+optimizes and fails if any function exceeds the
  budget. `pnpm setup:local` now completes clean end-to-end (example installs, tECDSA EVM recipient
  derives, test-payer funded) — confirming no IC0505 and no crypto rewrite. A loop-based
  SHA-256/Keccak rewrite was NOT needed.
- [~] **B1 — Upgrade incompatibility from v2.0.0 — WAIVED for the single-operator deploy.**
  The operator accepts a state-dropping fresh deploy (the library has no external consumers
  relying on in-place upgrade), so this is not a blocker for that context. Original note: `main.mo` is a
  `persistent actor` (EOP); v2.1.0 added stable fields (`evmRails`/`operatorPayouts`,
  optional) and a required `bindResult` to `#ZkGroth16`, so an in-place upgrade is
  rejected (M0170 — verified with `moc --stable-compatible`). No migration function; a
  fresh deploy drops all escrow/session/grant/nonce/registry state. **Do:** add a
  `migration` function **or** document a state-dropping fresh-deploy in the CHANGELOG
  (as v2.0.0 did). Under EOP you cannot add *any* stable field without a migration.
- [x] **B2 — Unconfirmed broadcast treated as settled (H1-class) — FIXED + VERIFIED (v2.1.1).** The
  EVM *outbound* paths (`ServiceRegistry.settleJob`/`refundOnRail`, Sessions EVM
  `closeEvmSessionInternal`) finalize state (`#Settled`/`#Refunded`/`#closed`) on mempool
  acceptance, without `confirmTransaction` — unlike the hardened inbound `Gateway.settle`.
  A reverted/never-mined transfer marks the job/session paid while no funds moved.
  **Do:** add `EvmSender.sendErc20TransferConfirmed` (tri-state confirmed/reverted/pending,
  mirroring `executeTransferWithAuthorization`), widen the `EvmTransferFn` hook, and
  finalize only on `#confirmed` (park on pending via the existing `#closing`/`#Settling`
  idiom; reuse `#settlementPending`; **no new stable field/variant** — EOP-safe).
  **Landed (f579545):** `sendErc20TransferConfirmed` tri-state added, `EvmTransferFn`
  hook widened, and settle/refund/close finalize only on `#confirmed` — verified on
  Base Sepolia this release (mined `status==1` settle + session close+refund).
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
- [~] **SEC-1 — PARTIAL (v2.1.1).** Rate-limit/gate the unauthenticated facilitator **update**
  endpoints (`POST /verify`, `/settle`): they run in `http_request_update` (cost the canister
  cycles) and parse attacker JSON before any policy rate-limit → **cycle/DoS** surface.
  (No theft — C-1 binding holds — but spam is unmetered.) **DONE:** the unbounded-state half is
  closed — `policy.gcRateLimit()` is now wired into the hourly maintenance timer (it existed but
  was never called, so `rateLimitLog` grew unbounded under attacker-minted payer principals).
  **Still open:** a pre-policy global cycle/rate guard ahead of the ecrecover/RPC work, and
  `canister_inspect_message`.
- [ ] **SEC-2** — `getFeeData` hostile-RPC grief-park: one persistently bad provider can
  park every EVM close/settle (max-base-fee picks the outlier; the 10k-gwei ceiling
  bounds but doesn't eliminate). Ship a recovery path (`recoverEscrow`/confirm-only
  re-poll) — the example currently exposes none.
- [ ] **SEC-3** — MCP admin tools (`register_service`, `enable_service`, `claim_job`,
  `submit_job_result`, `upload_content`) are **default-enabled**, gated only by an in-band
  `confirm` flag a prompt-injected LLM can set. Re-examine the trust model.
- [x] **SEC-4 — FIXED (v2.1.1).** `getPolicyConfig` now redacts `allowedCallers`/
  `blockedCallers` (returns them null), so the public query no longer exposes the access-control
  roster; the spend limits (non-secret — advertised in the 402 challenge) still read back.

## Stuck-state recovery & operability (fresh assessment 2026-06-18)

A grounded re-assessment (single-operator, real-funds context, B1 waived) confirmed there is
**no money-theft path** (recipient binding, `value==amount`, nonce lock, confirm-before-finalize
all hold). The real remaining gap is **recoverability + observability of funds that get STUCK** —
a direct consequence of the B2 fix (it correctly stopped finalizing on unconfirmed broadcasts, so
a `#pending`/`#reverted`/RPC-`#err` outbound leg now parks the job in `#Settling` / the session in
`#closing`).

- [x] **Observability — DONE (v2.1.1).** Controller-only `health()` (cycle balance + job/session
  status counts; watch `jobs.settling` / `sessions.closing`) and `listJobs(serviceId, ?status)`.
  The operator can now SEE parked funds.
- [x] **Manual recovery escape hatch — DONE (v2.1.1).** Controller-only `resolveJob(jobId,
  terminal)` (a `#Settling` job → `#Settled`/`#Refunded`/`#Expired`) and `forceResolveSession`
  (a `#closing` session → `#closed`). **State assertion only — moves no funds**: the operator
  verifies the on-chain outcome, then unsticks the record so it stops pinning memory and becomes
  GC-eligible. Funds for a never-landed transfer are reconciled out-of-band (or via EVM sweep).
- [ ] **Auto confirm-only reconcile — TODO (designed).** Persist the parked tx hash + leg on the
  Job/Session (stable-field addition; fine under the B1 fresh-deploy waiver) and add
  `reconcileJob`/`reconcileSession` that re-poll the stored hash via a **read-only** confirm hook
  and finalize ONLY on a mined `status==1` — never re-broadcast (re-broadcast risks double-pay).
- [ ] **`sweepEvm(chainId, token, to, amount)` — TODO.** Controller-only escape hatch to drain the
  canister's EVM balance (key/subnet-compromise response, or to settle a never-landed refund),
  reusing the confirmed-transfer sender.
- [ ] **Cycle-balance guard — TODO.** Each EVM settle burns ~60B cycles over ~6 HTTPS outcalls; add
  a pre-settle floor check so the canister never broadcasts a transfer it can't afford to confirm
  (a freeze mid-settle is what parks funds). `health()` now surfaces the balance.
- [ ] **Confirmation depth / reorg — TODO.** `status==1` is treated as final with no confirmation
  depth; require N confs on deposits + outbound confirms. Low probability, real on L2s.
- [ ] **2-provider chains park on one flaky RPC — TODO (broader than SEC-2).** 2-of-2 consensus on
  the nonce/broadcast path means one bad provider parks every settle (testnets + any 2-provider
  chain; mainnet Base/ETH/OP/Arb use resilient 2-of-3). Add a 3rd provider / provider-count-aware
  min + operator RPC override; pairs with the reconcile path above.

## Docs (some stale / missing)

- [x] AUDIT.md reconciled (header/banner/remediation-status — 2026-06-16).
- [x] CHANGELOG.md:9 false "root still 0.1.0" claim corrected.
- [x] **README.md** brought current with v2.1.0 — fixed the stale `settle`/`http402`
  signatures, added the facilitator endpoints + `getPolicyConfig`/`verifyPayment` + the
  new HttpHandler helpers, and added a Testing section.
- [x] Added **`integrations/mcp/README.md`** (tool inventory + security model) and a
  top-level **`SECURITY.md`** (remediation status, threat models, WASM pinning, disclosure).
  Note: SECURITY.md leaves a `[maintainer: set a security contact]` placeholder to fill.
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
cycles attached, timers/GC bounded; `.did` in sync; versions uniform at 2.1.1.
