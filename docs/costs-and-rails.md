# ic402 costs & rail selection

**Who this is for**

- **Integrators** — read §3: pick the payment rail by payment size. This is the decision that most affects your economics.
- **Operators** — read §1, §2, §4: what a settle actually costs, the cycle buffer you must hold, and how to budget top‑ups.

## TL;DR

- Cost is **bimodal**: everything is cheap *except* signing **and** broadcasting an EVM transaction.
- A single **EVM settle nets ~17B cycles** (measured, local replica) — far below the `~100B` you'll see in code comments. That `~100B` / `MIN_BROADCAST_CYCLES = 120B` is a **safety reserve**, not consumption.
- **Per‑call EVM settle is underwater below ~$0.05–0.10.** For micropayments, use the **ICP rail** (settle ≈ <$0.001) or **sessions** (one settle amortized over thousands of calls).

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

## Where these figures come from

Empirical: `health().cyclesBalance` deltas captured across the interactive demo (Base Sepolia, this repo), net of refunds. Cross‑checked against in‑source constants (`RPC_CYCLES = 10B`, `MIN_BROADCAST_CYCLES = 120B`) and the IC cost model. Pinning *mainnet* numbers against a funded end‑to‑end run remains an optional periodic live‑testnet smoke (B3 itself is **closed** — the outbound rail is now CI‑gated hermetically); see [`production-readiness.md`](production-readiness.md).
