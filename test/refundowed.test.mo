/// 2.18.0 — a refund the close could not make is reported and never stranded.
///
/// When an ICP close's refund leg fails (the ledger refuses it, or rejects the call), the session ends
/// #closed with the payer's remainder still in its escrow subaccount, recoverable only by the payer's
/// recoverEscrow — which needs the session record. Before 2.18.0 nothing reported it (the expiry
/// sweep drops its results; sessionCounts counted it `closed` like a clean close) and the 24h GC then
/// deleted the record, stranding the remainder for good. Now:
///   - sessionCounts().refundOwed counts it, from either close path (the payer's or the sweep's);
///   - recoverEscrow clears it once one fee or less is left (a partial recovery does not);
///   - gcClosedSessions keeps the record while it is owed;
///   - refundOwedToStable / loadRefundOwed carry it across an upgrade without touching StableSession.
/// 2.22.0: the entry is the payer's whole claim on an ICP escrow:
///   - forceResolveSession writes one (deposited − consumed, fee 0), and recoverEscrow pays only
///     against an entry, never more than it in total, one recovery at a time;
///   - recoverEscrow uses the session's own ledger and refuses any other;
///   - clearRefundOwed drops an entry whose escrow is in fact empty;
///   - gcClosedSessions deletes #closed records only, never an #expired one.
///
/// The fake ledger is an in-file `persistent actor` (as in test/closeledger.test.mo): it answers
/// icrc1_fee with 10_000, and transfer number `errAt` with #Err / number `rejectAt` with a reject
/// (1-based; 0 = never), after parking each transfer for `hops` yields. `paid` sums the amounts of the
/// transfers it answered #Ok. Each test names the mutation that turns it red.
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import Text "mo:base/Text";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");

