# Changelog

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
