# Stuck-funds recovery runbook (operators)

**Who this is for:** operators (or agents acting for them) of a canister embedding ic402, when a
payment ends in a **non-final** state. Companion docs: [`security-model.md`](security-model.md)
(who may call what — every recovery method here is controller-gated at the consumer unless noted)
and [`upgrade-safety.md`](upgrade-safety.md) (why some recovery state is transient and must be
drained before an upgrade).

The code-derived claims here were verified against source at **v2.5.6**. They have **not** been
exercised end-to-end with real funds, and one caveat is token-contract-dependent, not ic402's
(EIP-3009 `validBefore` — golden rule 3). Confirm both before relying on a procedure in a live
incident.

## Golden rules

1. **`#settlementPending` is NOT final.** No receipt was issued. **Do not deliver value** on it,
   and do not treat it as a failure either — the broadcast tx may still mine.
2. **Never re-broadcast a parked transaction.** A tx that is "broadcast but unconfirmed" may have
   landed. Recovery is always **confirm-first**: re-poll the tx hash (`reconcileSession`,
   `reconcileEvmDeposit`, `confirmEvmTransaction` are confirm-driven), then act on what actually
   happened on-chain. Re-driving a maybe-landed transfer double-pays from the shared EVM pool.
3. **Do not ask the payer to re-sign while the old payment can still land.** An EIP-3009
   authorization is single-use *on-chain*, but a *fresh* authorization is a *new* payment — if the
   original tx later mines too, the payer paid twice. Resolve the pending tx to a terminal outcome
   first. For a spec-conformant EIP-3009 token (USDC), once the authorization's `validBefore`
   timestamp has passed the old tx can no longer execute (the token's `transferWithAuthorization`
   enforces `require(block.timestamp < validBefore)`), so a fresh payment is safe from then on. This
   is the token contract's behavior, not ic402's — confirm your token honors it.
4. **`force*` methods move no funds** (`forceResolveSession` is a state assertion only). Anything
   still owed after forcing must be returned manually with `sweepEvm` — which is the
   controller-only "drain anything" hatch ([`security-model.md`](security-model.md) §4). Verify the
   on-chain facts (block explorer or `confirmEvmTransaction`) **before** forcing, and compute the
   owed amounts from the session record **before** it becomes GC-eligible.
5. **Watch `health()` / `sessionCounts()`.** `sessions.closing` is the parked-session count and
   `pendingEvmDepositCount()` the parked-inbound-deposit count. Non-zero and non-decreasing means
   client funds are parked and need one of the procedures below.

## Triage: symptom → section

| You see | State of funds | Go to |
|---|---|---|
| `settle()` / charge returned `#settlementPending("EIP-3009 transfer broadcast but not yet confirmed (tx …)")` | Payer's USDC may or may not have landed at the canister's EVM address; **no receipt issued** | §1 |
| Session status `#closing` and not resolving (`sessions.closing` non-decreasing) | Deposit (or its remainder) parked mid-close in the shared EVM pool | §2 |
| ICP close returned `#settlementFailed("Refund leg failed (settle succeeded; session marked #closed): …")` | Remainder sits in the session's **ICP escrow subaccount** | §3 |
| `openSession` returned `#err(#settlementPending("EVM deposit broadcast but not yet confirmed (tx …) — no session was created…"))` | Deposit may or may not have landed in the shared pool; **no session exists** | §4 |
| You are about to upgrade the canister | Transient recovery state (parked txs, pending-deposit tracker) would be wiped | §5 |
| ICP close returned `#settlementFailed("Settle: …")` | Nothing moved; session was reverted to `#open` | Not stuck — retry `closeSession` |
| EVM charge returned `#settlementFailed("EIP-3009 transfer reverted on-chain …")` | Nothing moved, nonce unlocked | Not stuck — fix the cause (payer balance / reused authz nonce), client re-signs fresh |
| EVM close returned `#settlementFailed("EVM settle failed — nothing broadcast, session reopened (safe to retry)")` | Nothing moved; session is `#open` again | Not stuck — retry `closeSession` |

---

## §1 Charge `settle()` returned `#settlementPending` (EVM broadcast, unconfirmed)

**What happened:** the canister broadcast the payer's EIP-3009 `transferWithAuthorization` and
could not confirm it within the poll budget (or the confirmation RPC failed). The tx hash is in
the error text. The server nonce stays **locked** until its expiry (default 5 min) precisely so
the same challenge cannot be re-broadcast; the daily-spend reservation was already released.