let ledger = persistent actor {
  var errAt = 0; var rejectAt = 0; var hops = 0; var transfers = 0; var paid = 0;
  public func script(e : Nat, r : Nat, h : Nat) : async () { errAt := e; rejectAt := r; hops := h; transfers := 0; paid := 0 };
  public func transferCalls() : async Nat { transfers };
  public func paidTotal() : async Nat { paid };
  public func icrc1_fee() : async Nat { 10_000 };
  public func icrc1_transfer(arg : Types.TransferArg) : async Types.TransferResult {
    transfers += 1;
    let n = transfers;
    var i = 0; while (i < hops) { await async {}; i += 1 };
    if (n == rejectAt) { throw Error.reject("transfer rejected") };
    if (n == errAt) { #Err(#TemporarilyUnavailable) } else { paid += arg.amount; #Ok(n) };
  };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { #Ok(1) };
};
let ledgerP = Principal.fromActor(ledger);

/// A second ledger, not this session's: any transfer it is asked for is counted.
let otherLedger = persistent actor {
  var transfers = 0;
  public func transferCalls() : async Nat { transfers };
  public func icrc1_fee() : async Nat { 10_000 };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult { transfers += 1; #Ok(transfers) };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { #Ok(1) };
};

/// A session record: deposited 50_000, consumed 1_000 (so a close settles 1_000 + a 10_000 fee and
/// leaves 39_000 in escrow, of which the refund tries to send 29_000).
func stable_(id : Text, status : Types.SessionStatus, lastActivityAt : Int, idleTimeout : ?Int) : Types.StableSession = {
  id; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed = 1_000;
  remaining = 49_000; voucherCount = 1; status; openedAt = 0; lastActivityAt;
  lastSequence = 1; lastCumulativeAmount = 1_000; subaccount = Blob.fromArray([]); network = "icp:1";
  token = Principal.toText(ledgerP); recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout; evmDeposit = null;
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
    // Mutations: drop the refundOwed.put in the refund-failure arm — the count stays 0; make
    // sessionCounts ignore the set — likewise.
    await ledger.script(2, 0, 0); // transfer 1 (the settle) succeeds, transfer 2 (the refund) is refused
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert owed(m) == 1;
    assert m.sessionCounts().closed == 1;
    // Control: the same close with a working ledger owes nothing.
    await ledger.script(0, 0, 0);
    let c = mk([stable_("sess-1", #open, 7, null)]);
    switch (await c.closeSessionInternal("sess-1")) { case (#ok(_)) {}; case (_) { assert false } };
    assert owed(c) == 0;
    assert c.sessionCounts().closed == 1;
  });

  await test("a refund the ledger rejects → counted", func() : async () {
    // Mutation: as above.
    await ledger.script(0, 2, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert owed(m) == 1;
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 39_000; fee = 10_000 }];
  });

  await test("the sweep: a refund rejected during the expiry close is counted; the other session is not", func() : async () {
    // Mutation: as above. This is the path EngramX reported: the timer drops the sweep's results, so
    // the count is the only place the failure shows.
    await ledger.script(0, 2, 0); // the first session swept: settle #1 ok, refund #2 rejected; the second closes cleanly
    let m = mk([stable_("sess-1", #open, 0, ?1), stable_("sess-2", #open, 0, ?1)]);
    let results = await m.closeExpiredSessions();
    assert results.size() == 2;
    assert m.sessionCounts().closed == 2;
    assert owed(m) == 1;
  });
});

await suite("recoverEscrow settles an owed refund (2.18.0)", func() : async () {

  await test("a partial recovery leaves it owed; leaving one fee or less clears it", func() : async () {
    // Mutations: clear the entry on any successful recovery (the partial step reads 0); never clear it
    // (the final step reads 1); subtract without the fee (the partial step leaves 34_000, not 24_000);
    // clear only below one fee (`<` for `<=`: the final step leaves exactly one fee, still 1).
    await ledger.script(2, 0, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    await ledger.script(0, 0, 0);
    // 39_000 in escrow: 5_000 + its fee leaves 24_000 — still more than a fee, so still owed.
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 5_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    assert owed(m) == 1;
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 24_000; fee = 10_000 }];
    // 4_000 + its fee leaves exactly one fee: nothing more can move, so it is cleared.
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 4_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    assert owed(m) == 0;
  });

  await test("a recovery the ledger refuses changes nothing", func() : async () {
    // Mutation: account for the recovery before checking its result — the count would drop.
    await ledger.script(2, 0, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    await ledger.script(1, 0, 0); // the recovery transfer is refused
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 29_000)) { case (#err(_)) {}; case (#ok(_)) { assert false } };
    assert owed(m) == 1;
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 39_000; fee = 10_000 }];
  });
});

/// Close `m`'s #open "sess-1" with its refund failing: owed { escrow = 39_000; fee = 10_000 }.
func makeOwing(m : Sessions.Sessions) : async () {
  await ledger.script(2, 0, 0);
  switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
  await ledger.script(0, 0, 0);
};

func refusedWith(r : { #ok : Nat; #err : Text }, prefix : Text) {
  switch (r) { case (#err(msg)) { assert Text.startsWith(msg, #text prefix) }; case (#ok(_)) { assert false } };
};

await suite("2.22.0: recoverEscrow is bounded by the refundOwed entry", func() : async () {

  await test("a forced ICP session is owed deposited − consumed, and repeated recoverEscrow cannot exceed it", func() : async () {
    // Mutations: drop the refundOwed.put in forceResolveSession — the entry is missing and the payer
    // of a forced session cannot recover at all; or cap a recovery at deposited − consumed only (the
    // pre-2.22.0 per-call cap, dropping the entry term) — the first call pays 49_000 out of an escrow
    // that, when the settle never landed, still holds the recipient's 1_000 share too. The entry,
    // less one fee for the recovery's own transfer, bounds the total at 39_000; a second call finds
    // nothing owed.
    let m = mk([stable_("sess-1", #closing, 7, null)]);
    switch (m.forceResolveSession("sess-1")) { case (#ok) {}; case (#err(_)) { assert false } };
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 49_000; fee = 0 }];
    await ledger.script(0, 0, 0);
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 49_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    refusedWith(await m.recoverEscrow(payerP, ledger, "sess-1", 49_000), "Nothing is owed");
    refusedWith(await m.recoverEscrow(payerP, ledger, "sess-1", 1), "Nothing is owed");
    assert (await ledger.paidTotal()) == 39_000;
    assert owed(m) == 0;
  });

  await test("a session with no entry (a clean close) has nothing to recover", func() : async () {
    // Mutation: drop the entry check at the top of recoverEscrow — the call goes on to the ledger
    // (a fee query) before it is refused, with a different reason. The refusal also names the
    // lost-entry case (an upgrade that did not persist the entries) and its remedy.
    await ledger.script(0, 0, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#ok(_)) {}; case (_) { assert false } };
    await ledger.script(0, 0, 0);
    let r = await m.recoverEscrow(payerP, ledger, "sess-1", 1);
    refusedWith(r, "Nothing is owed on this session: its close");
    switch (r) { case (#err(msg)) { assert Text.contains(msg, #text "loadRefundOwed") }; case (#ok(_)) {} };
    assert (await ledger.transferCalls()) == 0;
  });

  await test("an entry of one fee or less is cleared by the recovery that finds it, which moves nothing", func() : async () {
    // Mutation: refuse without deleting the entry — it can never move anything (5_000 is below the
    // 10_000 fee), so it stays counted in refundOwed and pins its record from the GC for good.
    let m = mk([{ stable_("sess-1", #closing, 7, null) with consumed = 45_000; remaining = 5_000 }]);
    switch (m.forceResolveSession("sess-1")) { case (#ok) {}; case (#err(_)) { assert false } };
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 5_000; fee = 0 }];
    await ledger.script(0, 0, 0);
    refusedWith(await m.recoverEscrow(payerP, ledger, "sess-1", 5_000), "Nothing left to recover");
    assert owed(m) == 0;
    assert (await ledger.transferCalls()) == 0;
  });

  await test("two recoveries at once cannot both be paid from one entry", func() : async () {
    // Mutation: drop the recoveriesInFlight check — both calls read the entry (39_000) before either
    // reduces it and both are paid 29_000.
    let m = mk([stable_("sess-1", #open, 7, null)]);
    await makeOwing(m);
    await ledger.script(0, 0, 40); // park each recovery transfer
    let a = m.recoverEscrow(payerP, ledger, "sess-1", 29_000);
    let b = m.recoverEscrow(payerP, ledger, "sess-1", 29_000);
    let ra = await a;
    let rb = await b;
    var paidCalls = 0; var refusedCalls = 0;
    for (r in [ra, rb].vals()) {
      switch (r) {
        case (#ok(_)) { paidCalls += 1 };
        case (#err(msg)) { if (Text.contains(msg, #text "already in flight")) { refusedCalls += 1 } };
      };
    };
    assert paidCalls == 1 and refusedCalls == 1;
    assert (await ledger.paidTotal()) == 29_000;
  });

  await test("a ledger other than the session's is refused, and neither ledger is asked to pay", func() : async () {
    // Mutation: drop the ledger-mismatch check — the call is paid (on the session's own ledger,
    // which recoverEscrow now resolves itself) instead of being refused.
    let m = mk([stable_("sess-1", #open, 7, null)]);
    await makeOwing(m);
    refusedWith(await m.recoverEscrow(payerP, otherLedger, "sess-1", 1_000), "Wrong ledger");
    assert (await otherLedger.transferCalls()) == 0;
    assert (await ledger.transferCalls()) == 0;
    assert owed(m) == 1;
  });
});

await suite("2.22.0: clearRefundOwed", func() : async () {

  await test("drops the entry: the count returns to 0 and recoverEscrow then refuses", func() : async () {
    // Mutation: make clearRefundOwed answer #ok without deleting — the count stays 1.
    let m = mk([stable_("sess-1", #open, 7, null)]);
    await makeOwing(m);
    assert owed(m) == 1;
    switch (m.clearRefundOwed("sess-1")) { case (#ok) {}; case (#err(_)) { assert false } };
    assert owed(m) == 0;
    refusedWith(await m.recoverEscrow(payerP, ledger, "sess-1", 1_000), "Nothing is owed");
    switch (m.clearRefundOwed("sess-1")) { case (#err(_)) {}; case (#ok) { assert false } };
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

  await test("gcClosedSessions never deletes an #expired session (2.22.0)", func() : async () {
    // Mutation: GC #expired records again (`s.status == #closed or s.status == #expired`) — the
    // aged #expired record, whose close has not finished, is deleted with its escrow's only key.
    // The aged #closed record is the control (see the test above).
    let aged : Int = -25 * 60 * 60 * 1_000_000_000;
    let m = mk([stable_("sess-expired", #expired, aged, null), stable_("sess-clean", #closed, aged, null)]);
    m.gcClosedSessions();
    assert not exists(m, "sess-clean");
    assert exists(m, "sess-expired");
  });

  await test("refundOwedToStable / loadRefundOwed carry the count across an upgrade", func() : async () {
    // Mutation: loadRefundOwed ignores its input — the restored count reads 0.
    await ledger.script(2, 0, 0);
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    let restored = mk(m.toStable()); // the upgrade: sessions through toStable, owed refunds on their own
    assert owed(restored) == 0; // not persisted → restarts at 0 (the pre-2.18 behaviour, documented)
    restored.loadRefundOwed(m.refundOwedToStable());
    assert owed(restored) == 1;
    assert restored.refundOwedToStable() == m.refundOwedToStable();
  });
});

await suite("2.23.0: recoverEscrowReceipt reports what moved", func() : async () {

  await test("asking for everything reports the capped amount the ledger paid, its fee, and nothing left owed", func() : async () {
    // Mutation: report the requested amount instead of the capped one — the receipt says 1_000_000
    // while the ledger paid 29_000 (the entry's 39_000 less the recovery's own 10_000 fee).
    let m = mk([stable_("sess-1", #open, 7, null)]);
    await makeOwing(m);
    switch (await m.recoverEscrowReceipt(payerP, ledger, "sess-1", 1_000_000)) {
      case (#ok(r)) {
        assert r.amount == 29_000;
        assert r.fee == 10_000;
        assert r.owedLeft == 0;
        assert r.amount == (await ledger.paidTotal());
      };
      case (#err(_)) { assert false };
    };
    assert owed(m) == 0;
  });

  await test("a partial recovery reports what the entry still owes, and the next one finds it", func() : async () {
    // Mutation: report owedLeft from the entry as it was before the recovery — the receipt says
    // 39_000 while the entry holds 24_000 (5_000 plus its fee came out).
    let m = mk([stable_("sess-1", #open, 7, null)]);
    await makeOwing(m);
    switch (await m.recoverEscrowReceipt(payerP, ledger, "sess-1", 5_000)) {
      case (#ok(r)) { assert r.amount == 5_000; assert r.fee == 10_000; assert r.owedLeft == 24_000 };
      case (#err(_)) { assert false };
    };
    assert m.refundOwedToStable() == [{ sessionId = "sess-1"; escrow = 24_000; fee = 10_000 }];
    // recoverEscrow keeps its shape (the block index) and runs the same caps: 14_000 is all that is left.
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 1_000_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    assert (await ledger.paidTotal()) == 19_000;
    assert owed(m) == 0;
  });

  await test("a refusal is the same text as recoverEscrow's", func() : async () {
    let m = mk([stable_("sess-1", #open, 7, null)]);
    switch (await m.recoverEscrowReceipt(payerP, ledger, "sess-1", 1)) {
      case (#err(msg)) { assert Text.startsWith(msg, #text "Cannot recover escrow from an open session") };
      case (#ok(_)) { assert false };
    };
  });
});
