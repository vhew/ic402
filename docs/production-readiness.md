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
- [~] **B4 — CI green is hollow for the substance — MOSTLY FIXED (v2.1.1).** The only e2e suite
  (`test/integration.test.ts`, now 50 cases) used to **silently pass in CI** (every case is
  `if (skip) return`; with no replica vitest counts them as passed) and failed locally on
  hardcoded `svc-1`/price assumptions. **DONE:** (1) the suite is now deterministic — it binds to
  its own registered service id and is hermetic (every fetch hits the local replica; the EVM cases
  are sign-only, no broadcast); (2) a **`test-integration` CI job** deploys a real local replica
  (`pnpm setup:local`) and runs it with `IC402_REQUIRE_REPLICA=1`, turning a missing replica into a
  HARD failure (verified 50/50 enforced locally); (3) a `did-sync` gate fails on a drifted
  `example.did`. **Still open:** the suite covers the LOCAL money/protocol paths but NOT the EVM
  OUTBOUND broadcast money paths (settle/refund/session-close to Base) — those need a funded
  testnet or a Foundry-fork mock (can't be hermetic) and the full async `reconcileJob`/
  `reconcileSession` loop (only their pure decision matrices are unit-tested). First CI run also
  validates the ubuntu `icp` network-launcher path.

## Security (fresh composed-system pass before tagging "production-ready")

- [x] **SEC-0 — DONE (composed-system adversarial audit run; findings fixed).** A multi-agent
  composed-system pass (attack → majority-vote verify → cross-surface critic) plus two re-attack
  rounds covered the unauthenticated facilitator endpoints, marketplace cross-rail settle/refund,
  EVM session close, key custody, the MCP tools, and EVM reorg/RPC trust. **Confirmed + fixed:**
  (1) ServiceRegistry ZK `#err` branch clobbered terminal job state → double-refund (now status-
  guarded); (2) EVM session accepted EIP-3009 overpayment → stranded excess (now `value == deposit`);
  (3) unmetered `ecRecover` cycle-DoS on the paid-settle + session-open paths (now one global token
  bucket inside settle/verifyPayment/openEvmSession); (4) `EvmEscrow.totalAllocated` was dead code +
  an open-time allocation leak (now a live `poolCap` guard + validate-before-allocate); (5) MCP
  cumulative spend-cap TOCTOU (now reserve-at-confirm + refund-on-failure); (6) MCP DNS-rebinding
  SSRF (now DNS-resolved at every fetch entry point). Re-attack #2 verdict: PASS, no non-documented
  blocker. **Deferred/documented residuals** (see `docs/security-model.md`): (a) system-wide shared-
  EVM-pool solvency — marketplace/sweep vs `totalAllocated`; (b) SSRF connect-time re-resolve window
  (no undici IP-pinning yet) + `probeX402` per-redirect-hop literal validation; (c) `recoverBuyer-
  ActionSigner` ungated but not example-wired; plus a recommended regression-test layer (ServiceRegistry
  async interleavings; MCP `spendGuard`/`refundSpend`) and the pre-existing transient `submit_request`
  lost-reply cap under-count (availability, not a cap-bypass).
- [~] **SEC-1 — PARTIAL (v2.1.1).** Rate-limit/gate the unauthenticated facilitator **update**
  endpoints (`POST /verify`, `/settle`): they run in `http_request_update` (cost the canister
  cycles) and parse attacker JSON before any policy rate-limit → **cycle/DoS** surface.
  (No theft — C-1 binding holds — but spam is unmetered.) **DONE (v2.1.1):** (1) `policy.gcRateLimit()`
  wired into the hourly timer (closes the unbounded-`rateLimitLog` growth under attacker-minted
  principals); (2) a **GLOBAL caller-agnostic admission gate** — `Gateway.facilitatorAdmit()` (pure,
  unit-tested `tokenBucketStep` + a 500B cycle floor) runs FIRST in the `/verify`+`/settle` branch,
  before the body parse / ecrecover / settle, returning 429/503. The bucket keys on nothing, so the
  attacker can't mint fresh per-`from` buckets; the floor (above the 120B broadcast floor) self-
  disables the facilitator before a drain reaches freezing. Adversarially reviewed SAFE/EFFECTIVE.
  **Still open (follow-up, lesser):** the paid `/content`/`/search`/`/service` settle paths run
  ecrecover on attacker input without the global gate (same drain class, but they require a parseable
  payment header) — extend the gate to them; and (optional) `canister_inspect_message` to bound ingress.
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
- [x] **Auto confirm-only reconcile — DONE (v2.1.1), jobs + sessions.** Both re-poll a STORED
  parked tx via a **read-only** confirm path and finalize ONLY on a mined `status==1` — never
  re-broadcast (no double-pay); each has a pure, unit-tested decision matrix; both adversarially
  reviewed SAFE (no double-pay / false-finalize / double-credit / lost-park / GC-drop).
  - **Jobs:** `Job.parkedTx` (stable) at every `#pending` park site; `reconcileJob` + the pure
    `reconcileDecision` (7 branch tests); `gcTerminalJobs` won't reclaim a job carrying a parkedTx;
    `resolveJob` clears it; `health` reports `jobs.parked`.
  - **Sessions:** the close is TWO-PHASE (settle consumed → refund remainder), so `reconcileSession`
    + the pure `sessionReconcileDecision` (5 branch tests) finalize `#closed` when confirming the
    parked leg completes the close (a confirmed refund, or a confirmed settle with no remainder). A
    confirmed settle WITH a remainder owed can't be auto-completed confirm-only (the refund is
    unsent) → `forceResolveSession` + `sweepEvm` returns it. Parked leg+hash in a transient side-map.
