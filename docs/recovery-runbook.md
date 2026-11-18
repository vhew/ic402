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
| ICP close returned `#settlementFailed("Refund leg failed (session marked #closed): …")` or `"Refund leg rejected (…)"`, or `sessionCounts().refundOwed` / `health().sessions.refundOwed` > 0 | Remainder sits in the session's **ICP escrow subaccount** | §3 |
| `openSession` returned `#err(#settlementPending("EVM deposit broadcast but not yet confirmed (tx …) — no session was created…"))` | Deposit may or may not have landed in the shared pool; **no session exists** | §4 |
| You are about to upgrade the canister | Transient recovery state (parked txs, pending-deposit tracker) would be wiped | §5 |
| A marketplace job returned `"Settlement failed: …"` and rests in `#Verified` | Nothing moved; the buyer's payment is still in the pool | §6 |
| EVM charge or `openSession` returned `#settlementPending("This EIP-3009 authorization was already broadcast by this canister …")` (2.22.0) | Nothing new was sent; the earlier broadcast named in the text may have paid | §1 |
| EVM charge returned `#settlementPending("EIP-3009 transfer tx … reverted, but the authorization is already used on chain …")` (2.22.0), or `openSession` the same for its deposit | Another tx may have moved the payer's funds to the canister's EVM address; **no receipt, no session** | §1 (charge), §4 (deposit) |
| EVM charge returned `#settlementPending("EIP-3009 broadcast call rejected (…)…")`, or `openSession` `#err(#settlementPending("EIP-3009 deposit call failed and whether it was broadcast is unknown …"))` (2.22.0) | **Unknown**, and there is **no tx hash**: the authorization may or may not have been broadcast | §1 (charge), §4 (deposit) |
| ICP charge `settle()`/`settleFrom()` returned `#settlementPending("Ledger call rejected (…)")` (2.20.0) | **Unknown**: the payer may have been charged; no receipt; the nonce stays locked. 2.21.0, with `setLedgerDedup` on and a `settleFrom` charge: the payer's `settleFrom` with the same payment resolves it | §7 |
| A charge returned `#policyDenied("A settlement with this payment is already in progress — retry this same payment …")` (2.22.0) | Nothing of this payer's is known to have moved: an attempt naming a **different** payer holds this payment | Not stuck — retry the same payment shortly (preferred), or pay anew |
| ICP `openSession` returned `#err(#settlementPending("Deposit rejected (…) … Session … is parked #closing …"))` (2.21.0) | **Unknown**: the deposit is in that session's escrow subaccount, or never arrived | §7 |
| ICP close returned `#settlementPending("Settle leg rejected (…)")` (2.20.0), session rests `#closing` | **Unknown**: the escrow is either intact or already settled to the recipient | §7 |
| ICP close returned `#settlementFailed("Settle: …")` | Nothing moved; session was reverted to `#open` | Not stuck — retry `closeSession` |
| EVM charge returned `#settlementFailed("EIP-3009 transfer reverted on-chain …")` | Nothing moved, nonce unlocked (since 2.22.0 only when the token reports the authorization still unused) | Not stuck — fix the cause (payer balance / paused token), client re-signs fresh |
| A marketplace job rests in `#Settling` after the expiry sweep's refund or settle (2.22.0) | **Unknown**: the transfer call was rejected, and the transfer may have landed | §6 |
| Canister log: "ic402 job …: … failed (…); nothing moved. The sweep tries again at most once an hour; a controller can act sooner." (2.22.0) | Nothing moved; the sweep's retries for that job are backing off | §6 |
| Canister log: "… not sent again — the job is parked #Expired …" (2.22.0) | A refund reverted on-chain: nothing moved, and it is not sent again | §6 |
| EVM close returned `#settlementFailed("EVM settle failed — nothing broadcast, session reopened (safe to retry)")` | Nothing moved; session is `#open` again | Not stuck — retry `closeSession` |

---

## §1 Charge `settle()` returned `#settlementPending` (EVM broadcast, unconfirmed)

**What happened:** the canister broadcast the payer's EIP-3009 `transferWithAuthorization` and
could not confirm it within the poll budget (or the confirmation RPC failed). The tx hash is in
the error text. The server nonce stays **locked** until its expiry (default 5 min) precisely so
the same challenge cannot be re-broadcast; the daily-spend reservation was already released.

Since 2.22.0 three more answers land here:

