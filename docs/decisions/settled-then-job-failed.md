# DECISION-SCOPING: `settled-then-job-failed` in the ic402 service marketplace

**Status: RESOLVED in v2.5.6 — shipped Option C (S2/S4) + Option A (S1); S3 refuted; B/D deferred.**
Decision: honor-with-a-job on disable-mid-settle (Option A); fee-source unification (open question 3)
left as a follow-up. Produced by a multi-agent scope (map 3 layers → adversarially verify → design
options → synthesize), every claim verified against source at v2.5.5.

## 1. Precise problem statement

`submitServiceRequest` moves money **before** it commits the job, and the commit step can still fail:

- `example/main.mo:891` — `switch (await gate.settle(sig, null))`. On `#ok(receipt)` the buyer's funds have **already, finally** moved (ICP: awaited `icrc2_transfer_from` returned a real block index, `Gateway.mo:786-799`; EVM: tx `#confirmed` on-chain before any receipt, `Gateway.mo:700-714`) and the ic402 nonce is consumed (`Gateway.mo:787`).
- `example/main.mo:893` — only **then** calls `registry.submitRequest(...)`. If it returns `#err`, `main.mo:895` surfaces `#error(e)`.
- `ServiceRegistry.mo:344-370` — `submitRequest` has 5 returnable `#err` modes (invalid buyer :347, not found :350, **disabled :354**, Exact insufficient :359, Upto too low :366), all of which return **before** the job is created at `:372-394`. No trap path.

Result on that arm: money is in `config.recipient`, **no job exists, `receipt.id` is persisted nowhere**, and every recovery API (`reconcileJob`, `resolveJob`, `resolveDispute`, `refundOnRail`) keys off an existing `jobId` — so there is no way to mint a job from the receipt or refund by receipt without settling again. The same settle-first ordering exists at the HTTP `/service/` handler (`main.mo:544-560`).

The example's own comment names it: `main.mo:873-874` — *"submitRequest rejects after the funds have moved, keeping the buyer's payment with no job."*

## 2. Confirmed blast radius

| # | Scenario | Real? | Severity | Fund mechanism |
|---|----------|-------|----------|----------------|
| **S1** | Canister settle-then-no-job | **YES** | **Medium** | `gate.settle #ok` moves funds + consumes nonce; `submitRequest #err` → `main.mo:895 #error`, no job, no persisted receipt, **no receipt-keyed recovery path**. Funds stranded in platform pool; recoverable only by out-of-band controller ledger transfer. |
| **S2** | MCP submit_request spend-cap drift | **YES** | **Medium** | `index.ts:1436` calls `refundSpend(reservedAmount)` on **any** throw after the gate, including the settled-then-failed path (client collapses `#error` → `throw Ic402Error('sign_failed')`, `client.ts:777`). `sessionSpentAtomic` under-counts money that actually moved → later auto-pay can exceed the true session cap. |
| **S4** | MCP open_session refunds `settlementPending` | **YES** | **Low** | `index.ts:705-712` `refundSpend(depositAtomic)` on any `openSession` throw; the canister folds `#settlementPending` (EVM deposit **broadcast, may still mine**, `main.mo:632`) into a plain `#err`. Deposit lands on-chain, cap un-counts it. Also leaks a **raw error string** (no `errorResult` wrapper, unlike `fetch_x402`). Funds recoverable via `reconcileEvmDeposit`; the defect is a weakened cap + bad UX. |
| **S3** | fetch_x402 double-pay on 402-after-pay | **REFUTED** | — | **Do not fix.** Already guarded: `settlement_failed` is `retryable:false` (`evm.ts:44`), a second payment needs a fresh human `confirm:true` round-trip, and `fetch_x402` **keeps** the reservation after a successful sign (`index.ts:1168-1170`). Residual double-pay requires a *malicious/buggy external settler* **and** explicit human re-confirmation — inherent to bearer EIP-3009, not an ic402 defect. |

Key nuances that scope the fix:

- **S1 is low-likelihood but unrecoverable.** The code already pre-empts almost every trigger before settle: M14 checks `enabled` (`main.mo:875`), there is no service-delete API (not-found can't race), no `setPrice`/`updateService` API (price can't race), and the invalid-buyer arm is effectively unreachable. The **only** live trigger is a genuine TOCTOU: an operator calling `disableService` on their own service (`ServiceRegistry.mo:256-265`) during the ~2s settle await, after which `submitRequest`'s fresh re-fetch (`:350-354`) rejects an already-paid request. The one non-race trigger is a **config skew**: `CKUSDC_FEE` (main.mo) ≠ `config.ledgerFee` (registry) on the insufficient-payment arm.
- **Latent double-job risk.** `submitRequest` writes `paymentReceiptId` (`:382`) but never reads it for dedup. Harmless today (no endpoint accepts a raw receipt), but **any** receipt-replay/recovery endpoint added without a dedup guard turns one payment into two jobs paying two operators.

## 3. Options