**Do:**

1. **Do not deliver value.** No receipt exists; nothing is owed to the payer yet either.
2. **Re-poll by tx hash** — `confirmEvmTransaction(chainId, txHash)` (read-only, never
   broadcasts), or a block explorer. `confirmEvmTransaction` is a `Gateway` library method — a
   receipt poll (`Gateway.mo:1035`); the reference example calls it internally for job reconciliation
   (`main.mo:171`) but does **not** expose a public endpoint — expose one controller-gated, or use
   an explorer.
3. **If it confirms** (`status == 1`): the funds ARE at the canister's EVM address, but no receipt
   was issued and there is **no in-band API to mint one retroactively**. Operator decision,
   out-of-band: deliver the value manually, or refund the payer via `sweepEvm(chainId, token,
   authz.from, amount)`. Do not do both.
4. **If it reverted**: no funds moved. The payer can re-sign a fresh authorization and pay again
   normally.
5. **If it stays pending**: keep polling. Only after the authorization's `validBefore` has passed
   (golden rule 3) is it safe to have the payer re-pay with a fresh signature.

**Do NOT:** re-submit the same authorization (single-use on-chain), or hand out a fresh 402
challenge to the same payer for the same purchase while the original tx can still mine.

## §2 Session stuck in `#closing` (parked EVM close)

**What happened:** an EVM session close is two legs — settle `consumed` → recipient, then refund
the remainder → payer — and one leg broadcast without confirming (parked, tx hash recorded
in-heap), reverted, or failed pre-broadcast on a path that couldn't safely reopen. The session is
deliberately parked in `#closing`: `closeSession`/`forceCloseSession` reject it (re-closing risks
a double-pay from the shared pool), and `#closing` sessions are never GC'd.

**Decision tree:**

1. **First, always:** `reconcileSession(sessionId)` — **confirm-only**; it re-polls the parked tx
   and **never broadcasts**. Outcomes:
   - `#ok("Refund confirmed …")` or `#ok("Settle confirmed … (no remainder)")` → done. The
     session is `#closed`, the EVM pool allocation is released, and the payer's daily-spend
     reservation is credited back. Nothing else to do.
   - `#err("Settle confirmed on-chain but the remainder refund is unsent — forceResolveSession +
     sweepEvm to return it")` → the settle leg landed but the refund was **never sent** and
     cannot be auto-broadcast by a confirm-only tool. Record `deposited − consumed` and the
     payer's EVM address from the session **now**, then `forceResolveSession(sessionId)`, then
     `sweepEvm(chainId, token, payerEvmAddress, deposited − consumed)` to return the remainder.
   - `#err("Parked close tx still pending …")` → wait and re-run. Stays parked; safe.
   - `#err("Parked close tx reverted on-chain; no funds moved — use forceResolveSession")` → the
     parked leg reverted: whatever that leg was moving is still in the pool. Work out what is owed
     from the session record (settle leg reverted ⇒ `consumed` → recipient AND remainder → payer
     both still owed; refund leg reverted ⇒ only the remainder → payer is owed — the settle leg
     had already confirmed), then `forceResolveSession` + `sweepEvm` each owed amount.
   - `#err("Confirm RPC failed …")` → transient; retry later.
   - `#err("Session is #closing but has no parked tx — use forceResolveSession")` → the close
     failed **pre-broadcast** on a park-without-tx path (e.g. settle reverted, refund
     pre-broadcast failure after a confirmed settle, or the parked hash was lost across an upgrade
     — see §5). Nothing new was broadcast for the missing leg. Determine on-chain what DID happen
     (the deposit tx and any confirmed settle tx are in the session record / prior receipts), then
     `forceResolveSession` + `sweepEvm` the owed amounts.
2. **`forceResolveSession(sessionId)`** — controller-only state assertion: flips `#closing` →
   `#closed` so GC can reclaim the record. It **moves no funds** — every owed amount must be
   returned via `sweepEvm` by hand. Extract `deposited`, `consumed`, `payerEvmAddress`,
   `tokenAddress`, `chainId` from the session **before** forcing (the record becomes GC-eligible
   ~24 h after).
   - As of **v2.5.5**, `forceResolveSession` releases the session's EVM pool allocation
     (`EvmEscrowManager.deallocate`) and credits back the payer's unconsumed daily-spend reservation
     — the same finalize path (`finalizeClosedSession`) that `reconcileSession` uses — so it no
     longer leaks pool headroom under a live `setEvmPoolCap`. It still moves **no on-chain funds**:
     any owed USDC must be returned with `sweepEvm` (above). Earlier versions DID leak the allocation
     permanently (`gcClosedSessions` only deletes the record); upgrade before relying on this hatch
     at scale.