- **A replayed authorization.** The canister broadcasts each EIP-3009 authorization once. A settle
  (or session open) of one it already broadcast sends nothing and answers `#settlementPending`
  naming the earlier tx ("This EIP-3009 authorization was already broadcast by this canister in tx
  …"); the server nonce that call came with is unlocked, since nothing of it moved. Resolve the
  named tx with the steps below. If the text says the broadcast is still in flight (no hash), wait
  for the first attempt's answer.
- **A broadcast call that was itself rejected** ("EIP-3009 broadcast call rejected (…): the
  transfer may or may not have been broadcast …"). There is no tx hash to poll. The daily
  reservation is released and the authorization stays claimed, so the canister never sends it
  again. Check the authorization (*Checking an authorization on chain*, below): used → step 3;
  unused → a broadcast copy can still execute until its `validBefore`, so the payer re-pays only
  after that (golden rule 3).
- **A revert after another tx used the authorization.** Anyone can submit
  `transferWithAuthorization`, so the canister's tx can revert because another tx executed the
  same authorization first. When a transfer reverts, settle reads the token's `authorizationState`:
  still unused → `#settlementFailed`, nothing moved; used ("… reverted, but the authorization is
  already used on chain …") or unreadable ("… could not be checked …") → `#settlementPending`. Go
  to *Checking an authorization on chain* below.

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
4. **If it reverted**: the canister's tx moved nothing, but another tx may have executed the same
   authorization. Check the authorization (below). Unused: no funds moved, and the payer can
   re-sign a fresh authorization and pay again normally. Used: handle it as step 3.
5. **If it stays pending**: keep polling. Only after the authorization's `validBefore` has passed
   (golden rule 3) is it safe to have the payer re-pay with a fresh signature.

**Checking an authorization on chain (2.22.0).** Read the token contract's view
`authorizationState(address authorizer, bytes32 nonce)` (a block explorer's *Read Contract* tab,
or an `eth_call`). `authorizer` is the payer's address (`authorization.from`); `nonce` is the
authorization's 32-byte nonce, from the payer's signed payment.
- `false`: no tx has executed it. Nothing moved; it can still execute until `validBefore`.
- `true`: a tx executed it, or the payer cancelled it. An execution paid the canister's EVM
  address (the signed `to` is that address). To tell which, read the token's events for that
  authorizer and nonce: USDC emits `AuthorizationUsed` for an execution and `AuthorizationCanceled`
  for a cancellation (confirm your token does). Executed: the funds arrived and no receipt exists,
  so treat it as step 3 (deliver or refund with `sweepEvm`, not both). Cancelled: nothing moved.

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
   - `#err("Parked close tx still pending …")` → wait and re-run. Stays parked; safe. 2.22.0: an
     ambiguous send (e.g. "nonce too low", an RPC error after dispatch) also parks here, and a tx
     that never reached a mempool never confirms. Before `forceResolveSession` + `sweepEvm` on a
     parked tx, check on chain that the canister's account nonce has moved past it, or that no
     provider knows the hash; otherwise the parked tx can still land and the sweep pays twice.
   - `#err("Parked settle tx appears not to have landed (…) — verify on chain before forcing. Only
     if a block explorer shows it never landed: forceResolveSession, then sweepEvm what is owed: …")`
     (or "Parked refund tx …"; 2.22.0) → the account nonce the parked tx was signed with has been
     used by another tx, and the providers **agree** there is no receipt for it. It is reported only
     on that agreed answer: providers that disagree, an RPC error or no answer leave it "still
     pending". It is still not proof — a lagging pair of providers can agree on "no receipt" for a
     mined tx — so the session stays parked and the decision is yours. Confirm on a block explorer
     that the hash was never mined, then `forceResolveSession` + `sweepEvm` the amounts the answer
     names (settle leg: `consumed` → recipient and the remainder → payer; refund leg: the remainder
     → payer).
   - `#err("A close of this session is still in flight — call again once it returns")` (2.22.0) →
     a close of this session is running. Nothing changed; wait for it to return and re-run.
     `forceResolveSession` gives the same answer.
   - `#err("Parked close tx reverted on-chain; no funds moved — use forceResolveSession")` → the
     parked leg reverted: whatever that leg was moving is still in the pool. Work out what is owed
     from the session record (settle leg reverted ⇒ `consumed` → recipient AND remainder → payer
     both still owed; refund leg reverted ⇒ only the remainder → payer is owed — the settle leg
     had already confirmed), then `forceResolveSession` + `sweepEvm` each owed amount.
   - `#err("Confirm RPC failed …")` → transient; retry later.
   - `#err("Session is #closing but has no parked tx — use forceResolveSession")` → since 2.22.0
     a close still in flight gets the answer above instead, so no close is running. The close
     failed **pre-broadcast** on a park-without-tx path (e.g. settle reverted, refund
     pre-broadcast failure after a confirmed settle, or the parked hash was lost across an upgrade
     — see §5). Nothing new was broadcast for the missing leg. Determine on-chain what DID happen
     (the deposit tx and any confirmed settle tx are in the session record / prior receipts), then
     `forceResolveSession` + `sweepEvm` the owed amounts. If the missing leg failed with
     "Insufficient ETH for gas", check the canister's EVM address for that transfer before
     sweeping: since 2.22.0 the sender re-reads its pending nonce after that answer and treats a
     moved nonce as "maybe sent", but a tx held only by a provider the other two have not caught up
     with can still be missed.
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
   - As of **v2.17.3**, forcing a **live ICP close** (one suspended between its ledger awaits) no
     longer double-credits the daily limit when that close then succeeds: its transfers still run,
     and it skips its own `#closed` + daily release. If its settle fails, it reopens the session as
     before. Forcing also refreshes `lastActivityAt`, so the record keeps a full 24 h
     before GC.
   - As of **2.22.0**, `forceResolveSession` refuses a session whose close is still in flight, on
     either rail ("A close of this session is still in flight — call again once it returns"), so
     the live-close case above no longer arises. On an **ICP** session it records `deposited −
     consumed` as owed to the payer: the payer recovers it with `recoverEscrow` (§3), and the
     record is kept until then.

**Do NOT:** call `closeSession`/`forceCloseSession` on a `#closing` session (rejected by design),
or manually re-send a transfer for a leg whose parked tx is still `#pending` on-chain.

## §3 ICP close: refund leg failed (`recoverEscrow`)

**What happened:** an ICP session close settled `consumed` to the recipient, but the refund
transfer back to the payer failed (a transient ledger error) or, since v2.17.4, was rejected (the
ledger unreachable, for example mid-upgrade). The session was still marked `#closed` and (since v2.17.4)
the payer's daily reservation released; the remainder sits in the session's **per-session ICRC-1 escrow subaccount**
(`sha256("ic402-escrow" ++ sessionId)` under the canister's principal). The error text says so
explicitly. When the expiry sweep made the close, nobody sees that text: since v2.18.0 the session is
counted in `sessionCounts().refundOwed` (in the example, `health().sessions.refundOwed`), and
`refundOwedToStable()` lists the session ids with the escrow balance the close left. It is a library
method; the reference example does not expose it, so wire a controller-gated query returning
`gate.refundOwedToStable()` if you need the ids in-band. Contact those payers.

**Do:** `recoverEscrow(ledger, sessionId, amount)` — refunds from the escrow subaccount **to the
payer only** (the library hard-codes the destination and requires `caller == session.payer`; it
caps `amount` at `deposited − consumed`).

> **Changed in 2.22.0:** `recoverEscrow` pays only against the session's **refund-owed entry**
> (the list `refundOwedToStable()` returns). No entry, nothing to recover. Each recovery is capped
> at the entry less the ledger's **current** fee (and at `deposited − consumed`), and reduces the
> entry by what it paid plus that fee, so the payer's total never exceeds the entry. One recovery
> per session runs at a time. `ledger` must be the session's own ledger (resolved from its token);
> any other is refused. Entries are written by a close whose refund failed, by `reconcileSession`
> (§7) and by `forceResolveSession` (`deposited − consumed`, fee 0, since it cannot ask the
> ledger).

> **Changed in v2.17.3:** `recoverEscrow` accepts **`#closed` only**. `#closing` and `#expired` are
> refused: a close is in progress for them, and a recovery that lands mid-close drains the escrow
> under the close's settle (which then fails and reopens the session; repeated, the merchant's
> consumed share is recoverable too). Exits:
> - **ICP `#closing` at rest** (a settle rejected with an unknown outcome, since 2.20.0; a close
>   interrupted by a trap; or one left by an earlier version): controller **`reconcileSession(sessionId)`
>   first** (§7). It reads the escrow and either reopens the session (the settle never landed) or
>   closes it with the remainder owed, after which the payer runs `recoverEscrow`. Use
>   `forceResolveSession` only if reconcile cannot decide (the ledger stays unreachable), and only
>   after checking the ledger yourself (2.22.0: forcing records `deposited − consumed` as owed, so the
>   payer can then `recoverEscrow` it). **If the settle did not land, `forceResolveSession` strands the
>   recipient's `consumed` share**: `recoverEscrow` returns at most `deposited − consumed` to the
>   payer, and no library call moves the rest.
> - **`#expired` at rest with its escrow intact** (a sweep close that never ran before 2.17.3, or
>   one restored across an upgrade): the payer's `closeSession` or the controller's
>   `forceCloseSession` closes it normally — the close guard refuses only `#closed`/`#closing`. Do
>   NOT do this to an `#expired` an earlier version already settled: its settle fails on the drained
>   escrow and reopens it into the sweep loop — leave those to GC. **2.22.0:** the GC no longer
>   deletes `#expired` records (one can still hold funds), so such a record now stays, and keeps
>   the session sweep's timer running. If you upgrade from a version before 2.17.2, let the old
>   version's GC remove them first (24 h after their last activity).

Practical notes, all code-derived:

- **Scope: `recoverEscrow` is ICP-escrow ONLY.** EVM session deposits live in the canister's
  **shared EVM pool** (one tECDSA address for everything — [`security-model.md`](security-model.md)
  §6); there is no per-session EVM account to recover from. For EVM use §2 (`reconcileSession` /
  `forceResolveSession` + `sweepEvm`) or §4 (`reconcileEvmDeposit`).
- **Exposure:** `Gateway.recoverEscrow` is a library method. Since 2.22.0 the reference example
  (`example/main.mo`) exposes it as `recoverEscrow(sessionId, amount)`, for the payer: it passes
  `msg.caller` as `caller` and its one ICP ledger, and the library enforces payer-only and the
  session's own ledger from there. Before 2.22.0 it did not; a consumer adds it the same way.
- **Amount vs. ledger fee:** the refund is an `icrc1_transfer` with `fee = null` (`Escrow.refund`),
  so the
  ledger deducts its fee **on top of** `amount` from the subaccount. The subaccount holds
  `deposited − consumed − settleFee` (one fee was already spent settling, when `consumed > 0`) —
  so requesting the full `deposited − consumed` cap will typically fail with `InsufficientFunds`.
  Query `icrc1_balance_of({ owner = <canister>; subaccount = ?sha256("ic402-escrow" ++
  sessionId) })` and request `balance − fee`. Since 2.22.0 the most one call can recover is the
  entry less the current fee. An entry a close or `reconcileSession` wrote is the escrow balance the
  close left, so `entry − fee` empties it in one call, whatever the fee was at the close. An entry
  `forceResolveSession` wrote is `deposited − consumed`, one settle fee more than the escrow holds
  when the settle had landed: request `balance − fee` there. Either way, a recovery that leaves one
  fee or less of the entry clears it, and an entry already at one fee or less (a forced session's
  remainder the fee exceeds, or one the fee rose past) is cleared by the next recovery attempt,
  which answers "Nothing left to recover: …" and moves nothing.
- **Time window:** `recoverEscrow` needs the session record and its refund-owed entry. Since
  2.22.0 `gcClosedSessions` removes `#closed` records only (never `#expired`, a close not yet
  finished), **24 h after `lastActivityAt`**, and never one that still has an entry, so a record is
  kept until its payer has recovered. **Persisting `refundOwedToStable()` and restoring it with
  `loadRefundOwed` is required since 2.22.0** (the reference example does; see
  [`upgrade-safety.md`](upgrade-safety.md)): entries an upgrade drops leave those payers'
  remainders in the (deterministically derivable) subaccount with **no in-band method left to move
  them**; `recoverEscrow`'s "Nothing is owed" answer names that case. A controller holding a copy of
  the lost entries can put them back with `loadRefundOwed` (it replaces the whole set). The same
  holds, with no entry to begin with, for:
  - a refund that failed before the canister ran 2.18.0 (not retroactive), and an ICP session
    forced before 2.22.0. Those `#closed` sessions cannot use `recoverEscrow` from 2.22.0 on;
    settle them by hand (§5, *Upgrading from before 2.22.0*).
- **An entry whose escrow is empty (`clearRefundOwed`, 2.22.0):** a refund the close reported as
  failed can have landed after all (a reject with an unknown outcome). Its entry then stays in
  `sessionCounts().refundOwed` and keeps the record from the GC for good. Query the escrow balance
  first; only if it holds no more than one ledger fee (which no transfer can move), the controller
  calls `clearRefundOwed(sessionId)`. It moves no funds; afterwards `recoverEscrow` refuses the
  session and its record is GC-eligible. It is a library method; since 2.22.0 the reference
  example exposes it, controller-only. Wire it controller-gated.

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
  payer can simply re-sign and open a new session. Since 2.22.0 this also covers a deposit tx that
  appears not to have landed (its account nonce was used by another tx, and the providers agree
  there is no receipt), but only while the token reports the deposit's authorization unused.
- `#err("deposit tx appears not to have landed (…), but its authorization is used on chain …")`
  (2.22.0) → the canister's deposit tx appears to have moved nothing, but another tx executed the
  authorization (anyone can submit it) or the payer cancelled it. The entry is kept. Check the authorization (§1, *Checking
  an authorization on chain*): if the deposit arrived, return it with `sweepEvm` to the payer's
  EVM address. The tracker has no delete, so the entry keeps answering this way and counting in
  `pendingEvmDepositCount()` until an upgrade wipes the tracker: note the tx hash as handled.
  `#err("deposit tx appears not to have landed (…); whether its authorization was executed by
  another transaction could not be checked …")` → retry later.
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

**A deposit that reverted after another tx used its authorization (2.22.0).** `openSession`
returned `#err(#settlementPending("EVM deposit tx … reverted, but the deposit authorization is
already used on chain …"))` (or "… could not be checked …"). No session exists and the deposit is
**not** tracked, so `reconcileEvmDeposit` cannot reach it. Check the authorization (§1, *Checking
an authorization on chain*) with the payer's address and the deposit authorization's nonce. If it
was executed, the deposit is in the shared pool: return it with `sweepEvm` to the payer's EVM
address. If it was cancelled, nothing arrived; if it is unused, nothing has arrived yet, but it can
still execute until its `validBefore` (golden rule 3).

**A deposit call that failed with an unknown outcome (2.22.0).** `openSession` returned
`#err(#settlementPending("EIP-3009 deposit call failed and whether it was broadcast is unknown …"))`.
Before 2.22.0 this was `#settlementFailed`. No session exists, nothing is tracked and there is no
tx hash; the authorization stays claimed, so the canister never broadcasts it again. Check the
authorization as above and handle it the same way. A confirm call that is itself rejected during
the open is "confirmation unavailable": the deposit is tracked, and `reconcileEvmDeposit` handles
it as above. A rejected `authorizationState` call after a revert answers "could not be checked".

**Do NOT:** have the payer re-sign the same or a fresh deposit authorization while the original
deposit tx is still pending (golden rule 3), and do not `sweepEvm` a "refund" for a deposit that
`reconcileEvmDeposit` can still handle — the in-band path is double-refund-safe; the manual path
is not.

## §5 Drain before upgrade

Parked/pending recovery state is **transient — NOT in the stable snapshots**
([`upgrade-safety.md`](upgrade-safety.md), "Transient in-flight state"): the pending inbound
deposit tracker (§4), the parked close-tx hashes (§2), and the drain-mode flag itself are all
wiped by an upgrade, and so are the record of which EIP-3009 authorizations were broadcast
(2.22.0, §1: an upgrade allows one more broadcast per authorization) and the in-flight markers on
closes and recoveries. Session **records** (including ones in `#closing`) and EVM pool allocations
DO survive — but a `#closing` session that crosses an upgrade loses its parked tx hash, leaving
only the `forceResolveSession` + `sweepEvm` path.

**Controller procedure, before every upgrade:**

1. `setEvmDrainMode(true)` — `openSession` rejects new inbound EVM deposits before any funds move.
2. Poll `pendingEvmDepositCount()` until **0**; `reconcileEvmDeposit(txHash)` each straggler
   (`listPendingEvmDeposits()` to enumerate). A deposit §4 reports as "appears not to have landed
   … used on chain" stays counted after you have handled it; upgrading drops it.
3. Also drive `sessionCounts().closing` to **0** via §2 (`reconcileSession`, then
   `forceResolveSession` for the rest) — otherwise those sessions' parked hashes are lost and
   their recovery degrades to manual sweeps.
4. Upgrade.
5. `setEvmDrainMode(false)` (it also auto-resets to `false` on upgrade, since it is transient).

The IC gives the canister no upgrade warning, so this is an operator-run protocol, not automatic.
If you upgraded **without** draining: pending deposits are recoverable only via the tx hash in
each client's `#settlementPending` error (§4 `#notFound` branch); `#closing` sessions via §2's
no-parked-tx branch.

**Upgrading from before 2.22.0.** Read the CHANGELOG's 2.22.0 upgrade notes first. Two of them
concern funds that may need moving by hand:
- **ICP sessions `#closed` without a refund-owed entry** cannot use `recoverEscrow` any more (§3).
  Before upgrading, compare `refundOwedToStable()` with your `#closed` ICP sessions whose escrow
  still holds funds, and settle those by hand. From now on, persist the entries (§3).
- **If you called `setEvmDerivationPath` before 2.22.0,** session deposits, refunds and reconciles
  were signed from the **empty-path** address, not your configured one (sessions kept the sender
  built at construction). Check the empty-path address for funds and gas left there.

Sessions opened before 2.22.0 with a symbol, `icp:*` or other text keep closing on the ledger
they did: the stored token resolves to the first configured ledger, as 2.21.0 opened it. A stored
principal text that is not a configured ledger fails closed at close, reconcile and `recoverEscrow`
(the session stays as it was). That has two causes, and the refusal names both: the ledger was
removed from the configuration, or the session was opened before 2.22.0 with a principal that was
never configured, so its deposit is on the ledger that was then first. **Close the second kind
before upgrading.** After the upgrade, check which ledger holds the session's escrow subaccount
before changing the configuration; do not simply configure the stored ledger, or the close reads
an empty escrow. Marketplace jobs: §6, *Upgrading to 2.22.0*.

## §6 Marketplace job stuck in `#Verified` (operator payment failed)

**What happened:** `settleJob` reserved `#Settling`, the payment to the operator failed (an ICRC-1
error such as a short pool, or an EVM job whose operator never called `setEvmPayout`), and the job
was rolled back to `#Verified`. No funds moved. Before v2.17.6 nothing could move a `#Verified` job.
Since 2.22.0 the expiry sweep settles a `#Verified` job on its own (one whose dispute window
just ended, or one an earlier settle left behind), with the retries below; a job needs you when
its retries are backing off, or its payment reverted on-chain.

**Do:** fix the cause, then the controller calls `resolveDispute(jobId, false)` to retry the
settle, or `resolveDispute(jobId, true)` to refund the buyer instead (net of the ledger fee). Each
path reserves `#Settling` before its transfer, so a concurrent call aborts rather than paying twice.
`resolveDispute` is a library method; since 2.22.0 the reference example exposes it,
controller-only. Wire it the same way in your canister.

**The sweep's automatic retries (2.22.0).** A refund or operator payment that fails definitely
(an ICP ledger `#Err`, or an EVM send refused before broadcast) is retried at every sweep tick,
5 times in all, then at most once per hour of the job's age. A failure no retry can fix as things
are (no transfer hook, an unparseable chain, no operator payout address, no token, no assigned
operator, a buyer with no rail, an EVM-rail buyer that is not a 20-byte address) goes straight to
the hourly retry. A busy EVM sender is retried at the next tick and not counted. Every outcome
other than success is logged; a counted failure reads "ic402 job …: … failed (…); nothing moved.
The sweep tries again at most once an hour; a controller can act sooner." (or names the next tick
while under 5). The retry state is in memory: an upgrade, or `resolveDispute` on the job, clears
it. A job still waiting keeps the sweep at its 60 s cadence. To act sooner, fix the cause, then:
- `#Verified`, `#Submitted` or `#Disputed`: `resolveDispute` (above).
- `#Pending`, `#Assigned` or `#Computing` past its `expiresAt` (its expiry refund keeps failing):
  `resolveDispute(jobId, true)`, the controller's "refund now". With `false`, or before expiry,
  those states are refused ("Job (status: …) can only be refunded, and only once past its
  expiry").

**A controller refund that fails (2.22.0).** It puts the job back as it was, except that a
`#Verified` job comes back `#Disputed`: you chose the refund, so the sweep must not pay the
operator; it refunds a `#Disputed` job at `expiresAt`, and `resolveDispute` accepts it again.
A refund that cannot work as configured ("Refund unavailable: …" — no transfer hook or chain, or a
buyer with no refundable rail) is the exception: nothing could ever move the job again, so it stays
`#Settling`. Nothing moved; refund the buyer by hand, then `resolveJob(jobId, #Refunded)`.

**A transfer that reverted on-chain is never sent again automatically (2.22.0).** Whatever made it
revert would most likely do so again, and each try signs and pays gas. `health().jobs.parked`
counts these jobs with the parked ones.
- **A refund that reverted** (at expiry, or a controller's `resolveDispute(jobId, true)` on a job
  in any status): the job is parked `#Expired` carrying the reverted tx (the log says "… not sent
  again — the job is parked #Expired …"). Refund the buyer by hand, then
  `resolveJob(jobId, #Refunded)`.
- **An operator payment that reverted:** the job goes back to `#Verified` carrying the reverted tx,
  and the sweep skips it. `resolveDispute(jobId, false)` sends the payment again (your decision; it
  drops the record), `resolveDispute(jobId, true)` refunds the buyer instead, and `resolveJob`
  closes it if you have paid by hand. This survives an upgrade: the record is on the job.

**A job parked `#Settling` by the expiry sweep (2.22.0).** A refund at expiry, or a settle to the
operator, whose transfer call is *rejected* has an unknown outcome: the transfer may have landed.
The sweep parks the job `#Settling` and goes on. Check the ledger (or chain) for the transfer, then
`resolveJob(jobId, …)` with the status that matches what happened (`#Refunded` / `#Settled`); if
it did not land, pay it by hand first. `resolveJob` moves no funds. `expireJobs()` returns only the
jobs it refunded, or left `#Expired` with a pending refund parked on them.

**A parked tx that reverted.** `reconcileJob` cannot finalize a parked tx that reverted on-chain.
Since 2.22.0 `resolveJob` accepts any job that carries a parked tx, not only `#Settling`: a refund
parked on an `#Expired` job, or an Upto remainder parked on a `#Settled` one. Verify the outcome,
settle what is owed by hand, then `resolveJob`; it clears the parked tx so the job becomes
GC-eligible.

**Upgrading to 2.22.0.** On the first sweep after the upgrade, `#Submitted` `#BuyerConfirm` jobs
whose dispute window (> 0) has already passed are paid to the operator, and `#Verified` jobs an
earlier failed settle left behind are settled. Once a window has closed, a dispute is refused
("Dispute window has closed: the result was accepted"); a `#Disputed` job is still refunded at
`expiresAt` unless a controller rules first.


## §7 ICP ledger call rejected with an unknown outcome (2.20.0, 2.21.0)

A rejected ledger call does not prove the transfer failed. The DFINITY ledgers commit a transfer and
then await their archive inside the same call, and a stopped ledger answers with the same reject
code as a trap after commit. So ic402 treats any reject not raised before the ledger ran as
**unknown** (`Utils.rejectedBeforeExecution`).

**ICP session close: the settle leg was rejected.** The session rests in `#closing`; nothing re-closes it.
1. Once the ledger answers again, run **`reconcileSession(sessionId)`** (controller). It reads the
   session's escrow subaccount balance and moves no funds itself:
   - `#ok("Escrow still holds the full deposit …")`: the settle never landed, and the session is `#open`
     again. Close it (or let the expiry sweep); it settles once.
   - `#ok("The settle landed …")`: the session is `#closed` and the remainder is recorded as owed. The
     payer runs `recoverEscrow`.
   - `#err("… query failed …")`: the ledger is still unreachable. Nothing changed; run it again later.
   - `#err("A close of this session is still in flight …")`: wait for that close to return.
2. Only if reconcile can never decide, check the ledger yourself before `forceResolveSession` (see §3's
   warning: forcing a session whose settle did not land strands the recipient's share).

**ICP session open (2.21.0).** `openSession` first asks the ledger for its fee. If the ledger is
stopped (an upgrade) or unreachable, that query fails and the open is refused with
`#settlementFailed("Ledger fee query failed before the deposit (nothing moved; safe to retry) …")`:
nothing moved, nothing to recover; the payer retries.

**ICP session open: the deposit was rejected after that (2.21.0).** Rare: the ledger stopped between
the two calls, or rejected a transfer it had committed. `openSession` returned
`#err(#settlementPending("Deposit rejected (…) … Session <id> is parked #closing …"))`. The session record
exists, `#closing`, with nothing consumed and the payer's daily reservation held. Vouchers and closes
refuse it, the expiry sweep skips it (it keeps the sweep's timer running until it is resolved).
1. Once the ledger answers again, run **`reconcileSession(<id>)`** (controller). It reads the escrow:
   - `#ok("Escrow holds the full deposit … the deposit landed. Session opened.")`: the session is `#open`.
     Its open time is the original attempt's, so if you reconcile after its `maxDuration` has passed,
     the next sweep closes it and refunds the deposit less the ledger fee. Tell the payer.
   - `#ok("… nothing was consumed: the deposit did not land … nothing is owed.")`: the session is
     `#closed` and the daily reservation released. Nothing moved, and nothing is recorded as owed.
   - `#err(…)`: as for a close above; run it again later.
2. Tell the payer not to open another session for that deposit until it is reconciled.

**Not covered: the concurrency refund at open.** If a deposit lands but the payer's concurrent-session
limit was reached meanwhile, `openSession` refunds it at once, before any session record exists. If
that refund itself fails, the deposit sits in the session's escrow subaccount with no record, and
`recoverEscrow` cannot reach it: recover it by hand from the controller (unchanged from earlier versions).

**ICP charge (`settle` / `settleFrom`).** It returned `#settlementPending("Ledger call rejected …")`. No
receipt was issued, and the nonce stays locked (so the same payment cannot be replayed). For a
`settleFrom` charge the payer's daily reservation stays held; since 2.22.0 an HTTP `settle` releases
it (its `sender` is only claimed). The nonce clean-up removes the lock some time after the nonce expires:
it runs once the table holds 10,000 live nonces or 20,000 have been issued, and anyone can request
challenges. After that, the payer's re-submit is answered `#expired` (pay with a fresh challenge), so
resolve a pending charge before then. (2.21.0 corrects 2.20.0's "freed at expiry" only in that the
clean-up, not the expiry itself, frees it.)

*Busy vs pending (2.22.0).* Nonces are not bound to a payer, so the attempt holding a payment's
nonce may be anyone's. If it names a **different** payer (ICP `sender`; EVM authorization `from`,
in any hex spelling), the charge answers `#policyDenied("A settlement with this payment is already
in progress — retry this same payment …")`. That is not a recovery case: nothing of this payer's is
known to have moved. Retrying the same payment shortly is preferred; paying anew is also safe. If
it names the **same** payer (a client's re-send while its first attempt is running), the answer is
`#settlementPending`, as in 2.21.0: the first attempt may be moving that payer's funds, so wait for
its result. An attempt whose outcome is unknown answers pending too, and so does a lock restored
after an upgrade (nothing is in flight across one): treat those as above. The clean-up keeps a
nonce whose settlement is in flight for 24 hours past its expiry.

*With `setLedgerDedup(true)` (2.21.0).* Every charge first asks the ledger for its fee, so a stopped
ledger usually refuses the charge cleanly (`#settlementFailed`, nonce unlocked, nothing moved) and the
payer retries. A charge can still go pending if the ledger stops between the two calls, or rejects a
transfer it committed. Then:
- **Made through `settleFrom`** (the caller is the payer): the canister kept the transfer (fee, nonce as
  memo, `created_at_time`). **The payer calls `settleFrom` again with the same payment** once the ledger
  answers. The identical transfer is sent again, and the ledger's deduplication decides: it was charged
  (`#Duplicate`) or not yet (`#Ok`, charged now). Either way the payer gets one receipt. Another
  caller, network or price sends nothing. The nonce and the kept transfer survive the clean-up for 24
  hours past the nonce's expiry. It stays pending if:
  - the ledger still rejects, or answers a fixable error (allowance, funds): call again later. On
    DFINITY ledgers `#InsufficientAllowance`/`#InsufficientFunds` on a re-send also show the first
    transfer did not land (deduplication is checked first). The SDK's approvals expire after 5
    minutes, so after a longer outage the payer re-approves, then calls `settleFrom` again;
  - the ledger answers `#TooOld` (its 24-hour window has passed) or `#BadFee` (its fee changed): a
    re-send can no longer decide it. Use the manual steps below;
  - the canister was upgraded since (the kept transfer is not persisted): manual steps below.
- **Made through `settle`** (HTTP): nothing is kept, because over HTTP `sender` is only a claim and the
  nonce is not a secret. Use the manual steps below.

*Manual steps* (setting off, HTTP charges, or past the cases above):
1. Do not deliver, and tell the payer not to pay again yet.
2. Look on the ledger for an `icrc2_transfer_from` from the payer to the canister's recipient account
   for the charged amount, around the time of the call. With `setLedgerDedup` on, its memo is the
   payment's nonce.
3. If it landed, deliver (or refund the payer) out of band. If it did not, the payer pays again with a
   fresh 402 challenge. With `setLedgerDedup` on and a `settleFrom` charge still re-sendable (the
   ledger had not answered `#TooOld`/`#BadFee`), have the payer pay anew only after their allowance
   for the old payment has expired or been revoked; otherwise a later re-send of the old payment
   could also land.

## Method reference

| Method | Gate | Broadcasts / moves funds? | Use for |
|---|---|---|---|
| `reconcileSession(sessionId)` | controller (consumer-gated) | **No** — confirm-only; finalize releases allocation + daily reservation | EVM session parked in `#closing` with a recorded tx (§2); ICP session resting in `#closing` — reads the escrow balance (§7, 2.20.0), including a session parked at open (2.21.0) |
| `setLedgerDedup(on)` | init-time setting (transient) | No | Lets the payer's `settleFrom` with the same payment resolve a pending ICP charge through the ledger's deduplication (§7, 2.21.0). Only for deduplicating ledgers |
| `forceResolveSession(sessionId)` | controller | **No** — moves no on-chain funds; releases the pool allocation + daily reservation (v2.5.5) | `#closing` with no parked tx / after out-of-band verification (§2). 2.22.0: refused while a close is in flight; on an ICP session it records `deposited − consumed` as owed (§3) |
| `reconcileEvmDeposit(txHash)` | controller | **Yes** — refunds on confirmed deposit | Broadcast-but-unconfirmed inbound deposit, no session (§4) |
| `pendingEvmDepositCount()` / `listPendingEvmDeposits()` | controller | No | Drain / triage (§4, §5) |
| `setEvmDrainMode(on)` / `getEvmDrainMode()` | controller | No | Pre-upgrade drain (§5) |
| `confirmEvmTransaction(chainId, txHash)` | library method — consumer must expose (controller-gated) | **No** — read-only receipt poll | Re-polling a charge's `#settlementPending` tx (§1) |
| `recoverEscrow(ledger, sessionId, amount)` | payer-only (library-enforced); consumer must expose (the example does since 2.22.0) | Yes — ICP escrow subaccount → payer only; 2.22.0: only against the refund-owed entry, never more than it in total, from the session's own ledger | ICP refund-leg failure, or a forced / reconciled ICP session with a remainder (§3). **ICP only** |
| `clearRefundOwed(sessionId)` | controller; consumer must expose (the example does since 2.22.0) | No | 2.22.0: drop the refund-owed entry of a session whose escrow you have checked is empty (§3) |
| `resolveDispute(jobId, refundBuyer)` | controller; consumer must expose (the example does since 2.22.0) | **Yes** — settles to the operator or refunds the buyer | Marketplace job stuck in `#Verified` (§6), or a `#Submitted`/`#Disputed` job needing a decision; 2.22.0: also refunds (only) a `#Pending`/`#Assigned`/`#Computing` job past its expiry |
| `resolveJob(jobId, terminal)` | controller | No — state assertion | A job parked `#Settling`, or (2.22.0) any job carrying a parked tx, after you have checked the transfer's outcome (§6) |
| `forceCloseSession(sessionId)` | controller | **Yes** — runs the full close (settle + refund) | Admin-closing an `#open`/`#expired` session. **Rejected on `#closing`** — not a recovery tool |
| `sweepEvm(chainId, token, to, amount)` | controller | **Yes** — arbitrary transfer from the shared pool | Last resort, manual amounts only, after on-chain verification (never sweep funds backing open sessions — [`security-model.md`](security-model.md) §6) |

Every controller-gated method above ships in the library **without** access control — the consumer
canister must gate it (`assert(Principal.isController(msg.caller))`; see
[`security-model.md`](security-model.md) §2 and the reference wiring in
[`example/main.mo`](../example/main.mo)).
