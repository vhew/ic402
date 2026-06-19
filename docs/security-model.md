# ic402 security model

**Who this is for**

- **Integrators** (Motoko devs embedding the library) — read §1–§3. The library is **not secure‑by‑default**; §2 is a checklist you must implement.
- **Operators** (running an ic402 canister with real funds) — read §3–§5. Your controller key *is* the security boundary.

## TL;DR

- The **money paths are sound.** Recipient binding, exact `value == amount`, single‑use nonces, and confirm‑before‑deliver were all re‑verified adversarially (§1).
- The **library ships the mechanism; the example ships the policy.** Four security‑critical checks live *only* in [`example/main.mo`](../example/main.mo). Copy them or inherit a price‑bypass / roster‑leak / content‑leak (§2).
- **One trust root.** Every admin/signer/recovery power is `Principal.isController`. A single stolen controller key = total EVM drain + unlimited arbitrary signing. There is no operator‑vs‑controller separation (§4).
- **EVM finality is depth‑0** and RPC trust is **2‑of‑N** over public endpoints — fine for low‑value L2 USDC, not for high‑value or reorg‑prone settlement (§3).

## 1. What you get for free (already defended)

The *unprivileged* attack surface is well defended. These were probed adversarially and held:

- **Recipient binding (C‑1).** EVM settlement requires the EIP‑3009 `authorization.to` to equal the canister's own derived EVM address — a payer can't make the canister pay gas for a self‑transfer and still get a receipt.
- **Exact value.** `authorization.value` must *equal* the required amount (x402 v2 §6.1.2), not merely cover it — overpayment is rejected.
- **Replay.** Server nonces are single‑use and bound to `(expiry, amount, network, token)`; the EVM rail also relies on the on‑chain single‑use EIP‑3009 nonce and EIP‑155 chain‑id.
- **Finality before delivery.** `settle()` issues a receipt only on a confirmed (`status == 1`) transaction; a mempool ack is not treated as settlement.
- **Double‑broadcast safety.** `EvmSender` holds a synchronous `txInProgress` single‑flight lock, so two concurrent settles can't both reach `transferWithAuthorization`.
- **DoS floor.** The unauthenticated facilitator endpoints run behind a 500B‑cycle floor (and a global rate bucket) *before* any attacker‑controlled parsing / `ecRecover` / RPC / signing work.
- No inter‑`await` reentrancy gap and no value‑moving integer underflow were found.

## 2. Integration checklist — the library is **not** secure‑by‑default

The `Gateway`, `Policy`, and `ContentStore` modules intentionally ship **without access control** so you can wire your own auth model. `example/main.mo` is the reference wiring. If you embed the library, you **must** add these four — each one absent is a concrete exploit:

