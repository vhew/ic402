/// 2.18.0 — a refund the close could not make is reported and never stranded.
///
/// When an ICP close's refund leg fails (the ledger refuses it, or rejects the call), the session ends
/// #closed with the payer's remainder still in its escrow subaccount, recoverable only by the payer's
/// recoverEscrow — which needs the session record. Before 2.18.0 nothing reported it (the expiry
/// sweep drops its results; sessionCounts counted it `closed` like a clean close) and the 24h GC then
/// deleted the record, stranding the remainder for good. Now:
///   - sessionCounts().refundOwed counts it, from either close path (the payer's or the sweep's);
///   - recoverEscrow clears it once less than one fee is left (a partial recovery does not);
///   - gcClosedSessions keeps the record while it is owed;
///   - refundOwedToStable / loadRefundOwed carry it across an upgrade without touching StableSession.
///
/// The fake ledger is an in-file `persistent actor` (as in test/closeledger.test.mo): it answers
/// icrc1_fee with 10_000, and transfer number `errAt` with #Err / number `rejectAt` with a reject
/// (1-based; 0 = never). Each test names the mutation that turns it red.
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");

let ledger = persistent actor {
  var errAt = 0; var rejectAt = 0; var transfers = 0;
  public func script(e : Nat, r : Nat) : async () { errAt := e; rejectAt := r; transfers := 0 };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_fee() : async Nat { 10_000 };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult {
    transfers += 1;
    if (transfers == rejectAt) { throw Error.reject("transfer rejected") };
    if (transfers == errAt) { #Err(#TemporarilyUnavailable) } else { #Ok(transfers) };
  };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { #Ok(1) };
};
let ledgerP = Principal.fromActor(ledger);

/// A session record: deposited 50_000, consumed 1_000 (so a close settles 1_000 + a 10_000 fee and
/// leaves 39_000 in escrow, of which the refund tries to send 29_000).
func stable_(id : Text, status : Types.SessionStatus, lastActivityAt : Int, idleTimeout : ?Int) : Types.StableSession = {
  id; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed = 1_000;
  remaining = 49_000; voucherCount = 1; status; openedAt = 0; lastActivityAt;
  lastSequence = 1; lastCumulativeAmount = 1_000; subaccount = Blob.fromArray([]); network = "icp:1";
  token = "TKN"; recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout; evmDeposit = null;
};

func mk(data : [Types.StableSession]) : Sessions.Sessions {
  let m = Sessions.Sessions(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = ledgerP; symbol = "TKN"; decimals = 8 }]; evmChains = []; evmRpcCanister = null; ecdsaKeyName = null; nonceExpirySeconds = null },
    Policy.Engine(), Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
  );
  m.loadStable(data);
  m;
};

func owed(m : Sessions.Sessions) : Nat { m.sessionCounts().refundOwed };

func exists(m : Sessions.Sessions, id : Text) : Bool {
  switch (m.getSession(id)) { case (?_) { true }; case (null) { false } };
};

await suite("an owed refund is reported (2.18.0)", func() : async () {

  await test("a refund the ledger refuses → counted; a clean close is not", func() : async () {
    // Mutation: drop the refundOwed.put in the refund-failure arm — the count stays 0.
    await ledger.script(2, 0); // transfer 1 (the settle) succeeds, transfer 2 (the refund) is refused
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert owed(m) == 1;
    assert m.sessionCounts().closed == 1;
    // Control: the same close with a working ledger owes nothing.
    await ledger.script(0, 0);
    let c = mk([stable_("sess-1", #open, 7, null)]);
    switch (await c.closeSessionInternal("sess-1")) { case (#ok(_)) {}; case (_) { assert false } };
    assert owed(c) == 0;
    assert c.sessionCounts().closed == 1;
  });

  await test("a refund the ledger rejects → counted", func() : async () {
    // Mutation: as above.
    await ledger.script(0, 2);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert owed(m) == 1;
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 39_000; fee = 10_000 }];
  });

  await test("the sweep: a refund rejected during the expiry close is counted; the other session is not", func() : async () {
    // Mutation: as above. This is the path EngramX reported: the timer drops the sweep's results, so
    // the count is the only place the failure shows.
    await ledger.script(0, 2); // the first session swept: settle #1 ok, refund #2 rejected; the second closes cleanly
    let m = mk([stable_("sess-1", #open, 0, ?1), stable_("sess-2", #open, 0, ?1)]);
    let results = await m.closeExpiredSessions();
    assert results.size() == 2;
    assert m.sessionCounts().closed == 2;
    assert owed(m) == 1;
  });
});

await suite("recoverEscrow settles an owed refund (2.18.0)", func() : async () {

  await test("a partial recovery leaves it owed; emptying the escrow clears it", func() : async () {
    // Mutations: clear the entry on any successful recovery (the partial step reads 0); never clear it
    // (the final step reads 1); subtract without the fee (the final step leaves 10_000 > fee, still 1).
    await ledger.script(2, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    await ledger.script(0, 0);
    // 39_000 in escrow: 10_000 + its fee leaves 19_000 — still more than a fee, so still owed.
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 10_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    assert owed(m) == 1;
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 19_000; fee = 10_000 }];
    // 9_000 + its fee empties it.
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 9_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    assert owed(m) == 0;
  });

  await test("a recovery the ledger refuses changes nothing", func() : async () {
    // Mutation: account for the recovery before checking its result — the count would drop.
    await ledger.script(2, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    await ledger.script(1, 0); // the recovery transfer is refused
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 29_000)) { case (#err(_)) {}; case (#ok(_)) { assert false } };
    assert owed(m) == 1;
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 39_000; fee = 10_000 }];
  });
});

await suite("an owed record outlives the GC and an upgrade (2.18.0)", func() : async () {

  await test("gcClosedSessions keeps an owed record past 24h and deletes a clean one", func() : async () {
    // Mutation: drop the refundOwed check from gcClosedSessions — the owed record is deleted, and with
    // it the only thing that authorizes recoverEscrow. The clean record is the control: if this test
    // clock could not age a record past 24h, it would survive too and the test would fail, not pass.
    // The interpreter's Time.now() is within a day of 0, so the records' last activity is set 25h
    // BEFORE 0 to put them past retention whatever small value the clock returns.
    let aged : Int = -25 * 60 * 60 * 1_000_000_000;
    let m = mk([stable_("sess-owed", #closed, aged, null), stable_("sess-clean", #closed, aged, null)]);
    m.loadRefundOwed([{ sessionId = "sess-owed"; escrow = 39_000; fee = 10_000 }]);
    m.gcClosedSessions();
    assert not exists(m, "sess-clean");
    assert exists(m, "sess-owed");
    assert owed(m) == 1;
  });

  await test("refundOwedToStable / loadRefundOwed carry the count across an upgrade", func() : async () {
    // Mutation: loadRefundOwed ignores its input — the restored count reads 0.
    await ledger.script(2, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    let restored = mk(m.toStable()); // the upgrade: sessions through toStable, owed refunds on their own
    assert owed(restored) == 0; // not persisted → restarts at 0 (the pre-2.18 behaviour, documented)
    restored.loadRefundOwed(m.refundOwedToStable());
    assert owed(restored) == 1;
    assert restored.refundOwedToStable() == m.refundOwedToStable();
  });
});
