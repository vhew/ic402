# Changelog

## Unreleased

### Dev tooling

Three low findings from the 2.24.1 pre-release review. Nothing published changes.

- **`setup:local` creates its identities before it fetches the prebuilt artifacts.**
  `fetch-prebuilt.sh` needs `local-dev` to generate the ckUSDC ledger's init file. If that file
  was missing (it is tracked) on a machine without `local-dev`, setup stopped on every run, and
  the message's advice to run `pnpm setup:local` sent you back into the same failure. The message
  is now an error on stderr, and that advice now works.
- **`patch-local.sh` passes the identity as one word, `--identity=<name>`.** The old two-word form
  came out of its conditional expansion as a single argument under zsh, which icp rejects. The
  failure was then hidden as "EVM RPC canister not found". The scripts that set the identity
  today are bash, so nothing had broken yet.
- **CONTRIBUTING's rollback step says what icp 1.9.0's Candid check does.** A rollback usually
  removes methods, and icp then stops for confirmation (or `--yes`).

### Docs

Access control and marketplace guidance for integrators. Only the README,
`docs/security-model.md` and doc comments change; no code does.

- **`EvmSigner` enforces no policy.** Its header said the canister "still enforces spending policy
  before signing"; nothing does. The header now says it has no access control and no policy, and
  each `sign*` method, `Gateway.sendErc20Transfer` and `Gateway.sendErc20TransferConfirmed` carries
  a "no access control, no policy: gate it to the controller" line. The README's EvmSigner section
  and `lib.mo` say the same.
- **`docs/security-model.md` lists every controller-only library method,** by module (`Gateway`,
  `Sessions`, `ServiceRegistry`, `ContentStore`, `Policy` and the signers). It replaces a five-name
  list that included `sweepEvm`, which exists only in the example. The doc no longer claims that
  each of these methods warns in its doc comment: most do not, so the list is the reference.
  `Gateway.setPolicy`, `Policy.setGlobalPolicy` and `Policy.setCallerPolicy` now carry the warning
  the checklist quotes for them. New guidance on reads to gate or redact: `Gateway.getPolicy`,
  `Gateway.getSession` and `ServiceRegistry.listJobs`.
- **ServiceRegistry, in the README and doc comments:**
  - `ServiceConfig.recipient` must be the account the Gateway settles job payments into, owned by
    the canister. Payouts and refunds are sent from the canister's own account, and `owner` is not
    checked, so another owner leaves them failing or paid from other funds.
  - EVM-paid jobs need `setEvmTransfer`, `setEvmConfirm` and `setOperatorEvmPayout` wired. Without
    them the registry is ICP-only.
  - The job flow is `validateSubmittable`, then settle, then `createJobFromReceipt`, with the 402
    minted for `price + ledgerFee()`. `submitRequest` is marked not recommended for settle-first
    use: it validates after the funds have moved.
  - `createJobFromReceipt` takes only the receipt your own settle returned in the same message,
    and only once. It neither checks nor consumes the receipt.
- **README quick start:** a `#settlementPending` result is answered with an error that says "do NOT
  retry payment", as the example does, instead of a fresh 402. Its parameter is renamed from
  `query`, a reserved word in Motoko, so the snippet compiles.

## v2.24.1 — 2026-11-26

Patch, dev tooling only. The published packages are code-identical to 2.24.0: nothing under
`src/`, `packages/` or `integrations/` changed, so there is no reason to upgrade beyond keeping
pins current. No stored-state change (`STABLE_SCHEMA_VERSION` stays 1). Cut at EngramX's request
so its pins sit on the newest release.

### Dev tooling

- **icp CLI 1.7.0 → 1.9.0**, as both the devDependency and the CI pin (`ci.yml`, both replica
  jobs). Dev tooling only: nothing published changes. The reason is RUSTSEC-2026-0387
  (non-constant-time arithmetic in `crypto-bigint`, which icp uses for identity keys; identity
  files keep their format). 1.9.0 also refuses some breaking Candid upgrades that 1.7.0 accepted.
  - The build cache (`.icp/cache/artifacts`) has a new format, and a 1.9.0 `icp canister install`
    reports a canister built by 1.7.0 as not built until `icp build` runs. `setup:local` already
    deletes `.icp/cache` and installs `example` with an explicit `--wasm`, and
    `setup-evm-outbound.sh` does the same for `evm_rpc_mock`, so nothing here changes.
  - Intel macOS (`x86_64-apple-darwin`) is no longer a release target: `pnpm install` on an Intel
    Mac warns of an unsupported platform and gets no icp binary.
  - `icp.yaml`'s `$schema` link moves from v1.6.0 to v1.9.0 (the schema is unchanged).
- **The local scripts no longer change icp's default identity.** `setup:local` used to run
  `icp identity default local-dev`. That setting is machine-wide, so it changed the identity that
  every other project on the machine was using, including one in the middle of a mainnet deploy.
  Every icp call that acts as an identity now names one: `--identity local-dev`, or
  `--identity test-payer` for the payer's calls as before. That covers
  `setup.sh`, `predemo.sh`, `setup-evm-outbound.sh`, `fetch-prebuilt.sh`, the tests' icp calls and
  the demo client's canister lookups.
  - `patch-local.sh` names the identity only when the script sourcing it sets
    `IC402_LOCAL_IDENTITY`, so a script that sources it without setting that variable behaves as
    before.
  - After `setup:local`, a bare `icp canister …` runs as whatever your default identity is, not
    necessarily `local-dev`. Pass `--identity local-dev` for the local canisters.
  - CONTRIBUTING's mainnet rollback, status and top-up commands now name the identity too.

## v2.24.0 — 2026-11-25

Minor, additive: split payees. `Gateway.settleToSplit` settles an EVM charge the payer sent to a
0xSplits referral split instead of to the canister. The split pays a finder its share and the
canister the rest. It is off until the operator sets a ceiling, and `settle` is unchanged. No
stored-state change (`STABLE_SCHEMA_VERSION` stays 1). `example.did` adds `setEvmSplitCeiling` and
`settleToSplit`, both controller-only. Requested by EngramX for referral codes on an engram's own
Base sales.

### Added

- **`Gateway.settleToSplit(signature, expectedAmount, { finder; finderShareBps })`.** The payment
  must go to the 0xSplits push split (v2.2, no owner) that pays `finder` its `finderShareBps`
  (basis points of 10,000) and this canister's EVM address the rest. The canister recomputes that
  split's address with no outcall (`EvmSplits`) and accepts the payment only when the
  authorization's `to` is exactly it. Everything else is `settle`: the signature, the exact amount,
  the simulation, the payer slot, the gas stop and the confirmation.
  - **Refused before anything is signed** (`#policyDenied`): split payees off, a chain other than
    Base (8453) or Base Sepolia (84532), a share of 0 or above the ceiling, a zero-address finder,
    or the paid token as finder.
  - **Refused as `#invalidSignature`:** a `to` that is not that split.
  - **Refused as `#networkNotSupported`:** an ICP payment.
  - **The receipt's `recipient` is the split** (the canister's own computed address, lowercase),
    and its `amount` is the full payment.
- **`Gateway.setEvmSplitCeiling(?bps)` / `evmSplitCeiling()`.** The operator's ceiling on the
  finder share, 1–9,999 basis points, or null for off (the default). Transient: re-apply it after
  an upgrade.
- **`EvmSplits`** (also `Ic402.EvmSplits`): `splitAddress`, `splitPayTo`, `FACTORY`,
  `INIT_CODE_HASH`, `TOTAL_ALLOCATION`, `SPLITS_OFF` and the `SplitPayee` type. The address is the
  factory's deterministic one (`createSplitDeterministic`, owner 0, salt 0). It is pinned by test
  vectors that the deployed factory's `predictDeterministicAddress` returns on Base and Base
  Sepolia.

### Security notes

- **Trusted caller only.** Take the finder and share from your own records (the referral codes you
  honour), never from the payment or the request. Otherwise any payer can name itself finder and
  take the share as a discount. Do not call it from a public facilitator route. The example
  exposes it controller-only.
- **A buyer can still refer itself** through a code it controls. The ceiling bounds that discount.
- **Not for session deposits,** which must reach the canister's own address (closes refund from it).
- **Not for jobs.** Never pass a `settleToSplit` receipt to `ServiceRegistry.createJobFromReceipt`
  or `submitRequest`. The job would record the full amount, while only the seller's share reaches
  the canister, after distribution. A refund or operator payout would pay the difference out of
  other funds, and a buyer who is also the finder could profit from a refund.
- `settle`, `settleFrom` and `verifyPayment` are unchanged: `settle` still requires the canister's
  own address.

### Known residuals

- **ic402 does not deploy or distribute splits.** A payment to a split not deployed yet waits at
  its address until someone deploys it through the factory and distributes it. The distribution
  incentive is 0, so nobody is paid to do it. The canister's share is not in its EVM account until
  then.
- **Not yet confirmed:** whether anyone may deploy and distribute an owner-less v2.2 split. EngramX's
  deployment test will show it. The canister's share can only ever go to the canister.
- **A finder the token will not pay may block both shares.** If ERC-20 distribution pays each
  recipient in one transaction, a finder USDC refuses (a blacklisted address) would make every
  distribution revert. The split has no owner to fix it. This can't be checked offline, so honour
  only codes whose finders you trust.
- **Only splits made by `createSplitDeterministic` with salt 0 match.** A split from the
  nonce-salted `createSplit`, another owner or another factory version has another address, and a
  new factory version needs a library release.
- **The 402 challenge is the integrator's.** The library's built-in challenges offer the canister's
  own address, so an integrator offering a split builds its own requirement with `payTo` set to
  the split.

## v2.23.2 — 2026-11-25

Patch, EVM rail. The canister no longer signs again and again on a chain it cannot pay gas on.
Upgrade if your canister settles EVM payments, opens EVM sessions or sends EVM payouts. No
stored-state change (`STABLE_SCHEMA_VERSION` stays 1). `example.did` adds `liftEvmGasStop`.
Raised by EngramX after 2.23.1; an adversarial pre-release review widened the fix to every send.

### Upgrade notes: read before upgrading

- **Fund gas on every chain you list in `evmChains`, or leave the chain out.** Listing a chain
  offers it to every payer. A broadcast there that reports the canister's EVM address short of the
  chain's native token now stops every send on that chain for 10 minutes (see Fixed). That covers
  inbound payments and session deposits, and also closes, refunds, sweeps and payouts. Once the
  address is funded and the top-up confirmed, lift the stop early with `liftEvmGasStop(chainId)`:
  the next send signs.
- **Sends refused by a stop wait instead of parking.** An expired session whose close the stop
  refuses (nothing signed) is reopened, and the 60 s sweep retries it, with no outcall or signature
  while the stop lasts. It closes by itself on the first tick after the stop ends or is lifted.
  The job sweep likewise no longer counts a stop's refusal as a failed payout. Without this, every
  expired session would have parked in `#closing` with no transaction recorded, needing a manual
  recovery each (`forceResolveSession` plus hand-sent transfers).
- **The send that sets the stop is handled as before.** It was signed, and a provider that already
  saw a top-up may have accepted it, so it is not re-sent unattended. A timer close parks in
  `#closing`, and a job counts a failed payout. Its error now names the signed transaction: check
  that hash on chain before resending by hand (recovery runbook, "no parked tx").

### Fixed

- **On a chain the canister could not pay gas on, it signed every time.** Every send signs before
  the broadcast can tell whether the canister can pay the gas. The simulation that 2.23.1 runs
  before an inbound transfer is an `eth_call` without a gas price, so it doesn't check either. The
  EVM-RPC canister has no typed `eth_getBalance`, and reading the balance would cost one more
  outcall per payment. On a chain where the canister's EVM address held no native token:
  - **any wallet holding the payment's amount of the token** passed the simulation. The canister
    read its nonce and the fees and signed (~26B cycles with `key_1`), then the broadcast failed.
    Nothing moved, so the wallet could repeat it. No cooldown applied, and the simulation budget's
    token was not given back, so the budget was the only bound: about 14,400 signatures a day, on
    the order of 400T cycles, until the 500B inbound floor. Honest EVM payments on every chain were
    refused meanwhile, with the budget spent.
  - **a session payer's close failed before broadcast and reopened the session** "safe to retry".
    The payer could close again at once, each time signing, bounded only by the send lock and the
    120B broadcast floor.

  Before 2.23.1 the inbound path was open on custom-provider chains (such as 43114) with no budget
  at all; on the default-provider chains the nonce read failed first.

  Now `sendTransaction` stops a chain for 10 minutes when a broadcast reports the canister short of
  gas (`EvmSender.GasStops`, `gasShortageReported`). That is any of:
  - an agreed InsufficientFunds, unless the account's pending nonce is then seen to have moved;
  - an agreed provider error saying "insufficient funds";
  - providers that disagree, where at least one says so and none accepted the transaction.

  While a chain is stopped, every send on it is refused before signing, and an inbound transfer
  also before its simulation and budget. A chain without gas costs one signature per 10 minutes.

### Behaviour changes

- **The refusal while a chain is stopped** reads "This canister cannot pay gas on chain … refused
  until … (Unix seconds)". Its start is `EvmSender.GAS_STOP_PREFIX`; match on that or on
  `isGasStopped`, not the rest of the wording. Nothing was signed or sent.
  - Settle returns it as `#settlementFailed`, freeing the authorization, server nonce and daily
    reservation. Over the example's HTTP routes it is `errorReason: "invalid_transaction_state"`:
    final, because the operator has to act. It comes before the busy-lock check, so it is never
    turned into a "retry".
  - A session open returns it as `#err`.
  - A close returns it in `#settlementFailed`. When no leg of the close moved funds, the session
    reopens, whoever asked for the close (`Sessions.reopenAfterUnsentLeg`,
    `EvmSender.sendCanWait`).
  - The job sweep counts it as busy: the payout is put back and retried on the next tick,
    uncounted, like the busy send lock.
  - Sweeps and other outbound sends return it as `#err`.
- **The failed send that sets the stop** keeps its result.
  - After an agreed InsufficientFunds it is an `#err` whose text starts with `INSUFFICIENT_GAS`
    ("Insufficient ETH for gas"). The text now names the signed tx ("refused signed tx 0x…").
  - On an inbound payment it also gains "Payments and sends on chain … are refused for the next
    10 minutes, or until the operator lifts the stop."
  - After weaker evidence the send stays maybe-sent (polled, never re-sent) and carries no gas
    wording.
  - The maybe-sent reason after a refusal whose nonce then moved no longer contains
    `INSUFFICIENT_GAS` (`GAS_REFUSAL_NONCE_MOVED`).

### Added

- `Gateway.liftEvmGasStop(chainId) : Bool` lifts a chain's gas stop, returning true when one was in
  force. It is an operator method: restrict it to controllers. The example exposes it
  controller-only.
- `EvmSender.GasStops`, `GAS_STOP_SECONDS` (600), `GAS_STOP_PREFIX`, `gasStopText`,
  `isGasStopped`, `gasShortageReported`, `sendCanWait`, `INSUFFICIENT_GAS`, `isInsufficientGas` and
  `GAS_REFUSAL_NONCE_MOVED`. `isGasStopped` and `isInsufficientGas` also match a text a caller
  prefixed. `sendCanWait` takes a send's raw error and matches only a refusal made before signing.
- The EVM-RPC mock's `setSendMode(#insufficientFundsInconsistent)`.

### Known residuals

- **One signature per 10 minutes per chain without gas,** plus that send's reads, for as long as
  the chain stays listed and unfunded. A refused send costs no outcall.
- **Each waiting session and job still costs a little every tick:** a few self-calls of
  instructions, with no outcall, on the order of tens of billions of cycles a day each (an
  estimate). The cost lasts as long as gas is missing and grows with the number waiting.
- **A waiting session is `#open`.** It holds its payer's concurrency slot (`maxConcurrentSessions`,
  default 1), so that payer cannot open another session until gas is back. `forceResolveSession`
  and `reconcileSession` refuse it.
- **A chain abandoned unfunded drains slowly into manual recovery.** After each stop ends, the
  first send signs, fails and re-arms the stop. If that send is a timer close, its session parks
  (above). So the expired sessions park one per 10 minutes, each to be resolved by hand.
- **The send that sets the stop may have landed.** Under the 2-of-3 threshold a provider that
  already saw a top-up can accept it while two refuse, and the nonce re-read can miss it. It is not
  re-sent unattended (a timer close parks, a payout counts and backs off as before); its error names
  the signed tx. A payer's close still reopens after it, as it did before 2.23.2.
- **The stop is transient.** An upgrade forgets it, as does `setEvmDerivationPath` replacing the
  sender; the next failing broadcast sets it again. A sender built separately (such as
  `EvmSenderAt`) has its own stops.
- **A false stop is possible.** A fee spike, or several pending transactions each reserving their
  gas, can make a marginal balance fall short; one provider wrongly reporting "insufficient funds"
  while the others fail can do the same. Either delays sends on that chain for up to 10 minutes,
  or until lifted. No funds move because of it. As after any send that fails before broadcast,
  some cases still need manual recovery:
  - a close whose settle leg went out and whose refund leg is then refused rests in `#closing` with
    no transaction to reconcile (recovery runbook, "no parked tx");
  - an Upto job whose operator payment went out and whose remainder refund is then refused ends
    `#Settled` with the remainder unsent and a log line;
  - after weaker evidence, the send that set the stop is maybe-sent, so that close or payout parks
    with its tx for the usual confirm-only recovery.
- **The wording match is a list.** A client whose "insufficient funds" error uses other words, and
  which the EVM-RPC canister does not map to InsufficientFunds, sets no stop. That send stays
  maybe-sent, bounded by the payer's 5-minute hold.
- **`/verify` and the 402 challenge still offer a stopped chain,** as they do for a cooling payer.
- **The simulation budget is still shared** (a 2.23.1 residual). Anyone can hold it at zero with
  unfunded wallets, at roughly 24T cycles a day, refusing honest EVM payments meanwhile. An
  operator-set daily ceiling was considered and not added: it caps that cost only by extending the
  outage to the end of the day.

## v2.23.1 — 2026-11-25

Patch, EVM rail. Two things:
- EVM payments on Ethereum, Base, Optimism, Arbitrum and Ethereum Sepolia work again; they have
  failed on every call since 2.1.0.
- The canister no longer signs an inbound EVM payment that cannot succeed.

Upgrade if your canister settles EVM payments or opens EVM sessions, and read the upgrade notes
first. No stored-state change (`STABLE_SCHEMA_VERSION` stays 1). `example.did` adds
`clearEvmPayerCooldowns` and `liftEvmPayerCooldown`. Reported by EngramX. Three adversarial
pre-release reviews found the consensus-config break and the gaps closed before release.

### Upgrade notes: read before upgrading

- **EVM on the default-provider chains starts working.** On chains 1, 8453, 10, 42161 and
  11155111, every EVM-RPC call ic402 made since 2.1.0 was refused before it reached a provider (see
  Fixed). After the upgrade, those calls go through:
  - charges, session deposits, closes, refunds, sweeps and marketplace payouts on those chains
    really broadcast;
  - the canister's EVM address pays the gas.

  If you listed one of these chains in `evmChains`, check that you mean to run it, and fund the
  address. Nothing was broadcast on those chains before, so nothing is parked from that time.
- **Inbound EVM payments are refused below 500B cycles.** The old floor for any broadcast was 120B.
  The reserve now kept below 500B is for closes and refunds.
- **Keep a larger cycle cushion if payments can arrive in bursts.** Up to 10 inbound checks can now
  be in flight at once, each holding outstanding calls. Before, almost every concurrent payment
  stopped at the send lock without an outcall. In the hermetic suite, a canister with about 5T
  could no longer make its calls ("could not perform self call") under a burst of 16 session opens;
  at 10T it could.
- **Concurrent EVM payments from one wallet are serialized.** A wallet whose sent transfer reverts
  is refused for an hour (5 minutes when another transaction executed its authorization), and one
  whose transfer has not confirmed within the confirmation polls is refused for 5 minutes. On Ethereum mainnet, where a transfer often has not confirmed within
  the polls, a wallet's next payment can therefore wait up to 5 minutes. All are detailed below.
- **Keep `nonceExpirySeconds` at 300 (the default) or more.** The 402's EVM `maxTimeoutSeconds` is
  the nonce window, and stock x402 clients sign for exactly that long. With the 120 s margin
  below, a window of 125 s or less gets every stock EVM payment refused, and 180 s leaves a client
  under a minute.

### Fixed