| # | Guard | What the library leaves open | What to do (see `example/main.mo`) | If you skip it |
|---|-------|------------------------------|------------------------------------|----------------|
| 1 | **Policy‑mutation auth** | `Gateway.setPolicy` / `Policy.setGlobalPolicy` perform no caller check (the source even warns: *"MUST restrict access… `assert(Principal.isController(msg.caller))`"*). | Gate your `setPolicy` with `assert(Principal.isController(msg.caller))`. | Anyone rewrites your spend/rate limits to zero or adds themselves to an allowlist. |
| 2 | **Roster redaction** | `Policy.getGlobalPolicy()` returns the raw allow/block lists. | In any **public** read, redact the rosters (the example's `getPolicyConfig`, SEC‑4). | You leak your access‑control roster. |
| 3 | **Cross‑resource underpayment** | A server nonce binds `amount/token/network` but **not** the resource. | After `settle`, check `receipt.amount >= thisResourcePrice` (the example's `getContent` does exactly this). | A cheap nonce unlocks an expensive resource. |
| 4 | **Content access control** | `ContentStore.get` / `getChunk` decrypt for **any** caller — they take no caller argument. | Deliver only behind a settled payment or a valid grant (the example gates `getContent` on `gate.settle`). | Free content. |

**Also:** every "admin/timer" library method ships with no auth and says so in‑source (*"WARNING: this method performs no access control"*) — `forceCloseSession`, `forceResolveSession`, the `reconcile*` hooks, `sweepEvm`, `signTypedData`. Controller‑gate **every one** you expose publicly.

> The README quick‑start is deliberately minimal. Treat [`example/main.mo`](../example/main.mo) — not the quick‑start — as the secure baseline to copy.

## 3. EVM‑rail trust assumptions (integrators + operators)

- **No confirmation‑depth / reorg protection.** `confirmTransaction` treats `status == 1` at the chain tip as final, on *both* the inbound (you got paid) and outbound (you refunded) directions. A shallow reorg can un‑mine a credited payment or a confirmed refund after value was delivered. (`#Safe`/`#Finalized` block tags exist but are unused — blocked by the absence of `eth_getBlockByNumber` in the RPC interface.) Practically low‑risk for optimistic‑L2 USDC; real for L1 or high value.
- **RPC trust is 2‑of‑N consensus** over hardcoded public, no‑auth endpoints (for Avalanche + testnet L2s). A 2‑of‑3 provider coalition could forge a "confirmed" receipt. The live path checks only `status == 1` and re‑derives nothing from the mined receipt (the thorough log re‑verifier `EvmVerify.verifyTransaction` is not on the production path).
- **Implication:** size EVM payments to what depth‑0 finality and 2‑of‑N RPC can safely carry. For high value, prefer the ICP rail or add your own confirmation‑depth gate.

## 4. Key custody & blast radius (operators)

- **One key, everything.** The canister derives a single tECDSA key (`derivation_path = []`) used for all EVM signing, all chains, all users — there is no per‑user key isolation.
- **The controller principal *is* the security boundary.** In the example, every fund/key/recovery method is `assert(Principal.isController(msg.caller))`:
  - `sweepEvm` — drains the **entire** EVM balance to any address (no balance check);
  - `signTypedData` — a **blind EIP‑712 oracle**: signs any 32‑byte `domainSeparator + structHash`, bypassing every spend cap;
  - `setPolicy` and the reconcile / force‑resolve recovery hooks.
- **Therefore a single stolen controller key = total, irreversible loss** (full EVM drain + arbitrary signing). Treat the controller like a hot wallet's private key: minimize the controller set, prefer a threshold/multisig or SNS/NNS‑style controller for funded mainnet canisters, and never leave a funded canister controlled by a single dev key.

## 5. Other operator notes

- **Content at rest.** ChaCha20‑Poly1305 (RFC 8439) is real, but the master key sits in **plaintext stable memory** — recoverable by any controller or via a state snapshot. "Only the canister can decrypt" holds against node operators and raw memory dumps, **not** against a controller. Don't store data whose confidentiality must survive controller compromise.
- **Facilitator / paid‑settle DoS.** The expensive EIP‑3009 `ecRecover` on every unauthenticated path — `/verify`, `/settle`, paid `/content` & `/search`, and EVM session‑open — is rate‑limited by a single **global** token bucket (~120/min) *inside* `settle`/`verifyPayment`/`openEvmSession` (so it doesn't depend on the consumer remembering to gate); a ~500B‑cycle floor backstops the facilitator HTTP routes. The bucket is transient (resets on upgrade) and un‑keyed (one client can consume the whole budget) — it bounds drain, not fairness.
- **MCP server.** Well‑designed two‑tier (operator vs LLM) trust with default‑deny on dangerous tools — **but the reference demo invocation turns the safety off** (`IC402_MCP_ALLOW_DANGEROUS_TOOLS=1`, `IC402_MCP_ALLOW_SECURITY_CHANGES=1`, `autoPayment`). Do **not** copy the demo's environment into production; keep the safe defaults. Outbound fetches are SSRF‑guarded — every host is validated *and DNS‑resolved*, rejecting names that resolve to private/metadata IPs (DNS‑rebinding). **Residual:** the OS re‑resolves at connect time, so a host validated‑public can still rebind before the socket opens; full closure needs IP‑pinning at the transport (a custom undici dispatcher) — tracked as a follow‑up.
- **Upgrades.** The example is a persistent actor with **no migration function**; adding stable fields breaks in‑place upgrade, and the supported remedy is a *state‑dropping fresh deploy* that discards escrow/sessions/grants/nonces **and any funds parked mid‑settlement**. Drain and settle before upgrading. (Tracked as **B1** in [`production-readiness.md`](production-readiness.md).)
- **Dependencies / supply chain.** `@ic402/client`'s only runtime deps are `@icp-sdk/core`, `cborg`, and `viem`; `@ic402/mcp` adds the official `@modelcontextprotocol/sdk`. A `pnpm audit` / Socket scan flags a few **transitive** advisories — `ws` (via viem's **WebSocket** transport) and `hono`/`path-to-regexp`/`fast-uri` (via the MCP SDK's **HTTP/SSE** transports). ic402 uses **neither** transport: the EVM client uses `http()` RPC, and the MCP server is **stdio‑only** — so these are **not reachable** in ic402's usage, and the fixes are upstream. The `cborg` "shell access" flag is a test‑only file inside that library, not runtime. These are trusted, essential libraries doing expected things.

## 6. Shared EVM pool solvency (operators)

All three EVM subsystems — x402 charges, streaming sessions, and the service marketplace — settle from **one** tECDSA‑derived address. The library bounds *session* over‑allocation via `gate.setEvmPoolCap(cap)` (a per‑chain+token ceiling on outstanding session deposits; the example sets one), but it does **not** automatically reconcile the marketplace's `settleToOperator`/`refundOnRail` or the controller's `sweepEvm` against that ceiling. So the canister can pay marketplace/sweep funds out of the *same* balance that backs open session refunds.

What you must do as an operator:
- **Fund the EVM address at or above your `setEvmPoolCap` ceiling**, and treat the cap as a contract you keep solvent.
- **Don't `sweepEvm` funds that back open sessions** — `sweepEvm` sends an operator‑chosen amount with no record of what's owed; only sweep genuine surplus.
- **Monitor the on‑chain balance** against `health()` session counts; if you also run the marketplace on EVM, size its throughput so settle/refund outflows stay within the funded surplus.

This shared‑pool solvency is a **load‑bearing operator invariant**, not an automatic guarantee. A system‑wide on‑chain‑balance reservation (marketplace/sweep consulting `totalAllocated`) is a tracked follow‑up.

## Where this is tracked

[`docs/production-readiness.md`](production-readiness.md) is the maintainer backlog. The **SEC‑0** composed‑system adversarial audit has been run (two attack + re‑attack passes); its findings are fixed, with three deliberately‑deferred residuals documented there and above: shared‑pool solvency (§6), the SSRF connect‑time re‑resolve window (§5), and the ungated‑but‑unwired `recoverBuyerActionSigner` (§2). This document is the consumer‑facing model — what *you* must account for when you integrate or operate.
