# Security Policy

ic402 is a payment library: it moves money (ICRC-2 / ckUSDC on ICP, USDC on five EVM
chains via tECDSA) on behalf of canisters and AI agents. Security is the product. This
file states the current remediation posture, what is and is not yet production-ready, the
threat models we design against, and how to report a vulnerability.

> **Not yet production-deploy-ready with real funds.** v2.1.x is a unit-tested library
> with correct mainnet config and guarded money-**theft** paths, but several blockers
> remain open before a mainnet deploy with real funds — see
> [`docs/production-readiness.md`](docs/production-readiness.md) and **Known open items**
> below. Do not read "all audit findings fixed" as "production-ready."

## Supported versions

| Version | Supported | Notes |
|---|:--:|---|
| 2.1.x | ✅ | Current. x402 v2 compliance, EVM/marketplace settlement, self-hosted facilitator. |
| 2.0.x | ⚠️ | Security release (audit remediation). Superseded by 2.1.x; upgrade when practical. |
| < 2.0.0 | ❌ | Unmaintained. Pre-remediation; contains the Critical findings in `AUDIT.md`. Do not deploy. |

Security fixes land on the current minor series. There is no long-term-support branch for
older lines — this is early-stage software and the recommended action for any pre-2.0.0
deployment is to upgrade.

## Security posture / remediation status

The full-codebase audit ([`AUDIT.md`](AUDIT.md)) confirmed 51 findings (5 Critical, ~14
High, 11 Medium, plus Low/Info). **All Critical (C1–C5), High (H1–H14), and Medium
(M1–M11) findings were fixed in v2.0.0** (`c7e4307`); see `AUDIT.md` → "Remediation
status" and [`CHANGELOG.md`](CHANGELOG.md) → v2.0.0. A **v2.0.0 re-audit** (`40e561f`)
found and fixed 8 follow-on HIGH + 2 medium regressions the fixes themselves introduced
(nonce ring-buffer stale-blob leak, `releaseDaily` wrong day-bucket across UTC midnight,
`resolveDispute` double-refund race, ContentStore salt-boundary re-key, `confirmTransaction`
treating a missing receipt status as confirmed, a client BigInt crash, and a
`#Session requireAll(0)` trap). `AUDIT.md` is retained as the historical audit-of-record;
its per-finding sections are the **original v1.0.0 observations**, mapped to their fixes —
do not read them as describing current behaviour.

### Money-theft paths that are guarded (verified in source)

These are the load-bearing controls that stop value being stolen or fabricated. Each is
exercised on the inbound settlement path:

- **C-1 — recipient binding.** EIP-3009 settlement requires `authorization.to` to equal
  the canister's own derived EVM address before any signature verification or broadcast,
  in **both** the charge path (`src/ic402/Gateway.mo:491-499`) and the session-open path
  (`src/ic402/Sessions.mo:365-377`). This closes the self-transfer payment-bypass /
  treasury-drain that was the audit's highest-priority finding.
- **`value == amount` (exact-EVM).** The exact-EVM scheme rejects an authorization whose
  `value` is not exactly the required amount, not merely `>=` it
  (`src/ic402/Gateway.mo:500-506`) — a v1-style overpayment is rejected.
- **EIP-712 verify before broadcast.** The EIP-3009 signature is recovered and verified
  locally (`Eip712.verifyAuthorization`) **before** any on-chain outcall
  (`src/ic402/Gateway.mo:530-548`, then `executeTransferWithAuthorization` at `:564`), so
  an invalid signature never costs a broadcast.
- **H-4 — synchronous daily reservation.** The daily spend is reserved synchronously
  *before* the value-moving `await` (`policy.reserveCharge` / `reserveSessionOpen`,
  `Policy.mo:195-205`; reservation at `Gateway.mo:556-562`), with `releaseDaily(caller,
  day, amount)` rollback against the captured day-bucket on failure. Concurrent charges
  can no longer each pass a stale limit check.
- **S-3 / terminal close.** Session close sets `#closing` *before* any async operation
  (`src/ic402/Sessions.mo:650-652`) and finalizes `#closed` only on a confirmed transfer;
  a failed/ambiguous transfer is parked in `#closing` for recovery and never re-broadcast
  (`Sessions.mo:838-895`). This prevents double-settle / double-refund.

Cryptographic primitives reviewed sound: EIP-712 recovery, constant-time byte comparison,
and AEAD with constant-time tag comparison (`src/ic402/ContentStore.mo`). The residual
risk lives in the orchestration layer, which is what the open items below address.

## Known open items / not-yet-production-ready

Tracked in [`docs/production-readiness.md`](docs/production-readiness.md) (multi-agent
readiness audit). Current branch state:

- **B2 — unconfirmed-broadcast → settled: FIXED** (`f579545`, pending end-to-end
  verification). The EVM **outbound** paths (marketplace `settleJob`/`refundOnRail`,
  Sessions EVM `closeEvmSessionInternal`) previously finalized `#Settled`/`#Refunded`/
  `#closed` on mempool acceptance. They now broadcast then confirm via
  `EvmSender.sendErc20TransferConfirmed` (`src/ic402/EvmSender.mo:247`), finalize **only**
  on `#confirmed`, park on `#pending`/`#reverted`, and never re-broadcast an ambiguous
  send (`sendTransaction` returns a tri-state `{#ok; #err; #maybeSent}`). The
  recovery/re-poll path for a parked job/session is still manual (tracked as SEC-2).