**Do NOT:** call `closeSession`/`forceCloseSession` on a `#closing` session (rejected by design),
or manually re-send a transfer for a leg whose parked tx is still `#pending` on-chain.

## §3 ICP close: refund leg failed (`recoverEscrow`)

**What happened:** an ICP session close settled `consumed` to the recipient, but the refund
transfer back to the payer failed (transient ledger error). The session was still marked
`#closed`; the remainder sits in the session's **per-session ICRC-1 escrow subaccount**
(`sha256("ic402-escrow" ++ sessionId)` under the canister's principal). The error text says so
explicitly.

**Do:** `recoverEscrow(ledger, sessionId, amount)` — refunds from the escrow subaccount **to the
payer only** (the library hard-codes the destination and requires `caller == session.payer`; it
accepts sessions in `#closed`/`#expired`/`#closing`, and caps `amount` at `deposited − consumed`).

Practical notes, all code-derived:

- **Scope: `recoverEscrow` is ICP-escrow ONLY.** EVM session deposits live in the canister's
  **shared EVM pool** (one tECDSA address for everything — [`security-model.md`](security-model.md)
  §6); there is no per-session EVM account to recover from. For EVM use §2 (`reconcileSession` /
  `forceResolveSession` + `sweepEvm`) or §4 (`reconcileEvmDeposit`).
- **Exposure:** `Gateway.recoverEscrow` is a library method; the reference example
  (`example/main.mo`) does **not** expose it as a public endpoint (only `forceResolveSession` /
  `reconcileSession` / `sweepEvm` / `reconcileEvmDeposit` / `setEvmDrainMode` are wired). A consumer
  must add it (passing `msg.caller` as `caller` — the library enforces payer-only from there).
- **Amount vs. ledger fee:** the refund is an `icrc1_transfer` with `fee = null` (`Escrow.refund`),
  so the
  ledger deducts its fee **on top of** `amount` from the subaccount. The subaccount holds
  `deposited − consumed − settleFee` (one fee was already spent settling, when `consumed > 0`) —
  so requesting the full `deposited − consumed` cap will typically fail with `InsufficientFunds`.
  Query `icrc1_balance_of({ owner = <canister>; subaccount = ?sha256("ic402-escrow" ++
  sessionId) })` and request `balance − fee`.
- **Time window:** `recoverEscrow` needs the session record to authorize; `gcClosedSessions`
  removes `#closed`/`#expired` records **24 h after `lastActivityAt`** (which is NOT refreshed at
  close — the window can be shorter than 24 h from the failure). After GC, `recoverEscrow` returns
  "Session not found" and the funds still sit in the (deterministically derivable) subaccount, but
  there is **no in-band method left to move them** — recovery would need a custom controller
  method added by the consumer. **Recover promptly.**

## §4 Inbound EVM deposit broadcast-but-unconfirmed at `openSession` (no session)

**What happened:** `openSession` on an EVM rail broadcast the deposit's
`transferWithAuthorization` but could not confirm it. **No session was created**, the pool
reservation was released, and the deposit was recorded in the (transient, in-heap)
pending-deposit tracker keyed by tx hash. If the tx later mines, the payer's USDC lands
**unattributed in the shared pool**.

**Do:** `reconcileEvmDeposit(txHash)` — note this one, unlike `reconcileSession`, **does
broadcast** (the refund leg) on confirmation. Outcomes:

- `#refunded(refundTxHash)` → the deposit had mined; the full amount was refunded (confirmed
  on-chain) to the payer's EVM address. Done — the payer can open a fresh session.
- `#reverted` → the deposit never landed; nothing to refund. The tracker entry is dropped. The
  payer can simply re-sign and open a new session.
- `#stillPending` → deposit tx not yet mined; entry retained — retry later.
- `#notFound` → not tracked: wrong hash, already reconciled by a concurrent call (the entry is
  claimed synchronously exactly so two reconciles can't double-refund), or the tracker was wiped
  by an upgrade (§5). For the upgrade case: the tx hash from the client's `#settlementPending`
  error is the only trace — verify it on-chain; if it mined, refund manually via `sweepEvm` to the
  payer's EVM address.
- `#err("refund reverted on-chain …")` / `#err("refund failed (nothing broadcast): …")` → entry
  restored; retry `reconcileEvmDeposit` later.
- `#err("refund broadcast but not confirmed (tx …) — verify on-chain before retrying to avoid
  double refund")` → **fund-safety branch**: the refund itself is now the parked tx, and the
  tracker entry is deliberately **not** restored (a retry returning `#notFound` is intentional —
  restoring would risk a double refund). Poll the *refund* tx hash on-chain: if it landed, done;
  only if it is terminally dead may you `sweepEvm` the amount to the payer manually.

`listPendingEvmDeposits()` enumerates tracked entries (payer, EVM address, chain, token, amount,
age) for triage; `pendingEvmDepositCount()` is the watch metric.

**Do NOT:** have the payer re-sign the same or a fresh deposit authorization while the original
deposit tx is still pending (golden rule 3), and do not `sweepEvm` a "refund" for a deposit that
`reconcileEvmDeposit` can still handle — the in-band path is double-refund-safe; the manual path
is not.

## §5 Drain before upgrade

Parked/pending recovery state is **transient — NOT in the stable snapshots**
([`upgrade-safety.md`](upgrade-safety.md), "Transient in-flight state"): the pending inbound
deposit tracker (§4), the parked close-tx hashes (§2), and the drain-mode flag itself are all
wiped by an upgrade. Session **records** (including ones in `#closing`) and EVM pool allocations
DO survive — but a `#closing` session that crosses an upgrade loses its parked tx hash, leaving
only the `forceResolveSession` + `sweepEvm` path.

**Controller procedure, before every upgrade:**

1. `setEvmDrainMode(true)` — `openSession` rejects new inbound EVM deposits before any funds move.
2. Poll `pendingEvmDepositCount()` until **0**; `reconcileEvmDeposit(txHash)` each straggler
   (`listPendingEvmDeposits()` to enumerate).
3. Also drive `sessionCounts().closing` to **0** via §2 (`reconcileSession`, then
   `forceResolveSession` for the rest) — otherwise those sessions' parked hashes are lost and
   their recovery degrades to manual sweeps.
4. Upgrade.
5. `setEvmDrainMode(false)` (it also auto-resets to `false` on upgrade, since it is transient).

The IC gives the canister no upgrade warning, so this is an operator-run protocol, not automatic.
If you upgraded **without** draining: pending deposits are recoverable only via the tx hash in
each client's `#settlementPending` error (§4 `#notFound` branch); `#closing` sessions via §2's
no-parked-tx branch.

## Method reference

| Method | Gate | Broadcasts / moves funds? | Use for |
|---|---|---|---|
| `reconcileSession(sessionId)` | controller (consumer-gated) | **No** — confirm-only; finalize releases allocation + daily reservation | Session parked in `#closing` with a recorded tx (§2) |
| `forceResolveSession(sessionId)` | controller | **No** — moves no on-chain funds; releases the pool allocation + daily reservation (v2.5.5) | `#closing` with no parked tx / after out-of-band verification (§2) |
| `reconcileEvmDeposit(txHash)` | controller | **Yes** — refunds on confirmed deposit | Broadcast-but-unconfirmed inbound deposit, no session (§4) |
| `pendingEvmDepositCount()` / `listPendingEvmDeposits()` | controller | No | Drain / triage (§4, §5) |
| `setEvmDrainMode(on)` / `getEvmDrainMode()` | controller | No | Pre-upgrade drain (§5) |
| `confirmEvmTransaction(chainId, txHash)` | library method — consumer must expose (controller-gated) | **No** — read-only receipt poll | Re-polling a charge's `#settlementPending` tx (§1) |
| `recoverEscrow(ledger, sessionId, amount)` | payer-only (library-enforced); consumer must expose (example does not) | Yes — ICP escrow subaccount → payer only | ICP refund-leg failure (§3). **ICP only** |
| `forceCloseSession(sessionId)` | controller | **Yes** — runs the full close (settle + refund) | Admin-closing an `#open`/`#expired` session. **Rejected on `#closing`** — not a recovery tool |
| `sweepEvm(chainId, token, to, amount)` | controller | **Yes** — arbitrary transfer from the shared pool | Last resort, manual amounts only, after on-chain verification (never sweep funds backing open sessions — [`security-model.md`](security-model.md) §6) |

Every controller-gated method above ships in the library **without** access control — the consumer
canister must gate it (`assert(Principal.isController(msg.caller))`; see
[`security-model.md`](security-model.md) §2 and the reference wiring in
[`example/main.mo`](../example/main.mo)).
