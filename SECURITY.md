# Security Policy

ic402 is a payment library: it moves money (ICRC-2 / ckUSDC on ICP, USDC on five EVM
chains via tECDSA) on behalf of canisters and AI agents. Security is the product. This
file states the current remediation posture, what is and is not yet production-ready, the
threat models we design against, and how to report a vulnerability.

> **Current release: v2.23.0** (additive: `recoverEscrowReceipt`). The latest security release is
> **v2.22.0**: three high-severity fixes and about forty medium and low ones, all found by a
> whole-library adversarial review (advisory GHSA-jxw7-5x89-grxh). Read its upgrade notes in
> [`CHANGELOG.md`](CHANGELOG.md) before upgrading from an earlier version; several fixes change
> behaviour. Earlier security-relevant releases since v2.2.3:
> - 2.17.0: caller-authenticated sessions and `settleFrom`;
> - 2.20.0: an ICP ledger reject with an unknown outcome is no longer treated as "not paid";
> - 2.21.0: such payments can be resolved in-band.
>
> The current model is [`docs/security-model.md`](docs/security-model.md). The open-items section
> below is a snapshot from v2.2.3.

> **Status at v2.2.3 (snapshot).** The blockers tracked for a real-funds deploy are cleared —
> B0/B2/B3/B4 done, B1 waived (single-operator state-dropping fresh deploy) — and the
> composed-system security pass (SEC-0, plus SEC-1..4) is complete; see
> [`docs/production-readiness.md`](docs/production-readiness.md) (the source of truth) and
> **Known open items** below. What remains is **not** a blocker: an *optional* external
> professional audit (the SEC-0 pass was internal multi-agent), a deferred low-risk
> confirmation-depth/reorg tradeoff (NEW-5), and the SEC-0 documented residuals (operator
> invariants) in [`docs/security-model.md`](docs/security-model.md). Treat the
> MCP/facilitator identity as a hot wallet: cap it and review the model for your deployment.

## Supported versions

| Version | Supported | Notes |
|---|:--:|---|
| 2.23.x | ✅ | Current. |
| 2.22.x | ✅ | Supported: has every security fix. 2.23.0 only adds `recoverEscrowReceipt`. |
| 2.21.x | ⚠️ | Superseded; upgrade. Lacks the 2.22.0 security fixes, three of them high severity. |
| 2.20.x | ⚠️ | Superseded; upgrade. A pending ICP charge can only be resolved by checking the ledger, and a session-open deposit rejected with an unknown outcome is left without a session record. |
| 2.0.x – 2.19.x | ⚠️ | Superseded; upgrade. An ICP ledger reject with an unknown outcome is treated as "not paid", which can charge a payer twice (fixed in 2.20.0). |
| < 2.0.0 | ❌ | Unmaintained. Pre-remediation; contains the Critical findings in `AUDIT.md`. Do not deploy. |

Security fixes land on the current minor series. There is no long-term-support branch for
older lines — this is early-stage software and the recommended action for any pre-2.0.0
deployment is to upgrade.

## Security posture / remediation status

How each release is reviewed:

- **Adversarial review before every release.** Reviewers attack the release looking for theft,
  double-pay, fund loss and authorization bypass. Every finding is confirmed or refuted against
  the source before anything is fixed. For 2.22.0 the review covered the whole library, not only
  the release's changes.
- **Mutation-verified tests.** Each fix is pinned by tests. The fixes are then mutated one at a
  time, with each test run in isolation, and every mutation must turn at least one test red.
  Paths the Motoko interpreter cannot reach (timers, tECDSA, traps, real EVM broadcasts) are
  covered by review and by the replica-backed suites.
- **CI gates.** Every push and pull request runs the Motoko unit suites, the TypeScript client,
  MCP and security units, a replica-backed end-to-end suite and a hermetic EVM-outbound suite (both
  fail hard when their fixture is missing), the stable-schema compatibility check, the Candid
  mirrors of the ledger and EVM-RPC interfaces, the WASM-locals install gate, and source gates,
  most with a self-test proving they still catch what they guard.
