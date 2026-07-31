# ic402 costs & rail selection

**Who this is for**

- **Integrators** — read §3: pick the payment rail by payment size. This is the decision that most affects your economics.
- **Operators** — read §1, §2, §4: what a settle actually costs, the cycle buffer you must hold, and how to budget top‑ups.

## TL;DR

- Cost is **bimodal**: everything is cheap *except* signing **and** broadcasting an EVM transaction.
- A single **EVM settle nets ~17B cycles** (measured, local replica) — far below the `~100B` you'll see in code comments. That `~100B` / `MIN_BROADCAST_CYCLES = 120B` is a **safety reserve**, not consumption.
- **Per‑call EVM settle is underwater below ~$0.05–0.10.** For micropayments, use the **ICP rail** (settle ≈ <$0.001) or **sessions** (one settle amortized over thousands of calls).
- There is also a **fixed, per‑canister idle cost** that has nothing to do with payments — recurring timers. Since **2.11.0** ic402's expiry sweeps arm only while there is something to sweep; see §5, and read it before embedding ic402 in a many‑small‑canisters topology.

## 1. Measured cost per operation

Measured on a local replica (`dfx_test_key`, network‑launcher), **net of EVM‑RPC refunds** (see §2). Conversion: 1T cycles = 1 XDR ≈ **$1.33**.

| Operation | Net cycles | ≈ USD | What dominates |
|-----------|-----------:|------:|----------------|
| x402 `/verify`, 402 challenge, **content delivery** (query) | <1M – ~10M | ~$0 | keccak / `ecRecover` / HMAC+ChaCha; no outcall, no sign |
| **ICP settle** (ICRC‑2 `transfer_from`) | ~10–500M | <$0.001 | 1–2 inter‑canister ledger calls |
| **Session voucher** (per call) | <1M | ~$0 | Ed25519 verify, in‑canister, **zero outcalls** — the 5,000× lever |
| ZK Groth16 verify (inter‑canister) | ~1–5B | ~$0.005 | proof verification in the Rust canister |
| **EVM settle** — content (sign + sendRawTx + confirm, 1 leg) | **~17.5B** | ~$0.023 | tECDSA sign + RPC outcalls |
| **EVM session open** (1 leg) | **~17.1B** | ~$0.023 | same as a settle |
| **EVM session close** (2 legs: settle consumed + refund remainder) | **~63.7B** | ~$0.085 | two confirmed legs |
| EVM sign + nonce/gas RPC reads (e.g. agent register; **no broadcast**) | ~10.5B | ~$0.014 | `eth_getTransactionCount` + `eth_feeHistory` + 1 sign |

