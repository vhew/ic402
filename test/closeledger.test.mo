/// 2.17.3 ICP session close against a scriptable fake ledger (`mops test`, interpreter mode:
/// a `persistent actor` declared in a test file runs in-process, so the close's real ledger
/// awaits execute here — only the sweep's self-call rejection (B2) has no in-process trigger).
///
///   - A normal close settles, refunds and releases the daily reservation exactly once.
///   - G1: a refund that fails after a successful settle ends #closed with lastActivityAt
///     refreshed (the remainder is in escrow; recoverEscrow needs the record for a full 24 h).
///   - B3: forceResolveSession landing while the close is suspended at an await does not make
///     the close release the daily reservation a second time; the close's transfers still run.
///   - A ledger reject on the settle leaves the session #open for retry (nothing moved).
///   - B1: recoverEscrow does pay out once a session is #closed.
///   - B2: the expiry sweep keeps going past a close that throws mid-close, and leaves that
///     session #closing (it is not reopened). Only a rejected self-call before the close starts
///     has no in-process trigger; that revert is covered by review only.
///
/// Each test names the mutation that turns it red.
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
let STALE : Int = 7; // fixture lastActivityAt — any refresh (even to 0 in the interpreter) differs

/// `feeHops` / `transferHops` yield that many times before answering, parking the close at that
/// await so the test can act on the LIVE #closing. Transfers numbered >= `errFrom` (1-based)
/// return #Err(#TemporarilyUnavailable); those >= `rejectFrom` throw a reject instead.
/// `transfers` counts icrc1_transfer calls.
let ledger = persistent actor {
  var feeHops = 0; var transferHops = 0; var errFrom = 1_000; var rejectFrom = 1_000; var transfers = 0;
  public func script(fh : Nat, th : Nat, ef : Nat, rf : Nat) : async () {
    feeHops := fh; transferHops := th; errFrom := ef; rejectFrom := rf; transfers := 0;
  };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_fee() : async Nat {
    var i = 0; while (i < feeHops) { await async {}; i += 1 };
    10_000;
  };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult {
    transfers += 1;
    let n = transfers;
    var i = 0; while (i < transferHops) { await async {}; i += 1 };
    if (n >= rejectFrom) { throw Error.reject("transfer rejected") };
    if (n >= errFrom) { #Err(#TemporarilyUnavailable) } else { #Ok(n) };
  };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { #Ok(1) };
};
let ledgerP = Principal.fromActor(ledger);

/// A fresh manager holding one #open ICP session: deposited 50_000, `consumed` as given, with
/// 100_000 of daily spend recorded so a single releaseDaily of 49_000 leaves 51_000 (two: 2_000).
func mk(consumed : Nat) : (Sessions.Sessions, Policy.Engine) {
  let policy = Policy.Engine();
  let m = Sessions.Sessions(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = ledgerP; symbol = "TKN"; decimals = 8 }]; evmChains = []; evmRpcCanister = null; ecdsaKeyName = null; nonceExpirySeconds = null },
    policy, Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
  );
  m.loadStable([{
    id = "sess-1"; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed;
    remaining = 50_000 - consumed; voucherCount = 0; status = #open; openedAt = 0; lastActivityAt = STALE;
    lastSequence = 0; lastCumulativeAmount = consumed; subaccount = Blob.fromArray([]); network = "icp:1";
    token = "TKN"; recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout = null; evmDeposit = null;
  }]);
  policy.recordSpend(payerP, 100_000);
  (m, policy);
};

/// Two #open ICP sessions already past their idle timeout, for the expiry sweep.
func mkExpired() : Sessions.Sessions {
  let m = Sessions.Sessions(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = ledgerP; symbol = "TKN"; decimals = 8 }]; evmChains = []; evmRpcCanister = null; ecdsaKeyName = null; nonceExpirySeconds = null },
    Policy.Engine(), Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
  );
  let s = func(id : Text) : Types.StableSession = {
    id; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed = 1_000;
    remaining = 49_000; voucherCount = 0; status = #open; openedAt = 0; lastActivityAt = 0;
    lastSequence = 0; lastCumulativeAmount = 1_000; subaccount = Blob.fromArray([]); network = "icp:1";
    token = "TKN"; recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout = ?1; evmDeposit = null;
  };
  m.loadStable([s("sess-1"), s("sess-2")]);
  m;
};

func statusOf(m : Sessions.Sessions, id : Text) : Types.SessionStatus {
  switch (m.getSession(id)) { case (?s) { s.status }; case (null) { assert false; loop {} } };
};

func session(m : Sessions.Sessions) : { status : Types.SessionStatus; lastActivityAt : Int } {
  switch (m.getSession("sess-1")) { case (?s) { s }; case (null) { assert false; loop {} } };
};