- **EVM-RPC consensus config refused on default-provider chains (since 2.1.0).**
  - **The bug.** S10 (2.1.0) asked the EVM-RPC canister for 2-of-N agreement with no `total`. The
    canister refuses that for its default providers ("total must be specified when using default
    providers").
  - **The effect.** On chains 1, 8453, 10, 42161 and 11155111, every nonce read, fee read, send,
    receipt poll and `eth_call` failed before reaching a provider. Charges and opens failed with
    "Failed to get EVM nonce". Closes, refunds, sweeps and marketplace payouts failed before
    sending: sessions stayed open and payouts were retried. Chains on custom providers (Base,
    Optimism and Arbitrum Sepolia, Avalanche) were unaffected.
  - **Why it went unnoticed.** The hermetic suite's EVM-RPC mock ignored the config.
  - **The fix.** New `EvmRpc.consensusConfig(services)` sets `total = 3` for default providers, and
    `null` (all of them) for custom services or an explicit provider list; `min = 2` everywhere.
    The mock now refuses a config the real canister refuses.
- **An inbound EVM transfer is simulated before it is signed.**
  - **The problem.** `Gateway.settle`, `settleFrom`, the facilitator `/settle` and the EVM session
    open sign and send the payer's EIP-3009 authorization at the canister's cost: a threshold
    signature, the RPC reads, the receipt polls and the gas. Every check before that was off-chain.
    So an authorization from a wallet holding no USDC, which costs nothing to make, passed them all
    and was signed and sent, only to revert on chain.
  - **The effect.** Repeated, this spent cycles down to the broadcast floor. It also held the
    single-flight send lock, so honest settles, opens, closes and refunds were mostly refused as
    busy meanwhile. On the default-provider chains above, the config bug stopped this before the
    signature; on custom-provider chains it was live.
  - **The fix.** `EvmSender.executeTransferWithAuthorization` first runs the exact call as an
    `eth_call` at the latest block, through the EVM-RPC canister with 2-of-N agreement. The call is
    made as the broadcast will run it: from the canister's own address, with the transaction's
    120,000 gas limit. It signs only when the providers agree the call succeeds.
    - **When the simulation reverts:** `#settlementFailed`, final ("fix the cause"). The usual
      causes: the balance is below the amount, the authorization was used or cancelled, the token
      is paused, or the payer is blocked.
    - **When there is no agreed answer:** "could not check … retry this same payment". A revert
      counts as agreed when two providers report it and none reports success. The "could not
      check" answer also covers a revert within 60 s of the authorization's `validAfter`, since the
      latest block may predate it.
    - Either way, nothing is signed or sent, and the authorization claim, the server nonce and the
      daily reservation are freed.
- **The simulation's blind spots are bounded.**
  - **Expiry margin.** An authorization must still be valid for 120 s when the canister takes it.
    Otherwise it could pass the simulation and expire before it lands. This is checked by
    `settle`, `verifyPayment` (so `/verify` does not pass what `/settle` refuses), the session
    open and `executeTransferWithAuthorization`. The refusal is `#expired`.
  - **One inbound transfer per payer.** One is in flight per (chain, token, payer `from`), across
    settle and session open (new `EvmSender.PayerGuard`, on the sender as `inFlightPayers`). It is
    claimed after the signature verifies and released however the call returns. Without it, a
    wallet funded once could have many authorizations pass the simulation against the same
    balance. A second payment meanwhile gets `#policyDenied` ("… still settling, so this one was
    not sent — retry this same payment in a few seconds").
  - **Cooldown.** A payer whose sent transfer reverts is refused for an hour when the token's
    `authorizationState` then reads the authorization unused, or cannot be read. The payer is held
    for 5 minutes in three cases: the authorization reads used; the transfer has not confirmed
    within the confirmation polls; or the broadcast call failed with an unknown outcome. This
    covers funds moved after the check, a cancelled authorization (used: 5 minutes), and a payer
    with code (an EIP-7702 delegate) that answers the simulation differently from the real
    transaction.
    - Almost always the payer causes a revert after a passed check. A third party can only execute
      the payer's own authorization first (a mempool copier, on a chain with a public mempool), and
      then the payer has paid, so "used" gets the 5-minute hold, not the hour. A token paused, or
      the canister blocked, between the check and the send would also cool the payer.
    - A shorter hold never cuts a longer cooldown.
    - The refusal is `#policyDenied`, naming the end time, and it does not invite a retry.
    - An operator can lift one payer's cooldown with the new
      `Gateway.liftEvmPayerCooldown(chainId, token, from)`, or every one with
      `Gateway.clearEvmPayerCooldowns()`.
  - **Simulation budget.** Each simulation takes a token before its outcall, and gives it back only
    when the transfer then goes out: at most 10 at once, one more every 6 s.
    - A refused simulation keeps its token, as does one that passes but is not sent (the send lock
      was taken meanwhile).
    - With none left, payments are not checked (no outcall) until one refills ("… budget for
      checking payments … is spent … retry this same payment in a minute").
    - A simulation is an outcall; one estimate puts it at ~1.7B cycles on mainnet. Without the
      budget, a flood of unfunded payments under the global facilitator bucket (2 a second) would
      spend about as much as the signed broadcasts it replaced.
    - The budget bounds simulations in flight as well as refused ones, and honest payments that go
      out never use it up.
  - **Order of checks.** The margin, a busy send lock, the inbound cycle floor and the budget are
    all checked before the simulation, so those refusals make no outcall.
- **The retry signal.** Inbound refusals that sent nothing and clear by themselves now say "retry
  this same payment":
  - another payment from the payer still settling;
  - no agreed simulation answer;
  - the simulation budget spent;
  - the send lock busy (`INBOUND_SEND_BUSY`, which `isSendBusy` also recognises);
  - a nonce or fee read that failed or was rejected, or another failure before the broadcast.

  The example maps a `#policyDenied` or `#settlementFailed` carrying those words to `errorReason:
  "settlement_retry"`, an ic402 extension like `settlement_pending`. Before, these were
  `unexpected_settle_error` or `invalid_transaction_state`. `@ic402/client` maps
  `settlement_retry` to a `transient` (retryable, not funds-moved) error (new
  `isSettlementRetryBody`). This covers the 2.22.0 busy answer as well.

### Behaviour changes

- A settle or EVM session open makes one more EVM-RPC read, the simulation, before signing.
- Concurrent payments from one wallet on one chain and token are serialized: the second is refused
  as busy until the first returns, and succeeds when retried.
- A wallet whose transfer did not confirm within the polls is refused for 5 minutes, and one whose
  transfer reverted for an hour.
- Authorizations with less than 120 s left are refused. The `@ic402/client` and stock x402 clients
  sign for `maxTimeoutSeconds`, 300 s at ic402.
- Inbound EVM payments stop below 500B cycles.

### Added

- `EvmRpc.consensusConfig`.
- From `EvmSender`:
  - `classifySimulation`, `SimulationVerdict`, `isRevertError`, `simulationRefusal`,
    `transientSendError`, `NONCE_READ_FAILED`, `FEE_DATA_UNAVAILABLE`,
    `FAILED_BEFORE_BROADCAST`;
  - the texts `simulationRevertedText`, `simulationUnknownText`, `EXPIRES_TOO_SOON`,
    `PAYER_BUSY`, `payerCoolingText`, `SIMULATION_BUSY`, `LOW_INBOUND_CYCLES`,
    `INBOUND_SEND_BUSY`;
  - `expiresTooSoon`, `MIN_VALIDITY_SECONDS`, `RECENTLY_VALID_SECONDS`,
    `TRANSFER_WITH_AUTHORIZATION_GAS`, `REVERT_COOLDOWN_SECONDS`, `UNCONFIRMED_HOLD_SECONDS`;
  - `PayerGuard`, `SimulationBudget`, and `Sender.inFlightPayers`.
- `Gateway.clearEvmPayerCooldowns()` and `Gateway.liftEvmPayerCooldown(chainId, token, from)`
  (operator), both exposed controller-only in the example.
- `@ic402/client`: `isSettlementRetryBody`.
- The EVM-RPC test mock:
  - answers the simulation separately from `authorizationState` (`setSimulationMode`,
    `getSimulations`, `getLastSimulation`);
  - can hold a simulation in flight (`setHoldSimulations`; it waits a consensus round per check);
  - refuses invalid consensus configs.
- `scripts/setup-evm-outbound.sh` tops the example canister up by 5T. An EVM operation ties up
  hundreds of billions of cycles in flight, and the longer suite ran out by its last test.

### Known residuals

- **Reverting broadcasts per wallet.** A payer can still cost the canister one reverting broadcast
  per wallet per chain and token:
  - once an hour, where the polls see the revert and the authorization reads unused;
  - once every 5 minutes otherwise: the transfer still unconfirmed when the polls end (common on
    Ethereum mainnet, and a later revert is not watched), or the authorization used (cancelled
    after the check).

  It does so by moving its funds after the check, cancelling, or answering the simulation
  differently from code. Each new wallet needs funding (and, for code, a delegation), all
  on-chain transactions.
- **The budget is shared.** Anyone can spend the simulation budget with free wallets: one unfunded
  payment every 6 s keeps it spent, and honest payments wait while it is. Honest traffic can also
  spend it, through payments that pass but are not sent (the send lock busy, the gas account
  unfunded). This is the same class as the global facilitator bucket,
  which bounds the drain, not fairness. Spending the budget costs the canister about 10 checks a
  minute, plus 10 at once.
- **A slot is freed when its call returns,** even with the transfer unconfirmed
  (`#settlementPending`). The 5-minute hold then stands in for it, but a later revert is not
  cooled.
- **`validBefore` has no upper bound.** A payer's old, used authorizations can be replayed once the
  2.22.0 broadcast guard has forgotten them (24 h, or an upgrade). Each replay holds that payer's
  slot for one check and spends from the budget. A cap was left out: it would refuse long-lived
  authorizations that are legitimate today.
- **A direct caller of `executeTransferWithAuthorization`** gets the margin, the floor, the budget
  and the simulation, but not the per-payer slot or the cooldown.
- **`/verify` does not simulate.** It stays an off-chain check.
- **The retry mapping and the operator methods live in the example.** A consumer of the library
  maps "retry this same payment" to its own HTTP answer, and restricts
  `clearEvmPayerCooldowns` / `liftEvmPayerCooldown` to its controllers. The example's Candid
  routes still answer a `#settlementFailed` without its text (pre-existing).
- **Test gaps.** The mock cannot reject a receipt read, so the 5-minute hold after an unavailable
  confirmation or a rejected broadcast call is pinned only by reading the code. The budget is
  private, so its give-back on a sent transfer is tested only through the suite's sequence of
  payments.
- **Never run against live providers.** The default-provider chains have not been exercised by
  this repo's tests against the real EVM-RPC canister and providers. The config was checked
  against a local EVM-RPC canister, which validates it and then needs cycles and API keys to go
  further. Arbitrum's L1 data gas also comes out of the fixed gas limits (pre-existing).
- **Pre-existing:** below the in-flight peak of an operation (hundreds of billions of cycles), a
  send the canister cannot afford is reported as "EVM fee data unavailable".

## v2.23.0 — 2026-11-18

Minor, additive: `recoverEscrowReceipt` reports what a session-escrow recovery moved. No stored-state
change (`STABLE_SCHEMA_VERSION` stays 1), no `example.did` change, and no change to any existing call.

### Added

- **`Gateway.recoverEscrowReceipt(caller, ledger, sessionId, amount)`** reports what a recovery
  moved, so a consumer no longer recomputes the caps. On success it returns
  `#ok({ blockIndex; amount; fee; owedLeft })`:
  - `amount`: what the payer was paid, which is the request after both caps (the unconsumed
    deposit, and the refund-owed entry less the fee);
  - `fee`: the ledger fee charged out of the escrow for it;
  - `owedLeft`: what the refund-owed entry still holds afterwards; 0 means nothing more can be
    recovered.

  It runs the same checks, caps and accounting as `recoverEscrow`, which is unchanged and still
  returns the block index. New type `Ic402.RecoveryReceipt`. Requested by EngramX: since 2.22.0's
  entry cap, `min(asked, deposited − consumed)` over-states a full recovery by two fees.

## v2.22.0 — 2026-11-18

Minor — **security release. It fixes three high-severity issues and about forty medium and low
ones, all found by a whole-library adversarial review. Upgrade promptly, and read the upgrade notes
first: several fixes change behaviour.** No stored-state change (`STABLE_SCHEMA_VERSION` stays 1).
`example.did` adds `resolveDispute`, `recoverEscrow`, `clearRefundOwed`, `confirmJobEvm`,
`disputeJobEvm` and `buyerActionMessage`. The three high fixes were prepared as 2.21.1, which was
not published; they ship here.

### Upgrade notes: read before upgrading

- **Persist `refundOwed`; this is now required.** `recoverEscrow` pays only against a recorded
  refund-owed entry. A canister that does not save `refundOwedToStable()` and restore it with
  `loadRefundOwed` loses its payers' in-band recovery at every upgrade. The example does both.
- **ICP sessions that ended `#closed` before 2.22.0 without an entry can no longer use
  `recoverEscrow`.** That covers a refund that failed before 2.18.0, and any forced ICP session.
  Before upgrading, compare `refundOwedToStable()` with your `#closed` ICP sessions whose escrow
  still holds funds, and settle those by hand.
- **Session tokens now name the ledger holding the deposit.**
  - A new ICP open's token must be one of: the ledger's principal text; a configured token's exact
    symbol (new in 2.22.0); `icp:*`. Anything else is refused (`#tokenNotAccepted`). A symbol is
    stored as its ledger's principal text, so the close receipt's `token` shows the principal.
  - Sessions opened before 2.22.0 with a symbol, `icp:*` or other text keep closing as they did:
    the stored token resolves to the first configured ledger, as in 2.21.0.
  - A stored principal text that is not a configured ledger now fails closed at close, reconcile
    and `recoverEscrow`, and the session stays as it was. Before, it fell back to the first ledger.
  - **Close these before upgrading:** ICP sessions opened before 2.22.0 whose intent token was a
    principal text that was not configured. Their deposit was pulled on the ledger that was then
    first, and after the upgrade they can no longer close, reconcile or recover: they fail closed,
    indistinguishable from a removed ledger. The refusal names both causes and says to check which
    ledger holds the session's escrow before changing the configuration. Do not simply configure
    the stored ledger: the close would then read an empty escrow.
- **EVM chains whose tokens have different decimals are refused.** The constructor traps, so install
  or upgrade fails with the message, and `setEvmChains` returns `#err`. Tokens listed on one chain
  must also have equal unit value; that is the operator's duty.
- **EVM blocklist entries now match the payer's lower-cased address.** Rebuild any entry made from a
  checksum-case address with the new `Ic402.evmPolicyPrincipal`.
- **BuyerConfirm services with a dispute window above 0 now pay the operator automatically** once
  the window passes with no dispute. Inside the window they are no longer refunded at `expiresAt`,
  and after it a dispute is refused. A window of 0 keeps the old behaviour.
  - Existing `#Submitted` jobs whose window has already passed are paid to the operator on the
    first sweep after upgrading.
  - `#Verified` jobs left by an earlier failed settle are settled by the sweep.
- **Sessions an earlier version left resting `#expired` (before 2.17.2) are no longer deleted by
  the GC,** and keep the session sweep's timer running. If you upgrade from below 2.17.2, let the
  old version's GC remove them first (recovery runbook §3).
- **Grants:**
  - `issueGrant` caps the TTL at 7 days, and traps on a content id containing `|`.
  - `verifyGrant` refuses a grant with `|` in either id.
  - Check the new `grantsReady()` and your content id before settling a payment that ends in a grant.
- **If you called `setEvmDerivationPath` before 2.22.0:** session deposits, refunds and reconciles
  were signed from the empty-path address. Check that address for funds and gas.
- **`EvmRpc.EvmRpcCanister` gained `eth_call`.** A mock typed as that interface needs the method.
- **MCP server operators (breaking):**
  - The canister, host and identity now come only from the operator: set `IC402_MCP_CANISTER_ID`
    and `IC402_MCP_HOST`, plus `ICP_IDENTITY_PEM` or the config file.
  - `configure` and a per-call `canisterId` change them only when
    `IC402_MCP_ALLOW_SECURITY_CHANGES=1`.
  - Local development needs `IC402_MCP_LOCAL_DEV=1`.
  - `submit_request` with `confirm:true` must repeat the approved `amount`, and `open_session` the
    approved `maxDeposit`, from the proposal's `confirmWith`. Both are refused if the canister now
    asks something else.
- **EVM gas:** the ERC-20 transfer gas limit rises from 65,000 to 100,000. Unused gas is not
  charged, but the up-front reservation rises about 54%.

### Security: high

- **HTTP ICP payments could be paid out of the canister's own funds.**
  - The flaw: `settle`, the HTTP path where `sender` is only claimed, accepted the canister's own
    principal as the payer. DFINITY ledgers skip the allowance check when a transfer_from's `from`
    is the caller's own account.
  - The effect: anyone could get a paid response free, and each attempt also burned one ledger fee
    from the canister's default account. On a marketplace, a job "paid" this way still paid its
    operator from the canister's funds, so where operators can register services themselves this
    was direct theft (the example gates `registerService` to the controller).
  - The fix: `Gateway.settleCore` now refuses the canister as payer (`#invalidSignature`), on
    `settle` and `settleFrom`. `Escrow.depositCore` refuses a session deposit from the canister's
    own account.
  - Affected: canisters that call `settle` for ICP and hold a balance in their default account.
  - Not affected: `settleFrom` callers (the caller must be the sender), session opens, and the EVM
    rail.
- **EVM sessions: two closes of one session could pay the refund more than once from the shared
  pool.**
  - The flaw: the re-close guard and the `#closing` write ran in different messages, because the
    EVM close was a self-call. A close that then failed before broadcast (the single-flight send
    lock) reopened the session while the other close was paying, so a further close paid again.
  - Who could trigger it: a session's payer.
  - The fix: `closeEvmSessionInternal` now runs inline (`async*`), as the ICP close has since 2.18.1,
    so the guard and `#closing` share one message and the second close is refused.
- **EVM outbound sends: "nonce too low", and node or outcall errors after dispatch, were read as
  "not broadcast".**
  - The flaw: a send is not idempotent. A node whose copy of a tx arrives after another node's copy
    was included answers "nonce too low" for that same tx, and with a 2-of-N threshold a third
    provider may have accepted it. A consistent RPC error needs every provider to agree, but an
    outcall timeout may still have delivered the tx.
  - The effect: callers rolled back and sent again, a second transfer from the pool. This affected
    session closes, `reconcileEvmDeposit` and marketplace EVM payouts.
  - The fix: these outcomes are now `#maybeSent` (`EvmSender.classifySend`). Inbound payments
    confirm-poll the tx hash; outbound sends park for confirm-only recovery (`reconcileSession`,
    `reconcileJob`). Nothing re-sends. Only failures raised before any provider was called are still
    safe to retry: provider or validation errors, and insufficient gas funds.
  - Insufficient gas funds is still "not sent" unless the account's pending nonce has moved past
    the tx's nonce (re-read after the answer; then it is "maybe sent"). A tx held only by a third
    provider the agreeing pair has not caught up with is still missed. Mapping every such answer to
    "maybe sent" would park every send whenever the gas account runs dry.
  - `Gateway.sendErc20Transfer` (no in-repo caller) still returns `#err` for a maybe-sent transfer,
    for API compatibility, but its text now reads "MAYBE SENT — do NOT retry; confirm tx <hash>".
  - The recovery runbook (§2) says to check the chain before force-resolving a parked tx.
  - New public symbols, additive: `EvmSender.classifySend`, `EvmSender.SendOutcome`.

### Security: medium and low

**ICP charges**

- **A stranger could make a payer's own settle report "funds may have moved".** Nonces are
  predictable and not bound to a payer, so anyone could start a settle of the same payment (an HTTP
  settle naming any sender).
  - While an attempt naming a **different** payer is in flight, the payer's settle now answers
    `#policyDenied("A settlement with this payment is already in progress — retry this same
    payment …")`. Retrying the same payment is preferred; paying anew is also safe.
  - An attempt naming the same payer (ICP sender; EVM authorization `from`, in any hex spelling)
    still answers `#settlementPending`, as in 2.21.0: it may be moving that payer's funds.
  - An attempt whose outcome is unknown answers `#settlementPending`. Locks restored after an
    upgrade count as unknown.
  - The SDK treats the busy answer as retryable with the same payment.
- Nonce clean-up during a settle's fee query could drop the lock of a dedup charge still in flight.
  In-flight locks are now kept 24 hours past expiry, like stored transfers.
- Junk HTTP settles naming a payer during a ledger outage held that payer's daily limit. An HTTP
  settle (not `settleFrom`) whose ledger call was rejected now releases the reservation.
- A malformed `sender` trapped (HTTP 5xx). It now returns `#invalidSignature`, using a new
  non-trapping parser.
- The grant HMAC key is seeded with retries (5 tries over about 2.5 minutes after a `raw_rand`
  reject), and `grantsReady()` says when it is ready. Until then, the example refuses content
  delivery before settling.
- A revocation could be forgotten before a long-lived grant expired. Grant TTLs are now capped at
  7 days, the revocation retention.
- Grant fields containing `|` could be re-split into another valid grant. They are now refused.

**ICP sessions**

- **`recoverEscrow` had no total bound,** so a payer could recover more than they were owed, reaching
  the merchant's consumed share. It now:
  - pays only against the refund-owed entry;
  - caps each recovery at the unconsumed deposit and at the entry less the current ledger fee;
  - runs one recovery per session at a time;
  - reduces the entry by what it paid.
- `forceResolveSession` on an ICP session now writes that entry (deposited − consumed). It refuses
  while a close is in flight.
- `recoverEscrow` took the ledger from its caller. It now uses the session's own ledger and refuses
  any other.
- `gcClosedSessions` deleted `#expired` sessions, which can still hold funds. It now deletes
  `#closed` only.
- New `clearRefundOwed(id)` drops an entry whose escrow you have checked is empty. Gate it to
  controllers.
- A client's `idleTimeout` was not clamped. It can now only shorten the policy's
  `sessionIdleTimeout`.
- An open parked by an unknown deposit outcome did not count toward `maxConcurrentSessions`. It now
  does.
- A session token that did not resolve fell back to the first ledger, a principal text no longer
  configured included, so a refund could be paid in the wrong token. Such a principal now fails
  closed; other legacy tokens keep the first ledger, where their deposit is (see the upgrade notes).
- An owed entry of one fee or less could never move anything and kept its record from the GC. The
  next recovery attempt now clears it ("Nothing left to recover: …"). `recoverEscrow`'s no-entry
  refusal now names entries lost at an upgrade, and `loadRefundOwed`.
- EVM reconcile and force could act on an EVM session while its close was in flight. Both now refuse
  with "A close of this session is still in flight — call again once it returns".

**EVM rail**

- **One authorization could be broadcast more than once.** Each replay cost gas and could hold the
  send lock.
  - The sender now keeps one claim per chain, token, payer and nonce. It takes the claim before
    sending and releases it only if nothing was broadcast.
  - A replay answers `#settlementPending` naming the earlier tx, and unlocks the server nonce it
    came with (nothing of it moved).
  - The claims are transient: an upgrade allows one more broadcast per authorization.
- A rejected EVM send, confirm or `authorizationState` call left the server nonce locked as if in
  flight, the authorization claimed and the daily reservation held. Each now ends
  `#settlementPending` with the reservation released; a rejected send keeps the claim, since it may
  have broadcast.
- **A reverted transfer was read as "no funds moved".** Anyone can submit
  `transferWithAuthorization`, so our tx can revert because another tx used the authorization
  first. Settle and session open now read the token's `authorizationState`:
  - unused: failed, as before;
  - used, or the read failed: `#settlementPending`, with no receipt and no session.
- **Parked transactions that appear not to have landed are reported.** A tx is reported when its
  nonce has been used by another tx and the providers agree there is no receipt for it. Providers
  that disagree, an RPC error or no answer leave it "still pending". It is not proof: verify on a
  block explorer before `forceResolveSession` and `sweepEvm`.
  - `reconcileSession` reports such a tx and leaves the session parked.
  - `reconcileEvmDeposit` treats such a deposit as reverted only if the authorization is still
    unused.
  - Maybe-sent transactions are confirm-polled before parking.
- A session open whose deposit call failed with an unknown outcome answered `#settlementFailed`,
  inviting a re-sign. It now returns `#settlementPending` with no tx hash (check the payer's
  authorization on chain), and the authorization stays claimed. A rejected confirm call during the
  open is "confirmation unavailable" (the deposit is tracked for `reconcileEvmDeposit`), and a
  rejected `authorizationState` call is "could not be checked", as on settle. Before, a rejected
  confirm call left the caller's open lock held and the broadcast deposit untracked.
- Sessions kept the sender built at construction, so a later `setEvmDerivationPath` did not reach
  them (see the upgrade notes). They now read the gateway's current sender. Re-applying the current
  path is a no-op, so the sender keeps its send lock, authorization claims and nonce memory.
- Tokens with different decimals on one chain (see the upgrade notes).
- Checksum and lower-case spellings of one address had separate policy buckets, which let a payer
  escape a blocklist. `evmPolicyPrincipal` now lower-cases the address.
- Smaller fixes:
  - no settle leg when the session's recipient is the canister's own EVM address;
  - pool token buckets compare addresses case-insensitively;
  - the gas limit is 100,000, in `EvmSigner` too;
  - authorization nonces are time × 2^64 plus a per-call sequence;
  - uint256 fields and 32-byte nonces are range-checked instead of truncated;
  - `validBefore` is strict on all three intake paths, and `openEvmSession` had no time-window check
    before;
  - `EvmVerify.verifyTransaction` now documents that it does not authenticate the payer;
  - `sendErc20Transfer` is deprecated.

**Marketplace**

- BuyerConfirm jobs ignored the dispute window, so a silent buyer was always refunded at expiry
  (owner decision; see the upgrade notes).
- A rejected expiry refund stopped the sweep and left the job `#Expired`.
  - It now parks the job `#Settling` for `resolveJob`.
  - A refund that fails definitely is retried by later ticks (below).
  - `expireJobs()` returns only jobs that were refunded or parked.
- **The sweep retries failed refunds and operator payments, with a backoff.** Before, a refund that
  failed definitely left the job `#Expired` with the refund owed, until the GC dropped it.
  - A definite failure (an ICP ledger `#Err`, an EVM send refused before broadcast) is retried at
    every tick 5 times, then at most once per hour of the job's age.
  - A failure no retry can fix as things are (no hook, chain, payout address, token or operator; a
    buyer with no rail) goes straight to the hourly retry.
  - A busy EVM sender is retried at the next tick and not counted: only genuine payment failures
    count. Every outcome other than success is logged.
  - The retry state is in memory: an upgrade, or a controller's `resolveDispute`, clears it.
  - A reverted EVM refund is never sent again: the job stays `#Expired` carrying the tx (pay by
    hand, then `resolveJob`). A reverted operator payment is not sent again automatically: the job
    goes back to `#Verified` carrying the tx; `resolveDispute` sends again or refunds, `resolveJob`
    closes it. `health().jobs.parked` counts both.
  - A job still waiting keeps the sweep at its 60 s cadence.
- `resolveDispute(jobId, true)` is also the controller's "refund now" for a `#Pending`, `#Assigned`
  or `#Computing` job once past `expiresAt`. With `false`, or before expiry, those states are
  refused ("Job (status: …) can only be refunded, and only once past its expiry").
- A controller refund of a `#Verified` job that fails comes back `#Disputed`, not `#Verified`, now
  that the sweep settles `#Verified` jobs: the sweep refunds a `#Disputed` job at `expiresAt` and
  never pays its operator, and `resolveDispute` accepts it again. A controller refund that reverts
  on-chain (any status) parks the job `#Expired` with the tx: pay by hand, then `resolveJob`. A
  controller refund that cannot work as configured (no hook or chain, a buyer with no refundable
  rail) leaves the job `#Settling`: refund the buyer by hand, then `resolveJob(jobId, #Refunded)`.
- The sweep now settles a `#Verified` job: one whose window ended, or one an earlier failed settle
  left (not one carrying a reverted payment). Before, only a controller could move the latter.
- A dispute filed after a window above 0 had closed was accepted. It is now refused ("Dispute window
  has closed: the result was accepted"). A `#Disputed` job is still refunded at `expiresAt` unless a
  controller rules first (owner decision).
- The EVM rail followed the buyer's spelling, so a payer written `0X…` or as bare hex was put on
  the ICP rail, where its refund could not be paid. It now follows the receipt's `eip155:` network.
  A job on the EVM rail whose buyer is not a 20-byte address (a consumer that recorded a principal)
  cannot be refunded on-chain: its refund is `#unavailable` ("EVM refund unavailable: buyer … is
  not a 20-byte EVM address"), without calling the hook.
- `submitResult` accepted a second submission while a ZK verifier call was in flight, and a throwing
  verifier left the job stuck `#Computing`. It now accepts `#Assigned` only, and returns the job to
  `#Assigned` on a verifier error.
- `confirmJob`, `disputeJob` and their EVM variants acted on services that do not use BuyerConfirm.
  They now refuse.
- `resolveJob` now also clears a parked tx. A controller's resolution made during an Upto
  remainder's pending send is kept.
- `registerService`:
  - consumed an id before validating, and now validates first;
  - let callers squat `svc-<n>` ids, blocking auto ids forever, and now reserves them;
  - had no size caps, and now caps ids at 64 characters and verification keys at 16 KiB.
- `completedAt` is stamped on every settled write. A non-zero idle poll re-arms a disarmed sweep.

**SDK (`@ic402/client`)**

- `call()` and `submitServiceRequest()` paid whatever the canister asked. Both take
  `{ maxAmount }` and refuse a higher price before approving anything. `submitServiceRequest`
  returns `paidAmount`.
- `Ic402Error.paymentNotSent` marks refusals raised before the paying call; `fundsMoved` marks the
  opposite. A settlement already in progress is another payer's attempt and is transient: retrying
  the same payment is preferred, and paying anew is also safe.
- `fetchX402` treated a network error, timeout or unreadable body after the paid request as a
  retryable error, and a retry signed a second authorization. Those, and any non-402 error status,
  are now possibly paid: `fundsMoved`, kind `not_confirmed`, not retryable. New export
  `paidRequestError`.
- `call()` returned a post-payment `{error}`, or a fresh `{paymentRequired}`, as a value. It now
  throws.

**MCP server (`@ic402/mcp`)**

- The LLM could change the canister, host and identity, or raise caps (owner decision; see the
  upgrade notes).
- A `fetch_x402` confirmation could pay terms other than those shown. The confirming call must now
  repeat the proposal's amount, recipient, asset and chain exactly (`confirmWith`). Only USDC on the
  five supported chains is paid.
- Spend caps did not count ledger fees. They now count the payment, the transfer fee and the approve
  fee.
- Spend reservations were released after timeouts and post-payment errors. Now they are released
  only when no payment was sent.
- `submit_request` and `open_session` paid what the canister asked when confirmed. The
  `confirm:true` call must now repeat the approved `amount` (`submit_request`) or `maxDeposit`
  (`open_session`) from `confirmWith`, and is refused if the canister now asks something else (see
  the upgrade notes). The confirmed amount is the SDK's ceiling.
- A `fetch_x402` failure after the paid request was sent (network error, timeout, refused hop,
  oversized body), and any non-402 error status, is now reported as possibly paid (`fundsMoved`,
  not retryable).
- SSRF gaps closed:
  - NAT64, 6to4, 198.18/15 and 240/4 are refused;
  - the x402 probe checks DNS on every redirect;
  - fetched bodies are capped at 10 MiB.

**Example canister**

- `sessionQuery` charged nothing per call. A voucher that raises the total by less than
  `costPerCall` is now refused. The refusal is a trap that undoes the voucher, so it cannot reveal
  another payer's session state.
- Content that could not be delivered was charged first. It is now refused before the 402 and before
  settling: multi-chunk content over HTTP gets 501, an unfinished upload 503. New
  `ContentStore.isComplete`.
- Service routes did not bind a payment to the service's price, so a nonce issued for a cheaper
  resource could pay for a service. They also left out the fee and accepted `#Session` services.
  They now charge price plus fee, check the expected amount, and refuse `#Session` services.
- `getJob` and `getJobResult` were readable by anyone. Only the buyer, the operator or a controller
  can read them now. EVM-paid buyers lose access to results; job status stays public.
- `registerService` mapped an unknown verification string to AutoSettle. It is now refused.
- New endpoints:
  - `resolveDispute` and `clearRefundOwed`, to controllers only;
  - `recoverEscrow`, for the session's payer;
  - for EVM-paid buyers, `confirmJobEvm` and `disputeJobEvm` (behind the facilitator's admission
    limit) and the query `buyerActionMessage`. The buyer signs keccak256 of the message as a raw
    digest (no EIP-191 prefix), sent as r ‖ s ‖ v.
- Smaller fixes:
  - the JSON reader rejected payment headers with whitespace, as Python's `json.dumps` writes them;
  - `/search` echoed the query unescaped;
  - `escapeJsonString` missed some control characters.

### Changed messages

- The EngramX contract strings are unchanged.
- The EVM settle text for a revert now says the authorization is still unused on chain, and drops
  "authorization nonce already used" from its list of causes.
- ICP close, reconcile and `recoverEscrow` no longer say "No token configured". They name the
  token that does not resolve, say the session stays open (close) or `#closing` (reconcile), and
  give both causes: the ledger was removed from the configuration, or the session was opened before
  2.22.0 with an unconfigured token and its escrow is on the ledger that was then first. They say to
  check which ledger holds the escrow before changing the configuration.
- The EVM reconcile texts for a tx whose nonce was taken now say it "appears not to have landed …
  verify on chain before forcing" (they said it "can never land … moved no funds"); the deposit
  texts likewise.
- An EVM session open whose deposit call failed answers `#settlementPending`, not
  `#settlementFailed`.

### Known residuals

- The EVM authorization claims, and the other new in-memory sets, are lost on upgrade.
- Grants issued before 2.22.0 with a TTL over 7 days can outlive their revocation.
- A recovery whose ledger call is rejected with an unknown outcome leaves the refund-owed entry
  unchanged.
- An open made while a close is in flight can exceed `maxConcurrentSessions`.
- `confirmEvmTransaction` and `ServiceRegistry.reconcileJob` do not detect dropped transactions.
- A fresh authorization from an unfunded wallet costs gas once.
- `authorizationState` is read at the latest block, so a lagging provider pair can still read
  "unused" for an authorization another tx has just used.
- `icp:*` session tokens are stored as given, so they follow whatever the first configured ledger
  is.
- The MCP `fetch_x402` confirmation is stateless, and `ledger` and `rpcUrl` are not pinned at
  startup.
- The SDK and the MCP server treat any failure once the paid x402 request was attempted as possibly
  paid, including a refusal before the request left the process and a non-402 4xx/5xx. This is
  conservative, and the MCP's spend caps bound it.
- An `Upto` job's remainder refund that finds the EVM sender busy (another send took the
  single-flight lock between the operator payment and the refund) is not retried: the job ends
  `#Settled` and the remainder stays in the pool. This predates 2.22.0; the settle's error text
  reports it.

### Tests

- 867 Motoko tests. New suites: `payerguards`, `icpcharge`, `sessionguards`, `jobguards`,
  `evmrail`, `sessiontoken`.
- More than 150 mutations across the Motoko fixes, each test run in isolation. Each turns at least
  one test red, except paths the interpreter cannot reach: timers, tECDSA, traps, and real EVM
  broadcasts.
  Those are covered by review and by the replica cases.
- New replica cases in `test/integration.test.ts` and `test/evm-outbound.test.ts`. They run in CI.
  The EVM-RPC mock gained `eth_call` and modes for insufficient funds, unavailable fees and
  scripted nonces.
- TypeScript: 236 root tests and 105 client tests.

### Release tooling

- **The release's mops step no longer fails on a registry reject after a publish that landed.**
  For v2.21.0, the registry's `finishPublish` answered IC0406 "Timeout expired" and the version was
  published anyway, but the job went red. `scripts/publish-mops.sh` now:
  - skips a version already on mops, so a re-run is safe;
  - after an error, checks the registry before failing, and retries once.

  Its `--self-test` (7 cases, against a stub `mops`) runs in CI's `verify-scripts`.

### Docs

- `Gateway.openSession`'s doc comment now describes the ICP behaviour from 2.21.0. A failed fee
  query refuses the open. A deposit rejected with an unknown outcome returns `#settlementPending`
  with the session parked `#closing`, so a session does exist. Before, it described only the EVM
  case, where none exists.

## v2.21.0 — 2026-11-18

Minor — **ICP payments whose ledger call ends with an unknown outcome: a stopped ledger is refused
cleanly, a session-open deposit is never left without a record, and a pending Candid charge can be
settled by the payer's own re-submit.** 2.20.0 stopped treating such a reject as "not paid", but a
pending charge could only be resolved by checking the ledger by hand, and a rejected session-open
deposit escaped `openSession` with no session record. No stored-state change (`STABLE_SCHEMA_VERSION`
stays 1), no `example.did` change, no `mops.toml` change.

Behaviour changes integrators see:
- **ICP `openSession`** queries the ledger's fee before pulling the deposit. If the query fails, the
  open returns `#err(#settlementFailed)` and nothing moves.
- **A deposit rejected with an unknown outcome** after that query returns `#err(#settlementPending)`
  with the session parked.
- **With the new setting on,** a pending `settleFrom` charge is settled by the payer calling
  `settleFrom` again with the same payment.

### Added

- **`Gateway.setLedgerDedup(on)`** (default **off**; transient, set it at init) and
  `ledgerDedupEnabled()`.
  - **Every ICP charge, with the setting on,** queries `icrc1_fee` first. A failed query moves
    nothing, so it is `#settlementFailed` with the nonce unlocked: in practice a stopped ledger (an
    upgrade) now refuses a charge cleanly instead of leaving it pending. The charge then sends that
    fee, the payment nonce as memo and a `created_at_time`.
  - **A charge made through `settleFrom`** (the caller is the payer) whose transfer is rejected with
    an unknown outcome keeps that transfer. When the payer calls `settleFrom` again with the same
    payment, the transfer is re-sent unchanged and the ledger's deduplication decides: `#Duplicate`
    (it was charged) or `#Ok` (charged now). Either way the payer gets exactly one receipt.
  - **Charges made through `settle` (HTTP) keep nothing and are never re-sent.** There `sender` is
    only a claim, and nonces are not secrets (the memo even shows the nonce on the ledger). A re-send
    on that path would let anyone who saw the transfer collect the payer's receipt. They stay
    `#settlementPending`, as in 2.20.0.
  - **Re-sends are narrow.** Another caller, network or price sends nothing.
  - **A send in flight blocks re-sends.** While a send of the kept transfer is in flight (the first
    attempt, or a re-send), it stays stored but marked in flight. A re-submit meanwhile sends
    nothing, and the nonce clean-up still keeps the nonce.
  - **When re-sending stops.** `#TooOld` (the ledger's 24-hour window passed) and `#BadFee` (its fee
    changed) leave the charge pending and stop further re-sends. Other errors and rejects leave it
    re-sendable.
  - **The fee is explicit because the ICP ledger keys deduplication on the fee it charges.** With
    `fee = null`, a fee change between the attempts would turn the re-send into a second transfer.
    Explicit, it is `#BadFee`, which both DFINITY ledgers check before deduplication. Verified
    against dfinity/ic `0dc067ae`.
  - **The nonce clean-up keeps a nonce that holds a kept transfer** for 24 hours past its expiry
    (`Nonce.PENDING_RETENTION_NS`), so the ledger's window is really available.
  - **The kept transfer is transient:** after an upgrade a pending charge behaves as in 2.20.0.
  - **Turn the setting on only for ledgers that deduplicate** on `created_at_time` + `memo`.
    DFINITY's ICP and ICRC-1 ledgers do. ICRC-1 makes deduplication a SHOULD and no ledger API
    declares it, so this is the operator's declaration; on a ledger that does not deduplicate, a
    re-send charges twice. The ledger's memo limit must be at least 32 bytes.
- **`Escrow.depositCore`** (`async*`): the deposit run inline, so the ledger's reject code reaches the
  caller. As with `settleCore`, a trap decoding a malformed ledger reply now rolls back the caller's
  message; `openSession` then leaves no record and its open lock expires after 5 minutes. Identical
  for any conformant ledger.

### Changed

- **ICP `openSession` asks the ledger for its fee before pulling the deposit.** If that query fails (a
  stopped ledger), the open returns `#err(#settlementFailed("Ledger fee query failed before the deposit
  (nothing moved; safe to retry) …"))`. Nothing is parked, and the open lock is released. One extra
  ledger query per ICP open.
- **ICP `openSession`: a deposit rejected after that, with an unknown outcome, parks the session.**
  Rejects raised before the ledger ran are still `#settlementFailed` (nothing moved). Any other reject
  records the session `#closing` with nothing consumed and the daily reservation held, and returns
  `#err(#settlementPending("Deposit rejected (…) … Session <id> is parked #closing …"))`. Vouchers,
  closes and the expiry sweep leave it alone, and the sweep's timer keeps running. The controller's
  `reconcileSession` reads that session's escrow:
  - the full deposit opens the session;
  - anything less closes it with the daily reservation released.

  Before, the reject escaped `openSession`, and a deposit that had landed had no session record. A
  late reconcile can open a session already past its `maxDuration`, which the next sweep closes,
  refunding the deposit less the fee.
- **`reconcileSession` (ICP): a short escrow with nothing consumed owes nothing.** A close sends a
  settle only when something was consumed, so the escrow is short because the deposit never arrived
  (or a refund already left). It used to record `deposited − fee` as owed regardless.
- **`example/main.mo` turns `setLedgerDedup(true)` on:** its one ledger, ckUSDC, is a DFINITY ledger.
- **The example's pending prefix now reads `Settlement pending — do NOT retry payment with a new
  nonce: `.** It still contains the SDK's moved-funds marker.

### Corrected

- **When a locked nonce is freed.** 2.20.0 said a pending payment's nonce "is freed when it
  expires". It is freed by the first nonce clean-up after it expires. The clean-up runs once the
  table holds 10,000 live nonces or 20,000 have been issued, and anyone can request challenges, so
  on a busy canister that is soon after expiry. The payer's re-submit is then answered `#expired`,
  so a pending payment must be resolved before then. With `setLedgerDedup` on, a nonce with a kept
  transfer is kept 24 hours longer (above).
- Doc comments that still described 2.20.0: `openSession`, `reconcileSession`, `sessionCounts`, and
  the `#settlementPending` variant.

### Not covered

- **The concurrency refund at open.** If a deposit lands but the payer's concurrent-session limit
  was reached meanwhile, `openSession` refunds it before any record exists. If that refund fails, the
  deposit has no session record. Unchanged.
- **HTTP charges stay manual.** A pending charge made through `settle` (HTTP) is still resolved by
  checking the ledger (recovery runbook §7).

### Tests

- **`test/chargededup.test.mo` (19).** The resolution against a fake ledger that deduplicates as
  DFINITY's do. It covers:
  - charged-then-rejected, with one fee query;
  - rejected-before-charge;
  - the receipt consuming the nonce;
  - the fields sent;
  - the setting off (exactly 2.20.0), and the setting flipped mid-call;
  - HTTP charges kept nothing, and HTTP re-submits never re-send;
  - another caller, network or price;
  - no price given;
  - two re-submits at once, and a re-submit during the first attempt;
  - re-sends rejected or refused;
  - `#TooOld`, `#BadFee`, and a failed fee query.

  The interpreter's clock never moves, so no test can tell a re-send that reuses the stored
  `created_at_time` from one that takes a fresh one. That part is pinned by review.
- **`test/opendeposit.test.mo` (2):** reconciling a parked deposit, landed and not landed, against
  that session's escrow subaccount.
- **`test/nonce.test.mo` (+5):**
  - the kept transfer needs the lock, and is checked out once until put back;
  - a first attempt's transfer is in flight;
  - dropping it keeps the lock;
  - it goes with the lock;
  - it survives the clean-up for 24 hours past expiry, also while checked out.
- **`test/integration.test.ts` (+2, replica).** Both stop the local ckUSDC ledger with the icp CLI:
  - a charge is refused before any transfer, and the same payment then settles once;
  - a session open is refused before the deposit, nothing is parked, and the next open succeeds.

  No test reaches the parking itself. The replica cannot stop the ledger between the fee query and
  the deposit, and the interpreter cannot run a successful `openSession`. It is covered by review;
  its reconcile is unit-tested.
- **Mutation check:** 37 mutations, each test run in isolation. None went undetected; 32 turn exactly
  one test red. Five turn more, by design:
  - treating the re-send's `#Ok` as pending breaks all 8 tests that resolve that way;
  - storing the transfer whatever the setting and path breaks the 3 tests that pin "off" and "HTTP";
  - a `takePending` that hands out a checked-out record breaks the concurrency and `#TooOld`/`#BadFee`
    tests as well as its unit test;
  - `setInFlight` leaving the record available, and `dropPending` also unlocking, are each caught by
    a Nonce unit test and by the Gateway test of the behaviour it protects.

  The `openSession` fee check has no mutation here; only the replica test pins it.
- **Adversarial review.** Three Fable reviewers (fund safety, the parked deposit, tests and docs),
  then one on the fixes. Confirmed and fixed:
  - a pending HTTP charge's receipt could be collected by anyone who saw the transfer;
  - the nonce clean-up could drop a pending charge long before the ledger's 24 hours;
  - the clean-up could still drop a nonce while its transfer was out for a send, which the in-flight
    marker fixes;
  - a ledger outage turned every open attempt into a parked record;
  - plus test gaps and doc errors.

  Not fixed: the open lock can be overridden after 5 minutes and then deleted by the stale call.
  This pattern already existed on the deposit await, and the post-deposit concurrency re-check
  still bounds it.

### Interop: viem accepts colon-namespaced EIP-712 names again

- **What changed:** viem 2.57.17 (wevm/viem#5403) accepts struct names such as Hyperliquid's
  `HyperliquidTransaction:Withdraw` again, after 2.57.12–2.57.16 refused them. It hashes them
  context-free, so its digest now equals ic402's byte-for-byte. That holds even on a types map that
  also holds a struct named the first segment, where viem ≤ 2.57.11 computed a different digest.
  Checked against viem 2.57.17 and 2.57.19.
- **Effect:** none on ic402's encoder or on `@ic402/client`, which never hashes typed data with viem.
  The `EIP712Domain:` first-segment rejection stays, because verifiers on viem ≤ 2.57.11 still
  disagree on that name. Its error message no longer claims current viem refuses colon names.
- **Test:** the drift alarm in `packages/client/test/eip712-colon-interop.test.ts` now pins viem's
  agreement on all three shapes. It fails on viem 2.57.11 (wrong digest) and 2.57.13 (refusal).
- **Dependencies:** `viem` 2.57.17, `@x402/core` 2.30.0, `vitest` 5.1.0, `cborg` 6.2.1, `eslint` 10.14.0,
  `@types/node` 26.6.6 (Dependabot PR #50).

### Tooling and docs

- **`scripts/setup.sh` no longer deletes other projects' local-network files.** Its cleanup removed
  every icp-cli port descriptor on the machine and the shared cached pocket-ic. Another project's
  running network then lost track of itself. It now removes only descriptors whose `project-dir` is
  this checkout, and skips the pocket-ic purge while any network is running from that cache.
- **`RELEASING.md`** describes the publish as it works: pushing the tag runs `release.yml`, which
  publishes to npm by trusted publishing and to mops. The manual `npm publish` / per-repo token steps
  (replaced in July 2026) and the `integrations/mcp/README.md` version step are gone.

### Docs

- `docs/recovery-runbook.md` §7: the open's fee check, the parked deposit, the `settleFrom` re-send and
  its limits, when the nonce clean-up runs, and the concurrency refund at open (not covered).
- `docs/security-model.md` §2b and `docs/fund-safety-invariants.md`: the operator declaration, why HTTP
  charges are not re-sent, a new invariant (DEDUP-RESEND-IS-VERBATIM), and the corrected NONCE-EXPIRY.
- `ci.yml` and `docs/production-readiness.md`: the replica suite has 60 cases, not 50.

## v2.20.0 — 2026-11-04

Minor — **an ICP payment whose ledger call is rejected with an unknown outcome is no longer treated as
"not paid".** That assumption could charge a payer twice (`settle`) or settle a session twice out of
the payer's escrow (session close). No type, stored-state or `example.did` change. The behaviour change
is that ICP-rail calls can now return `#settlementPending`, which until now only the EVM rail returned.
Handle it the same way: do not deliver, do not retry.

### Why

A reject does not prove the transfer failed. The DFINITY ICP and ICRC-1 ledgers commit a transfer and
then await `archive_blocks` inside the same call, so a trap after that await rejects a transfer that
landed. They are written not to trap there, but a library that accepts any ledger can't rely on that.
A stopped ledger answers with the same code (`CANISTER_ERROR`). Found while reviewing 2.19.1.

### Changed

- **`Utils.rejectedBeforeExecution(code)`** is the one rule. Only three rejects, all raised by the
  system before the callee runs, mean nothing moved: `#destination_invalid` (no such canister),
  `#system_transient` (overload, low cycles) and `#call_error` (the call was never sent). Every other
  code means the outcome is unknown.
- **`Gateway.settle` / `settleFrom`, ICP rail.**
  - A reject from before execution is still `#settlementFailed`, with the nonce unlocked.
  - Any other reject now returns `#settlementPending`. The nonce **stays locked**, so the same payment
    can't be replayed; it's freed at expiry. The payer's daily reservation stays held, and no receipt
    is issued.
  - Before, it unlocked the nonce and returned `#settlementFailed`. Re-submitting the payment could
    then charge again whenever the payer's allowance still covered it.
- **ICP session close, settle leg.**
  - A reject from before execution still reopens the session for a retry.
  - Any other reject leaves the session `#closing` and returns `#settlementPending`. Nothing re-closes a
    `#closing` session.
  - Before, the session reopened, and the expiry sweep, unattended, could close it again and settle a
    second time out of the payer's escrow.
- **`reconcileSession` now also resolves those ICP sessions.** It reads the session's escrow subaccount
  balance and moves no funds itself.
  - **The full deposit is still there:** the settle didn't land. The session reopens, and the next
    close settles it once.
  - **Less than the deposit is left:** the settle landed. The session ends `#closed`, the daily
    reservation is released, and the remaining escrow is recorded as owed to the payer
    (`recoverEscrow`).
  - It's sound because the subaccount belongs to that session alone and only this canister moves money
    out of it. A transfer *in* can only raise the balance. If that makes a settle that did land read as
    "not landed", the second settle is paid out of that transfer, not the payer's share.
  - It's refused while a close of that session is in flight, tracked by a transient set. Nothing is in
    flight across an upgrade, so after one every such session is reconcilable.
  - A failed balance or fee query leaves the session `#closing`; call it again later.
  - Gateway and the example already expose `reconcileSession` (controller-only).

### Also changed (from the release review)

- **The example's HTTP routes** (`/content`, `/search`, `/service`) now send `#settlementPending` as a 402
  `SettlementResponse` with its own `errorReason`, `settlement_pending`. Before, it got the same
  `invalid_transaction_state` as a definite failure, which reads as "pay again".
- **`@ic402/client`** has new `isSettlementPendingBody` / `settlementError402`. A 402 whose
  `errorReason` is `settlement_pending` becomes an `Ic402Error` with `fundsMoved = true`, from `fetchX402`
  and the client's paid fetch.
- **The MCP server** uses the same helper, and its error results now include `fundsMoved: true` when it's
  set, so an agent is told not to pay again.
- **Re-submitting a payment whose nonce is locked** (a settlement in flight, or one that ended pending)
  now returns `#settlementPending` ("do NOT pay again") instead of `#expired`, which told the caller to
  pay with a fresh nonce. `Nonce.isLocked` is new.
- **The `reconcileSession` owed remainder is computed** the way the close computes it, not read from the
  queried balance, which anyone can raise by sending into the subaccount. The query only decides
  whether the settle landed. The `Types.RefundOwed` doc says so.
- **Recovery guidance now routes an ICP session stuck in `#closing` to `reconcileSession`.** This covers
  three library messages, the `forceResolveSession` doc, and the recovery runbook (two triage rows, the
  `#closing` exit in §3, and a new §7). Forcing one whose settle never landed strands the recipient's
  share.
- **There is no in-band resolution for a pending ICP charge.** The canister keeps no record of the
  attempt; runbook §7 says how to check the ledger. Ledger dedup is the tracked follow-up.

### Unchanged, and why

- **The refund leg of a session close.** A rejected refund still ends `#closed`, with the remainder
  recorded as owed. If the refund did land, that owed figure overstates what's left, but
  `recoverEscrow` only draws on that session's escrow, which the refund emptied. Nothing is paid twice.
- **Session open** still doesn't catch a reject on its deposit pull. If one ever followed a committed
  transfer, the deposit would sit in that session's escrow subaccount with no session record. Fixing
  that needs a new session state, so it's left for a separate decision.
- **The trade-off:** a ledger stopped for an upgrade now gives "pending" instead of a clean retryable
  failure. A `settle` then needs a fresh payment once the nonce expires; a session close needs
  `reconcileSession`.

### Tests

- **`test/settlereject.test.mo` (new, 5).** It drives an ICP `settle` against a fake ledger that
  rejects: `#settlementPending`; re-submitting the same payment is refused as pending without reaching
  the ledger; and the daily reservation is held. It also tests the classifier against every reject code.
- **`packages/client/test/evm.test.ts`:** `isSettlementPendingBody` / `settlementError402`.
- **`test/closeledger.test.mo`.** The settle-reject and sweep tests now expect `#closing`, and 7 new
  tests cover `reconcileSession`:
  - nothing landed (exactly the deposit, and above it);
  - landed (closed, released once, the owed remainder computed rather than read, recoverable);
  - the balance query fails;
  - refused while a close is in flight, and when a second reconcile resumes after a new close began;
  - a `forceResolveSession` landing mid-reconcile wins.
- The interpreter can't produce the three "never ran" codes, so that branch is covered by the classifier
  test only.
- Mutation: 17 mutants (5 on the Gateway, 12 on session close and reconcile). 16 are killed. The
  survivor removes the first in-flight check, which the re-check after the ledger awaits duplicates;
  it's kept as a cheap early exit.

## v2.19.1 — 2026-11-04

Patch — **a service-job payout that finishes after a controller's `resolveJob` no longer overwrites
it or sends more money.** `ServiceRegistry` only. No API, type, stored-state or `example.did` change.
Prompted by an EngramX hand-over; see "Not done" for what it proposed instead.

### Fixed

- **`resolveJob` is no longer undone by a payout that was in flight.** `resolveJob` accepts any
  `#Settling` job, including one whose payout is awaiting the ledger or the chain. 2.17.6 stopped a
  *failed* payout from undoing it, but a *successful* one still overwrote the controller's status with
  `#Settled` or `#Refunded`. Worse, an Upto settle then went on to refund the buyer's remainder after
  the controller had stepped in.
  - When a definite outcome (paid or failed) arrives after a resolve, the job now keeps the
    controller's status and no further transfer is sent.
  - The call returns `#err` saying what was paid, including any Upto remainder left unrefunded.
  - The same text goes to the canister log, because the `#err` reaches whoever triggered the settle
    (often the buyer or operator), not the controller.
  - A pending EVM broadcast is still recorded on the job (re-parked with its tx hash), as before.
    That hash is the only handle `reconcileJob` has on a transfer that may land.

### Not done

- **Catching ledger rejects so the job rolls back.** Proposed and reverted in review, because a
  reject does not prove the transfer failed.
  - The DFINITY ICP and ICRC-1 ledgers commit the transfer and then await `archive_blocks` inside the
    same `icrc1_transfer` call. A trap after that await would reject a transfer that landed.
  - They are written not to trap there, but a library that accepts any ledger cannot rely on it.
  - A stopped ledger, the common reject, answers with the same code (`CANISTER_ERROR`) as such a trap.
  - So a rejected payout still leaves the job `#Settling`, for a controller to check on the ledger and
    `resolveJob`. A test now pins this.
- **Ledger deduplication (`memo` + `created_at_time`).** This is the structural fix for the case above.
  `job.createdAt` could serve as `created_at_time` without a stored-record change. The limit is the
  ledger's 24 h dedup window: a job settled more than a day after it was created gets `#TooOld`, and
  service jobs routinely live longer. Making it work for every job means storing a send time, which is
  a stored-record change and a migration in every consumer. Worth revisiting on its own.
- **A settle callback on `ServiceRegistry`.** It would run in the settle's own message after the final
  write, so a callback that trapped would roll the job back to `#Settling` with the operator already
  paid.
- **Follow-up, not changed here:** `Gateway.settle` and session close *do* catch ledger rejects and
  treat them as "not paid" (since 2.17.3). They rest on the same ledger behaviour described above.
  Session open does not catch a reject on its deposit pull: nothing is lost, but the caller's open
  lock is held until it expires (5 minutes).

### Tests

- `test/jobrevert.test.mo` gains 10 tests. Its fake ledger can now script a reject and a different
  outcome per transfer, and an injected EVM hook calls `resolveJob` from inside the payout's await.
  - A ledger reject is not caught, so the job stays `#Settling` (settle and dispute refund).
  - Each of the four definite-outcome guards has a test where `resolveJob` lands mid-payout.
  - Each of the three pending-broadcast paths keeps its tx hash on the job.
- Mutation: 8 of 8 fail their own test: a blanket catch, each guard dropped, and an early return on
  each pending path.

## v2.19.0 — 2026-10-30

Minor — **a host can run the gateway's hourly clean-up on its own schedule.** Requested by EngramX,
which is moving each engram to one check-in every 6–24 hours. That leaves the gateway's hourly timer
as 80–95% of a quiet engram's remaining upkeep: 24 wakes and ~0.68B cycles a day, measured on PocketIC.
`startTimers` behaves exactly as before. No type, `PaymentResult` or stored-state change. Includes
2.18.2.

### Added

- **`Gateway.runMaintenance()`** runs the hourly clean-up on demand and returns
  `{ dailySpendRemoved; rateLimitRemoved; revokedGrantsRemoved; more }`. It drops daily-spend entries
  from earlier days, rate-limit entries with no hit in the last 60 s, and grants revoked more than 7
  days ago. It is synchronous, needs no `<system>` and has no trap path.
  - It removes at most `maintenanceCapPerMap` (10,000) entries per map per call. Reach the cap as
    `Ic402.maintenanceCapPerMap`. `more = true` means the cap stopped it, so call again in a later
    message.
  - The cap counts entries removed, not entries examined. The maps keep no position between calls,
    so a cap on entries examined would rescan the same live entries every time and never reach the
    stale ones. The cap therefore bounds removals, not the scan: a call can walk each whole map, as
    the hourly timer always has, and its cost grows with the maps. Run it often enough to keep them
    small.
- **`Gateway.startTimersWith<system>({ hourlyGc : Bool })`.** `startTimers()` is now
  `startTimersWith({ hourlyGc = true })`. With `hourlyGc = false` it arms the session sweep and the
  HMAC-seed and EVM-derivation one-shots, but not the hourly timer.
  - **A host that turns it off MUST call `runMaintenance()` at least once a day**, and more often
    under heavy inbound traffic. While `rateLimitPerMinute` is set, the rate-limit log gains an
    entry per caller on every session-open attempt (before any other check; principals cost nothing
    to mint) and on every successful settle. It grows with attacker-chosen keys until a clean-up
    runs (SEC-1).
  - Timers do not survive an upgrade and the init body re-runs, so a host switches at its next
    upgrade. There is no `stopTimers`.
- **`Gateway.maintenanceTimerArmed()`** reports whether the hourly clean-up is armed. The example
  shows it as `health().timers.maintenanceArmed` (`example.did` gains that field; old clients ignore it).
- `Policy.gcDailySpendUpTo` / `gcRateLimitUpTo` and `Grants.gcRevokedGrantsUpTo` are the bounded forms
  behind `runMaintenance`. The unbounded `gcDailySpend` / `gcRateLimit` / `gcRevokedGrants`, which the
  hourly timer runs, behave as before.

### Not done: cleaning at use

EngramX also offered an alternative: trim a payer's stale entries when that payer next pays, with no
timer and no host call. It would not bound the maps. An entry written once is never revisited, and
that covers every one-time payer and every attacker-chosen principal in the rate-limit log, which is
the case the clean-up exists for.

### Tests

- `test/maintenance.test.mo` plants stale and live entries through `loadStable`, since the test clock
  is fixed. It checks that `runMaintenance` cleans all three maps and keeps live entries, holds its
  cap (10,001 entries → 10,000 + `more`, then 1), and reports exactly 10,000 without `more`. It also
  checks the bounded and unbounded clean-ups in Policy and Grants.
- The replica suite checks that `startTimers` still arms the hourly clean-up.
- No unit test covers the `hourlyGc = false` branch: `mops test` has no timer API. Hosts can assert
  `maintenanceTimerArmed() == false` in their own replica tests.

## v2.18.2 — 2026-10-30

Patch — **`POST /verify` now accepts an EIP-3009 signature only if USDC will accept it on chain.**
Before, it could call a signature valid that the transfer then reverted on. A seller who delivered
on a `/verify` verdict alone could be left unpaid. Settle never moved USDC on one: the transfer
reverted and settle returned `#settlementFailed`. But the canister paid gas for each reverting
broadcast, bounded only by the facilitator rate bucket. No API, type, `PaymentResult`,
stored-state or `example.did` change.

### Fixed

- **Payment signatures are checked the way the chain checks them.** `Eip712.recoverAuthorizationSigner`
  (behind `verifyPayment`, `settle`/`settleFrom` and `openEvmSession`) now applies USDC's
  `ECRecover` rules, which OpenZeppelin's ECDSA shares for other EIP-3009 tokens:
  - **Low s only** (s ≤ n/2). A high-s signature recovers the same signer, so ic402 used to pass it;
    USDC reverts on it. Wallets produce low s, so honest payers are unaffected.
  - **v must be 27 or 28**, or the recovery id 0/1 that ic402 converts back to 27/28 on chain. Other
    values used to be folded onto a parity: v = 29 verified as 27 did, then went on chain as 29 and
    reverted. `EvmUtils.recoveryIdFromV` now converts only 27/28, so an HTTP signature byte of
    54/55 is refused instead of passing as 27/28.
  - **Recovery as Ethereum's `ecrecover` does it**, through the new `EvmAddress.ecRecoverEvm`: x = r
    only, v's parity only, and no key for the point at infinity. The lenient `ecRecover` also tries
    x = r + n and falls through to the other parity. Neither difference is reachable for a payment
    signed by a real key, but the payment path no longer depends on that argument.
  - Settle and session-open fail early with `#invalidSignature` instead of broadcasting a transfer
    that reverts, so the canister no longer pays gas for one. The message now names the signature
    form as a cause.
- **Fixed a wrong comment** in `Eip712.mo`, which said `ecRecover` tried both parities and handled high
  s "via its parity loop".

### Unchanged

- `EvmAddress.ecRecover` keeps its lenient behaviour, which `test/secp256k1.test.mo` pins. It still
  serves EVM buyer confirm/dispute (`ServiceRegistry`), which never reaches a chain, and
  `recoverYParity`.
- Contract-wallet (ERC-1271) payers remain unsupported.

### Tests

- `ecRecoverEvm` must return exactly the key Ethereum's `ecrecover` gives for both v of all 252
  Wycheproof vectors. The fixture generator computes those keys with its own model, and a new
  vitest (`test/secp256k1-fixtures.test.ts`) checks that model against `@noble/curves` on all 504,
  every CI run.
- `verifyPayment` with real wallet signatures: low-s originals pass as v = 27 and v = 28, and as
  0/1. A high-s twin and v = 2/29/255 are refused. `recoveryIdFromV` leaves 54/55 unconverted.
- A parity-fallthrough signature over a real EIP-712 digest recovers no signer, as on chain.
- `isLowS` is pinned at USDC's exact bound.
- The secp256k1 suites now run in the interpreter, in two files (`secp256k1.test.mo` for `ecRecover`,
  `secp256k1evm.test.mo` for `ecRecoverEvm` and the payment path). Compiled to wasi, the file peaked
  at 7 GB of memory, and once the new suite was added the CI runner was killed twice. Interpreted,
  each takes about 50 s and stays under 300 MB.

## v2.18.1 — 2026-10-28

Patch — **ic402 now builds with moc 2.1.0, with every dependency refreshed.** Requested by EngramX. No
API, type, `PaymentResult`, stored-state or `example.did` change. The library source still compiles
with moc 1.x, so consumers move to moc 2 on their own schedule.

### Changed

- **Toolchain:**
  - moc 1.16.1 → **2.1.0**, wasmtime 48.0.5 → **50.0.0**, and the mops CLI pinned in CI 3.4.2 →
    **3.5.1**. 3.5.1 closes smol-toml GHSA-r4xh-jqrq-34v2; 3.5.0 had already fixed `mops publish` on
    moc 2, which our release job avoids anyway with `--no-bench`.
  - Under moc 2.1.0 every module compiles with zero errors, and the full test suite passed
    unchanged.
  - `[moc] args = ["-E", "M0074"]` is gone: moc 2 makes M0074 an error by default.
  - **Timers (moc 2.1.0, #6440).** A timer dispatch rejected for lack of cycles no longer stops timers
    for good. ic402's recurring sweeps are unaffected, since an overdue run is still skipped. Its
    one-shot install timers (HMAC seed, EVM recipient derivation, content-store seed) are now retried
    instead of dropped. ic402 never cancels a one-shot, so the new limit that a retried one-shot can't
    be cancelled doesn't apply.
- **Motoko dependencies:**
  - `sha2` 0.2.5 → 0.3.2. 0.3 removed `Digest.fold`/`combineLeaves`/`combineNodes` and changed the
    stored `Sha256.Digest` type. ic402 only uses the one-shot `fromArray`/`fromBlob`, so its hashes are
    byte-identical and every golden vector (escrow subaccounts, Ed25519, vouchers) passes.
  - **`ecdsa` stays at 8.0.1, on purpose.** 8.0.2 only migrates it to moc 2 and moves it to `sha2`
    0.3, but it declares that as `sha2@0`. mops resolves one version per 0.x major, so 8.0.2 drags
    *every* package in a consumer's build that asks for any 0.x `sha2` onto 0.3. Packages written
    against 0.1/0.2 then fail to compile: the EngramX canary caught it on `ic-certification` 1.1.0,
    whose `MerkleTree.mo` calls the `SHA256.Digest(#sha256)` constructor that 0.3 removed. ic402's
    own `sha2 = "0.3.2"` has no such effect, since it uses the unversioned package name. 8.0.1
    compiles and passes under moc 2.1.0.
  - `core` 2.6.2 comes in transitively. `base` stays at 0.16.0, its final release.
- **Published npm dependencies:**
  - `@icp-sdk/core` 6.1.1. It bounds Candid decode allocation and LEB128 parsing against
    memory/CPU-exhaustion DoS (#1393, #1391), and reuses the signed call on v4 fallback (#1405).
  - `@modelcontextprotocol/sdk` 1.32.2, `viem` 2.57.13, `cborg` 6.1.6, `zod` 4.6.7.
- **Dev tooling:**
  - **vitest 4.1.11 → 5.0.5.** A major. Two of its breaking changes touch this repo:
    - Config files are no longer found in parent directories. `packages/client` now has its own
      `vitest.config.ts`, so `pnpm test:client` keeps the root config's 120 s timeout.
    - `clearMocks` is now on by default. That's a no-op here, since every mock is created inside its
      test.
    - Browser mode, benchmarks, coverage and nested `vi.mock` aren't used.
  - eslint 10.13.0, typescript-eslint 8.72.1, prettier 3.9.10, `@types/node` 26.6.5.
  - icp CLI 1.7.0, as both the devDependency and the CI pin. It only adds commands, none of which
    change the ones ic402 runs; checked locally as the pin note requires.
  - pnpm 10.34.9.
- **Fewer outstanding calls on timer and install paths.** A local `async` function called with
  `await` is a self-call, and on a 13-node subnet each one holds about 82B cycles of reply
  reservation until it answers. These now run inline with `await*`. Behaviour is identical for any
  ICRC-1-conformant ledger. The only difference: a ledger reply that fails Candid decoding now rests an
  ICP close in `#closing` for `forceResolveSession`, as a malformed `icrc1_fee` reply already did,
  instead of reopening the session or recording an owed refund.

  | Path | Self-calls saved |
  |---|---|
  | Install-time EVM recipient derivation (the `startTimers` one-shot) | 2 → 0 |
  | `deriveEvmRecipient`, when a consumer calls it (its own `async` hop remains) | 2 → 1 |
  | Escrow settle and refund inside an ICP close, from the sweep or the payer | 2 per close |
  | `recoverEscrow`, and `openSession`'s concurrent-limit refund | 1 each |
  | `ServiceRegistry`'s payment from the main account, for job payouts and the job sweep's refunds | 1 each |

  - `Escrow.settle`/`refund` keep their `async` signatures and gain inline `settleCore`/`refundCore`.
  - Deliberately still separate messages: the sweep's per-session close (2.17.3: a trap fails only
    that close) and `refundOnRail` (it parses the buyer principal before its first await, so one
    malformed job can't wedge the job sweep).
- Removed 6 unused identifiers in the library (moc 2 warns M0194).

### Interop note: viem now refuses colon-namespaced EIP-712 names

- **What changed:** viem ≥ 2.57.12 (wevm/viem#5308) rejects struct names such as Hyperliquid's
  `HyperliquidTransaction:Withdraw` with `InvalidStructTypeError`. viem ≤ 2.57.11 accepted them.
- **Effect:** ic402's encoder is unchanged and still signs them, as 2.13.1 intends. A verifier on
  current viem can't hash that typed data; ethers, and viem ≤ 2.57.11 on the venue's single-struct map,
  still agree with ic402. `@ic402/client` never hashes typed data with viem, so it isn't affected.
- **Test:** `packages/client/test/eip712-colon-interop.test.ts` is re-derived. It now checks the Motoko
  golden digest against an independent EIP-712 computation (keccak + ABI encoding). A control shows
  that computation equals viem's on a plain name, and the drift alarm pins viem's refusal.
- **Unchanged:** the `EIP712Domain:` first-segment rejection stays (fail-closed).

### Not changed

- **TypeScript stays at 6.0.3.** typescript-eslint 8.72.1, the latest, still requires TypeScript
  < 6.1.0, so TypeScript 7 is blocked by that dependency.
- **pnpm 11/12 stay deferred**, as they're package-manager majors. The move from `base` to `core`
  belongs to 3.0.0.
- **The example keeps `persistent actor` and `preupgrade`/`postupgrade`,** so it still compiles under
  moc 1.x. moc 2 only warns (M0217, M0270).

## v2.18.0 — 2026-10-08

Minor — **a refund the close could not make is reported, and its record is kept until the payer
recovers it.** Requested by EngramX. No `PaymentResult` tag change; no stored type changed
(`StableSession`, `StableGatewayState` and `STABLE_SCHEMA_VERSION` are unchanged).

### Added

- **`sessionCounts().refundOwed`.** When an ICP close's refund leg fails (refused or rejected by the
  ledger), the session ends `#closed` with the payer's remainder in its escrow subaccount. When the
  payer closed, `closeSession` returned `#settlementFailed("Refund leg …")`; when the **expiry sweep**
  closed, the timer dropped that result and `sessionCounts()` counted the session `closed` like a clean
  close, so nobody knew. `refundOwed` now counts these sessions until `recoverEscrow` leaves one fee
  or less in the escrow (a partial recovery keeps it counted). The escrow balance is computed from the
  close, not queried: an escrow subaccount is derivable and anyone can top it up. The example's
  `health().sessions` gains the field, so `example.did` and the client IDL gain `refundOwed : nat`
  (additive; existing decoders ignore it).
- **`refundOwedToStable()` / `loadRefundOwed(data)`** on the Gateway, and the `Ic402.RefundOwed` type.
  The owed refunds are kept outside `StableSession`, so persist them in **their own** stable variable
  and restore them after `loadStable` (README, `docs/upgrade-safety.md`; the example does). The new
  variable is upgrade-compatible for an existing persistent actor. Unpersisted, the count restarts at 0
  on upgrade, as before 2.18.0.

### Fixed

- **An owed refund could be stranded for good.** `gcClosedSessions` deleted a `#closed` record 24 h
  after its last activity even when its refund had failed, and the record is what authorizes
  `recoverEscrow`: after that, the remainder sat in the escrow with no way left to move it. A session
  whose close reported a failed refund leg (from either close path) now keeps its record until the
  payer has recovered it.

### Not changed

- A session forced out of `#closing` with `forceResolveSession`, or a close a force landed on, is not
  recorded: the library cannot know whether its refund ran, and a wrong entry could never clear. It
  keeps the usual 24 h window from the force (runbook §3).
- Not retroactive: a refund that failed before the canister ran 2.18.0 is not tracked (the stored
  session record does not say whether its refund succeeded, and escrow balances are never queried).
- The owed figure uses the ledger fee at the close; if the fee changes before recovery, recover the
  full `balance − current fee` in one call.

### Changed (toolchain, merged since 2.17.7)

- pnpm 9.15.0 → 10.34.6, with `@icp-sdk/icp-cli` and `esbuild` install scripts ignored explicitly
  (they only validate an optional platform binary; both work without them).
- icp CLI 1.6.0 everywhere (it was 1.0.2 locally and 1.1.0 in CI).
- moc 1.11.0 → 1.16.1 and wasmtime 44.0.0 → 48.0.5. The 108 `.vals()` calls moc 1.16 flags (M0269)
  are now `.values()` (available since moc 0.14, so consumers on moc 1.x are unaffected). An in-place
  upgrade of a 1.11.0-built example holding state to the 1.16.1 build was rehearsed: state preserved,
  the replica suite green afterwards.

## v2.17.7 — 2026-10-06

Patch — **dependency refresh**, from an audit of every dependency and toolchain pin. No library
(Motoko) change, no API, type, `PaymentResult` or `example.did` change.

### Security

- `@modelcontextprotocol/sdk` 1.29.0 → 1.32.1 in `@ic402/mcp`. Clears the high advisory
  GHSA-6qxp-vccf-f47h (the SDK's OAuth client), which `npm audit` reported against `@ic402/mcp` for
  every consumer. ic402's MCP server is stdio-only and never used that client.
- `vitest` 4.1.10 → 4.1.11 (dev only): GHSA-82fw-gwwq-j7x9.

### Changed

- **Published runtime dependencies:** `@icp-sdk/core` 6.0.0 → 6.1.0 (`@ic402/client`, `@ic402/mcp`),
  `viem` 2.55.2 → 2.57.3, `cborg` 5.1.7 → 6.1.3, `zod` 4.4.3 → 4.6.5.
  - `cborg` 6 changed how some CBOR map keys are ordered. Voucher payloads are arrays of text and
    unsigned integers, so their bytes are unchanged. New golden vectors with 4- and 8-byte integers,
    asserted on both the client and the canister side, now pin that.
- **`@ic402/client` no longer declares `@icp-sdk/core` as a peer dependency.** The `>=5.1.0` peer
  range had no effect alongside the exact runtime dependency: npm always installed 6.0.0 for the
  client, and a nested second copy if the app used a different version. It is now a plain
  dependency. Use the same version in your app (6.1.0) to get a single copy.
- **`engines.node`:** `@ic402/client` `>=20.19.0` (was `>=19.0.0`; the real floor of
  `@icp-sdk/core`'s `@noble/*` dependencies), `@ic402/mcp` `>=20.19.0` (was undeclared), and the
  repo `>=22.22.1` (lint-staged 17; eslint 10 needs 22.13+).
- **Dev tooling:** `@x402/core` 2.28.0 (its v2 wire schemas are byte-identical, so the conformance
  suite validates against the same schemas), `eslint` 10.12.0, `typescript-eslint` 8.71.1,
  `prettier` 3.9.9, `tsx` 4.23.15, `lint-staged` 17.6.0, `@noble/curves` and `@noble/hashes` 2.4.0,
  `@types/node` 26.6.4.

### Fixed (tests)

- **Nine assertions in `test/evmutils.test.mo` checked nothing.** Expected arrays written as
  `[0xde : Nat8, 0xad]` type only the first element, so moc inferred `[Any]` and `==` was always
  true. They covered hex decoding and RLP encoding, on the EVM transaction-signing path; the code
  was correct. `[moc] args = ["-E", "M0074"]` now makes `mops test` reject the pattern.

### CI

- `actions/checkout` and `actions/setup-node` v7, `pnpm/action-setup` v5 (Node 24 runtimes).
- `setup-mops` points at its new owner `caffeinelabs`, with the mops CLI pinned at 3.4.2. It used to
  install `latest` on every run.
- No package-manager cache in the publishing job.
- Dependabot: `@icp-sdk/*` packages arrive as their own PR, and `@icp-sdk/icp-cli` is bumped by hand
  together with its CI pin.

## v2.17.6 — 2026-10-06

Patch — **three job-registry fixes: no job is paid twice or stranded by a race or a failed
payment.** Found by the adversarial reviews of 2.17.5 and 2.17.6. No API, type, `PaymentResult` or
`example.did` change; `resolveDispute` accepts one more status.

### Fixed

- **A resolved job could come back to life.** `resolveDispute` (refunding the buyer) and
  `settleJob` (paying the operator) put the job in `#Settling`, await the ledger, and on failure
  revert it for retry. `resolveJob` accepts any `#Settling` job, so a controller could make it
  terminal during that await; the failure then restored the job from a copy taken before the
  await, back to its pre-await status (`#Submitted` or `#Disputed`) or to `#Verified`. A
  `#Submitted` or `#Disputed` job could then be refunded a second time (by the expiry sweep or
  another `resolveDispute`), and a `#Submitted` one could be confirmed by the buyer and settled to
  the operator, after the controller had already handled the funds out-of-band. A `#Verified` one
  was stuck (see below), and with this release's `resolveDispute` change could have been settled or
  refunded a second time. Those two failure arms now revert only a job that is still `#Settling`.
- **The expiry sweep could refund a job whose operator had just been paid.** `expireJobs` awaits
  each refund while walking the job map, and the map's iterator hands back the jobs of a bucket as
  they were when it entered that bucket. A job a buyer confirmed (or a controller resolved) during
  an earlier job's refund still looked `#Submitted` to the sweep, so it was marked `#Expired` and
  its buyer refunded on top of the operator payment. A buyer with two timed-out jobs in the same
  job-map bucket could set this up (ids are sequential and the hash is public, so such a pair turns
  up within a few dozen jobs). The sweep now re-reads each job's live record before deciding.
- **A failed operator payment stranded the job in `#Verified`.** `settleJob` rolls the job back to
  `#Verified` for retry when paying the operator fails (an ICRC-1 error, or an EVM operator with no
  payout address), but nothing could retry it: every public transition rejected `#Verified`, and
  the record was never garbage-collected (and since 2.17.5 held the job sweep at its 60 s cadence).
  `resolveDispute` now also accepts a `#Verified` job, so a controller can retry the settle
  (`refundBuyer = false`) once the cause is fixed, or refund the buyer. No funds have moved for a
  `#Verified` job, so either is safe; see the recovery runbook's §6.

### Not changed

- The success and parked (`#pending`) arms, and `settleJob`'s Upto-remainder arms once the
  operator is paid (which mark `#Settled` even when that refund fails), still write their outcome
  over a `resolveJob` that landed during the await: they record a transfer that did, or may have,
  happened, which `reconcileJob` relies on.

## v2.17.5 — 2026-10-06

Patch — **a closed session no longer keeps the 60-second expiry sweep running for a day.** Reported
by EngramX. No API, type, `PaymentResult` or `example.did` change.

### Fixed

- **Retained `#closed` sessions kept the session sweep ticking.** The sweep stopped only when no
  session record existed at all, and a closed session is kept for 24 h so the payer can still call
  `recoverEscrow`. So every close kept the canister waking every 60 s for a day (~1,440 empty
  ticks), measured by EngramX at ~3.4B cycles/hour against ~0.3B/hour once the record was gone.
  The sweep now counts only sessions that are not yet `#closed`: `#open` ones, and `#closing` /
  `#expired` ones, which a failed close can return to `#open`. Closed records are still kept, and
  are deleted by the first sweep after their 24 h (the next session opened, or an upgrade, arms
  one), so retention is now at least 24 h.
- **The job sweep had the same pattern.** Terminal jobs (`#Settled`, `#Refunded`, `#Expired`) kept it
  at its 60 s working cadence through their 24 h retention. It now drops to its hourly idle poll,
  which still runs `gcTerminalJobs`. `armExpiryTimer` now also keeps the working cadence for the
  next tick: `example/main.mo` arms just before the settle that creates the job (because
  `createJobFromReceipt` is synchronous and cannot), and a tick landing during that settle used to
  find no job and drop to the idle poll, leaving the new job's timeout unenforced for up to an hour
  (or, with `setExpiryIdlePollSeconds(0)`, until the next arm). Found by adversarial review.
- **Each tick is one message cheaper.** The timers ran the sweep with `await closeExpiredSessions()` /
  `await expireJobs()`, and a call to a local `async` function is a message the canister sends
  itself. They now run it inline with `await*`; the public functions are unchanged, and each
  session's close is still its own message. Measured on a local replica with one open session:
  39.8M → 28.2M cycles per tick (−29%).

### Not changed

- While a session is open the sweep still ticks every 60 s. `setSessionExpiryIntervalSeconds`
  trades expiry latency for fewer ticks (a timed-out session then closes within the interval).
- A settle that outlasts a whole sweep interval (60 s) between the arm and `createJobFromReceipt`
  can still let the job sweep drop to its idle poll before the job exists. The job is then picked
  up within the hour, or with `setExpiryIdlePollSeconds(0)` on the next arm.
- Each tick's saving from running the sweep inline is measured, not guarded by a test: a test
  cannot count a canister's own messages.

## v2.17.4 — 2026-10-05

Patch — **a refund the ledger rejects no longer strands the remainder behind a controller.**
Reported by EngramX. No API, type, `PaymentResult` or `example.did` change.

### Fixed

- **A rejected refund left an ICP session resting in `#closing`.** 2.17.3 handled a rejected settle
  and a refund the ledger refused, but not a refund the ledger *rejected* (for example while it is
  being upgraded): the close threw, the session rested in `#closing` with the remainder in escrow,
  and since 2.17.3's `recoverEscrow` refuses `#closing`, only a controller's `forceResolveSession`
  could free it. An ICRC ledger either answers or traps (rolling the transfer back), so a reject
  means nothing moved: it is now handled like a refused refund. The session ends `#closed`,
  `lastActivityAt` is refreshed, the payer can recover the remainder with `recoverEscrow` for the
  full 24 h, and the close returns `#settlementFailed("Refund leg rejected (session marked #closed): …")`.
- **A failed refund now releases the payer's daily reservation**, refused or rejected, like every
  other terminal close. Before, a refused refund left the unspent remainder counted against the
  payer's daily limit until the day rolled over (a rejected one released it only when a controller
  ran `forceResolveSession`). A `forceResolveSession` landing during the refund still releases it
  once, not twice.
- The refused-refund message drops its "settle succeeded" clause, which was false when nothing had
  been consumed: it is now `"Refund leg failed (session marked #closed): …"`.

### Not changed

- A trap after one of the close's awaits can still leave a session resting in `#closing`; its exit
  is still the controller's `forceResolveSession`.
- With no ICP ledger reject left that makes the close throw, the sweep's catch arm is now reached
  only by a rejected self-call or a trap; it is covered by review only.
- A refund that fails during the expiry sweep is still not reported: the timer discards the sweep's
  results. A rejected one used to show as a session resting in `#closing` (the `sessions.closing`
  count); it now ends `#closed` silently, as a refused one already did. Surfacing sweep failures is
  a follow-up.

## v2.17.3 — 2026-10-05

Patch — **session-close fixes found by an adversarial review of 2.17.2.** No API, type,
`PaymentResult` or `example.did` change; no new state; schema stays v1.

### Fixed

- **`recoverEscrow` could drain an escrow under an in-flight close.** It accepted `#closing` and
  `#expired` as well as `#closed`, capped only per call. A payer racing it against their own ICP close
  drained the escrow, so the settle failed and reopened the session, and repeating it recovered the
  merchant's consumed share too. It now accepts **`#closed` only**.
- **An expiry-sweep close that never ran stranded the deposit.** The sweep set `#expired` and called
  the close with no `try/catch`. If that message was rejected or trapped before the close started,
  the session stayed `#expired` with its full escrow until the 24 h GC deleted the record. The sweep
  now reverts it to `#open` so the next tick retries, and one failed close no longer stops the sweep.
- **A ledger reject on the settle left the session resting in `#closing`.** A reject on that
  guaranteed-response call moved nothing, so it is now handled like a failed settle: the session
  goes back to `#open` and the close is retried. A ledger outage therefore no longer parks sessions.
- **`forceResolveSession` during a live ICP close double-credited the daily limit** once that close
  succeeded. The close now finishes with `#closed` + its daily release only if it is still
  `#closing`; its transfers still run.
- **A `#closed` session still holding escrow gets the full 24 h to recover it.** A failed refund and
  `forceResolveSession` now refresh `lastActivityAt`; GC used to measure from the last voucher, so a
  long-idle session's record could be deleted on the next tick.

### Visible changes

- `recoverEscrow` on `#closing`/`#expired` returns `#err`. Close an `#expired` session with
  `closeSession`; a session resting in `#closing` (a refund rejected by the ledger, a trap, or an
  earlier version) needs the controller's `forceResolveSession` before the payer can recover it.
- `closeSession`/`forceCloseSession` return `#settlementFailed("Settle: ledger call rejected: …")`
  on a settle reject instead of throwing.

### Not changed

- A `forceResolveSession` during a live close whose settle then fails: the close reopens the session
  (funds first, as before), so the daily limit can still be double-credited in that case. The EVM
  half of the force-resolve race is unchanged too.
- `recoverEscrow` still caps each call, not the total: after a controller forces a session whose
  settle never ran, repeated calls can recover part of the merchant's share.
- Sessions from before 2.17.2 that rest `#expired` after being settled: re-closing one still reopens
  it, so leave them to the 24 h GC.
- A rejected or trapped sweep self-call can't be induced in a test, so that revert is covered by
  review only; the sweep carrying on past a close that fails mid-close is tested.

## v2.17.2 — 2026-10-04

Patch — **a session the expiry sweep closed can no longer be reopened by closing it again.**
Reported by EngramX. No API, type or `PaymentResult` change.

### Fixed

- **A re-close reopened a settled ICP session.** The expiry sweep marks an idle session `#expired`
  and closes it (settle + refund), and a successful ICP close left it `#expired` again. The re-close
  guard refuses only `#closed` and `#closing`, so a later `closeSession` by the payer or a
  controller's `forceCloseSession` got through. Its settle then failed on the drained escrow and
  reverted the session to `#open`. After that the sweep retried it every tick, it was never
  garbage-collected, the expiry timer never disarmed, and it held the payer's session slot. No money
  moved twice, because each ICP escrow is per-session.
- **The fix is S-3 for ICP:** a successful ICP close now ends `#closed`, as a successful EVM close
  already does, so the existing guard refuses any re-close ("Session already closed …") before any
  ledger call. `#expired` now only means the sweep has marked a session and its close has not
  finished, so a session left there (say, by a sweep close that never ran) still closes normally.
- **Visible change:** sessions the sweep settled on the ICP rail now read `#closed`, not `#expired`
  (in `getSession` and in the `health()` session counts), matching EVM.
- **Not covered:** sessions settled by an earlier version stay `#expired` until the 24h GC removes
  them. Re-closing one in that window still reopens it, and a reopened session (including any an
  earlier version already reopened) loops in the sweep as before, with no library method to end
  it. So after upgrading, do not re-close sessions settled before the upgrade. EngramX found the
  bug on the interpreter; it has not been seen live.
- **A separate, pre-existing path to the same loop** remains in consumers that expose
  `recoverEscrow`: it accepts a session whose close is still in flight, and a recovery that lands
  mid-close makes the settle fail and reopen the session. Not changed here.
- Tested on a replica (I4): the sweep's close ends `#closed`, not `#expired`; the payer's and the
  controller's re-close are then refused without reopening it, and the payer's balance is unchanged.

## v2.17.1 — 2026-09-30

Patch — **`@ic402/mcp` installs from npm again.** No library behaviour change.

### Fixed

- **Every `@ic402/mcp` from 2.5.2 to 2.17.0 was uninstallable.** Each one declared
  `"@ic402/client": "workspace:*"` (pnpm's workspace protocol), so `npm install -g @ic402/mcp` (as
  `docs/mcp-install.md` says) failed with `EUNSUPPORTEDPROTOCOL`. `release.yml` published with
  `npm publish <dir>`, which does not rewrite `workspace:`. It now packs both packages with pnpm,
  which does, and publishes the mcp tarball. The new `scripts/check-npm-pack.sh` fails if a packed
  manifest still names a `workspace:` version, then installs both tarballs together with npm. It
  runs in CI (`build-integrations`) and again right before publishing. Reported by EngramX.
- **`openSession`'s `signer` is typed required**, matching the runtime, which has thrown without one
  since 2.17.0. TypeScript callers that omitted it now fail at compile time instead of at runtime.
- **Two compiler warnings in `Sessions.mo`** from 2.17.0's small-order key check (a `Nat`
  subtraction the compiler could not prove safe) are gone. Library code builds warning-free again.

### Changed

- **The EngramX canary type-checks instead of running EngramX's test suite.** Its full `mops test`
  got the runner killed on every run since 2026-08-14, whatever ic402 changed, so the gate was dark.
  It now runs `moc --check` on every EngramX actor against ic402 HEAD, which catches the API and
  type breaks the canary exists for.

## v2.17.0 — 2026-09-30

Additive — **session calls are authenticated by the IC, not by the canister.** The per-session
Ed25519 key becomes the caller: `consumeVoucherFrom(msg.caller, voucher)` accepts a voucher on
session state, sequence, amount and policy when the caller is that key's self-authenticating
principal, with no signature check — ~8.3M cycles a voucher instead of ~415M (40 vouchers through
`@ic402/client`, the 2.16.1 method). Candid, `Voucher`, `Stable*` types, `example.did` and
`STABLE_SCHEMA_VERSION` (1) are unchanged.

### Added

- `Gateway`/`Sessions.consumeVoucherFrom` and one knob, `setSignedVoucherFallback` (default on;
  transient, re-apply at init). **With the fallback on the exposure is exactly today's**: older
  clients keep the signed path, and anyone who knows an open session id can still make the
  canister run the ~415M-cycle check and spend the payer's per-minute rate slot. Off, only the
  session key can spend a session, and bare `consumeVoucher` (now deprecated) refuses every
  voucher. **Consumers should turn it off once their clients call as the session key.** A
  small-order session key is refused at open and never trusted as the caller (the IC's ingress
  check is cofactored, so anyone can sign as one); the SDK's `openSession` now requires a signer
  (without one it registered an all-zero key).
- `Gateway.settleFrom`; `Policy.precheckCharge` / `recordRateHit`; SDK `VoucherSigner.actorFactory`
  (vouchers stay signed, so new clients work against older canisters); the MCP calls as the key.
- SDK approvals are exactly `amount + icrc1_fee()` (a session: the deposit the canister pulls,
  `min(suggestedDeposit, maxDeposit)`), expiring in 5 minutes (+100_000 if the ledger actor lacks
  `icrc1_fee`); `approvalFeeBuffer` now replaces the fee query (same amount). Two payments in
  flight from one identity may fail with `InsufficientAllowance`, never double-pay. A clock over
  5 minutes behind the ledger gets `Expired` on approve.
- Example: fallback off, and its Candid session/settle paths use the caller-bound methods; older
  SDK/MCP/demo builds get `#invalidSignature`, with a message naming the cause.

### Fixed

- **ICP allowance theft on Candid paths**: `signature.sender` was only claimed; `settleFrom`
  requires the caller to be the sender. HTTP paths have no caller and stay allowance-authenticated,
  so on a canister serving both, a standing allowance is still spendable: payers must not keep one.
- **AUDIT I6, both rails**: a settle recorded a rate hit for a claimed sender before the transfer
  confirmed; it now checks read-only and records only on `#Ok` / `#confirmed`. The rate slot
  only: a claimed sender's daily reservation is still held while the transfer is in flight.
- **A fully consumed ICP session could not close** (the settle needed `consumed + fee` from an
  escrow holding `deposited`). The close queries the fee first — failing closed, no 10_000 guess —
  and settles `min(consumed, deposited − fee)`; the receipt's `amount` is what was settled.

## v2.16.1 — 2026-09-29

Patch — **Ed25519 verification agrees with RFC 8032.** `Identity.verifyCallerEd25519` and the
voucher check in `Sessions.consumeVoucher` keep their names and types,
`selfAuthPrincipalOfEd25519` is untouched, `STABLE_SCHEMA_VERSION` stays 1, and no stable type
changed.

Both checks used `mo:ed25519` 0.1.0, which refused about 1 valid signature in 32, accepted a
malleated partner of each one it refused, and allocated ~245 MB per check. ic402 now verifies with
a vendored copy of ic-agent-mo's Ed25519 (`src/ic402/Ed25519.mo`, Apache-2.0, byte-identical to
upstream below an attribution header), and the `mo:ed25519` dependency is gone.

### Fixed

- **Valid signatures were refused.** In 0.1.0, `bitrightshift(0, n)` returns 2^n − 1 instead of
  0 (`utils.mo:670`, `let bit = if (num > 0) false else true`). Its base-point multiply walks
  8-bit windows; when the window carried into the top is zero, the bug turns it into 255 and
  adds −2^256·B. The result: every valid signature with S < 2^247 was refused, plus a thin band
  in [2^247, 2^247 + 2^240) where no carry crosses byte 29. Over 400,000 uniformly drawn S that
  is 3.10% — about 1 in 32, with the band adding about 1 in 7,100.
- **Some invalid signatures were accepted.** For each refused (R, S), 0.1.0 accepted
  (R, (S + 2^256) mod L) — a second "signature" on the same message, which OpenSSL and noble
  reject. Confirmed 5 of 5 inside a deployed canister. ic402's own vouchers could not be
  replayed this way (`sequence` and `cumulativeAmount` are signed and must strictly increase),
  but **a consumer that keys replay or dedup on signature bytes** should check what the old
  verifier let in.
- **A bad R encoding trapped** instead of returning false (the "KNOWN SHARP EDGE" in
  `verifyCallerEd25519`'s doc). Every malformed input now returns false.
- **Cost.** One 0.1.0 verification allocated 244.7 MB and ran 4.96 billion instructions, just
  under the 5 billion query limit. A fresh canister went from 8.1 MB to 337 MB after one call.
  The vendored verifier allocates 8.4 MB and runs ~200–206 million, depending on the signature.

### Changed

- **The policy is stated and pinned**: RFC 8032, strict and cofactorless. A and R must be
  canonical encodings (y < p, the point exists, no negative zero); S must be below L; k is
  hashed over the original bytes; and small-order public keys are refused. That is stricter
  than OpenSSL on small-order and non-canonical public keys (ed25519-speccheck cases 0, 1 and
  11) and agrees with it everywhere else. Why each case falls where it does is written beside it
  in `test/ed25519.test.mo`.
- **`mo:ed25519` removed from `mops.toml`.** `HttpHandler`'s hex encoder, the only other use,
  is now local and byte-identical over all 256 byte values, so the `ic402Nonce` wire format is
  unchanged.
- **Example canister:** two diagnostic queries, `ed25519Verify` and `ed25519VerifyCost`
  (additive to `example.did` and the client IDL).

### Docs

- **The voucher cost was wrong.** `docs/costs-and-rails.md` put a session voucher at under 1M
  cycles, and the README called sessions "5,000× cheaper". Measured for this release with the
  doc's own method (40 vouchers through `@ic402/client`, local replica, 13-node pricing), one
  voucher costs ~415M cycles, ~96% of it the signature check. Wasm64 execution is billed at 2
  cycles per instruction, so that is the mainnet price on a 13-node subnet too. Under 0.1.0 it
  was ~10B. The 5,000× was never cycles: it counted 10,000 per-call settlements against a
  session's 2, and a session is really a fixed few transactions (deposit, settle, refund; plus
  the payer's approve on ICP). In cycles, at 10,000 calls an EVM session is ~40× cheaper than
  per-call EVM settlement locally (the ceiling; fewer calls save less), and more on mainnet.
  On ICP a voucher can cost the canister more than a per-call settle; there, a session saves
  the payer's per-transfer ledger fees. `docs/costs-and-rails.md` has the numbers and the
  pricing floor: price session calls above ~$0.0006, the voucher check's cost, plus the legs
  spread over the calls. The README, getting-started, mcp-install, the client README and the
  demo drop the 5,000× and two-transaction claims, and the README, the client README and the
  demo now state the voucher cost.

### Notes

- **The memory plateau is the GC, not the verifier.** Repeated verifications on the example
  canister grow its memory ~8.4 MB per call until the first collection (~67 MB of heap), after
  which it sits at 202.75 MB. A no-crypto probe allocating 8.4 MB per call follows the same
  curve to the same 202.75 MB, and one allocating 1 MB per call gets there at call 60 instead of
  call 8. That is Motoko's incremental GC; less garbage per call only delays it.
- **If you import `mo:ed25519` yourself**, it has the same defects: its `verify` refuses and
  accepts as above, and its `sign` and `getPublicKey` are wrong about 1 time in 32 for the same
  reason (3.14% of seeds get a wrong public key). Upstream has only ever published 0.1.0.
- ic402 calls only `Ed25519.verify`. The vendored file also carries upstream's `sign` and
  `publicKey`, which ic402's tests use; they are reachable as `mo:ic402/Ed25519` but are not part
  of ic402's API, and they are not constant-time (nor was the package they replace).

### Testing

- `test/ed25519.test.mo` (58 tests, `mops test`): the RFC 8032 §7.1 vectors (verified, and
  reproduced by the vendored signer), all 151 Wycheproof vectors by flag, the 12
  ed25519-speccheck cases with the policy per case, 13 regression vectors from 0.1.0, three
  policy vectors that each pin one check (y < p, and each half of the final comparison), the
  small-order universal forgery, and totality over malformed lengths and encodings.
- `test/ed25519.test.ts`, inside the deployed canister: 2,000 fresh OpenSSL key/message pairs
  (messages 0–300 bytes) plus one corruption of each must match OpenSSL; the run must reach
  S < 2^247. It also runs Wycheproof, speccheck (where ic402 is stricter than OpenSSL, so the
  differential cannot see it), the policy vectors, the regressions, and a budget of 400 M
  instructions and 16 MB per verify. About 5 minutes on a local replica.
- CI: an Ed25519 step in `test-integration`, and a new `ed25519-fixtures-sync` job that pins the
  vendored Wycheproof and speccheck files to their upstream bytes and fails if `Vectors.mo` is
  stale. Provenance: `test/fixtures/ed25519/README.md`.
- Mutation-verified, every new test failing at least once against a mutant that compiles:
  - All 58 Motoko tests, each run in isolation.
  - The seven canister tests, against eight mutants built into the example and reinstalled:
    - refusing S < 2^247 fails the differential and the regressions;
    - accepting whatever decodes fails the differential's invalid direction;
    - dropping S < L fails Wycheproof;
    - dropping the small-order check fails speccheck;
    - dropping y < p fails the policy vectors;
    - 16 MB of extra allocation, or three times the multiply, fails the budget;
    - an unreachable canister fails the gate under `IC402_REQUIRE_REPLICA=1`.
- `mops test` is about 6× faster, 45 s to 8 s, because the old tests signed with 0.1.0.

## v2.16.0 — 2026-09-22

Minor — **the derivation path reaches every deriving site.** Additive: every current caller
compiles and behaves exactly as in 2.15.0, `STABLE_SCHEMA_VERSION` stays 1, and no config
record or stable type gained a field.

2.15.0 gave `EvmSigner` a per-instance path, but four other sites still derived from the
empty path on the same key name — so a consumer moving its signer to a labelled path would
sign from an address nothing funds, while deposits and outbound settlement kept using the
unlabelled one. `grep -rn "derivation_path = \[\]" src/ic402/` now returns nothing.

### Added

- **`EvmSenderAt(ecdsaKeyName, evmRpcCanister, derivationPath)`** → `{ #ok : Sender; #err : Text }`.
  Both of EvmSender's deriving sites read the instance path; its cache was already
  per-instance. `EvmSender(keyName, rpc)` is unchanged and stays a type.
- **`Identity.getPublicKeyAt(keyName, derivationPath)`** → `async { #ok : Blob; #err : Text }`,
  beside the unchanged `getPublicKey(keyName)`.
- **`Gateway.setEvmDerivationPath(derivationPath)`** → `{ #ok; #err : Text }`, moving the
  gateway's outbound sender AND its inbound recipient onto one path, plus
  **`Gateway.getEvmDerivationPath()`**. **Not persisted** — re-apply after every upgrade in
  the same init path that calls `loadStable`, exactly as `setEvmChains` requires.
- **`Gateway.deriveEvmRecipientAt(ecdsaKeyName, derivationPath)`** → `async { #ok; #err : Text }`,
  beside the unchanged `deriveEvmRecipient(ecdsaKeyName)`. It refuses a path the gateway's
  sender is not already on, and refuses to report success for a recipient derived under a
  different path.
- **`Ic402.EvmSender`** is now exported from `lib.mo` — it was reachable only by direct module
  import before.
- **A CI gate**, `scripts/check-derivation-paths.sh`, failing the build if a hardcoded empty
  derivation path reappears under `src/ic402/`. Its allowlist is empty and meant to stay
  empty; `--self-test` proves it still catches a planted violation, including a whitespace
  variant, rather than having decayed into a green no-op.

### Fixed

- **The Gateway's own outbound sender could not follow the path.** `evmSenderInst` was a
  `let` on the empty path with no setter, and it is the signer behind every outbound money
  path (Sessions, the EIP-3009 relay, `sendErc20Transfer`, `sendErc20TransferConfirmed`,
  `confirmEvmTransaction`). A labelled recipient would have been funded at one address and
  spent from another — the exact split this release exists to prevent, inside the Gateway
  itself. It is now a `var` rebuilt by `setEvmDerivationPath`, and `deriveEvmRecipient`
  derives under the gateway's current path (default `[]`, so unchanged by default).
- **`deriveEvmRecipientAt` reported success for a path it had not applied.** The
  already-derived branch returned a bare `#ok`. Since `evmRecipient` is persisted, every
  gateway upgraded from ≤2.15.0 has that slot filled at the empty path, so a consumer asking
  for a labelled one would read `#ok` as "applied", publish one address and sign for another.
  It now confirms the existing recipient is the one the requested path derives, and says
  plainly when it is not.
- **`Identity`'s public-key cache was a single unkeyed slot**, so `getPublicKey(keyNameA)`
  followed by `getPublicKey(keyNameB)` returned A's key. It is now keyed by
  `(keyName, derivationPath)`. Pre-existing, and adding a path would have widened the same
  confusion to paths.

### Notes

- **THE SAME PATH EVERYWHERE.** A gateway's recipient, the `EvmSigner` that spends from it
  and the `EvmSender` that settles outbound must all be derived under one path. They are one
  address; deriving them apart splits funds from the ability to spend them.
- **A published path is permanent.** These addresses are given to payers and cannot move, so
  choose before publishing. `Gateway.evmRecipient` is a single persisted slot
  (`StableGatewayState.evmRecipient`) and the first successful derivation wins, which is what
  enforces that.
- **No config record gained a field.** A consumer structurally inlines this library's
  `Stable*State` types into its own stable signature, so a new field on anything that can
  reach stable state would fail the consumer's stable-compatibility gate. The path is carried
  as an argument throughout, exactly as 2.15.0 did.
- Bounds everywhere are `SchnorrSigner.validateDerivationPath` — reused, never restated; a
  unit test asserts each `…At` form accepts and refuses at exactly the counts SchnorrSigner
  does.
- `Utils.derivationCacheKey` is now the single injective path encoder, used by both
  `SchnorrSigner.cacheKey` and Identity's cache. Its prefix is length-prefixed: without that,
  `("a", ["b"])` and `("a/62", [])` collide — a latent edge for today's key names, caught by
  its own test.

### Testing

- 13 Motoko unit tests over construction, validation, bound-sharing and the cache-key
  encoding.
- 15 replica-backed tests (`test/derivation-paths.test.ts`), including the cross-module one:
  `EvmSigner`, `EvmSender` and the identity under the same path yield the **same** address,
  with a companion test proving that agreement is not vacuous.
- Mutation-verified: reverting the four sites fails 5 tests and trips the new CI gate
  (exit 1); un-keying Identity's cache fails 6; removing both Gateway path guards fails the
  silent-success test. The two guards are mutually redundant — each alone still produces the
  right answer, which is why only removing both is caught.
- **Not covered:** the Gateway recipient's labelled-path derivation on a FRESH canister — its
  slot is persisted and `setup:local` fills it at the default path. Also not exercised is the
  address-comparison branch, which is reachable only after an upgrade where the consumer
  forgot to re-apply `setEvmDerivationPath`; the harness cannot upgrade in place. What IS
  proven on a replica: the gateway's own sender and its published recipient are one address,
  a path that cannot be applied is refused rather than reported as success, and the setter
  refuses to move a gateway whose recipient already exists.

## v2.15.0 — 2026-09-22

Minor — **`EvmSigner` accepts a derivation path.** Additive: every current caller compiles
and behaves exactly as in 2.14.0, `STABLE_SCHEMA_VERSION` stays 1, and no stable state is
touched.

Threshold Schnorr has taken a path per call since 2.14.0; EvmSigner took none at all — it
passed `derivation_path = []` at all four of its management-canister sites, so a deployment
labelling its keys could not label the EVM one. It now takes a path **per instance**, not
per call, because an EVM address is published to payers and must never move.

### Added

- **`EvmSignerAt(ecdsaKeyName, derivationPath)`** → `{ #ok : Signer; #err : Text }`. Validates
  the path with `SchnorrSigner.validateDerivationPath` — the same
  `MAX_DERIVATION_PATH_ELEMENTS` (254) and `MAX_DERIVATION_PATH_BYTES` (8_192) bounds,
  reused rather than restated so the two signers cannot drift apart on what a valid path is.
  It **returns `#err`; it never traps.**
- **`EvmSigner(ecdsaKeyName)` is unchanged** — same name, same one-argument call, same empty
  path, same addresses. `EvmSigner` also remains a *type*, so existing annotations still
  resolve.
- Example endpoints `evmAddressAt` / `signTypedDataAt` showing the labelled-path form.

### Notes

- **The path is fixed at construction.** No setter, no per-call override: an address derived
  under a path gets published, and letting it move afterwards would strand funds sent to the
  old one. Choose before publishing an address.
- The empty path is a **default, not a decision** — it is what the library did before paths
  existed, kept so no caller has to change. A deployment running more than one purpose off
  one key name should give each its own labelled path.
- **Why factories rather than a second constructor.** Motoko has neither constructor
  overloading (two classes of one name is `M0051`) nor a constructor that can return a
  `Result` (`M0134`). Both forms are therefore functions over one class, `Signer`, which is
  what keeps the one-argument spelling working while still allowing a refusal.
- The public-key/address cache is per-instance class state, so two signers on different paths
  cannot share an entry — no cache-key change was needed.

### Testing

- 6 Motoko unit tests over construction and validation, including a drift test asserting
  `EvmSignerAt` accepts and refuses at exactly the counts `SchnorrSigner` does.
- 9 replica-backed tests (`test/evmsigner-path.test.ts`): two paths on one key name derive
  different addresses; each signature **recovers independently** (via `@noble/curves`, from
  the returned digest and r/s/v — not the canister's own `signer` field) to that path's own
  address; the one-argument form and the explicit `[]` form derive the **same** address; and
  over-limit paths are refused in-library.
- Mutation-verified: reverting the four sites to `derivation_path = []` fails exactly the
  three path-dependence tests, and replacing the shared bound with a private looser one fails
  the drift test.

## v2.14.0 — 2026-09-20

Minor — **threshold Schnorr signing** (Ed25519 and BIP340-secp256k1) beside the existing
threshold ECDSA. Purely additive: no existing type, method or behaviour changes, the stable
contract is untouched (`STABLE_SCHEMA_VERSION` stays 1), and `EvmSigner`'s hardcoded empty
derivation path is deliberately left exactly as it was. No wire/HTTP or `@ic402/client`
breaking changes.

### Added

- **`SchnorrSigner`** (`src/ic402/SchnorrSigner.mo`, exported as `Ic402.SchnorrSigner`) —
  `getPublicKey(algorithm, path)`, `sign(algorithm, path, message, aux)`,
  `getBip340XOnlyKey(path)` and `signatureCost(algorithm)`. A low-level primitive by design:
  no policy, no spend caps, no audit logging, no state beyond a transient public-key cache,
  and nothing in stable memory. The calling canister wraps it and enforces its own rule that
  no signature leaves without a policy check and a log entry.
- **The derivation path is a required parameter, never a default.** A published address or key
  becomes permanent the moment a customer uses it, so the choice belongs to the caller.
- **No internal retry, deliberately.** The interface spec warns that a `SYS_UNKNOWN` or
  `CANISTER_ERROR` reject does not mean no signature was produced — so a retry could hand out
  two signatures for one authorised request. One call in, at most one signature out.
- **Fail-closed validation before the call is built**: empty and oversized messages, overlong
  derivation paths, `#bip341` aux on `#ed25519`, and a `merkle_root_hash` that is neither empty
  nor 32 bytes. This matters because oversized arguments *trap* the calling canister at
  `ic0.call_data_append` rather than rejecting, and a trap cannot be caught.
- **Example endpoints** `schnorrPublicKey` / `schnorrSign` in `example/main.mo`, controller-gated,
  showing both algorithms and the BIP341 path.
- **New CI step** `Schnorr suite (replica-enforced)` in the `test-integration` job, gated by
  `IC402_REQUIRE_SCHNORR=1`.

### Notes

- **Key names are shared with ECDSA** — `dfx_test_key`, `test_key_1`, `key_1`. The algorithm is
  a separate field of `key_id`, so one name serves both Schnorr variants.
- **`bip340secp256k1` returns a 33-byte SEC1-compressed key**; BIP340 verification needs the
  32-byte x-only form. With `aux = #bip341` the signature verifies against the **tweaked** output
  key, not the returned `internal_pubkey`.
- **Ed25519 threshold signatures are non-deterministic** — verify, never compare bytes.
- **Both algorithms sign the message whole**, not a digest (unlike `sign_with_ecdsa`'s mandatory
  32-byte `message_hash`).
- Cost per signature is set by the subnet the *key* lives on, not the caller's, and is identical
  for both algorithms and for ECDSA: 10,000,000,000 cycles for `test_key_1`,
  26,153,846,153 for `key_1`. `schnorr_public_key` is free. There is no cycle constant in
  `mo:ic` to read — `Cost.signWithSchnorr` resolves it from the replica at call time, which is
  what `signatureCost` surfaces.
- **A caller may supply at most 254 derivation-path elements, not 255.** The spec's "at most
  255" is the whole extended-BIP32 path and the IC prepends the calling canister's id. Verified
  against a live replica: 254 succeeds, 255 is rejected by the management canister's Candid
  decoder. `MAX_DERIVATION_PATH_ELEMENTS` is 254 so that value fails closed in-library rather
  than on a wasted cross-subnet round trip.

### Testing

- 24 Motoko unit tests over the pure validation and encoding helpers, including a literal pin
  on the bound constants (every other bound test is written in terms of them, so a wrong
  constant would stay green — which is exactly how the 254 bound below was caught). Signing itself is
  **not unit-testable**: the `mops test` interpreter has no `costSignWithSchnorr` primitive, and
  `mo:ic/Call` does not type-check under `-wasi-system-api` — so every signing path is proven
  against a real replica instead.
- 16 replica-backed tests (`test/schnorr.test.ts`) signing with both algorithms and verifying each
  signature with `@noble/curves`, including a BIP341-tweaked signature checked against the
  independently recomputed tweaked key — and asserted *not* to verify against the untweaked key,
  so the test would fail if the aux were silently dropped.
- Adds `@noble/curves` 2.2.0 as a root devDependency (BIP340/BIP341 verification; it was only
  reachable transitively before).

### Not included (follow-ups)

HTTP message signatures, SSH certificates, JWS, Solana/Bitcoin transaction builders. No EngramX
changes.

## v2.13.1 — 2026-08-05

Patch — **colon-namespaced struct names** (consumer-reported, blocking a real venue). 2.13.0's
identifier rule (`[A-Za-z_][A-Za-z0-9_]*`) refused struct names like Hyperliquid's
`HyperliquidTransaction:Withdraw`, whose colon is part of the primaryType, participates in the
typeHash, and is verified against exactly that digest by the venue's servers. The rule was
stricter than the ecosystem: the reporting consumer verified ethers v5/v6, viem, alloy, and
Turnkey all accept the colon; a name the encoder refuses is a digest no one can produce through
it — a functional block, not a safety margin.

### Fixed

- **Struct names now admit one colon-namespaced segment pair**:
  `[A-Za-z_][A-Za-z0-9_]*(:[A-Za-z_][A-Za-z0-9_]*)?`. The colon is safe in *our* emitter
  because it is not structural in the canonical type-string grammar (only `(` `)` `,` and
  space are), so `encodeTypeString` stays injective — the struct name is everything before the
  first `(`. **Field names stay strict** single identifiers; empty segments, multiple colons,
  and bare `:` remain rejected; `EIP712Domain` stays reserved. Implementation note: Motoko's
  `Text.split("")` yields an *empty* iterator, so the empty-name rejection needed an explicit
  lower bound — caught during implementation by the existing injection suite's
  `typeHashOf("")` pin, which is exactly what that pin is for.
- **Golden vectors over the venue's real type** (viem 2.55.2): `HyperliquidTransaction:Withdraw`
  with its actual fields (`string`×3 + `uint64`), pinned at type-string, typeHash, hashStruct,
  and full-digest level under the real domain (`HyperliquidSignTransaction`/`1`/42161/zero
  address).
- **Anti-normalization pin**, from the reporter's own hazard note: `:` is a scope separator in
  many policy DSLs, so any downstream matcher that splits on it would silently alias
  `HyperliquidTransaction:Withdraw` to `Withdraw`. A test asserts the name round-trips *whole*
  and that the namespaced and bare forms commit to **different** hashes — with the bare form's
  hash also pinned to viem, so a normalizing encoder can't hide behind producing the suffix's
  (valid) digest. ic402 never *normalizes* on `:` (validation splits, encoding never does);
  the pin makes that a contract.

### Hardened by this release's adversarial review (pre-release, all fixed)

- **viem does not hash colon names context-free** — the review disproved this patch's own
  initial rationale ("viem hashes the colon literally"). viem's dependency lookup truncates
  the primaryType at the first non-word character, so its digest for a colon name is
  **contingent on the verifier's types map**: with a singleton map (the venue's real shape)
  viem/ethers/ic402 agree byte-for-byte, but a verifier whose map *also* holds a struct named
  exactly the first segment gets a silently different viem digest (ethers hard-throws
  "ambiguous" on the same map). Strictly fail-closed — ic402's single-group type string can
  never equal viem's two-group one — but documented now in `isStructName`'s comment and
  **pinned as a drift alarm** in `packages/client/test/eip712-colon-interop.test.ts` (if viem
  changes this behaviour, that suite says so). Policy layers should refuse to register a
  namespaced type whose first segment names another registered type.
- **`EIP712Domain:*` is rejected outright**: viem injects an `EIP712Domain` entry into every
  types map, so for this prefix the truncated lookup *always* resolves and viem permanently
  disagrees with ethers (and us) on the digest — verified empirically, no verifier
  configuration avoids it.
- **The atomic-shadowing rule no longer misfires on colon names.** It ran against the full
  name, refusing `intents:Swap`/`uint256:Foo` with an error claiming standard tooling rejects
  them — disproved on the full wallet path (viem 2.55.2 and ethers 6.17.0 sign *and verify*
  both, singleton maps). No solidity atomic contains `:`, and these names can only ever be the
  primaryType here, so nothing can shadow: colon names are now exempt; bare-name behaviour is
  unchanged.
- **Character-level injection pins for both colon segments.** Two natural `isStructName`
  implementations (checking segments only for non-emptiness) passed the entire suite while
  accepting `Order:Safe(Evil e)Evil` — whose type string ethers reads as a *nested* struct
  definition, verbatim the valid-signature-over-an-unreviewed-struct failure the module
  exists to prevent. Both mutants now die on dedicated tests covering structural characters
  in either segment, digit-leading second segments, and a positive digits/underscore
  round-trip.

## v2.13.0 — 2026-08-04

Minor release — **field-driven EIP-712 encoding** (consumer-requested). `Eip712` gains a generic
struct-encoding path beside the hardcoded `TransferWithAuthorization`: given an ordered
`[(fieldName, solidityType)]` and matching values, it produces the canonical type string, its
typeHash, `encodeData`, and `hashStruct` — the missing construction half of the advice
`EvmSigner.signTypedData` has always given ("construct the structHash yourself from validated
parameters"), which was previously unfollowable for any struct but EIP-3009's. Additive public
API ⇒ minor; no interface, stable, or existing-signature change.

### Added

- **`Eip712.encodeTypeString` / `typeHashOf` / `encodeData` / `hashStructOf`** +
  **`Eip712.FieldValue`** (`#address`/`#uint`/`#bool`/`#string`/`#bytes`/`#fixedBytes`).
  Trap-free — every entry point returns `#err` on invalid input, matching the L19/L28 pattern on
  the verification paths.
  - **Deliberately flat and atomic**: `address`, `bool`, `string`, `bytes`, `bytes1..32`,
    `uint8..256`. No arrays, no nested structs, no `int*` — those drag in transitive type
    collection and alphabetical dependency sorting, whose failure mode is a **valid signature
    over the wrong struct**; they are rejected at the boundary with an error saying the
    exclusion is deliberate. Also rejected: bare `uint` (EIP-712 forbids the alias),
    zero-padded widths (`uint08` — two spellings must not alias one type), duplicate field
    names, empty field lists, and — security-critical — **non-identifier struct/field names**,
    which would otherwise inject syntax into the canonical type string and alias a different
    type than the one an auditor reviewed.
  - Values are validated against the *declared* type: `uintN` range-checked, `bytesN`
    length-exact (no implicit value padding), addresses 0x-prefixed 20-byte hex, no tag
    coercion.
  - **Audit note** (for layers rendering "what am I signing"): `string`/`bytes` words in
    `encodeData` are keccak256 *digests* of the contents per spec — render human-readable views
    from the `FieldValue`s, never by decoding `encodeData`.
- Golden vectors (`test/eip712.test.mo`, viem 2.55.2 as the independent oracle): the generic
  path over `TransferWithAuthorization`'s field list reproduces the **hardcoded mainnet-proven
  constant** byte-for-byte (typeHash and hashStruct); an all-types struct (unicode string,
  dynamic bytes, `bytes1`/`bytes32`, `uint8` at 255, >64-bit `uint256`) pinned at type-string,
  typeHash, hashStruct, **and full-digest** level through the existing
  `domainSeparator`/`digest`; empty-string/empty-bytes/false/zero edge vector; a rejection
  table covering every excluded type, injection attempt, and conformance violation.
  Mutation-verified: flipping the `bytesN` pad direction and dropping the typeHash prefix each
  break exactly the pinning vectors.
- `EvmSigner.signTypedData` doc now names `Eip712.hashStructOf` as the sanctioned construction
  path. Mechanism/policy split preserved: type registration, per-field rules, cool-offs, and
  audit rendering remain consumer-side.

### Hardened by this release's adversarial review (pre-release, all fixed)

- **Struct-NAME namespace was unvalidated** — the identifier check closed type-*string*
  injection but accepted names with reserved protocol semantics:
  - `"EIP712Domain"` — standard implementations sign the **domain only** for that primaryType
    (viem drops the struct part of the digest entirely), so a digest built from it is
    unverifiable everywhere; worse, its `hashStruct` over the standard domain fields is a
    **byte-identical domain separator**, inviting parameter-swap confusion in
    `digest(domainSep, structHash)`. Now rejected as reserved.
  - Atomic-shadowing names (`"address"`, `"uint256"`, `"string"`, …) — in an EIP-712 types map
    they shadow the atomic type; viem refuses them (`InvalidStructTypeError`) the moment the
    name is referenced, which the domain's own `string`/`uint256`/`address` fields always do.
    A signature over such a struct is unverifiable by standard tooling. Now rejected, matching
    viem's rule exactly (exact `address`/`bool`/`string`, or any `uint`/`bytes`/`int` prefix).
- **Field-count cap (64)** — the duplicate-name scan is O(n²) and the module promises never to
  trap on relayed input; an uncapped multi-thousand-field list was measured crossing the IC
  per-message instruction limit (a trap also rolls back the SEC-1 admission-token decrement —
  the metering bypass the L19/L28 comment guards against). Real structs have a handful of
  fields.
- **Array rejections now tell the truth**: `uint256[]` previously reported *"invalid uint
  width"* — a false diagnosis (256 is valid; the *array* is the exclusion) that would send an
  integrator retrying `uint128[]`/`uint64[]`… without ever learning arrays are categorically
  out. The `[` check now runs first, and an `int`-prefixed identifier (`intent`) is reported
  as an unsupported nested type, not a signed integer.
- **Three surviving mutations pinned**: dropping the `uintN % 8` rule, an off-by-one in the
  identifier digit rule, and swapping underscore→comma in the identifier alphabet each passed
  the entire pre-review suite (viem hashes `uint12` happily, masking the first from golden
  vectors). Each now fails exactly one added test.

## v2.12.0 — 2026-08-02

Minor release — **`payTo`/`recipient` now carries a configured subaccount** (ICRC-1 textual
account encoding). Reported by a consumer with a mainnet-confirmed test vector. Additive public
API (`Ic402.icrc1AccountText`, plus `Utils.crc32`) ⇒ minor; no interface, stable, or
existing-signature change.

### Fixed

- **The advertised ICP `recipient` (x402 `payTo`) and receipt stamps dropped a configured
  `recipient.subaccount`.** `recipientText()` rendered only the owner principal while settlement
  (`recipientAccount()`, an ICRC-2 `transfer_from` pull) honoured the subaccount — so with a
  non-null subaccount, every 402 challenge and every receipt named an account (owner, default
  subaccount) that funds never touched. Now both render the **ICRC-1 textual encoding**:
  `<owner>` for a null/all-zero subaccount — **byte-identical to the previous output**, so every
  default-subaccount config (effectively all working configs today) sees no change — and
  `<owner>-<crc32-base32-checksum>.<subaccount-hex, leading zeros stripped>` otherwise.
- **ICP session-close receipts had the same defect one rail over** (found by this release's
  adversarial review, not the original report): `closeSessionInternal` settles consumed funds to
  `recipientAccount()` but stamped the receipt with the consumer-supplied `intent.recipient`
  display text. The ICP close receipt now stamps the ICRC-1 encoding of the account funds
  actually settled into. The **EVM** close receipt keeps `session.recipient` — there the text
  *is* the transfer target the canister signed for. Residual, deliberately out of library scope:
  `SessionIntent.recipient` itself is consumer-built and advertised verbatim — build it with the
  newly exported `Ic402.icrc1AccountText` (the example's `requestSession` now does).
  - **Scope, precisely**: no ICP fund movement is ever *directed* by this text — ic402's ICP
    rail settles by ICRC-2 pull and sessions escrow to canister subaccounts — so this was an
    advertisement/receipt **integrity** defect, not a misdelivery path. But external tooling
    reconciling against `payTo`, receipt audits, and any payer resolving the advertised account
    got the wrong answer whenever a subaccount was configured. A client that pushed funds to
    the (wrong) advertised account now fails **closed** (the textual form doesn't parse as a
    bare principal) instead of open.
  - **Spec position**: x402 defines `payTo` as scheme/network-specific text; the `icp:*`
    mapping is ic402's to define and is now documented in `docs/x402-compliance.md` as the
    ICRC-1 textual encoding.

### Added

- **`Ic402.icrc1AccountText(owner, subaccount)`** (exported via `lib.mo`) — pure ICRC-1 textual
  account encoder (handles the null/all-zero collapse the spec requires; left-pads short blobs,
  which are already ledger-invalid for transfers, for display). Exported because consumers build
  `SessionIntent.recipient` themselves and previously had no correct encoder to reach for.
  `Utils.crc32` — IEEE CRC-32, required by the encoding.
- **Wiring pin** (`test/gateway.test.mo`): a Gateway constructed with a non-null recipient
  subaccount must advertise the encoded account from `require()`. Added because the adversarial
  review demonstrated that reverting `recipientText()` to the pre-fix body passed the entire
  previous suite (every other test config uses `subaccount = null`, where old and new output are
  byte-identical). Mutation-verified: that exact revert now fails this test and only this test.
- Golden-vector tests (`test/utils.test.mo`): the reporter's **mainnet-confirmed** vector
  (verified by a real transfer landing in the encoded subaccount, cross-checked against the
  legacy 64-hex account-id), the **ICRC-1 spec's own** `-6cc627i.1` example, the CRC-32
  canonical check value `0xCBF43926`, exact-equality-with-`Principal.toText` for the
  null/all-zero collapse, and full-length/padding edge cases — all expected strings produced by
  an independent implementation (Python `zlib.crc32` + base32), per the 2.9.0 golden-vector
  methodology.

## v2.11.0 — 2026-07-31

Minor release — **self-arming expiry timers**. `startTimers()` used to arm two unconditional
60-second recurring timers for the canister's entire life. A recurring timer is billed **per
tick** — the message-execution base fee — regardless of what its callback finds, so a canister
that never opened a session or created a job still paid for 120 ticks/hour. They now run only
while there is state to sweep. Additive public API ⇒ minor; no existing signature, interface, or
stable-type change; `STABLE_SCHEMA_VERSION` stays v1, upgrade-compatible, no migration.

### Fixed

- **The two 60s sweeps no longer tick on an idle canister.** Reported with mainnet measurements
  by a consumer embedding ic402 in a per-user canister (one canister per user, so every fixed
  cost multiplies by the fleet): two independent production canisters agreeing to four
  significant figures at **4.449B cycles/hour with no user activity**, of which **~2.84B/hour
  (64%) was these two timers** — ~2T/month/canister, for callbacks that iterated an empty map
  120 times an hour. Attributed by tick count at **~23.6M cycles/tick**; the charge is the tick,
  not the body, so guarding inside the callback saves nothing.
  - **Session expiry** (`Gateway.startTimers`) is armed by the session-creating paths and
    **disarms itself** when the last session record is GC'd: **0 ticks/hour when idle**.
  - **Job expiry** (`ServiceRegistry.startTimers`) drops to a **1 tick/hour idle poll** instead
    of disarming, because its only job-creating entry point, `createJobFromReceipt`, is
    *synchronous* — and a synchronous Motoko function cannot hold the `system` capability, so it
    cannot arm a timer. The poll is the safety net; see `armExpiryTimer` below to remove even
    that latency.
  - Net: ic402's fixed cost on an idle canister goes from **121 ticks/hour to 2** (~2.86B →
    ~47M cycles/hour, ~$2.77 → ~$0.05 per canister-month). The hourly policy/grant GC is
    unchanged — it does real work.
  - **Expiry semantics are unchanged**: a session/job is still swept within 60s of its deadline
    while any exist. Nothing about settlement or refund correctness depended on the cadence (a
    close settles from the canister's own escrow with its own signature — there is no external
    deadline to miss), which is what made this safe to fix rather than fund knowingly.

### Added

- **`Gateway.sessionExpiryTimerArmed()`**, **`ServiceRegistry.expiryTimerArmed()` /
  `expiryTimerActive()`** — is the sweep ticking, and at which cadence. Steady state on an idle
  canister is `false` / `false`; `sessionExpiryTimerArmed() = true` with zero sessions is a bug.
  The example surfaces all three under `health().timers`, so a fleet operator can attribute a
  canister's fixed burn instead of guessing.
- **`ServiceRegistry.armExpiryTimer<system>()`** — call it on the job-creating path, from the
  async context your settle already runs in, and a new job's expiry starts at the working cadence
  instead of waiting for the idle poll. `example/main.mo` calls it at both call sites **before**
  `gate.settle`, not next to `createJobFromReceipt`: that keeps the arm out of the window between
  the funds moving and the job existing, so it adds no new trap surface to Option A's
  money-moved ⇒ job-exists invariant (`docs/decisions/settled-then-job-failed.md`). Arming for a
  settle that then fails is harmless — the sweep finds no work and drops back to the idle poll.
  With every call site arming, `setExpiryIdlePollSeconds(0)` gives zero idle ticks on the job
  side too.
- **Cadence knobs** (the consumer's second ask): `Gateway.setSessionExpiryIntervalSeconds<system>`,
  `ServiceRegistry.setExpiryIntervalSeconds<system>` (default 60), and
  `ServiceRegistry.setExpiryIdlePollSeconds<system>` (default 3600). Note this trade is *not*
  free the way self-arming is: expiry latency is bounded by the interval, and a stale session
  holds its slice of `maxConcurrentSessions` and of the EVM pool cap until it is closed.
- **`Gateway.armSessionExpiryTimer<system>()`** — for a consumer that drives a `Sessions`
  instance itself and restores it outside `startTimers`.
- `docs/costs-and-rails.md` §5 — the fixed per-canister idle cost, the measured tick price, the
  before/after tick table, and why the job sweep polls rather than disarming.

### Notes for consumers

- **No action required**: `startTimers()` keeps its contract (timers are running when it
  returns) and still arms **unconditionally** — deliberately, because a `persistent actor`
  re-runs its init body *before* `postupgrade` restores stable sessions, so a predicate-gated
  arm would leave exactly the canisters that DO have live sessions unswept. The first tick
  disarms if there is nothing to do; the cost is at most one tick per install/upgrade.
- Marketplace consumers who want no expiry latency should add the one
  `registry.armExpiryTimer<system>()` line after job creation.
- `example/main.mo`'s `health()` gained a `timers` field (additive record field — old clients
  decode unchanged); `@ic402/client`'s IDL now includes `health`.

### Internal

- `Utils.expiryCadence(hasWork, fastMode, idlePollSeconds)` — the pure cadence decision the
  tick's atomic tail takes, module-level so it is exhaustively unit-testable. `mops test` cannot
  arm a real timer (the interpreter has no `global_timer_set`; `wasi` mode rejects the async
  modules), so the decision, the work predicates, and the arm SITES are covered separately:
  `test/expirytimer.test.mo`, the replica-backed `test/integration.test.ts` (polls for a real
  disarm), and `scripts/check-expiry-arm-sites.sh` — a CI source gate, with a self-test, that
  fails if a session-creating path stops arming the sweep. That gate exists because the failure
  is asymmetric and silent: a missed **arm** site means sessions never expire, while a missed
  disarm only wastes cycles.

## v2.10.0 — 2026-07-17

Minor release — **runtime EVM chain reconfiguration**. A single deployment can now repoint its
EVM rail (the 402 `accepts` list, verify/settle resolution, and session opens) at a different
chain set at runtime — e.g. Base Sepolia ↔ Base mainnet, or add/remove a chain — without a
redeploy. Additive public API ⇒ minor per the 2.6.0 precedent; no interface, stable, or
existing-signature change; `STABLE_SCHEMA_VERSION` stays v1, upgrade-compatible, no migration.

### Added

- **`Gateway.setEvmChains(chains) : { #ok; #err : Text }`** — swap the accepted EVM
  chain/token set live. All-or-nothing validation: nonzero AND RPC-serveable chainIds
  (membership in the static `EvmRpc.rpcServices` provider table — an unserveable chain would
  advertise 402 challenges that can never settle), no duplicate chainIds or per-chain token
  addresses (first-match shadowing), canonical `0x`-prefixed 20-byte addresses (challenges
  advertise the configured strings verbatim; strict clients reject bare/`0X` forms). An empty
  list turns the EVM rail off.
  - **The capture fix**: Sessions receives `config` by value at construction and performs its
    own `evmChains` lookup at session-open, so a Gateway-only swap would silently leave the
    session rail on the old chains. Both classes now read live cells that `setEvmChains`
    updates in one synchronous call — pinned by `test/evmchains.test.mo`, which drives the
    real async open path and was mutation-verified to fail against a Gateway-only swap.
  - **Drain semantics** (adversarially reviewed; every money path verified fail-closed):
    in-flight messages complete on the chain set they resolved at entry; already-open
    sessions on a removed chain still close/reconcile/park (those paths use session-stored
    fields, never the live list); a pre-swap 402 challenge or session intent for a removed
    chain/token fails cleanly at settle/open — nonce unlocked, nothing broadcast, no funds
    move.
  - **TRANSIENT** like `setPolicy`/`setRequireCallerBoundSessions`: reverts to the
    constructor config on upgrade. Persist the choice in the consumer's stable state and
    re-apply at init; verify with `getEvmChains()` after upgrades.
- **`Gateway.getEvmChains()`** — the chain set currently in effect.
- Example canister: controller-gated `setEvmChains`/`getEvmChains` endpoints demonstrating
  the pattern (the demo does not persist the override; the doc comment shows how a production
  consumer should).
- `@ic402/client` needs no change: it takes the chain from `config.network` or extracts it
  from the server-advertised 402 options at runtime.

### Fixed

- **`Sessions.openEvmSession` now requires the deposit token to be in the (live) chain's
  configured token list** — surfaced by the adversarial review of this feature. Previously an
  unconfigured `intent.token` fell through to the default `"USD Coin"/"2"` EIP-712 domain,
  which is canonical USDC's real domain — so a genuine signature over a token the operator
  had just delisted still verified and opened a new funded session (not fund-losing: the
  refund is paid in-kind from the payer's own deposit; but it kept a delisted rail alive).
  Now rejected with a typed error, matching `Gateway.settle`'s strict `resolveEvmDomain`.
  The chain and token lookups on both rails were also unified to first-match resolution.

## v2.9.1 — 2026-07-14

Patch release — **dependency and toolchain refresh**, no ic402 API or behavior change. Every
golden-vector suite from v2.9.0 re-verified the upgrades byte-for-byte.

### Changed

- **moc 1.9.0 → 1.11.0** — full battery green: 20 mops test files (incl. the wasi candid
  suite), stable-compat gate (baseline still upgrade-compatible), candid-mirror gate +
  self-test, example build (`-E M0145`, wasm locals 96), regenerated `example.did`
  byte-identical.
- **@icp-sdk/core 5.4.0 → 6.0.0** — runtime dependency of `@ic402/client` and `@ic402/mcp`;
  all 86 client + 135 root tests green, Ed25519 goldens unaffected.
- **viem 2.55.2, cborg 5.1.7** (client runtime) — voucher-CBOR and EIP-1559 golden vectors
  confirm byte-stable encodings.
- **@x402/core 2.17.0 → 2.18.0** — the conformance suite re-ran clean: the deliberate
  upstream-drift check; Coinbase's v2 wire is unchanged.
- Dev tooling: eslint 10.7.0, typescript-eslint 8.64.0, prettier 3.9.5, vitest 4.1.10,
  tsx 4.23.1, lint-staged 17.0.8, @types/node 26.1.1, @icp-sdk/icp-cli 1.0.2.

### Held back (deliberate)

- **TypeScript stays 6.0.3** (latest 6.x, now an explicit root devDep): tsc 7.0.2 compiles
  the workspace, but typescript-eslint 8.64 crashes loading TS 7 (peer `<6.1.0`) — revisit
  when typescript-eslint supports TS 7.
- **wasmtime 44.0.0** (mops still passes `-Spreview2=n`) and **npm@11** in release.yml
  (npm 12.0.0 provenance breakage; 12.0.1 unverified) keep their documented pins.

## v2.9.0 — 2026-07-10

Minor release — **protocol golden-vector sweep**: every externally-defined byte encoding on a
fund path is now pinned against its official reference implementation (viem/ethers for EIP-1559,
the official ICRC-1/2 + EVM-RPC `.did`s, Coinbase's `@x402/core` v2 schemas, `@icp-sdk` Ed25519,
RFC 4648/Node for base64 and hex), and everything the sweep found is fixed. Minor (not patch) per
the 2.6.0 precedent: new public API (`EvmAddress.normalizeS`), observable 402-wire corrections,
and newly accepted base64 inputs. No interface, stable, or existing-signature change;
`STABLE_SCHEMA_VERSION` stays v1, upgrade-compatible, no migration.

### Fixed

- **EIP-1559 signature RLP encoding (live intermittent bug)** — `EvmUtils.signedRawTx` encoded
  signature `r`/`s` as fixed 32-byte RLP *strings*; EIP-2718/1559 define them as RLP *integers*
  (minimal encoding, leading zeros trimmed). A tECDSA signature whose `r` or `s` begins with a
  zero byte (~1 in 128 broadcasts) was rejected by geth-family nodes as `rlp: non-canonical
  integer` — and the locally derived fallback `broadcastTxHash` was the hash of a tx no node
  would ever accept, so the parked-hash recovery path polled a hash that could never resolve.
  Affected every outbound leg (settle, refund, sweep). Pinned by viem-derived golden vectors
  including a leading-zero-`r` regression.
- **`EvmSigner.signErc20Transfer` recipient guard (fund-affecting)** — the sign-only twin of the
  L21 `EvmSender` fix: a malformed recipient (odd/invalid hex → `[]`, or truncated hex) was
  silently zero-extended to `address(0)` or left-padded into a *different* valid address, then
  signed and handed to the client as a broadcastable tx. Now rejected pre-sign.
- **`EvmSigner.signTransaction` `to` validation** — a malformed `to` address hit
  `addressToBytes`' `assert`, an uncatchable local trap surfacing as an opaque `IC0503`; now a
  structured `#err` before any awaits.
- **x402 v2 `maxTimeoutSeconds` strictly positive** — the official v2 schema requires `> 0`, and
  strict clients rejected the *entire* `PaymentRequired` on a 0. Every discovery/Bazaar listing
  entry was 0 (`Gateway.describe` has no live nonce), as was any challenge with under a second
  remaining. Now: discovery entries advertise the standard 300s window; live challenges floor
  at 1.
- **EIP-712 domain-name fallback for Base Sepolia USDC (payment-rejecting when unconfigured)** —
  the `"USD Coin"` fallback is the wrong EIP-712 domain `name` for Base Sepolia USDC (FiatToken
  v2.2: `"USDC"`), so an unconfigured token yielded client signatures that revert on-chain. The
  fallback now special-cases the canonical Base Sepolia USDC deployment; configure `tokenName`
  explicitly for anything else (`"USD Coin"` remains correct for Base mainnet USDC).
- **Strict base64 decoder (parser-differential fix)** — the previous decoder silently *altered*
  output around stray bytes on fixed 4-char windows (early-return, mid-group truncation), so the
  same header could decode to different bytes here than in lenient upstream decoders — the
  classic smuggling surface (assessed fail-closed on the trust path, but real). Any invalid
  character now rejects the whole input; base64url (`-`/`_`) and unpadded input — legitimate
  senders previously mis-decoded — are now accepted.

### Added

- **`EvmAddress.normalizeS(sBytes) : ([Nat8], Bool)`** — EIP-2 low-S normalization, applied
  defensively at all four tECDSA sign sites (EvmSender broadcast, EvmSigner tx/EIP-3009/typed-
  data). The IC replica does guarantee low-s today (normalized at the tECDSA combine step *and*
  consensus-verified) — but only as dfinity/ic implementation detail; the interface spec is
  silent, and ic402 would have silently broadcast consensus-invalid txs if it ever changed.
  Normalize-before-parity-recovery, so the yParity bookkeeping is automatic.
- **137 new tests across 8 suites** — all golden literals generated by official implementations
  and adversarially re-derived with an independent second implementation before pinning:
  EIP-1559 (viem 2.55.0, cross-checked ethers v6), `normalizeS` boundary vectors (@noble/curves
  cross-check), candid mirrors (76 wasi-mode tests: officially-encoded fixtures for every ICRC
  TransferError/TransferFromError arm and every EVM-RPC result arm on ic402's call surface
  `from_candid`-decode into the repo's mirror types — the decode-trap class that bit twice —
  plus subtype-mismatch negatives and the silent-`Ok(null)` receipt sharp-edge), x402 v2 wire
  (`@x402/core` 2.17.0 schema validation of ic402's emission + the real official-client header
  parsed field-for-field), externally-signed Ed25519 vouchers (@icp-sdk 5.4.0 — the first
  hermetic acceptance of a signature the canister did not itself create, raw + full
  `consumeVoucher` path), base64 RFC 4648 §10 + strict-reject semantics, hex codec vectors.
- **`scripts/check-candid-mirrors.sh` CI gate** (new `candid-mirrors` job) — compiles probe
  actors from the mirror types (`moc --idl`), then `didc check` against vendored official
  `.did`s (`test/fixtures/official/`: ICRC-1/2 @ dfinity/ICRC-1 `f8c39be`, evm_rpc v2.8.0 —
  byte-identical to the deployed mainnet canister), didc sha256-pinned and cached, with a
  `--self-test` that proves the gate rejects a grown result variant. Catches real-canister
  interface drift at PR time — the hermetic EVM-RPC mock imports the library's own types, so
  no amount of mock-based CI could.
- **Toolchain**: `wasmtime` pinned to 44.0.0 in `mops.toml` (mops passes `-Spreview2=n`;
  wasmtime 45 prints a deprecation warning on stderr which mops treats as test failure; ≥47
  hard-errors from 2026-07-20 — revisit when mops drops the flag). Root devDependency
  `@x402/core@2.17.0` for the conformance suite.

### Wire changes (spec-conformance corrections, visible to clients)

- 402 `maxTimeoutSeconds`: `0` → `300` (discovery) / `≥1` (live challenges).
- 402 `extra.name` fallback on Base Sepolia USDC: `"USD Coin"` → `"USDC"` (only when
  `tokenName` is unconfigured).
- Inbound payment-header base64: stray/invalid characters now reject the header outright
  (previously silent truncation/desync); base64url and unpadded input now decode.

### Docs

- `docs/x402-compliance.md`: the non-standard extension keys are FLAT `extra.ic402Nonce` /
  `extra.ic402Expiry` (the doc previously showed a nested `extra.ic402` object that never
  matched the code); added a client-generation note (stock `x402-fetch@1.x` is protocol v1 and
  cannot transact with ic402's v2-only wire in either direction — use `@x402/*` v2 clients or
  `@ic402/client`).
- `packages/client/src/voucher.ts`: corrected the `VoucherSigner` doc-comment (an @icp-sdk
  `Ed25519KeyIdentity` needs a raw-bytes wrapper; passing it directly would register the
  session under a garbage key).
- `Types.mo` `LedgerActor`: documented the structural-subset + CI-gate relationship and why
  `icrc1_fee` is deliberately declared as an update.

## v2.8.0 — 2026-07-05

Minor release — **opt-in caller binding for ICP-rail session voucher keys**, all additive (new
public API ⇒ minor per the 2.6.0/2.7.0 precedent; no interface, stable, or existing-signature
change; `STABLE_SCHEMA_VERSION` stays v1, upgrade-compatible, no migration).

Previously `openSession` accepted any 32-byte Ed25519 `sig.publicKey` (length check only), so a
session's vouchers were bound to "some key" — a relying party could not conclude the principal that
opened (and paid for) a session is the one whose key signs its vouchers.

### Added

- **`Ic402.selfAuthPrincipalOfEd25519(pubkey) : ?Blob`** — the IC self-authenticating principal for
  a raw 32-byte Ed25519 key (`sha224(DER-SPKI(key)) ‖ 0x02`), verified byte-for-byte against
  `@icp-sdk` via a golden-vector test. Ed25519-only and opportunistic: a mismatch means "not
  identity-bound", never "invalid" — Internet Identity delegations and secp256k1/P-256 identities
  derive different principals.
- **`Ic402.verifyCallerEd25519(caller, pubkey, signature, message)`** — ownership (the key derives
  the caller's principal) plus possession (the signature verifies) in one check.
- **`Gateway.setRequireCallerBoundSessions(on)`** — opt-in, **default OFF**: reject an ICP-rail
  `openSession` whose voucher key is not the caller's own identity key. Checked before the deposit
  pull (a rejection moves no funds); reuses `#invalidSignature`. An operator-level knob by design —
  the relying party is the canister, so a client-supplied `SessionConfig` flag would prove nothing.
  ICP rail only: an EVM session's payer identity is the on-chain EVM address, not `msg.caller`.
  Leave OFF unless every session client authenticates with a raw Ed25519 identity.
- **`Gateway.sessionCallerBound(sessionId) : ?Bool`** — whether a session's voucher key is the
  payer's own identity key, derived from already-stored state (works for pre-existing sessions).
  `null` = unknown session; `false` = "not identity-bound", never "invalid" (EVM-rail sessions are
  typically `false`; their voucher key is session-ephemeral).

## v2.7.0 — 2026-07-03

Minor release — four **additive** consumer-facing methods (no existing signature, interface, or
stable change; `STABLE_SCHEMA_VERSION` stays v1, upgrade-compatible, no migration). Minor (not
patch) because they are new public API on the published packages. Requested by downstream consumers
(per-caller-policy removal, EVM pool observability, drift-proof marketplace fee, async-job
settlement header).

### Added

- **`Gateway.removeCallerPolicy(caller)`** — the write-path complement of `setPolicy(?caller, _)`:
  removes a per-caller spending-policy override so the caller reverts to (and keeps tracking) the
  global policy. Previously the only way "back" was overwriting the override with a frozen copy of
  the global policy. Gate on the consumer's owner/controller check, like `setPolicy`.
- **`Gateway.getEvmPoolCap()` and `Gateway.totalAllocated(chainId, token)`** (plus
  `EvmEscrow.getPoolCap()`) — read-only EVM shared-pool observability. Remaining reservation
  headroom under a cap is `getEvmPoolCap() − totalAllocated(chainId, token)`; previously only
  `setEvmPoolCap` was exposed, so the cap could be set but never read back or sized against live
  utilisation.
- **`ServiceRegistry.ledgerFee()`** — returns the registry's configured `config.ledgerFee`, the
  value `validateSubmittable` checks. Settle-first marketplace consumers should derive
  `expectedAmount = price + ledgerFee()` from this getter instead of mirroring their own fee
  constant, so the two can never drift.
- **`HttpHandler.http202JsonWithSettlement(json, settlementJson)`** — 202 Accepted mirror of
  `http200JsonWithSettlement`, so an async "job created, payment escrowed, poll for the result"
  response can carry the v2 `PAYMENT-RESPONSE` settlement header.

## v2.6.1 — 2026-07-03

Patch release — fund-safety hardening surfaced by the invariant catalog
(`docs/fund-safety-invariants.md`). No consumer-facing interface change: `Gateway.settle`'s
`PaymentResult` is unchanged and `STABLE_SCHEMA_VERSION` stays v1 (upgrade-compatible; no migration).
The internal `EvmSender.executeTransferWithAuthorization` return type gains an additive `#maybeSent`
variant (an EVM broadcast primitive; no in-repo direct caller uses it).

### Fixed

- **An ambiguously-broadcast inbound EVM deposit could be stranded with no recovery handle (G5/G6).**
  When an EIP-3009 transfer returned `#maybeSent` (post-dispatch error / inconsistent RPC / nonce
  too high — the tx may still mine), `executeTransferWithAuthorization` collapsed it to a hash-less
  `#err`, so `Gateway.settle` returned `#settlementFailed` and `openEvmSession` returned
  `#settlementFailed` with **no tx hash** — an ambiguously-broadcast-then-mined deposit was
  unrecoverable. The hash is now preserved and routed into `confirmTransaction`: if it mines it
  yields a receipt / opens the session; if it stays pending it parks as `#settlementPending` (tracked
  in `pendingEvmDeposits`, refundable via `reconcileEvmDeposit`). No double-pay — the EIP-3009 token
  nonce is single-use on-chain. This aligns the inbound path with the already-correct outbound
  `sendErc20TransferConfirmed`.

### Changed

- **Example: rail-aware marketplace buyer (G2).** The update-method `submitServiceRequest` recorded
  the ICP caller as the job buyer regardless of rail — mislabeling an EVM payer's job (misdirected
  refund / wrong-pool draw). It now uses `receipt.sender` for EVM and `msg.caller` for ICP, matching
  the HTTP `/service/` handler. Footgun, not reachable via the shipped client (which sends only ICP
  sigs to that method). Example-only.
- **Docs: strengthened the `sendErc20Transfer` footgun comment (G3)** — its `#maybeSent→#err`
  collapse on the replay-unprotected outbound rail is a double-pay risk for an external caller that
  re-sends on `#err`; use `sendErc20TransferConfirmed`. No in-repo caller.

## v2.6.0 — 2026-07-03

Minor release — closes the **settled-then-job-failed** fund-path class in the service marketplace
(scoped in `docs/decisions/settled-then-job-failed.md`). No funds could be stolen; the fixes close a
fund-availability / cap-accounting gap and, on the canister, make **money-moved ⇒ job-exists** an
invariant. Minor (not patch) because it adds public surface: two new `ServiceRegistry` methods
(`validateSubmittable`, `createJobFromReceipt`) and a `fundsMoved` flag on `@ic402/client`'s
`Ic402Error` — both **additive**. The `example.did` interface and `STABLE_SCHEMA_VERSION` (v1) are
unchanged (upgrade-compatible; no migration).

### Fixed

- **`submitServiceRequest` could settle a payment and then fail to create the job (Option A / S1).**
  The example settled FIRST, then called `registry.submitRequest`, which could still reject (a
  service disabled during the settle await, or a `CKUSDC_FEE` vs `config.ledgerFee` skew) — moving
  the buyer's funds with no job and no receipt-keyed recovery. `ServiceRegistry.submitRequest` is now
  split into `validateSubmittable` (all pre-settle-checkable guards, checked against the amount that
  will settle, using the registry's own fee) and an **infallible** `createJobFromReceipt`; both
  example call sites (the update method and the HTTP `/service/` handler) now validate → settle →
  create, so a `#ok` settle always yields a job. `submitRequest` stays (validate + create) so no mops
  consumer breaks. Additive methods; no stable change.

- **The MCP un-counted spend that actually moved, and could invite a double-pay (Option C / S2, S4).**
  When a payment settled but a downstream step failed (settle `#ok` then job-create failed, or an EVM
  settlement/deposit still `#settlementPending`), the MCP called `refundSpend()` on the catch-all —
  restoring cumulative-cap headroom for money that really left, so a later auto-pay could exceed the
  session cap; `open_session` additionally leaked a raw error string. The canister now prefixes a
  canonical `do NOT retry payment` marker on the funds-moved arms; the client tags `Ic402Error` with
  an additive `fundsMoved` flag; and the MCP refunds a reservation **only** when funds provably did
  not move (and wraps `open_session` failures in a structured error). `fetch_x402`'s 402-after-pay
  path was assessed and found already safe (`retryable:false` + human re-confirm + reservation kept).

## v2.5.5 — 2026-07-02

Patch release — **fund-availability fix** in EVM session recovery, plus a reference-example
payment-handling fix and MCP/docs improvements. No funds could be stolen by any of these; the
session fix closes a liveness leak. `example.did` is unchanged and `STABLE_SCHEMA_VERSION` stays at
`1` (upgrade-compatible; no interface or stable change).

### Fixed

- **`forceResolveSession` leaked the EVM escrow pool allocation (and the unconsumed daily-spend
  reservation).** The controller-only escape hatch for a session stuck in `#closing` set the
  session to `#closed` and cleared the parked tx but — unlike the other `#closing→#closed` path,
  `reconcileSession`'s confirmed close — skipped the `deallocate`/`releaseDaily` that terminal close
  requires. `gcClosedSessions` only deletes the record (it never deallocates), so the pool
  allocation leaked permanently and, once GC dropped the session, was no longer referenceable. With
  a `poolCap` set (required for shared-pool solvency), each use of the hatch monotonically shrank
  the funded pool's headroom until `allocate()` refused new EVM sessions with "EVM pool
  over-allocation" despite adequate on-chain funding. The reservations are pure canister-side
  accounting (no funds move), so releasing them on terminal close is always correct. Root cause was
  duplicated finalize logic drifting across paths; it is now factored into a single
  `finalizeClosedSession` shared by both recovery paths so they cannot diverge again. The
  daily-reservation leak was bounded (reset at day rollover); the pool-allocation leak was not.

- **The example service marketplace's `submit_request` reported `#settlementPending` as a flat
  failure** (example canister, not in the published package). A broadcast-but-unconfirmed EVM
  settlement fell through a `case (_)` wildcard to "Payment settlement failed" — which reads as
  "retry" and invites a double-payment for a tx that may still mine, violating the library contract
  (callers MUST NOT deliver value on `#settlementPending`). It is now handled explicitly, mirroring
  the search/serve/open-session paths. The settle `switch` is also made exhaustive and
  `build-example.sh` treats a non-exhaustive `switch` as a hard error (`-E M0145`), so a future
  `PaymentResult` variant can't be silently swallowed again.

### Changed

- MCP tool descriptions rewritten to state the read-only vs value-moving split, the two-phase
  confirmation protocol, and atomic-unit encoding, plus a server `instructions` block; new
  `docs/mcp-install.md` install guide. Retracted a stale "DNS rebinding not covered" note in the MCP
  README (closed by the SEC-0 resolve-and-reject guard) and refreshed stale version/status strings.

## v2.5.4 — 2026-07-02

Patch release — **money-path fix**. Every inbound EVM x402 settlement via EIP-3009
`transferWithAuthorization` reverted on-chain; **upgrade is strongly recommended for any
canister accepting EVM payments.** `example.did` is byte-identical to v2.5.3 and
`STABLE_SCHEMA_VERSION` stays at `1` (no interface or stable change).

### Fixed

- **EIP-3009 `transferWithAuthorization` broadcast the payer signature `v` as `0/1` instead
  of `27/28`.** The parser normalizes `v` (27/28 → 0/1) for ic402's internal ecRecover, but
  `EvmSender` then wrote that raw `0/1` into the on-chain calldata — where USDC's `ecrecover`
  requires `27/28` — so the contract recovered the wrong signer and reverted. No funds moved;
  `settle` returned `#settlementFailed(...reverted on-chain...)`. The fix denormalizes `v` at
  the on-chain-encoding layer only (`EvmUtils.chainVFromRecoveryId`); the verify path is
  unchanged. ICP and single-token rails were unaffected. Found via a live Base-Sepolia
  end-to-end run; invisible to unit tests because it only manifested on a real broadcast.

### Internal / tests

- Named, idempotent `v` conversions (`recoveryIdFromV` / `chainVFromRecoveryId`) replace the
  scattered inline normalization so the representation seam is explicit, and
  `buildTransferWithAuthorizationCalldata` is now a pure, unit-testable function. A new
  replica-free guard (`test/eip3009calldata.test.mo`) recovers the signer from the **encoded**
  calldata `(v, r, s)` exactly as the chain does, so any future on-chain-encoding regression
  (v form, r/s order, digest) fails in the fast suite.

## v2.5.3 — 2026-07-02

Patch release. Adds public wire-form TS types for typing hand-built canister payloads, plus
dev-facing test/demo fixes. **No canister behavior or interface change**: `example.did` is
byte-identical to v2.5.2 and `STABLE_SCHEMA_VERSION` stays at `1`. The mops `ic402` library and
`@ic402/mcp` are unchanged since v2.5.2 — only `@ic402/client` gains additive exports.

### Added

- **`@ic402/client`: `PaymentSignatureArg` / `Eip3009AuthorizationArg`** — wire-form (agent-js
  Candid encoding) types for hand-built canister-argument payloads. Annotate a raw
  `PaymentSignature` so `tsc` flags a missing field (e.g. a future opt like v2.5.0's `asset`) at
  compile time, instead of only at agent-js encode against a live replica.

### Tests / tooling

- **Schema-drift guard.** A new `idl-encode-contract` test round-trips representative
  `PaymentSignature` / `Eip3009Authorization` / `Voucher` payloads through the actual record IDLs,
  so a payload missing a required field fails in the fast (replica-free) suite — the exact class
  that slipped through after v2.5.0 added `asset`. Also fixed two pre-existing integration failures
  (4 payloads missing `asset`; an HTTP test hitting a never-uploaded content id).

### Demo

- **Step 6 x402 endpoint swapped** from the dead `x402.goldrush.dev` (its API route hangs
  indefinitely) to the live `sandbox.node4all.com/v1/x402-test` from Coinbase's x402 Bazaar
  (Base Sepolia USDC; a drop-in for the SDK's `payment-required`-header probe). Step 6 now
  completes a real paid round-trip on a local replica.

## v2.5.2 — 2026-07-02

Patch release — **diagnostics only, no behavior or interface change**. `example.did`
is byte-identical to v2.5.1 and `STABLE_SCHEMA_VERSION` stays at `1`. Ships the
error-message actionability pass and the SDK `[object Object]` fix.

### Changed

- **Actionable error messages (library + SDK).** 34 human-readable diagnostic
  messages across the fund path (Gateway, Sessions, EvmSender, EvmVerify, Policy, and
  `@ic402/client`) now state what happened AND the next step — e.g. Sessions'
  `"Session already closed"` names the `#closing` / `reconcileSession` recovery path;
  Gateway's `"ICP settlement requires the ic402 server nonce"` tells you to echo the
  challenge's `ic402Nonce`; `#insufficientFunds` / `#insufficientAllowance` say "needs
  amount + ledger fee, re-approve"; EvmSender's nonce/gas/receipt errors state "nothing
  was broadcast — safe to retry" and where to fund / what to re-poll. **No error
  variant, `Ic402Error` kind, x402 `invalidReason` token, or interpolation changed** —
  the protocol surface and every test-asserted string are byte-identical.

### Fixed

- **SDK: `openSession` error rendered `[object Object]`.** `client.ts` interpolated the
  Candid error variant object directly; it now uses `safeStringify(result.err)` so the
  real reason (`policyDenied` / `settlementPending` / `depositBelowMinimum` …) surfaces.

### Tests

- Fixed two pre-existing integration failures that only surface against a live replica
  (the suite skips in CI): PaymentSignature payloads were missing the v2.5.0 `asset`
  field (agent-js `Invalid opt record`), and the HTTP settlement-failure test's
  `GET /content/probe` 404'd because that id was never uploaded. Integration is now 50/50.

## v2.5.1 — 2026-07-02

Patch release — **documentation only, no code or interface change**. `example.did` is
byte-identical to v2.5.0 and `STABLE_SCHEMA_VERSION` stays at `1`. This ships the
library doc-comment audit that landed after the v2.5.0 mops publish (which mops
cannot retroactively include), plus the rewritten `@ic402/client` README and a new
getting-started guide.

### Documentation

- **Library doc-comments (`src/ic402`).** Comment-only audit of the public fund-path
  surface (Gateway, Sessions, Types, HttpHandler, lib): fixed two misattributed doc
  blocks (`settle`'s doc was stranded on a private helper; "start recurring timers"
  sat on `setEvmPoolCap`), documented the NANOSECOND units on the expiry/duration
  fields (the nearby EIP-3009 fields say "seconds" — a real misconfiguration
  footgun), promoted the v2.5.0 `PaymentSignature.asset` docs from `//` to `///` so
  they appear in generated docs, and added `#settlementPending` / close-parking /
  `consumeVoucher` / `recoverEscrow`-is-ICP-only / drain-before-upgrade invariants.
- **`@ic402/client` README** rewritten: corrected the stale `call()` / `openSession()`
  signatures, documented every public method with real signatures, the `VoucherSigner`
  contract, the EIP-712 helpers, the error kinds, and a Multi-token (v2.5.0) note on
  `PaymentSignature.asset`.
- **`docs/getting-started.md`** (new): a zero-to-first-payment tutorial (x402 charge,
  streaming session, EIP-3009 EVM), plus a root-README prose polish and a v2.5.0
  release announcement.

## v2.5.0 — 2026-07-02

Minor release. Fixes a latent multi-token EIP-712 settlement bug by threading the paid EVM asset
through the payment path via an additive `PaymentSignature.asset` field; the remainder is an internal
robustness pass (shared-helper extractions, dead-code removal, new tests). **No wire/HTTP or
`@ic402/client` breaking changes** — `asset` is an optional Candid field, so an old client that omits
it decodes to `null` and the chain's first configured token is used (the prior behavior).
`STABLE_SCHEMA_VERSION` stays at `1` (`PaymentSignature` is a message payload, not stable state), so
an in-place upgrade from v2.4.x is stable-compatible.

### Fixed

- **Multi-token EIP-712 settlement (correctness).** `Gateway.verifyPayment` resolved the EIP-712
  domain from the paid asset, but `settle` and `Sessions.openEvmSession` took the verifyingContract,
  domain, and on-chain execution token from `chain.tokens[0]`. On a chain configured with **more than
  one token**, a valid EIP-3009 signature for a non-first token verified but was then rejected /
  mis-executed at settle. `PaymentSignature` now carries the signed `asset`, and settle /
  openEvmSession key their domain + execution off it. Single-token-per-chain deployments (the shipped
  config) were unaffected, and no path moved funds on a failed verify.

### Added

- **`PaymentSignature.asset : ?Text`** (mops `ic402` + `@ic402/client` idl/types) — the EVM token
  contract (EIP-712 verifyingContract) the payer signed for. Optional/additive → backward-compatible.
  New pure, tested Gateway helpers `resolveEvmAsset` (asset ?? first token) and `resolveEvmDomain`
  (name/version keyed on the actual token) are the shared seam for verify / settle / openEvmSession.

### Changed (internal, no behavior change)

- **Robustness / de-duplication pass.** Extracted shared seams and removed copy-paste across the
  library, SDK, MCP server, scripts, and the reference demo: Gateway/EvmSender RPC-preamble +
  candid-decode helpers, MCP response-envelope routing through `textResult`/`serialize`, a shared
  script PATH-sanitize helper, the SDK's `candid.ts` opt/byte decoders, and the demo client's new
  `codec.ts` (opt / nonce / inline-blob / USDC formatting) + `evm.ts` (`demoPayer` +
  `signTransferWithAuthorization`, collapsing two ~120-line pasted EIP-712 blocks). Dead code swept
  (unused imports, redundant post-settle guards).

### Tests

- New Motoko + TypeScript coverage for the touched seams: `resolveEvmAsset` / `resolveEvmDomain` (6),
  the `consumeVoucher` streaming-charge fund gate, the MCP call-guard case matrix, and the demo codec
  helpers + a **pinned EIP-712 signing vector** with an ecrecover round-trip (19) that proves the
  extracted signer is byte-identical to the old inline blocks.

## v2.4.0 — 2026-07-01

Minor release. Resolves a full-codebase review (28 findings) — EVM fund-safety, SDK correctness,
DoS bounds, and reference-example hardening — and adds new controller API for inbound-EVM-deposit
recovery and zk-verifier access control. `STABLE_SCHEMA_VERSION` stays at `1` (no stable type
changed — the new inbound-deposit tracker is **transient**), so an in-place upgrade from v2.3.x is
stable-compatible.

### Dependencies

- `mo:ic` 4.1.0 → 4.2.0, `mo:ecdsa` 8.0.0 → 8.0.1. Hash/signature suites pass; example wasm stays at
  96 / 1900 per-function locals.

### Added

- **Inbound EVM deposit recovery + upgrade drain (M8).** A session deposit broadcast but not
  confirmed within `openSession`'s poll budget is now tracked (transient) so it can be reconciled
  instead of stranding in the shared pool. New controller-gated API: `pendingEvmDepositCount`,
  `listPendingEvmDeposits`, `setEvmDrainMode` / `getEvmDrainMode`, and `reconcileEvmDeposit`
  (refund-on-confirm to the payer's EVM address). Upgrade runbook: drain to a `0` pending count
  before upgrading — see `docs/upgrade-safety.md`.
- **zk-verifier authorized-caller allowlist (L24).** The reference verifier gains controller-only
  `set_authorized_callers` / `get_authorized_callers` (persisted across upgrades), checked before the
  ~1–5B-instruction verification — closing an unauthenticated cycle-drain.

### Fixed

**EVM fund-safety (high):**

- **Double-settle from the shared pool (H1).** `closeExpiredSessions` re-fetches each session and
  only expires those still `#open`, so a concurrently-`#closed` session can no longer be flipped back
  and re-settled (the S-3 bypass).
- **Ambiguous EVM sends are now recoverable (H2/M11).** The canonical tx hash is derived locally
  (`keccak256` of the signed raw tx) and carried in a structured `#maybeSent`, so a parked entry is a
  pollable hash rather than an error string / raw tx — confirm-only reconcile can resolve it.
- **Pool-cap check moved before the deposit (H3).** `openEvmSession` reserves the pool allocation
  before pulling funds and deallocates on any later failure, so an over-cap open no longer strands an
  honest payer's USDC.
- **Refund-and-settle double spend in the marketplace (H4).** `verifyAndSettle`'s
  `#AutoSettle`/`#HashMatch` branches re-check the job is still `#Submitted` before paying.

**EVM robustness (medium/low):**

- Outbound-rail wedge fixed — `sendTransaction` validates the destination before taking the
  single-flight lock and releases it in `finally` (M9). A safe-to-retry pre-broadcast `#err` on a
  client-initiated close reopens the session instead of stranding it in `#closing` (M10). Empty
  `#Consistent` fee data returns `null` instead of broadcasting an unmineable 1-gwei tx (L20). A
  malformed ERC-20 recipient is rejected pre-broadcast instead of encoding `address(0)` (L21).
- Unauthenticated verify/settle/open paths no longer trap on a malformed EIP-712 `from`/`nonce`/etc.
  — `verifyAuthorization` returns a graceful `false` (L19/L28), and the HTTP payment-header parser no
  longer traps on bad hex (L22).

**SDK correctness:**

- `Ic402Client.call` auto-pay handles the real `vec PaymentRequirement` wire shape (H5), and
  `fetchContent` / MCP `fetch_content` unwrap the `opt blob` chunk instead of returning zero bytes
  (H6). `Ic402Client.fetchX402` echoes the advertised requirement verbatim as `accepted` for
  strict facilitators (M15).

**Reference example + tooling:**

- Existence/enabled is checked before settling (content + service, HTTP + Candid), and
  `#settlementPending` returns the pending tx instead of a fresh challenge (M13/M14). ZkGroth16
  `bindResult` uses the correct little-endian byte for BN254 reduction (M12). The MCP
  `fetch_content` caps `chunkCount` from untrusted delivery JSON (M17). `operatorEvmPayout` is
  capped (L23). `setup.sh` restores the tracked ckUSDC candid (M18); the
  broken redundant `local-start.sh` is removed in favor of `setup.sh` (L26); the patch-drift gate
  checks the previously-missed EVM-RPC/recipient/key markers (L27); demo Step 2 fails loudly on a
  real upload failure (L25).

## v2.3.1 — 2026-06-24

Patch release. Dependency bump only — no API or behavior change.

### Dependencies

- `mo:sha2` 0.2.4 → 0.2.5. SHA-256 output is unchanged (hash-dependent suites pass), and the
  example wasm stays well under the per-function locals budget (96 / 1900), so the install-limit
  (B0) concern is unaffected.

## v2.3.0 — 2026-06-24

Minor release. Adds **consumer upgrade-safety** for ic402's library stable types. No wire/HTTP
or `@ic402/client` API changes; `STABLE_SCHEMA_VERSION` starts at `1` (this release does not change
any stable type, so an in-place upgrade from v2.2.x is stable-compatible).

### Added

- **Stable-schema versioning + a CI gate that can't silently brick a consumer's upgrade.** ic402's
  four `Stable*State` snapshots are embedded in every consumer canister's persisted state; a future
  incompatible change to one of them would trap in `loadStable` on a live, fund-holding canister.
  - New public mops API: `Ic402.STABLE_SCHEMA_VERSION : Nat` and
    `Ic402.checkSchemaVersion(persisted)` (returns `#ok` / `#migrate` / `#ahead`), for consumers to
    persist + check **before** `loadStable` — turning a cryptic Candid trap into a clear error or a
    migration branch. `example/main.mo` demonstrates the guard.
  - A `stable-compat` CI job (`scripts/check-stable-compat.sh`) compiles a dedicated anchor
    (`test/stable-anchor.mo`, persisting exactly the four library types) to a `.most` signature and
    checks it against a committed baseline with moc's own `--stable-compatible` oracle. A breaking
    change **fails the build unless `STABLE_SCHEMA_VERSION` is bumped**; `--update` (the release-time
    baseline advance) refuses a breaking advance without a bump; a `--self-test` proves the gate
    still discriminates, and a coverage guard stops the anchor from silently dropping a type.
  - `docs/upgrade-safety.md` documents the mechanism + the consumer pattern; `RELEASING.md`
    documents the two-version release process.

### Fixed

- **`scripts/setup.sh` now sanitizes its PATH** so a sibling repo's `node_modules/.bin` can't shadow
  `mops`/`pnpm` (which silently broke `mops install`, leaving an empty `.mops`). Keeps `$PNPM_HOME`
  so the GitHub pnpm action still resolves; reinstalls when `.mops` is empty and fails loudly.

## v2.2.4 — 2026-06-19

Docs + tooling patch. No wire/HTTP or `@ic402/client` API changes.

### Docs

- **100% mops documentation coverage** (was 96.94%). Added `///` doc comments to the 25
  public declarations `mo-doc` flagged — `lib.mo` marketplace-type re-exports, the `EvmRpc`
  error types, the `ServiceRegistry` class + its EVM transfer/confirm hooks + reconcile
  helpers, and `Sessions` / `EvmSender` / `Types` members.
- **`SECURITY.md` brought current.** Every `file:line` reference in the money-theft and
  threat-model sections had drifted after the SEC-0..4 changes — all corrected against
  source. The H-4 bullet now cites the live `recordSpend`/`releaseDaily` mechanism (the
  `reserveCharge`/`reserveSessionOpen` it named are dead code). The status banner,
  supported-versions table, and open-items list now reflect B0/B2/B3/B4 done, B1 waived,
  and SEC-0..4 closed; the remediation narrative includes the composed-system pass.
- **B3 reflected across the docs.** `README`, `CONTRIBUTING`, and `CLAUDE.md` list the
  EVM-RPC mock (`example/evm-rpc-mock/`) and the hermetic outbound test; a stale README
  "not enforced in CI" line and a duplicate `CONTRIBUTING` layout entry are fixed; and
  `docs/costs-and-rails.md` no longer labels the (closed) B3 as open backlog.

### Tooling

- **`scripts/setup.sh` now sanitizes its PATH** (the same guard `build-example.sh` uses),
  so a sibling repo's `node_modules/.bin` can no longer shadow `mops` and silently break
  `mops install`. It also reinstalls when `.mops` is empty (not just absent) and fails
  loudly instead of masking a broken toolchain.

## v2.2.3 — 2026-06-19

Patch release. CI/test infrastructure only — no wire/HTTP or `@ic402/client` API
changes. Closes **B3**, the last production-readiness hermeticity gap: the EVM
**outbound** rail (sign → broadcast → confirm / park) is now gated in CI without a
funded testnet or any network egress.

### Added

- **Hermetic EVM-outbound CI gate (B3).** A scriptable Motoko mock of the DFINITY
  EVM-RPC canister (`example/evm-rpc-mock/`) implements the exact
  `EvmRpc.EvmRpcCanister` interface and answers every RPC round-trip with canned,
  controllable data, so the whole outbound state machine runs on a plain local
  replica. The canister under test still does **real tECDSA signing + RLP encoding** —
  only the broadcast/confirm leg is mocked, and the mock records each raw tx it was
  asked to broadcast so a test can assert the bytes went out exactly once.
  `scripts/setup-evm-outbound.sh` re-points the example at the mock, and
  `test/evm-outbound.test.ts` drives the controller-only `sweepEvm` through
  confirmed / reverted / never-mined / pending-then-mined / inconsistent-fee
  outcomes — including ones a live testnet won't produce on demand. A new
  `test-evm-outbound` CI job enforces it (`IC402_REQUIRE_EVM_OUTBOUND=1`).

### Notes

- With B3 closed, the remaining production-readiness items are NEW-5 (confirmation
  depth, deferred — low practical risk on optimistic L2s) and an optional external
  audit / periodic live-testnet smoke (the funded leg can't be hermetic). B1 waived.
  `docs/production-readiness.md` is the source of truth.

## v2.2.2 — 2026-06-19

Patch release. Fixes a `@ic402/client` packaging bug and trims dead code/deps
(supply-chain cleanup). No wire/HTTP or API changes.

### Fixed

- **`@ic402/client` was mis-packaged.** It imported `@icp-sdk/core` without
  declaring it — so a clean `npm install @ic402/client@2.2.1` is broken
  (`MODULE_NOT_FOUND`) — and declared three deps it never imports
  (`@canister-software/x402-icp`, `@x402/core`, `@x402/fetch`), which dragged in
  the legacy `@dfinity/*` tree (the source of most supply-chain-scan alerts). Now
  `@icp-sdk/core` is declared and the three dead deps are removed. **Republish from
  2.2.2 to fix the live package.**

### Removed (dead code)

- `client.ts` unused `SignedTransaction` import; `guards.ts` unused
  `dangerousTools()` export; demo `versus()` helper and two unused constants.
  Verified with depcheck / ts-prune / eslint; build + 72 client tests pass.

### Notes

- The transitive advisories a supply-chain scan flags — `ws` (via viem's WebSocket
  transport) and `hono`/`path-to-regexp`/`fast-uri` (via the MCP SDK's HTTP/SSE
  transports) — are **not reachable**: ic402 uses viem `http()` and a stdio-only
  MCP server, so neither transport runs. The fixes are upstream. See
  `docs/security-model.md` §5.

## v2.2.1 — 2026-06-19

Security release. A composed-system adversarial security audit (SEC-0) plus two
re-attack rounds found and fixed six issues. No wire/HTTP or `@ic402/client` breaking
changes; two additive Motoko methods (below).

### Security (SEC-0)

- **[critical] Marketplace double-refund.** The ServiceRegistry ZkGroth16 `#err`
  branch wrote `#Disputed` unconditionally, clobbering a terminal `#Settled`/`#Refunded`/
  `#Expired` set during the verifier await → the next `expireJobs` tick re-refunded the
  job. Now status-guarded (only `#Computing` → `#Disputed`, mirroring the `#ok` branch).
- **[high] EVM session overpayment strand.** `openEvmSession` accepted `authz.value >
  deposit`, pulling the full value on-chain but crediting only `deposit`. Now requires
  `authz.value == deposit` (mirrors the charge path).
- **[high] Unmetered-ecRecover cycle-DoS.** The expensive EIP-3009 `ecRecover` ran
  without the global rate gate on the paid `/content`/`/search` settle paths and on
  `openEvmSession`. A single global token bucket now meters `settle`/`verifyPayment`/
  `openEvmSession`; the example uses a floor-only check on `/verify`+`/settle` so the
  bucket isn't double-charged.
- **[high] EVM pool over-allocation + open-time leak.** `EvmEscrow.totalAllocated` was
  never consulted (dead code) and the session public key was validated *after*
  `allocate`. Now a live per-chain+token `poolCap` guard, and the key is validated
  before the on-chain deposit + allocation.
- **[high] MCP spend-cap TOCTOU.** Concurrent/pipelined tool calls passed the same
  stale cumulative cap. The cap is now reserved synchronously at confirm time and
  refunded on a no-money-moved failure.
- **[high] MCP DNS-rebinding SSRF.** The `fetch_x402` probe leg and `register_agent`
  rpcUrl bypassed the redirect-safe fetch. Outbound hosts are now DNS-resolved and
  rejected if they resolve to a private/metadata IP, at every fetch entry point.

### Added

- `Gateway.setEvmPoolCap(cap)` — bound outstanding EVM session deposits per chain+token
  (the over-allocation guard). The example wires a ceiling.
- `Gateway.cyclesBelowFloor()` — the facilitator cycle-floor check, split out so a
  consumer doesn't double-charge the global rate bucket.

### Documented residuals

Deliberately deferred and disclosed in `docs/security-model.md` /
`docs/production-readiness.md` (SEC-0): system-wide shared-EVM-pool solvency
(marketplace/`sweepEvm` vs `totalAllocated`); the SSRF connect-time re-resolve window
(no undici IP-pinning yet); and the ungated-but-unwired `recoverBuyerActionSigner`.

## v2.2.0 — 2026-06-18

Minor release. Adds a recovery/observability suite and a facilitator DoS gate,
fixes a latent EVM-RPC decode trap that could hit any EVM operation, and bumps
the Motoko crypto/IC dependencies. No wire/HTTP or `@ic402/client` breaking
changes; one Motoko-library breaking change for direct `EvmRpc` consumers (below).

### Added

- **Recovery & observability** (controller-only via the consumer). Escape hatches
  for funds parked mid-settlement: `health()` (cycle balance + job/session counts),
  `listJobs`, manual `resolveJob` / `reconcileJob` / `reconcileSession` /
  `forceResolveSession`, and `sweepEvm(chainId, token, to, amount)`. Auto
  confirm-only reconcile timers for marketplace jobs and streaming EVM sessions
  re-poll a STORED tx and finalize when confirmed — they never re-broadcast.
- **SEC-1 — facilitator DoS gate.** The unauthenticated `/verify` + `/settle`
  update endpoints now run behind a global token-bucket rate limit and a
  500B-cycle floor, evaluated before any attacker-controlled parsing / `ecRecover`
  / RPC / signing work.
- **Pre-broadcast cycle guard.** `EvmSender.sendTransaction` refuses to broadcast
  below `MIN_BROADCAST_CYCLES` (120B), so it never strands a half-sent EVM tx.
- **RPC resilience.** Added a verified 3rd RPC provider to the testnet chains that
  previously had only two, so one flaky endpoint no longer parks settlement.

### Fixed

- **EVM-RPC decode trap (`openSession`, and any EVM op).** `EvmRpc.RpcError`
  mis-modeled three of its four arms versus `evm_rpc.did` — `ProviderError`,
  `HttpOutcallError`, and `ValidationError` are variants on the wire, not flat
  `{ code; message }` records. A multi-provider response is Candid-decoded *whole*
  before consensus runs, so a single provider returning one of those (a common
  transient testnet failure) trapped the entire call. Now mirrors the canister
  candid exactly. Surfaced as a Step-7 session-open failure but could hit
  settle/verify/identity too.
- **All compiler warnings cleared.** `M0155` (Nat-subtraction trap risk, 7 sites,
  all provably guarded → `Utils.satSub`) and `M0194` (unused, 4 sites) removed; the
  build is warning-free.

### Breaking (Motoko library — direct consumers only)

- **`EvmRpc.RpcError`** arms changed shape to match `evm_rpc.did`: `ProviderError`,
  `HttpOutcallError`, and `ValidationError` are now variants (with their real
  sub-types), not `{ code : Int32; message : Text }` records; `JsonRpcError` is
  unchanged. Code that pattern-matches these arms directly must update — consumers
  using `EvmRpc.rpcErrorToText` (the normal path) are unaffected.

### Dependencies

- `mo:ic` 4.0.0 → **4.1.0**
- `mo:sha2` 0.2.1 → **0.2.4** — SHA-256 output unchanged (hash-dependent suites
  green; the tECDSA EVM address derives identically), and it stays under the
  IC0505 Wasm-locals limit after `wasm-opt -O` (96/1900).

### Docs

- **`docs/costs-and-rails.md`** — measured per-operation cycle costs (a single EVM
  settle nets ~17B cycles locally, not the ~100B *reserve* in code comments), the
  cycle buffer operators must hold, and rail selection by payment size.
- **`docs/security-model.md`** — what's defended by default, the secure-by-default
  integration checklist (the four guards that live only in `example/main.mo`), and
  the key-custody / blast-radius model.

### Tooling

- Replica-backed integration CI job (B4) with a `.did`-sync gate; the ckUSDC ledger
  is now mintable on a fresh `local-dev` (CI funding fix).

## v2.1.1 — 2026-06-17

Patch release. Makes the example canister installable on the current IC (the
critical fix), confirms outbound EVM transfers before finalizing, fixes four
issues found running the demo end-to-end on Base Sepolia, and surfaces on-chain
settlement proof on content delivery. No wire/HTTP or `@ic402/client` breaking
changes; two Motoko-library breaking changes for direct consumers (below).

### Breaking (Motoko library — direct consumers only)

- **`ServiceRegistry.EvmTransferFn`** return type widened from `{#ok; #err}` to
  `{#confirmed; #reverted; #pending; #err}` (the B2 confirmation fix). A canister
  that wires the marketplace EVM-transfer hook via `setEvmTransfer` must update
  its callback's return type — no shim. `Gateway`/`EvmSender` gained a matching
  `sendErc20TransferConfirmed` (tri-state); the old `sendErc20Transfer` is retained.
- **`Types.ContentDelivery`** gained a `settlementTxHash : ?Text` field, so Motoko
  code *constructing* a `ContentDelivery` must supply it. Readers are unaffected,
  and the Candid / `@ic402/client` decoders treat it as additive.

### Fixed

- **Installability (critical):** the example WASM was rejected at install time —
  `moc` unrolls `mo:sha2`'s SHA-256 compressor into **2081 Wasm locals** in one
  function, over the IC's 2000-locals-per-function limit (IC0505). The build now
  runs `wasm-opt -O` (binaryen ≥ v130) to coalesce them (2081 → 96 locals);
  `setup.sh` installs the optimized module, and a `wasm-locals` CI job +
  `scripts/check-wasm-locals.js` gate it. No crypto rewrite. (B0)
- **Outbound settlement confirmation:** marketplace `settleJob`/`refundOnRail`
  and EVM session close now confirm the transfer mined (`status==1`) before
  finalizing `#Settled`/`#Refunded`/`#closed` — an unconfirmed or reverted
  broadcast no longer marks a job/session paid. `EvmSender.sendTransaction`
  distinguishes maybe-broadcast from pre-broadcast failure to avoid double-pay. (B2)
- **Demo Step 8 (Agent Identity):** raised the ERC-8004 register gas limit
  (350k → 600k; a real mint needs ~396k) so it no longer reverts out-of-gas, and
  the client SDK now throws on a reverted receipt so a revert is reported
  honestly instead of as `register_agent succeeded / Awaiting confirmation`.
- **Demo Step 4 (delete):** the post-delete payment probe encoded the nonce as
  hex *characters* (Candid `Invalid vec nat8`) and mislabeled the result as a
  replica outage; decode the nonce to bytes (clean rejection, no charge) and
  report a paid-endpoint 402 as the expected gated response, not a warning.
- **Demo Step 2:** corrected the content-encryption label to **ChaCha20-Poly1305
  AEAD (RFC 8439)** — it had incorrectly said "SHA-256-CTR".
- Integration test suite made deterministic vs replica state (binds to its own
  registered service id, not a hardcoded `svc-1`). (P0)

### Added

- **`ContentDelivery.settlementTxHash : ?Text`** — `getContent` now returns the
  on-chain settlement proof (EVM tx hash / ICP ledger block index) of the payment
  that unlocked the content; the demo's Step 3 prints it. Added to the Motoko
  library type (constructors must supply it — see Breaking), the `@ic402/client`
  IDL/TS type, and the example `.did`.

### Changed

- Non-interactive demo (`IC402_DEMO_CI=1`) exercises the Base Sepolia EVM path by
  default (override with `IC402_DEMO_DEFAULT_CHOICE=1`).
- zk-verifier: the prebuilt deploy artifact moved to
  `example/zk-verifier/prebuilt/zk_verifier.wasm.gz`; the Rust `target/` build
  tree is no longer tracked (gitignored), so local builds stop dirtying the tree.
- Docs: reconciled `AUDIT.md`, brought `README.md` current, added
  `integrations/mcp/README.md`, `SECURITY.md`, and a production-readiness backlog
  (`docs/production-readiness.md`).

> **Not production-ready yet.** This patch closes B0/B2 and the demo issues, and
> a funded Base Sepolia run now completes end-to-end (real `status==1` settle,
> session close+refund, and an ERC-721 mint). Remaining blockers — B1 (upgrade
> migration from v2.0.0), a Foundry-fork/CI replay for the EVM rail (B3), a
> replica-backed CI job (B4), and the composed-system security pass (SEC-0..4) —
> are tracked in `docs/production-readiness.md` and are **not** closed here.

## v2.1.0 — 2026-06-15

x402 **v2 compliance**, the EVM/marketplace settlement paths, live policy
introspection, and an honest interactive demo.

> ⚠️ **Contains breaking changes despite the minor version.** ic402 is early-stage and
> the minor bump is deliberate — but
> if you consume the Motoko library, the `@ic402/client` types, or talk to the canister
> with a **v1** x402 client, treat this as a breaking upgrade and read the section below.

### Breaking interface changes

- **Motoko library (no overloads/defaults to shim — direct callers must update):**
  - `Gateway.settle(signature)` → `settle(signature, expectedAmount : ?Nat)` — enforces
    per-resource exact-equality for nonce-less (stock EVM) clients + cross-resource guard.
  - `HttpHandler.http402(requirements)` → `http402(requirements, resourceUrl)`.
  - `HttpHandler.paymentRequiredJson(requirements)` →
    `paymentRequiredJson(requirements, resourceUrl, errorMsg : ?Text)`.
  - `Policy.releaseDaily(caller, amount)` → `releaseDaily(caller, day, amount)`.
- **`@ic402/client`:** the exported `buildX402PaymentHeader` is **removed** (it emitted a
  conflicting `x402Version:1` payload; use `fetchX402` / `applyVerbatimAccepted`).
  `X402PaymentRequirement` now **requires** `amount: string` (v2 atomic units);
  `maxAmountRequired` remains an optional **reader** alias only — constructors must supply `amount`.
- **Wire (affects a deployed v1 client):** the 402 challenge emits `amount` and no longer
  `maxAmountRequired` server-side; exact-EVM now requires `value == amount` (a prior
  **overpayment is rejected**); `ic402Nonce`/`expiry` moved under `extra`; marketplace
  buyers are charged price **+ ledger fee** so settlement can pay the operator.

### Retained for back-compat

- The canister still accepts the legacy `x-payment` header (prefers `PAYMENT-SIGNATURE`).
- The EVM rail is now payable **without** the ic402 server nonce (v2); the ICP rail still
  uses it, and an echoed nonce is still honored.
- `@ic402/mcp`: every baseline tool name + input schema is unchanged (purely additive).

### Added

- **x402 v2**: v2 wire format + header transport (`PAYMENT-REQUIRED` / `PAYMENT-SIGNATURE`
  / `PAYMENT-RESPONSE`), CORS/OPTIONS, the exact-EVM scheme; self-hosted **facilitator**
  (`GET /supported`, `POST /verify`, `POST /settle`) and discovery `GET /discovery/resources`.
  See `docs/x402-compliance.md`.
- **`getPolicyConfig`** query — read back the live global `SpendingPolicy`; the demo's
  policy step displays it live instead of hardcoding.
- Real EVM streaming sessions; on-chain marketplace settlement + refunds to the operator;
  `quoteServiceRequest` read-only price query.
- `@ic402/mcp`: 7 new dedicated operator tools (`upload_content`, `delete_content`,
  `register_service`, `enable_service`, `claim_job`, `submit_job_result`,
  `sign_typed_data`), default-denied where dangerous. `@ic402/client`: `applyVerbatimAccepted`
  and an optional `probeX402` redirect-validation option.

### Fixed

- **EVM fee data**: `getFeeData` no longer parks a session close on transient
  multi-provider `#Inconsistent` base-fee disagreement (takes the max base fee, clamped to
  a 10 000 gwei ceiling so a hostile/buggy provider can't inflate the gas reservation);
  nonce/send consensus stays strict.
- **`verifyPayment`**: resolves the EIP-712 domain from the token matching the paid `asset`
  (not `tokens[0]`) — a valid signature for a non-first token on a multi-token chain no
  longer fails; unconfigured assets are rejected.
- Demo honesty: every reported success/metric is gated on the real canister verdict — a
  reverted/failed payment no longer renders as completed, and live values replace hardcoded ones.

### Tooling

- One uniform project version: `scripts/version.sh` now bumps **every** place the
  version lives — `mops.toml` (source of truth), all four `package.json` files
  (root + `packages/client` + `integrations/mcp` + `example/client`), the
  `example/zk-verifier` `Cargo.toml` + `Cargo.lock`, and the runtime version
  literals in the MCP server and demo client (`McpServer`/`Client({ version })`),
  which had drifted to `0.1.0`. The source-literal seds are guarded (a bump fails
  loudly if the pattern moves), and a same-version run re-syncs any drifted file.

### Tests

- `mops test`: 16 suites (adds `test/gateway.test.mo` for verifyPayment asset/domain
  resolution and `test/evmsender.test.mo` for the fee math + ceiling; `getGlobalPolicy`
  round-trip in `test/policy.test.mo`). Client SDK: 72 vitest tests.

## v2.0.0 — 2026-06-08

Security release. Fixes all confirmed Critical, High, and Medium findings from the
full-codebase audit (`AUDIT.md`). **This is a breaking release** — see the
"Breaking interface changes" section before upgrading. v2 stable state is not
upgrade-compatible from v1 in all modules; treat as a fresh deploy or migrate
deliberately (see "Migration").

### Critical fixes

- **C1 — EVM settlement now validates the payment recipient.** `Gateway.settle`
  and `Sessions.openEvmSession` now require the EIP-3009 `authorization.to` to equal
  the canister's own derived EVM address. Previously a payer could sign a
  self-transfer (`to` = an address they control), pass signature verification, have
  the canister pay gas to broadcast it, and still receive a valid receipt / funded
  session — a complete payment bypass and (for sessions) a treasury-drain vector.
- **C2 / C3 — MCP server no longer exposes the controller signing key to the LLM.**
  The generic `call` tool is restricted to a read-only/query allowlist; `fetch_x402`
  enforces a URL allowlist (SSRF), per-call + cumulative spend caps, and explicit
  confirmation before signing. (`integrations/mcp`.)
- **C4 — Service-marketplace escrow custody fixed.** `ServiceRegistry.settleJob` /
  `expireJobs` now pay the operator and refund the buyer from the platform recipient
  account (where the payment actually lands) instead of an unfunded per-job
  subaccount, so settlements/refunds no longer fail with `InsufficientFunds`.
- **C5 — EVM service-over-HTTP no longer traps after payment.** The example passes
  `receipt.sender` to the registry as `Text` instead of `Principal.fromText(...)`,
  which trapped for 0x EVM senders *after* the on-chain transfer had executed.

### High fixes

- **H1** — EVM settlement waits for on-chain confirmation (`eth_getTransactionReceipt`,
  status == 1) before issuing a receipt; reverted/never-mined transfers no longer
  yield a "paid" receipt. New `PaymentResult` variant `#settlementPending`.
- **H2** — `EvmSender` reads the `#Pending` chain nonce before every send (removed the
  stale in-memory nonce cache that desynced against `EvmSigner` on the shared address).
- **H3** — `EvmSender` no longer broadcasts with a fabricated ~0.1 gwei fee when fee
  data is unavailable; it returns an error so the caller can retry.
- **H4** — Daily spending limit is reserved *before* the settlement await
  (`Policy.reserveCharge` / `reserveSessionOpen` + `releaseDaily`), closing the
  concurrent-charge bypass.
- **H5** — `ServiceRegistry` settlement uses a synchronous `#Settling` reservation to
  prevent double-settle/double-refund via racing `confirmJob`.
- **H6 / H7** — `ContentStore` requires external-randomness seeding (no more
  deterministic key from the public principal) and persists the key across upgrades.
- **H8** — Access grants are non-transferable: `verifyGrant` now takes the caller and
  requires `caller == grant.grantee`.
- **H9 / H10** — The HTTP x402 flow works end-to-end: paid GETs upgrade to update
  context so the 402 nonce is persisted, and the 402 response now carries the server
  nonce (`ic402Nonce`) for EVM clients to echo and bind the amount.
- **H11 / H12 / H13** — MCP `fetch_content` validates delivery targets (SSRF), and all
  money-moving tools enforce spend caps + confirmation.
- **H14** — Prebuilt ledger/EVM-RPC WASMs are verified against pinned SHA-256 hashes
  before deploy (`scripts/prebuilt.sha256`).

### Medium fixes

- **M1 / M8** — HMAC grant key uses the full 256-bit seed (was truncated to 64 bits).
- **M2** — `ContentStore` mixes a per-entry salt into key/nonce derivation, so
  delete + re-put of the same id never reuses a (key, nonce) pair.
- **M5** — `NonceManager` enforces a hard cap (oldest unlocked nonces evicted),
  bounding memory under 402-challenge spam.
- **M6** — `ServiceRegistry` adds `resolveDispute` and auto-expires stuck
  `#Submitted`/`#Disputed` jobs, so escrow can never be locked permanently.
- **M7** — Voucher signatures bind the verifying canister's principal (cross-canister
  replay protection on Ed25519 key reuse).
- **M9** — Session deposits are counted against the daily limit once and credited back
  on close (was double-counted: deposit + every voucher delta, never refunded).
- **M10 / M11** — Deploy scripts can't poison the source backup with testnet-patched
  content, and backups are gitignored / mainnet markers re-verified after restore.

### Breaking interface changes

**Motoko library API (recompile required):**
- `Gateway.verifyGrant(grant)` → `verifyGrant(caller : Principal, grant)`.
- `Grants.verifyGrant(grant)` → `verifyGrant(caller : Principal, grant)`.
- `Sessions.encodeVoucherPayload(sessionId, amount, sequence)` →
  `encodeVoucherPayload(canisterId : Text, sessionId, amount, sequence)`.
- `ServiceRegistry.submitRequest(buyer : Principal, …)` → `submitRequest(buyer : Text, …)`.
- `ServiceRegistry` no longer settles to an escrow subaccount; new
  `resolveDispute(jobId, refundBuyer : Bool)`.
- `EvmSender.getFeeData` is internal and now returns `?(Nat, Nat)`; new public
  `EvmSender.confirmTransaction(chainId, txHash, maxPolls)`.
- New `Policy` methods: `reserveCharge`, `reserveSessionOpen`, `releaseDaily`.
- `ContentStore` requires `initExternalSeed(...)` (or `startTimers()`) before any
  write — writes trap until seeded.

**Candid / wire / serialized formats (coordinate clients & upgrades):**
- `PaymentResult` gains `#settlementPending`; `JobStatus` gains `#Settling`
  (exhaustive matchers must add these variants).
- Voucher signed payload is now CBOR array(4) `[canisterId, sessionId, cumulativeAmount,
  sequence]` (was array(3)). **Client and canister must be upgraded together; in-flight
  vouchers are invalidated.** `@ic402/client` `signVoucher` gains a `canisterId` argument
  (handled automatically by the session handle).
- The 402 response JSON now includes `ic402Nonce` and `expiry`; EVM-over-HTTP clients
  must echo `ic402Nonce` in the X-PAYMENT payload (the `@ic402/client` `fetchX402`
  helper does this automatically).
- Stable schemas changed: `StableContentStoreState` (+`masterKey`, `seedInitialized`,
  `saltCounter`), `StableContentEntry` (+`salt`). New fields are optional so the
  upgrade decodes, but pre-v2 deterministic-key content is not decryptable under the
  v2 required-seed model.

**MCP server behavior (intended):**
- `autoPayment` defaults to **off**; money-moving/signing tools require `confirm: true`
  and enforce `perCallMaxAtomic` / `sessionMaxAtomic` caps; the generic `call` tool is
  read-only.

### Dependencies

- `ic` 3.2.0 → **4.0.0** (major). Canister types moved from the top-level `mo:ic`
  module to `mo:ic/Types`; `lib.mo` updated accordingly (`HttpResponse_` now aliases
  `ICTypes.HttpRequestResult`).
- `ecdsa` 7.1.0 → **8.0.0** (major). No source changes required (`mo:ecdsa/Curve` API
  compatible).
- `sha2` 0.1.14 → **0.2.1** (minor). No source changes required.
- **Toolchain:** `moc` 1.3.0 → **1.9.0** (required by `ic@4.0.0` / `ecdsa@8.0.0`, which
  need moc ≥ 1.4.0). Integrators must build with moc ≥ 1.4.0.

### Migration

- **EVM identity unchanged:** the canister's EVM address is the same (H2 reads the
  pending nonce rather than changing derivation paths), so no re-funding is needed.
- **ContentStore:** call `store.startTimers<system>()` (or `initExternalSeed(await
  raw_rand())`) once after deploy. Content stored under the pre-v2 deterministic key
  must be re-uploaded.
- **Sessions/vouchers:** upgrade `@ic402/client` and the canister together.
- **Service marketplace:** the platform recipient account custodies funds; operator
  payouts and buyer refunds now transfer from it.

## v1.0.0 — 2026-04-05

### Breaking Changes

- **X402Client removed**: Outbound x402 payments now use EvmSigner (canister signs) + client library (probes URL, broadcasts tx). The canister no longer makes EVM RPC outcalls for outbound operations, reducing cycles cost 40-85%.
- **Identity stripped to metadata**: `registerAgent()`, `getEvmNonce()`, `getFeeData()`, `buildRegisterCalldata()`, `parseAgentRegisteredEvent()` removed. Registration now uses `EvmSigner.signRegistration()` + client-side broadcast.
- **EvmSender is internal-only**: No longer exported from `lib.mo`. Used internally by Gateway for inbound settlement.
- **Client BudgetConfig removed**: Client-side budget tracking was advisory only (not enforceable by a compromised client). Canister-side SpendingPolicy is the enforcement point.
- **ServiceRegistry buyer parameter**: `submitRequest`, `confirmJob`, `disputeJob` now take `Principal` instead of `Text`.

### New Modules

- **EvmSigner** (`src/ic402/EvmSigner.mo`): Remote signing module — canister holds tECDSA key and signs; client handles all RPC/HTTP. Methods: `signTransaction`, `signErc20Transfer`, `signEthTransfer`, `signEip3009Authorization`, `signRegistration`, `signTypedData`.
- **ServiceRegistry** (`src/ic402/ServiceRegistry.mo`): Paid service marketplace coordinator. Canister escrows funds, assigns jobs to operators, verifies results (AutoSettle, HashMatch, BuyerConfirm, ZkGroth16), and settles payment. Full job lifecycle: Pending → Assigned → Submitted → Verified → Settled.
- **ZK Verifier** (`example/zk-verifier/`): Reference Rust canister implementing Groth16/BN254 verification via arkworks. ~392KB WASM, ~$0.005 per proof.

### New Exports

- `EvmSigner`: the only public EVM module (remote signing)
- `ServiceRegistry`: paid service marketplace
- `Eip712`: EIP-712 hashing utilities (domainSeparator, digest)
- `EvmAddress`: keccak256 hashing
- `EvmUtils`: ABI encoding, hex conversion

### Features

- **Generic EIP-712 signing** (`signTypedData`): Universal primitive for any EIP-712 protocol — DEX agent wallets (Hyperliquid, Vertex, Aevo), permit signatures, meta-transactions.
- **HTTP 202 Accepted**: Async service requests return 202 with poll URL. HTTP `/service/*` and `/job/*` routes added.
- **x402 v2 header**: 402 responses now include base64 `payment-required` header alongside JSON body.
- **Service pricing models**: Exact (fixed price), Upto (max with refund), Session (streaming).
- **Service verification methods**: AutoSettle, HashMatch (SHA-256), BuyerConfirm (dispute window), ZkGroth16 (inter-canister Groth16 proof verification).
- **Timer-based job expiry**: Stale jobs auto-refund. Terminal jobs GC'd after 24h.

### TypeScript Client (`@ic402/client`)

- **New `evm` module**: `probeX402`, `fetchX402`, `findPaymentOption`, `broadcastTransaction`, `pollReceipt`, `registerAgent`, `Ic402Error` with 11 classified error kinds and `retryable` flag.
- **Service methods**: `listServices()`, `submitServiceRequest()` (ICRC-2 auto-pay with nonce handling), `pollJobResult()`, `disputeJob()`.
- **EVM methods**: `sendErc20Transfer()`, `sendEthTransfer()`, `registerAgent()`.
- **Typed config**: `Ic402Identity` interface replaces `unknown`. Options object for `fetchX402`.
- **Fixes**: session publicKey encoding (Uint8Array), ICRC-2 approve fee buffer, EVM session authorization passthrough.

### MCP Server

- New tools: `list_services`, `submit_request`, `get_job_result`, `dispute_job`, `fetch_x402` (direct probe → sign → pay).
- ICRC-2 ledger IDL factory for auto-approval.
- 15s AbortController timeouts on HTTP requests.

### Security

- **C-1**: EVM session close leaves `#closing` (not `#closed`) when refund fails, preserving `recoverEscrow` path.
- **H-1**: `EvmSender` txInProgress lock serializes concurrent EVM transactions (prevents nonce desync).
- **H-2**: `forceCloseSession()` has WARNING doc — consuming canister MUST add access control.
- **H-5**: `recoverEscrow` restricted to unconsumed portion, always refunds to payer (removed arbitrary recipient).
- **H-6**: `ContentStore.decryptChunkData` returns `?Blob` — propagates auth failures instead of returning empty blobs.
- **M-1**: Revoked grants store timestamps, GC removes entries >7 days old (hourly timer).
- **M-2**: Policy rateLimitLog deletes empty keys after filtering.
- **M-4**: EIP-3009 validAfter/validBefore validated before expensive EVM outcall.
- **M-5**: `expireJobs()` also GCs terminal jobs >24h old.
- **M-6**: EIP-3009 nonce uses `Time.now()` nanoseconds (monotonic, survives upgrades).
- **M-8**: Client `parseAgentRegisteredEvent` checks topics[0] against keccak256 event signature.
- **CF-1**: Example canister restored to mainnet values; deploy scripts patch for local.

### Refactoring

- `Utils.mo`: extracted `isEvmNetwork()`, `extractChainId()`, `findLedger()` from Gateway/Sessions (~50 LOC dedup).
- `Policy.mo`: `warnIfInvalid()` validates invariants on `loadStable()`.
- Removed unused `ic-vetkeys` dependency.

### Testing

- **36 integration tests**: charges (ICP settlement), sessions, content, services, EVM signer, EIP-712, identity, HTTP gateway, ZK verifier, policy.
- **40 Motoko unit tests**: ServiceRegistry lifecycle, disputes, stable state round-trip, edge cases.
- **8 escrow unit tests**: subaccount derivation determinism, uniqueness, prefix isolation.
- **69 client unit tests**: fetchX402, services, polling, error classification, findPaymentOption.

### Demo

- 10-step interactive walkthrough: Configure, ADD Encrypted Content, SELL Content over x402, DELETE Content, SELL Services over x402, BUY over x402, Streaming Micropayments, Agent Identity, EIP-712 Delegate Signing, Policy + Summary.

### Tooling

- `@icp-sdk/icp-cli` upgraded 0.1.0 → 0.2.2 (fixes icp.yaml parse errors when run via pnpm).
- `icp.yaml` schema updated to v0.2.2. ZK verifier added to local environment.
- Setup/reset scripts always stop + clean before starting (port kill, cache purge, pocket-ic reset).

---

## v0.1.5 — 2026-03-28

### Documentation

- Add `///` doc comments to all remaining public declarations across 13 internal modules (EvmRpc, Eip712, EvmVerify, Sessions, Policy, Nonce, Escrow, Grants, EvmEscrow, EvmSender, Utils, HttpHandler, Identity) — targets 100% mops documentation coverage.

### Project Structure

- Rename `integration/` → `integrations/` for consistency with engramx convention. Update all references in workspace config, package.json scripts, version.sh, docs, and example client.
- Untrack `deploy/deploy.sh` — was force-added but belongs to gitignored local-only tooling.

---

## v0.1.4 — 2026-03-28

### API

- Trim public API surface ~60% — only Gateway, ContentStore, Identity, X402Client, and HttpHandler exported from `lib.mo`. Internal modules (Sessions, Nonce, Escrow, Grants, Policy, EvmSender, EvmEscrow, EvmRpc, EvmAddress, Eip712) are no longer re-exported.
- Add `///` doc comments to all 44 public types and all exported APIs.

### Dependencies

- `ic` 2.1.0 → 3.2.0 (adds `is_replicated` field to HTTP outcalls)
- `test` 2.0.0 → 2.1.2

### Package Metadata

- Add `keywords` to `mops.toml` for registry discoverability
- Add CHANGELOG entry for mops release notes

---

## v0.1.3 — 2026-03-27

### Security Hardening

- **C-1**: `recoverEscrow` rejects when session not found (was auth bypass)
- **C-2**: Remove `Math.random()` fallback in EIP-3009 nonce generation
- **H-1**: Add session garbage collection to prevent unbounded memory growth
- **H-2**: Surface EVM address derivation errors in canister logs
- **H-3**: Inline expiry check in `consumeVoucher` (closes timer gap)
- **H-5**: Validate PKCS#8 structure in MCP PEM parsing
- **M-1**: Replace bare `assert()` with descriptive `Debug.trap()` messages
- **M-3**: Rate-limit session open attempts via policy engine
- **M-4**: Validate URL scheme and path traversal in client `fetchContent`
- **M-5**: Return error when EVM chain config missing (was silent default)
- **M-6**: Add Zod validators for EVM addresses/hashes/networks in MCP

### Improvements

- Update `ic` dependency 2.1.0 → 3.2.0 (add `is_replicated` to HTTP outcalls)
- Trim public API surface ~60% — only Gateway, ContentStore, Identity, X402Client, HttpHandler exported
- Add `///` doc comments to all public types and exported APIs
- Add `keywords` to `mops.toml` for registry discoverability
- `@ic402/client` npm package: add README, LICENSE, `files` field, `peerDependencies`, `engines`
- Deploy script: selective stages (`production publish mops`, `production publish npm`, `production canister`)
- Deploy script: auto git push and GitHub release creation

### Dependencies

- `ic` 2.1.0 → 3.2.0
- `test` 2.0.0 → 2.1.2
- Zero npm audit vulnerabilities

---

## v0.2.0 — 2026-03-24

### Standard x402 Compatibility (EIP-3009)

- **EIP-3009 payment settlement**: Standard x402 clients can now pay ic402 servers. The canister acts as its own facilitator, executing `transferWithAuthorization` on USDC contracts via tECDSA.
- **EIP-712 signature verification**: On-canister verification of typed-data signatures for EVM authorization (`Eip712.mo`).
- **x402 v1 response format**: HTTP 402 responses now emit standard `asset`, `payTo`, `maxAmountRequired`, and `extra` fields.
- **Base64 X-PAYMENT header**: Standard x402 header format (base64-encoded JSON) alongside legacy ic402 format.
- **On-canister EVM signing**: RLP encoding, ABI encoding, EIP-1559 transaction construction, and EC recovery — all in pure Motoko (`EvmUtils.mo`, `EvmSender.mo`, `EvmAddress.mo`).
- **Autonomous agent registration**: Canister signs and submits its own ERC-8004 registration tx on Base via tECDSA (`Identity.mo`). No external wallet needed.
- **EVM session deposits via EIP-3009**: Session deposits on EVM chains use `transferWithAuthorization` instead of direct transfers.
- **EVM session settlement**: Close settles consumed amount and refunds remainder via tECDSA-signed ERC-20 transfers.
- **Client SDK EIP-712 helpers**: TypeScript functions for building `TransferWithAuthorization` typed data and `X-PAYMENT` headers (`eip712.ts`).

### Breaking Changes

- **EVM charge settlement requires EIP-3009**: Legacy direct ERC-20 transfer + tx hash flow removed. EVM payments must now use `transferWithAuthorization` authorization signatures.
- **`consumedTxHashes` removed from stable state**: EIP-3009 nonce-based replay protection replaces tx hash tracking.
- **`PaymentSignature.authorization`**: New optional field for EIP-3009 data.
- **`ERC8004Config` expanded**: Now requires `ecdsaKeyName`, `registryAddress`, `chainId`, `evmRpcCanister`, `gasConfig`.
- **`register-agent.ts` removed**: Agent registration is now on-canister via `registerAgent()`.

### Security Fixes

- **C-2**: EVM transfer logs filtered by contract address in `EvmVerify.findTransferLog`
- **H-1**: Grant issuance requires initialized HMAC seed
- **H-2**: Nonces bound to network + token (not just amount)
- **C-1**: Nonce lock state persisted across upgrades

---

## v0.1.0 — 2026-03-23

Initial production release.

### Features

- **x402 charges**: One-shot ICRC-2 payment gating with nonce replay protection
- **Streaming sessions**: Escrow deposits with cumulative Ed25519-signed vouchers
- **Encrypted content store**: In-canister chunked storage with HMAC-bound access grants
- **ERC-8004 identity**: On-chain agent registration on Base via EVM RPC canister
- **Cross-chain settlement**: 5 EVM chains (Base, Ethereum, Avalanche, Optimism, Arbitrum) via EVM RPC canister
- **TypeScript client SDK** (`@ic402/client`): Budget enforcement, session management, content fetching
- **MCP integration**: Model Context Protocol server for AI agent access

### Security

18-finding audit resolved (3 CRITICAL, 5 HIGH, 10 MEDIUM):

- **C-1**: EVM transaction replay prevention (consumed tx hash set)
- **C-2**: HMAC-bound access grants (contentRef.id included in HMAC)
- **C-3**: Nonce-amount binding (prevents amount manipulation)
- **H-1**: Session close authorization (only payer can close)
- **H-2**: Nat64 overflow protection in voucher encoding
- **M-4**: JSON injection prevention via `escapeJsonString`
- **M-5**: Zero-delta voucher rejection
- **M-8**: Escrow recovery authorization (only session payer)
- **M-10**: JSON unescape in `extractJsonField`

### Breaking Changes

- `closeSession` now requires caller to be the session payer (H-1)
- Access grant HMAC now binds `contentRef.id` — grants from prior versions are invalid (C-2)
- `recoverEscrow` now requires caller authorization (M-8)

### Known Limitations

- `discoverAgents()` returns empty array — ERC-8004 registries are sparse, no real data to query yet
- Ed25519 library (`mo:ed25519`) is unaudited
