/// Stable-compat ANCHOR — a test fixture, NOT a deployable canister.
///
/// ic402 is a library with no actor of its own, but a consumer canister persists ic402's four
/// `Stable*State` snapshots through pre/postupgrade. scripts/check-stable-compat.sh compiles THIS
/// minimal `persistent actor` with `moc --stable-types` to capture exactly that stable surface as a
/// `.most` signature, then asserts upgrade-compatibility against the committed baseline
/// (test/stable-anchor.most) with moc's own `--stable-compatible` oracle.
///
/// Why a dedicated anchor (not example/main.mo):
///   - It persists EXACTLY the four library `Stable*State` types and nothing else, so the signature
///     is the library's stable contract — no application state (e.g. an example's ledger config)
///     leaking in as false-positive surface.
///   - All four types are ALWAYS present, so coverage can't silently shrink if an example/consumer
///     drops a component.
///   - The vars are mutable (`var`), matching how a real consumer holds them (it reassigns them in
///     preupgrade). A `var`'s type is INVARIANT across upgrade, which is the stricter — and correct —
///     compatibility the gate must measure (e.g. adding a field to one of these records IS breaking,
///     which a `let`-based anchor would wrongly wave through).
import Ic402 "../src/ic402/lib";

persistent actor StableAnchor {
  var gateway : ?Ic402.StableGatewayState = null;
  var content : ?Ic402.StableContentStoreState = null;
  var identity : ?Ic402.StableIdentityState = null;
  var services : ?Ic402.StableServiceRegistryState = null;
};