- [x] **`sweepEvm(chainId, token, to, amount)` — DONE (v2.1.1).** Controller-only escape hatch that
  drains the canister's OWN EVM balance to an operator address (key/subnet-compromise response, or
  to settle a never-landed refund), via the confirmed-transfer sender (reports `#confirmed` only on
  a mined `status==1`).
- [x] **Cycle-balance guard — DONE (v2.1.1).** `EvmSender.sendTransaction` refuses to broadcast below
  a 120B cycle floor (a full settle ≈ ~100B over ~7 outcalls + a tECDSA sign), returning a
  pre-broadcast `#err` so the canister never broadcasts a transfer it can't afford to confirm (a
  freeze mid-settle is what parks funds). `health()` surfaces the balance.
- [x] **2-provider chains park on one flaky RPC — DONE (v2.1.1).** Added a verified 3rd RPC provider
  (drpc.org) to each 2-of-2 testnet chain (Base/OP/Arb Sepolia, Avalanche Fuji) → 2-of-3, which
  tolerates one provider failing. No consensus relaxation (receipts still need 2 to AGREE); mainnet
  Base/ETH/OP/Arb already use resilient managed 2-of-3 sets. An operator-configurable RPC override
  is a possible future nicety but no longer needed for resilience.
- [ ] **Confirmation depth / reorg — DEFERRED (genuine tradeoff; low practical risk).** `status==1`
  is treated as final with no confirmation-depth check on inbound deposits/charges (`EvmVerify`) or
  outbound confirms (`EvmSender.confirmTransaction`); a shallow reorg could un-mine a credited
  deposit. **Why deferred, not rushed:** (1) it needs a chain-head read — the EVM-RPC interface
  here exposes no `eth_getBlockByNumber`, so it must be added to `EvmRpc.EvmRpcCanister` (+ a Block
  result type) or derived from `eth_feeHistory.oldestBlock`; (2) it touches the security-sensitive
  inbound deposit-verification path; (3) it changes confirm SEMANTICS/timing for every settle (more
  `#pending` → more parking → leans on the reconcile path), so it needs a funded e2e re-verify. The
  practical risk is LOW here (mostly USDC on optimistic L2s, whose centralized sequencer rarely
  reorgs the tip). **Recommendation:** ship as a FOCUSED change — configurable depth (default ~2 for
  L2s) + the head-read addition + a demo re-run — or accept as a documented low-probability risk for
  the single-operator L2 context.

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