*Method:* snapshot `health().cyclesBalance` (a `query`, so polling doesn't itself burn balance) at **quiet points** before and after each operation. Two independent single‑leg settles both netted ~17B.

## 2. Net cost ≠ the balance you must hold (operators)

The EVM‑RPC canister requires generous cycle margins attached to each outcall and **refunds the unused remainder**. So during an EVM op the canister's balance **dips hard then recovers**: a single settle leg ties up ~340–500B in flight, and a 2‑leg session **close transiently ties up ~800B** — even though it *nets* only ~17B / ~64B.

Consequences:

- `EvmSender` refuses to broadcast below `MIN_BROADCAST_CYCLES = 120B`. That is a **floor**, not the cost.
- **Keep the canister funded well above the in‑flight peak of your heaviest EVM op** (hundreds of billions of cycles), plus headroom — not just above the net cost.
- Budget **top‑ups** against *net* consumption (~17–64B per EVM settle, plus ~11B/day idle burn for the example), but size the **minimum balance** against the *in‑flight peak*.

## 3. Rail selection by payment size (integrators)

The choice that matters most:

| Payment | Use | Why |
|---------|-----|-----|
| **Micropayment (< ~$0.05)** | **ICP** ckUSDC, or EVM via **sessions** | A per‑call EVM settle (~$0.05+ in cycles + EVM gas) costs more than the charge. |
| **One‑off ≥ ~$0.10, payer on EVM** | **EVM charge** (EIP‑3009) | Settle cost is a small fraction of the payment; self‑custodial, no bridge. |
| **High‑frequency from one payer** | **Sessions** (either rail) | Deposit once, stream Ed25519 vouchers (each ≈ free), settle once on close → per‑call overhead → ~0. |
| **High‑value / reorg‑sensitive** | **ICP**, or EVM with caution | EVM finality is depth‑0 and RPC is 2‑of‑N — see [`security-model.md`](security-model.md) §3. |

The "5,000× cheaper" sessions claim, grounded: 10,000 EVM per‑call settles ≈ 10,000 × ~17B = ~170T cycles (~$226) + 10,000 gas txns; the same traffic as **one session** is ~2 legs ≈ ~64B cycles (~$0.09) + 2 gas txns. The vouchers in between cost essentially nothing.

## 4. Local vs mainnet

The figures above are **local**. On mainnet, expect **higher** per‑EVM‑settle cost:

- **tECDSA `key_1` signatures cost ~26B cycles each** (system‑priced). Local `dfx_test_key` signing is ~free, which is why a local settle nets only ~17B — that ~17B is mostly outcalls.
- **HTTPS outcalls scale with subnet replication.** The EVM‑RPC canister runs on a 34‑node subnet, so each `sendRawTransaction` / confirm poll costs more than locally.
- **Estimate: ~40–80B net per EVM settle leg on mainnet** (sign‑dominated), **plus the EVM gas the canister pays in ETH** (~80k–120k gas for an EIP‑3009 transfer). Sessions still amortize all of this toward ~0 per call.
- **Re‑measure on your target subnet** before relying on a number — the method (`health().cyclesBalance` net at quiet points, §1) is reproducible against the interactive demo.

## 5. Fixed idle cost: recurring timers

Everything above is **per operation**. A canister embedding ic402 also burns cycles doing
*nothing*, because a recurring timer is billed **per tick** — the message‑execution base fee —
regardless of what its callback finds. Guarding inside the callback saves nothing; the timer
itself has to stop.

**Measured on mainnet** by a consumer running one canister per user (two independent production
canisters agreeing to four significant figures, attributed by tick count): **~23.6M cycles per
tick**, i.e. **~1.4B cycles/hour for a 60‑second timer** that never finds any work. Before 2.11.0
ic402 armed two such timers unconditionally — session expiry and job expiry — so **~2.8B
cycles/hour (~2T/month, ~$2.7/month) per canister** was fixed cost, whether or not that canister
had ever opened a session or created a job. In a one‑canister‑per‑user topology that multiplies
by the fleet, and it is invisible to a consumer reading only their own source.

**Since 2.11.0** the sweeps arm only while there is state to sweep:

| Timer | Idle (no sessions / no jobs) | While work exists |
| --- | --- | --- |
| Session expiry (`Gateway.startTimers`) | **disarmed** — 0 ticks | 60s (`setSessionExpiryIntervalSeconds`) |
| Job expiry (`ServiceRegistry.startTimers`) | **1 tick/hour** idle poll (`setExpiryIdlePollSeconds`) | 60s (`setExpiryIntervalSeconds`) |
| Policy/grant GC (`Gateway.startTimers`) | 1 tick/hour — real work, unchanged | — |

That takes ic402's fixed cost on an idle canister from **~121 ticks/hour to 2** (~47M cycles/hour,
~$0.05/month). Verify on a live canister with `health().timers`: steady state is
`sessionExpiryArmed = false`, `jobExpiryActive = false`.

Give it one interval before you read it. `startTimers()` arms **unconditionally** at install and at
every upgrade — it has to, because a `persistent actor` re-runs its init body *before*
`postupgrade` restores stable sessions, so an arm that asked "are there sessions?" would skip
exactly the canisters that have them. The first tick is what disarms. So `sessionExpiryArmed = true`
with `sessions.total = 0` is **expected for up to one interval** (60s by default) after a deploy;
if it is still true a few minutes later, that is a bug — please report it.

**Why the job sweep polls instead of disarming.** Its only job‑creating entry point,
`createJobFromReceipt`, is **synchronous**, and a synchronous Motoko function cannot hold the
`system` capability, so it cannot arm a timer. The hourly poll is the safety net for a job created
by a caller that did not arm the sweep itself. If your call sites do arm it — one
`registry.armExpiryTimer<system>()` on the job-creating path, from the async context you are
already in — you can set `setExpiryIdlePollSeconds(0)` and pay **nothing** when idle.
`example/main.mo` places that call **before** `gate.settle` rather than next to
`createJobFromReceipt`, so the arm cannot trap in the window between the funds moving and the job
existing; copy that ordering.

**Tuning the cadence is a different trade.** Self‑arming is free: an idle canister has no sessions
to expire, so nothing is delayed. Raising the *interval* is not free — expiry latency is bounded
by it, and until a session expires it holds its slice of `maxConcurrentSessions` and of the EVM
pool cap (a timed‑out job likewise stays escrowed until refunded). Nothing about settlement or
refund **correctness** depends on the cadence — a close settles from the canister's own escrow
with its own signature, so there is no external deadline to miss — so raise it only if you hold
sessions continuously and want to trade latency for cycles.

## Where these figures come from

Empirical: `health().cyclesBalance` deltas captured across the interactive demo (Base Sepolia, this repo), net of refunds. Cross‑checked against in‑source constants (`RPC_CYCLES = 10B`, `MIN_BROADCAST_CYCLES = 120B`) and the IC cost model. Pinning *mainnet* numbers against a funded end‑to‑end run remains an optional periodic live‑testnet smoke (B3 itself is **closed** — the outbound rail is now CI‑gated hermetically); see [`production-readiness.md`](production-readiness.md).
