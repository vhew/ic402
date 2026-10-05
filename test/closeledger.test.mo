/// ICP session close (2.17.3, 2.17.4) against a scriptable fake ledger (`mops test`, interpreter
/// mode: a `persistent actor` declared in a test file runs in-process, so the close's real ledger
/// awaits execute here). The fake keeps no balances: these tests pin the state machine, the
/// transfer count and the daily reservation, not the amounts moved.
///
///   - A normal close settles, refunds and releases the daily reservation exactly once.
///   - G1: a refund that fails after a successful settle ends #closed with lastActivityAt
///     refreshed (the remainder is in escrow; recoverEscrow needs the record for a full 24 h) and,
///     since 2.17.4, the daily reservation released.
///   - B3: forceResolveSession landing while the close is suspended at an await does not make
///     the close release the daily reservation a second time; the close's transfers still run.
///   - A ledger reject on the settle leaves the session #open for retry (nothing moved).
///   - B1: recoverEscrow does pay out once a session is #closed.
///   - 2.17.4: a refund the ledger REJECTS ends #closed and recoverable, like a refused one; a
///     force landing during a failing refund does not release the daily reservation twice.
///   - B2: the expiry sweep handles ledger rejects without parking sessions. Since 2.17.4 no ICP
///     ledger reject makes the close throw, so the sweep's catch arm is reached only by a rejected
///     self-call or a trap, neither inducible in-process: that arm is covered by review only.
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
import Text "mo:base/Text";
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

/// Yield until the close is suspended inside its `k`th icrc1_transfer.
func untilTransferring(k : Nat) : async () {
  var n = 0; while ((await ledger.transferCalls()) < k and n < 200) { await async {}; n += 1 };
  assert (await ledger.transferCalls()) == k;
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

  await test("a refund that fails after a successful settle → #closed, lastActivityAt refreshed, daily released", func() : async () {
    // Mutations: drop the lastActivityAt refresh in the refund-failure arm (a sweep-closed session
    // idle >24 h would be GC'd on the next tick, before recoverEscrow can run); drop its
    // releaseDaily (daily stays 100_000 — the unspent remainder counted against the payer's limit).
    await ledger.script(0, 0, 2, 1_000); // transfer 1 (the settle) succeeds, transfer 2 (the refund) fails
    let (m, policy) = mk(1_000);
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert session(m).lastActivityAt != STALE;
    assert policy.getDailySpendAmount(payerP) == 51_000;
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
    await untilTransferring(1);
    force(m);
    switch (await f) { case (#ok(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert (await ledger.transferCalls()) == 2;
    assert policy.getDailySpendAmount(payerP) == 51_000;
  });

  await test("during a refund that then fails: #closed, daily released exactly once (2.17.4)", func() : async () {
    // Mutation: drop the `status == #closing` guard in the refund-failure arm — daily is released
    // twice (2_000, not 51_000).
    await ledger.script(0, 40, 2, 1_000); // the refund (transfer 2) is parked, then refused
    let (m, policy) = mk(1_000);
    let f = m.closeSessionInternal("sess-1");
    await untilTransferring(2);
    force(m);
    switch (await f) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
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

  await test("a refund the ledger rejects → #closed, recoverable, and nothing re-closes it (2.17.4)", func() : async () {
    // Mutation: drop the try/catch around escrowManager.refund — the close throws and the session
    // rests in #closing, which recoverEscrow refuses.
    await ledger.script(0, 0, 1_000, 2); // transfer 1 (the settle) succeeds, transfer 2 (the refund) is rejected
    let (m, policy) = mk(1_000);
    switch (await m.closeSessionInternal("sess-1")) {
      case (#settlementFailed(msg)) { assert Text.startsWith(msg, #text "Refund leg rejected") };
      case (_) { assert false };
    };
    assert session(m).status == #closed;
    assert session(m).lastActivityAt != STALE;
    assert policy.getDailySpendAmount(payerP) == 51_000;
    await ledger.script(0, 0, 1_000, 1_000); // the ledger is back
    switch (await m.recoverEscrow(payerP, ledger, "sess-1", 1)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    let moved = await ledger.transferCalls();
    switch (await m.closeSessionInternal("sess-1")) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert session(m).status == #closed;
    assert (await ledger.transferCalls()) == moved; // the refused re-close moved nothing
    assert policy.getDailySpendAmount(payerP) == 51_000; // and released nothing again
  });

  await test("the expiry sweep handles ledger rejects without parking sessions (B2)", func() : async () {
    // The first session swept: settle #1 succeeds, its refund #2 is rejected → #closed. The
    // second: its settle #3 is rejected → #open for retry. (HashMap order decides which is first.)
    // Mutation: drop the refund's try/catch — that close throws and the session rests #closing.
    await ledger.script(0, 0, 1_000, 2);
    let m = mkExpired();
    let results = await m.closeExpiredSessions();
    assert results.size() == 2;
    let (a, b) = (statusOf(m, "sess-1"), statusOf(m, "sess-2"));
    assert (a == #closed and b == #open) or (a == #open and b == #closed);
  });
});