func force(m : Sessions.Sessions) {
  switch (m.forceResolveSession("sess-1")) { case (#ok) {}; case (#err(_)) { assert false } };
};

/// Yield until the close has committed #closing (it is then suspended at its first await).
func untilClosing(m : Sessions.Sessions) : async () {
  var n = 0; while (session(m).status != #closing and n < 30) { await async {}; n += 1 };
  assert session(m).status == #closing;
};

/// Yield until the close is suspended inside its first icrc1_transfer.
func untilTransferring() : async () {
  var n = 0; while ((await ledger.transferCalls()) < 1 and n < 30) { await async {}; n += 1 };
  assert (await ledger.transferCalls()) == 1;
};

await suite("an ICP close against the ledger", func() : async () {

  await test("a normal close settles, refunds and releases daily exactly once", func() : async () {
    // Mutations: the final `status == #closing` guard inverted, or releaseDaily dropped — daily
    // stays 100_000 instead of 51_000.
    await ledger.script(0, 0, 1_000, 1_000);
    let (m, policy) = mk(1_000);
    switch (await m.closeSessionInternal("sess-1")) { case (#ok(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert (await ledger.transferCalls()) == 2;
    assert policy.getDailySpendAmount(payerP) == 51_000;
  });

  await test("a refund that fails after a successful settle → #closed, lastActivityAt refreshed", func() : async () {
    // Mutation: drop the lastActivityAt refresh in the refund-failure arm (a sweep-closed session
    // idle >24 h would be GC'd on the next tick, before recoverEscrow can run).
    await ledger.script(0, 0, 2, 1_000); // transfer 1 (the settle) succeeds, transfer 2 (the refund) fails
    let (m, _) = mk(1_000);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert session(m).lastActivityAt != STALE;
  });
});

await suite("forceResolveSession landing on a LIVE ICP close (B3)", func() : async () {

  await test("during the fee await: transfers still run, daily released exactly once", func() : async () {
    // Mutation: drop the `status == #closing` guard around the final #closed + releaseDaily —
    // daily is released twice (2_000, not 51_000).
    await ledger.script(40, 0, 1_000, 1_000);
    let (m, policy) = mk(1_000);
    let f = m.closeSessionInternal("sess-1");
    await untilClosing(m);
    force(m);
    switch (await f) { case (#ok(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert (await ledger.transferCalls()) == 2; // settle and refund both ran
    assert policy.getDailySpendAmount(payerP) == 51_000;
  });

  await test("during a successful settle: refund still runs, daily released exactly once", func() : async () {
    // Mutation: as above (daily 2_000, not 51_000).
    await ledger.script(0, 40, 1_000, 1_000);
    let (m, policy) = mk(1_000);
    let f = m.closeSessionInternal("sess-1");
    await untilTransferring();
    force(m);
    switch (await f) { case (#ok(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert (await ledger.transferCalls()) == 2;
    assert policy.getDailySpendAmount(payerP) == 51_000;
  });
});

await suite("ledger rejects and recovery", func() : async () {

  await test("a settle rejected by the ledger → #open, nothing moved, daily untouched", func() : async () {
    // Mutation: drop the try/catch around escrowManager.settle — the close throws and the session
    // rests in #closing.
    await ledger.script(0, 0, 1_000, 1);
    let (m, policy) = mk(1_000);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert session(m).status == #open;
    assert policy.getDailySpendAmount(payerP) == 100_000;
  });

  await test("recoverEscrow pays out once the session is #closed", func() : async () {
    // Mutation: refuse #closed too in recoverEscrow — the payer could never recover a remainder.
    await ledger.script(0, 0, 1_000, 1_000);
    let (m, _) = mk(1_000);
    switch (await m.closeSessionInternal("sess-1")) { case (#ok(_)) {}; case (_) { assert false } };
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 1)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
  });

  await test("the expiry sweep keeps going past a close that throws mid-close (B2)", func() : async () {
    // The first session swept: settle #1 succeeds, its refund #2 is rejected → that close throws
    // with #closing committed. The second: its settle #3 is rejected → caught → #open. (HashMap
    // order decides which is first.) Mutations: revert ANY status in the sweep's catch (the
    // #closing one is reopened); drop the sweep's try/catch (the sweep throws).
    await ledger.script(0, 0, 1_000, 2);
    let m = mkExpired();
    let results = await m.closeExpiredSessions();
    assert results.size() == 2;
    let (a, b) = (statusOf(m, "sess-1"), statusOf(m, "sess-2"));
    assert (a == #closing and b == #open) or (a == #open and b == #closing);
  });
});
