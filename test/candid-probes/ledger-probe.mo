/// Candid-mirror probe for the ICRC-1/2 ledger surface — NOT a mops test
/// (deliberately no `.test.mo` suffix so `mops test` skips it).
///
/// A minimal actor whose public methods are EXACTLY Types.LedgerActor's three
/// methods (the only ledger methods ic402's Motoko ever calls: icrc1_transfer,
/// icrc1_fee, icrc2_transfer_from), typed with the repo's mirror types. Compiling
/// this file with `moc --idl` emits the mirror's .did, which
/// scripts/check-candid-mirrors.sh compares against the vendored official
/// ICRC-1/ICRC-2 interfaces (test/fixtures/official/) via a pinned `didc check`.
///
/// The `_self` witness makes the probe's surface provably a subtype of
/// Types.LedgerActor at compile time: if LedgerActor gains a method or a
/// signature changes and this probe is not updated to match, the probe stops
/// compiling and the gate fails loudly instead of silently shrinking coverage.
import Types "../../src/ic402/Types";

persistent actor LedgerProbe {
  transient let _self : Types.LedgerActor = LedgerProbe;

  public shared func icrc1_transfer(_arg : Types.TransferArg) : async Types.TransferResult {
    #Ok(0);
  };
  public shared func icrc1_fee() : async Nat {
    0;
  };
  public shared func icrc2_transfer_from(_arg : Types.TransferFromArg) : async Types.TransferFromResult {
    #Ok(0);
  };
};
