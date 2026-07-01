# Upgrade safety for ic402 consumers

ic402 is a **library**. A consumer canister embeds ic402's four stable snapshots —
`StableGatewayState`, `StableContentStoreState`, `StableIdentityState`,
`StableServiceRegistryState` — in its own persisted state and restores them with `loadStable`
on every upgrade. If a future ic402 release changes one of those types **incompatibly** (removes
or retypes a field, or adds a field to an existing stable record), the consumer's old persisted
blob no longer decodes into the new type, and `loadStable` **traps at upgrade time on a live,
fund-holding canister** — the canister is stuck, with the funds and data inside it.

This is the one upgrade failure that bites *despite* the consumer's own orthogonal-persistence
checks, because the incompatibility is hidden inside a dependency's opaque snapshot. ic402 guards
against it on two sides.

## 1. Prevention — the CI gate (library side)

`scripts/check-stable-compat.sh` (CI job `stable-compat`) stops ic402 from *shipping* an
un-versioned breaking stable change.

- **Anchor.** `test/stable-anchor.mo` is a minimal `persistent actor` that persists exactly the
  four `Stable*State` types as mutable `var`s and nothing else. `moc --stable-types` emits its
  **fully-expanded** stable signature (every nested type — `Job`, `Session`, `ParkedTx`, … — is in
  scope), which *is* the library's stable contract. Using a dedicated anchor (rather than the
  example app) keeps application state out of the signature and guarantees all four types are
  always covered.
- **Oracle.** The gate compares that signature to the committed baseline (`test/stable-anchor.most`,
  stamped with the schema version it represents) with moc's own `--stable-compatible` — the *same*
  check the IC runtime runs at upgrade. No hand-rolled diff; subtle rules (a new variant case is
  fine; a new field on a `stable var` record is **not**) are inherited exactly.
- **Enforcement.** A change that stays upgrade-compatible passes with no bump. A change that is
  **incompatible** from the baseline fails **unless `Ic402.STABLE_SCHEMA_VERSION` was bumped above
  the baseline's stamp** — so a breaking change cannot ship silently; it must move the version that
  consumers watch. `--update` (the baseline-advance step) itself refuses to stamp a breaking advance
  without a bump. A `--self-test` run proves the gate still rejects a break and accepts an additive
  change, so a future toolchain change can't quietly turn it into a no-op.

Releasing across a breaking change therefore means: bump `STABLE_SCHEMA_VERSION`, ship a migration,
and run `./scripts/check-stable-compat.sh --update` to advance the baseline (commit the new
`.most`). The baseline represents the **last released** stable signature, so the gate proves head is
upgrade-compatible *from that release*, or the version moved.

> **Note:** the gate is **structural**, not semantic. Reinterpreting a same-typed field (e.g.
> changing `amount`'s units, or repurposing an opaque `Blob`) is upgrade-compatible to moc but still
> mis-maps live data — that judgement stays with the author. Bump the version for a semantic break too.
>
> **Trust boundary:** the gate trusts the committed baseline (`test/stable-anchor.most`) as the last
> released signature. Hand-editing it to embed a breaking change while leaving the stamp/version
> unchanged would defeat the gate — but the baseline carries a "do not hand-edit" header and any such
> edit is a conspicuous stable-contract diff with no version move (a clear review red flag). Advance
> it only with `--update`, which refuses a breaking advance without a version bump.

## 2. Detection — the schema version (consumer side)

`Ic402.STABLE_SCHEMA_VERSION : Nat` is a single, coarse "any library stable type changed" signal.
A consumer **persists it next to ic402's snapshots and checks it before `loadStable`**, turning a
cryptic decode trap into a clear, actionable error — or a migration branch.

`Ic402.checkSchemaVersion(persisted)` returns `#ok` (decode directly), `#migrate { from; to }`
(persisted state is older — migrate first), or `#ahead { persisted; current }` (persisted state is
from a *newer* ic402 — a downgrade; refuse).

The reference wiring is in [`example/main.mo`](../example/main.mo): a `stable var
stableSchemaVersion` initialised to `Ic402.STABLE_SCHEMA_VERSION`, checked in the load block before
`loadStable` (trap on `#migrate`/`#ahead` until a migration is written), and re-stamped after
loading.

```motoko
stable var stableSchemaVersion : Nat = Ic402.STABLE_SCHEMA_VERSION;

// in the post-upgrade load block, BEFORE loadStable:
switch (Ic402.checkSchemaVersion(stableSchemaVersion)) {
  case (#ok) {};
  case (#migrate({ from; to })) { /* migrate old -> new, or trap with a clear message */ };
  case (#ahead({ persisted; current })) { /* refuse the downgrade */ };
};
// ... loadStable each component ...
stableSchemaVersion := Ic402.STABLE_SCHEMA_VERSION;
```

### Why one global version (not per-component)

`STABLE_SCHEMA_VERSION` is a single `Nat` covering all four components, not one version each. It is
a deliberate coarse signal: a bump means "at least one ic402 stable type changed incompatibly —
consult the CHANGELOG for which." A consumer that persists only some components still treats any
bump as relevant and checks the CHANGELOG for the components it uses. (Per-component versions would
be finer but change the public contract; the single `Nat` keeps the consumer check trivial.)

## When you bump ic402

1. Read the CHANGELOG for the target release. If `STABLE_SCHEMA_VERSION` did **not** change, an
   in-place upgrade is stable-compatible — deploy normally.
2. If it **did** change, write a migration from your persisted version to the new layout (or accept a
   documented state-dropping fresh deploy), wire it into the `#migrate` branch, and upgrade.

## Transient in-flight state — drain before upgrading

Not all ic402 state is in the four stable snapshots. Some short-lived, in-flight recovery state is
deliberately **transient** (in-heap, not serialized in `toStable`), so it does **not** survive an
upgrade — the same way a `transient` field would be wiped. This keeps it out of the stable contract
(no `STABLE_SCHEMA_VERSION` bump), at the cost of being lost if you upgrade while it is non-empty.

The one that holds **funds** is the **inbound EVM deposit tracker** (`pendingEvmDeposits`): a session
deposit that was broadcast but not confirmed within `openSession`'s poll budget is tracked so it can
be reconciled (refunded) if it later mines. Upgrading while an entry is pending drops it from the
tracker — the payer's deposit would then need manual recovery via the tx hash in the
`#settlementPending` error.

To avoid that, the library exposes a **drain protocol** (controller-gated at the consumer). Before an
upgrade:

1. `setEvmDrainMode(true)` — new inbound EVM session opens are rejected (before any funds move).
2. Poll `pendingEvmDepositCount()`; `reconcileEvmDeposit(txHash)` each straggler (refund-on-confirm)
   until the count reaches **0**. `listPendingEvmDeposits()` enumerates them.
3. Upgrade the canister.
4. `setEvmDrainMode(false)` — resume (drain mode is itself transient, so it also auto-resets to
   `false` on upgrade).

The canister cannot detect an imminent upgrade on its own (the IC does not signal it), so this is a
controller-run procedure, not automatic. The parked EVM **close** txs (`closeParkedTxs`) are transient
for the same reason; a session parked mid-close across an upgrade falls under the B1 fresh-deploy
waiver and is recovered with `forceResolveSession` + `sweepEvm`.