- **Private reporting.** Vulnerabilities are reported and fixed privately, and the advisory is
  published after the fixed release ([Reporting a vulnerability](#reporting-a-vulnerability)).

History: the full-codebase audit ([`AUDIT.md`](AUDIT.md)) confirmed 51 findings (5 Critical, ~14
High, 11 Medium, plus Low/Info). **All Critical (C1–C5), High (H1–H14), and Medium
(M1–M11) findings were fixed in v2.0.0** (`c7e4307`); see `AUDIT.md` → "Remediation
status" and [`CHANGELOG.md`](CHANGELOG.md) → v2.0.0. A **v2.0.0 re-audit** (`40e561f`)
found and fixed 8 follow-on HIGH + 2 medium regressions the fixes themselves introduced
(nonce ring-buffer stale-blob leak, `releaseDaily` wrong day-bucket across UTC midnight,
`resolveDispute` double-refund race, ContentStore salt-boundary re-key, `confirmTransaction`
treating a missing receipt status as confirmed, a client BigInt crash, and a
`#Session requireAll(0)` trap). `AUDIT.md` is retained as the historical audit-of-record;
its per-finding sections are the **original v1.0.0 observations**, mapped to their fixes —
do not read them as describing current behaviour. Beyond that v1.0.0 audit and its v2.0.0
re-audit, a separate **composed-system** security pass ran across the v2.1.x→v2.2.3 series:
**SEC-0** (an internal multi-agent adversarial audit with two re-attack rounds) plus the
targeted hardening **SEC-1..4**. Its findings are fixed and its deferred residuals
documented in [`docs/production-readiness.md`](docs/production-readiness.md) (the source of
truth) and [`docs/security-model.md`](docs/security-model.md).

### Money-theft paths that are guarded (verified in source)

These are the load-bearing controls that stop value being stolen or fabricated. Each is
exercised on the inbound settlement path:

- **C-1 — recipient binding.** EIP-3009 settlement requires `authorization.to` to equal
  the canister's own derived EVM address before any signature verification or broadcast,
  in **both** the charge path (`Gateway.settleCore`) and the session-open path
  (`Sessions.openEvmSession`). This closes the self-transfer payment-bypass /
  treasury-drain that was the audit's highest-priority finding.
- **`value == amount` (exact-EVM).** The exact-EVM scheme rejects an authorization whose
  `value` is not exactly the required amount, not merely `>=` it
  (`Gateway.settleCore`) — a v1-style overpayment is rejected.
- **EIP-712 verify before broadcast.** The EIP-3009 signature is recovered and verified
  locally (`Eip712.verifyAuthorization`) **before** any on-chain outcall
  (`executeTransferWithAuthorization`), so an invalid signature never costs a broadcast.
- **H-4 — synchronous daily spend recording.** The daily spend is recorded synchronously
  *before* the value-moving `await`: the charge path (`Gateway.settleCore`) captures
  `policy.currentDay()` then calls `policy.recordSpend(...)` before the transfer await, with
  `policy.releaseDaily(caller, day, amount)` rollback against the captured day-bucket on
  failure. Concurrent charges can no longer each pass a stale limit check. The session-open
  path (`Sessions.openSession`) checks the limit before the deposit and records the deposit
  once it has landed.
- **S-3 / terminal close.** Session close sets `#closing` *before* any async operation, in
  the same message as its re-close guard (`Sessions.closeSessionInternal`; for EVM since
  2.22.0), and finalizes `#closed` only on a confirmed transfer; a failed/ambiguous transfer is
  parked in `#closing` for recovery and never re-broadcast (confirm-only recovery:
  `reconcileSession`). This prevents double-settle / double-refund.
- **The canister is never the payer (2.22.0).** `settle` and `settleFrom` refuse the canister's
  own principal as the paying `sender`, and a session deposit refuses the canister's own account
  (`Gateway.settleCore`, `Escrow.depositCore`).

Cryptographic primitives reviewed sound: EIP-712 recovery, constant-time byte comparison,
and AEAD with constant-time tag comparison (`src/ic402/ContentStore.mo`). The residual
risk lives in the orchestration layer, which is what the open items below address.

## Known open items / production-readiness status

Tracked in [`docs/production-readiness.md`](docs/production-readiness.md) (the source of
truth). Current state at v2.2.3 — every tracked blocker is cleared or waived, and the
composed-system security pass is complete:

- **B0 — un-installable WASM (IC0505): FIXED.** A `wasm-opt -O` build step coalesces the
  unrolled SHA-256 locals (2081 → 96); a `wasm-locals` CI gate guards against regression.
- **B2 — unconfirmed-broadcast → settled: FIXED.** The EVM **outbound** paths (marketplace
  `settleJob`/`refundOnRail`, Sessions EVM `closeEvmSessionInternal`) broadcast then
  CONFIRM via `EvmSender.sendErc20TransferConfirmed`, finalize **only** on `#confirmed`,
  park on `#pending`/`#reverted`, and never re-broadcast an ambiguous send (`sendTransaction`
  returns a tri-state `{#ok; #err; #maybeSent}`).
- **B3 — EVM rail verified end-to-end AND CI-gated: DONE.** The funded outbound path has
  completed on Base Sepolia (mined `status==1` settle + session close/refund), and the
  outbound state machine is now gated **hermetically** in CI: a scriptable mock of the
  EVM-RPC canister (`example/evm-rpc-mock/`) drives confirm / revert / park / reconcile with
  no funded testnet (`test-evm-outbound` job). Real tECDSA signing + RLP still run; only the
  broadcast/confirm leg is mocked.
- **B4 — replica-backed CI: DONE.** `test-integration` enforces the end-to-end suite
  (`IC402_REQUIRE_REPLICA=1`); B3 closes its residual EVM-outbound gap.
- **B1 — upgrade migration from v2.0.0: WAIVED.** `main.mo` is a `persistent actor` (EOP);
  the operator accepts a state-dropping fresh deploy (single-operator, no external
  upgrade consumers), so this is not a blocker for that context.
- **SEC-0 — composed-system adversarial pass: DONE.** A multi-agent pass (attack →
  majority-vote verify → cross-surface critic) plus two re-attack rounds; 6 findings fixed.
  The documented residuals (shared-pool solvency operator-invariant; SSRF connect-pin;
  `recoverBuyerActionSigner`) are in [`docs/security-model.md`](docs/security-model.md).
- **SEC-1 — unauthenticated-facilitator cycle/DoS: FIXED.** A caller-agnostic token-bucket
  rate-limit + cycle-floor gate (`Gateway.facilitatorAdmit`) fronts the facilitator paths
  before the expensive work runs.
- **SEC-2 — `getFeeData` hostile-RPC grief-park: FIXED.** Fee data now takes the ROBUST
  (lower-median) base fee across providers, so a single outlier can't make the gas
  reservation unpayable; a confirm-only `reconcileJob` / `reconcileSession` recovery path
  exists (and `sweepEvm` / `forceResolveSession` as manual hatches).
- **SEC-3 — MCP admin-tool trust: FIXED.** The state-changing admin tools (`register_service`,
  `enable_service`, `claim_job`, `submit_job_result`, `upload_content`) are default-**DENIED**;
  an operator must opt in (`IC402_MCP_ALLOW_ADMIN_TOOLS`), and the dangerous primitives
  (`delete_content`, `sign_typed_data`) stay behind a separate flag.
- **SEC-4 — policy-roster disclosure: FIXED.** `getPolicyConfig` redacts the allow/block roster.

Not blockers, but recommended before treating it as battle-tested:

- An **external** professional audit — the SEC-0 pass was internal multi-agent.
- **NEW-5 — confirmation depth / reorg.** `status==1` is treated as final (DEFERRED; low
  practical risk on optimistic L2s — a deeper guarantee needs a chain-head read the EVM-RPC
  interface doesn't expose).
- An optional periodic **live-testnet smoke** for the funded leg (which can't be hermetic).

## Threat-model highlights

- **MCP server — untrusted-LLM model.** [`integrations/mcp/`](integrations/mcp/) runs
  against a canister authenticated as a **controller**, driven by an LLM that may be
  steered by prompt-injected content. The audit's C2/C3/H11–H13 all lived here. Mitigations
  in place: SSRF allowlisting with per-redirect re-validation **and a DNS-rebinding guard**
  that re-resolves each hop and rejects private/internal IPs (`integrations/mcp/src/security.ts`),
  restriction of the generic `call` tool to a read-only/query allowlist, and a `confirm`
  gate on every money-moving/signing tool (`integrations/mcp/src/index.ts`; admin-tool
  gating in `integrations/mcp/src/guards.ts`). Since 2.22.0 the canister, host and identity
  are set only by the operator; the LLM cannot change them unless the operator sets
  `IC402_MCP_ALLOW_SECURITY_CHANGES=1`. **Caveat:** the `confirm`
  flag is in-band — a confirmation an LLM can itself set is not equivalent to
  human-in-the-loop. Treat the MCP server's identity as a hot wallet, cap it, and keep the
  state-changing admin tools at their default-DENIED setting for an unattended agent — opt
  in (`IC402_MCP_ALLOW_ADMIN_TOOLS`) only for an attended/trusted deployment (SEC-3).
- **Self-hosted facilitator endpoints.** The canister self-hosts the x402 facilitator role
  (`GET /supported`, `GET /discovery/resources` — `example/main.mo:305-340`; `POST /verify`,
  `POST /settle` upgraded to `http_request_update` — `example/main.mo:368-389`). `/verify`
  and `/settle` are **unauthenticated update
  calls**: no funds can be stolen (C-1 recipient binding still applies), but they cost the
  canister cycles. They are now fronted by a caller-agnostic token-bucket rate-limit +
  cycle-floor gate (SEC-1, `Gateway.facilitatorAdmit`); operators should still cap the
  canister's overall cycle budget.
- **IC boundary-node CORS caveat.** Every HTTP response sets
  `Access-Control-Allow-Origin: *` (`src/ic402/HttpHandler.mo:42`) so browser agents can
  pass the OPTIONS preflight carrying the custom `PAYMENT-SIGNATURE` header. This is
  intentional for an open payment endpoint, but it means **any** web origin can invoke the
  HTTP/facilitator surface from a browser. The facilitator rate-limit (SEC-1) bounds the
  cost; an operator should still not assume same-origin protection.
- **M-2 — content (key, nonce) reuse (fixed, noted for migration).** Pre-v2, `delete()` +
  re-`put()` of the same content id reused the (key, nonce) pair (keystream reuse → XOR
  plaintext recovery). v2.0.0 mixes a per-entry (monotonic-counter) salt into key/nonce
  derivation (salt field `src/ic402/ContentStore.mo:36-39`, counter at `:119-120`/`:164-165`,
  mixed into key+nonce at `:45-67`); the salt boundary (fixed 8-byte framing) was re-hardened
  in the re-audit (`40e561f`, `:47`/`:56`). Note for integrators: pre-v2 deterministic-key content is **not**
  decryptable under the v2 required-seed model and must be re-uploaded; call
  `initExternalSeed(await raw_rand())` (or `startTimers()`) once after deploy.

## Supply chain

The prebuilt DFINITY artifacts (ICRC-1 ledger and EVM-RPC canister WASMs) consumed by the
local/CI setup are **pinned by SHA-256** (audit finding **H14**). Hashes live in
[`scripts/prebuilt.sha256`](scripts/prebuilt.sha256) and are verified with `shasum -a 256
-c` after download by `scripts/fetch-prebuilt.sh`, gating against a swapped binary
deploying a trojaned ledger/RPC into dev + CI. Pinned release tags:
`ledger-suite-icrc-2026-02-02` and `evm_rpc-v2.8.0`. Before bumping either pin, re-download
the artifacts and re-verify the fresh hashes against the official DFINITY release
`SHA256SUMS`, then update both the version variables in `fetch-prebuilt.sh` and the hashes
in `prebuilt.sha256`.

## Reporting a vulnerability

Please report security vulnerabilities **privately**. Do not open a public issue, PR, or
discussion for a security report.

- **Preferred:** GitHub private vulnerability reporting. On the repository's **Security** tab,
  open **Advisories** and click **Report a vulnerability**, or go straight to
  <https://github.com/vhew/ic402/security/advisories/new>. The report becomes a private draft
  advisory that only the maintainer and you can see.
- **Security contact:** [developer@engramx.ai](mailto:developer@engramx.ai)

Please include: the affected version/commit, the module and `file:line` if known, a
description of the impact (especially any money-theft or fund-loss path), and a proof of
concept or reproduction steps if you have one. We aim to acknowledge a report promptly and
will coordinate a fix and disclosure timeline with you.

What happens next:
- **Fix:** the fix is developed privately and released to npm and mops.
- **Advisory:** then the advisory is published with the affected and fixed versions, crediting
  you.
- **Consumers:** Motoko/mops consumers do not get automated advisory alerts, so known consumers
  are told directly.
- **Disclosure:** please keep the details private until the advisory is published. Given the financial nature of this
library, reports touching the settlement, facilitator, escrow, content-encryption, or MCP
signing paths are treated as highest priority.