| | Option | Layer / release | Closes | Effort | Interface / stable-compat | Money-path risk |
|---|--------|-----------------|--------|--------|---------------------------|-----------------|
| **A** | **Validate-before-settle**: split `submitRequest` into pre-settle `validate(expectedAmount)` + infallible `createJobFromReceipt`; callers validate → settle → create | `src/ic402` (**release**) + example | **S1, S2** (S2 transitively — settle`#ok` always yields a job, so no `#error`-after-settle) | Medium | **Additive** public methods; no stable change, no migration. Also kills the `CKUSDC_FEE` vs `config.ledgerFee` skew by validating with the registry's own fee | **Low**, contingent on one invariant: `createJobFromReceipt` must stay trap-free / `#err`-free. Does **not** recover already-stranded funds |
| **B** | **Settle-with-recovery**: persist receipt on failure (`pendingReceipts`), add idempotent `replayReceipt` (b2) + optional `refundReceipt` (b1) | `src/ic402` + Types stable state (**release**) | S1 (b2 = recoverable, needs b1 for permanently-disabled services); S2 only under b1 | Medium | Additive method + **new stable map** — safe **iff** field is optional with null-branch in `loadStable`. b1 adds a refund transfer that can itself park/revert | b2: no new transfer (only dedup gap to guard). b1: real outbound send on failure path, needs park-state → effectively needs b2 anyway |
| **C** | **Honest accounting**: MCP refunds only on proven no-settle; plumb a "funds-moved / do-NOT-retry" marker canister→client→MCP; wrap `open_session` in `errorResult` | example marker + `packages/client` + `integrations/mcp` (**no `src/ic402` change**) | **S2, S4** | **Small** | No mops change; marker rides existing `#error : Text`; optional additive `detail.fundsMoved`. Only makes the cap *more conservative* | **Lowest** — moves no funds, can only under-grant headroom. Does **not** touch S1's stranded funds |
| **D** | **Protocol idempotency key**: promote nonce → idempotency key; `settle` returns stored receipt on replay; `submitRequest` dedups on `receipt.id` | `src/ic402` Gateway+Registry+Types + client + MCP (**release, breaking**) | S1, S2 (S4 only if extended) | Large | **Breaking**: changes `settle`/`submitRequest` surface + adds unbounded stable maps needing TTL/prune | **High** — wraps the fund-move itself; store must be written atomically after ledger `#Ok`/EVM `#confirmed` or risk phantom jobs / double-move |

## 4. Recommendation

**Ship A + C, sequenced by severity. Defer B/D.**

**Phase 1 — Option C (small, no release, ship first).** It is the cheapest and closes the two *amplifiers* (S2, S4) that turn a bounded one-time loss into a repeatable/over-cap loss, plus it fixes the `open_session` raw-string leak. Because it never touches `src/ic402`, it needs no library release and no stable migration — it goes out on the client/MCP packages + an example-only string marker. This immediately stops the MCP from *inviting a silent double-pay* and from *un-counting real spend*, which is the actually-dangerous behavior even though S1's root strand is rarer.

**Phase 2 — Option A (medium, requires `src/ic402` release).** This is the durable fix for S1's root cause: once `validate` runs before `settle` and `createJobFromReceipt` is infallible, **money-moved ⇒ job-exists** becomes an invariant, and the disableService-TOCTOU and fee-skew triggers can no longer strand funds. It is additive to the mops surface with no stable migration, so it is a clean minor release. After A lands, C's marker for the submit path becomes belt-and-suspenders (the `#error`-after-settle arm is no longer reachable for submit), but keep C for `open_session`/`settlementPending`, which A does not cover.

**Why not B or D now.** B (recovery) and D (idempotency key) both solve a problem A *prevents*: recovering funds already stranded. Once A guarantees money-moved⇒job-exists, there is no ongoing strand to recover, so B/D's cost (new stable maps, dedup guards, TTL/prune, and for D a breaking interface + wrapping the fund-move) is not justified. Revisit **B (b2 only)** solely if you decide you must also *recover funds stranded by the current code before A ships* — that is a one-time backfill decision, not a forward-fix.

**Release split:**
- **Example-only, no release:** C's canister marker (`main.mo:893`), all MCP/client changes.
- **`src/ic402` minor release (additive, no migration):** A's `validate` + `createJobFromReceipt` and caller reordering.

**Hard invariant to guard in A (add an anti-regression comment/test):** `createJobFromReceipt` must never trap or return `#err` — it stores buyer as `Text` and must not call `Principal.fromText` (that trap-prone call stays confined to `buyerIcpAccount` at `ServiceRegistry.mo:326`). If a future edit adds a fallible check there, the strand returns.

## 5. Open questions for the maintainer

1. **Marketplace semantics on disable-mid-settle:** should a request paid *before* `disableService` be **honored with a job** (Option A's behavior — recommended) or **refunded**? A picks honor; if you want refund you need B/b1's refund-by-receipt, which is strictly more work.
2. **Backfill of already-stranded funds:** are there any live/mainnet payments already stranded by the current code? If yes, A alone won't recover them — you'd need a one-time B(b2)+b1 receipt→job/refund path. If no (pre-launch / no such incidents), skip B entirely.
3. **Fee-source unification:** A validates with the registry's `config.ledgerFee`. Confirm `CKUSDC_FEE` (main.mo) and `config.ledgerFee` are intended to be equal, or make main.mo read the fee from the registry so the skew trigger cannot recur through another path.
4. **Error signalling contract:** brittle string marker vs. additive `detail.fundsMoved` on `Ic402Error` (C step 2). Prefer the structured flag — do you want the client SDK's public error type extended (additive, non-breaking) or keep it text-only?
5. **`settlementPending` cap policy (S4):** when an EVM deposit is broadcast-but-unconfirmed, should the MCP **keep** the reservation (treat as spent) and rely on `reconcileEvmDeposit`, or reconcile the cap later? C keeps it (conservative). Confirm that's the desired cap semantics.
6. **HTTP call-site parity:** the `/service/` handler (`main.mo:544-560`) has the identical settle-first ordering — confirm A is applied to **both** call sites (it must be), and that no third consumer of `registry.submitRequest` settles-first elsewhere.

_Verified against source: `example/main.mo:869-918`, `src/ic402/ServiceRegistry.mo:338-401`, `src/ic402/Gateway.mo:521-816`, `integrations/mcp/src/index.ts:663-712, 1408-1438`, `packages/client/src/client.ts:752-790`._