Still open before "production-ready":

- **B1 — upgrade incompatibility from v2.0.0.** `main.mo` is a `persistent actor` (EOP);
  v2.1.0 added stable fields and a required `bindResult` on `#ZkGroth16`, so an in-place
  upgrade is rejected (M0170) with no migration function — a fresh deploy drops all
  escrow/session/grant/nonce/registry state. Needs a migration function or a documented
  state-dropping fresh-deploy.
- **B3 — EVM rail never verified end-to-end.** No funded on-chain settle/close has ever
  completed through ic402's tECDSA sender (a green Base Sepolia settle + session
  close/refund with mined `status==1` hashes is required).
- **SEC-0 — composed-system security pass (not yet done).** The v2.1.0 surface was
  reviewed per-commit but never audited end-to-end as a composed system: the
  unauthenticated facilitator endpoints, the marketplace cross-rail settle/refund, the
  EVM session close, and the 7 new MCP admin tools. This must be commissioned before
  tagging "production-ready." It specifically must cover:
  - **SEC-1 — unauthenticated-facilitator cycle/DoS.** `POST /verify` and `POST /settle`
    run in `http_request_update` and parse attacker JSON before any policy rate-limit, so
    spam is unmetered (cycle-DoS surface — no theft, the C-1 binding holds, but the cost
    is the canister's). Rate-limit/gate these endpoints.
  - **SEC-2 — `getFeeData` hostile-RPC grief-park.** One persistently bad RPC provider can
    park every EVM close/settle (max-base-fee picks the outlier; the 10 000-gwei ceiling
    bounds but does not eliminate). A recovery path (`recoverEscrow` / confirm-only
    re-poll) is needed; the example currently exposes none.
  - **SEC-3 — MCP admin-tool trust caveat.** The 7 admin tools (`register_service`,
    `enable_service`, `claim_job`, `submit_job_result`, `upload_content`,
    `delete_content`, `sign_typed_data`) are default-enabled, gated only by an in-band
    `confirm` flag that a prompt-injected LLM can set. The trust model must be re-examined.

## Threat-model highlights

- **MCP server — untrusted-LLM model.** [`integrations/mcp/`](integrations/mcp/) runs
  against a canister authenticated as a **controller**, driven by an LLM that may be
  steered by prompt-injected content. The audit's C2/C3/H11–H13 all lived here. Mitigations
  in place: SSRF allowlisting with per-redirect re-validation, restriction of the generic
  `call` tool to a read-only/query allowlist, and a `confirm` gate on every
  money-moving/signing tool (`integrations/mcp/src/index.ts`). **Caveat:** the `confirm`
  flag is in-band — a confirmation an LLM can itself set is not equivalent to
  human-in-the-loop. Treat the MCP server's identity as a hot wallet, cap it, and do not
  expose admin tools to an unattended agent (SEC-3).
- **Self-hosted facilitator endpoints.** The canister self-hosts the x402 facilitator role
  (`GET /supported`, `POST /verify`, `POST /settle`, `GET /discovery/resources` —
  `example/main.mo:233,290-364`). `/verify` and `/settle` are **unauthenticated update
  calls**: no funds can be stolen (C-1 recipient binding still applies), but they cost the
  canister cycles and are not yet rate-limited (SEC-1). Operators should front them with a
  rate limiter / cycle budget.
- **IC boundary-node CORS caveat.** Every HTTP response sets
  `Access-Control-Allow-Origin: *` (`src/ic402/HttpHandler.mo:40-46`) so browser agents can
  pass the OPTIONS preflight carrying the custom `PAYMENT-SIGNATURE` header. This is
  intentional for an open payment endpoint, but it means **any** web origin can invoke the
  HTTP/facilitator surface from a browser. Combined with the unauthenticated facilitator
  update calls (SEC-1), an operator should rate-limit and not assume same-origin
  protection.
- **M-2 — content (key, nonce) reuse (fixed, noted for migration).** Pre-v2, `delete()` +
  re-`put()` of the same content id reused the (key, nonce) pair (keystream reuse → XOR
  plaintext recovery). v2.0.0 mixes a per-entry random salt into key/nonce derivation
  (`src/ic402/ContentStore.mo:36,112-119`); the salt boundary was re-hardened in the
  re-audit (`40e561f`). Note for integrators: pre-v2 deterministic-key content is **not**
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

- **Preferred:** open a GitHub private security advisory:
  <https://github.com/vhew/ic402/security/advisories/new>
- **Security contact:** `[maintainer: set a security contact]`

Please include: the affected version/commit, the module and `file:line` if known, a
description of the impact (especially any money-theft or fund-loss path), and a proof of
concept or reproduction steps if you have one. We aim to acknowledge a report promptly and
will coordinate a fix and disclosure timeline with you. Given the financial nature of this
library, reports touching the settlement, facilitator, escrow, content-encryption, or MCP
signing paths are treated as highest priority.
