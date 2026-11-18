/// 2.21.0 — a session-open deposit rejected with an unknown outcome is parked #closing, and
/// reconcileSession decides from the escrow balance.
///
/// The parking itself happens in openSession, which no unit test can drive: a successful open
/// arms the expiry sweep, and the interpreter has no timer API (see test/expirytimer.test.mo).
/// That path is covered by the replica suite instead, which stops the real ledger mid-open
/// (test/integration.test.ts, "2.21.0 a stopped ledger"). Here the parked session is seeded
/// through loadStable, exactly as openSession records it: #closing, nothing consumed, the daily
/// reservation held. These tests pin how reconcileSession resolves it.
///
/// Each test names the mutation that turns it red.
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");
let escrowSub = Blob.fromArray([7, 7, 7, 7]); // the parked session's escrow subaccount

/// Answers icrc1_balance_of with the scripted escrow balance; counts transfers (there must be none).
let ledger = persistent actor {
  var balance = 0; var transfers = 0; var queried : ?Types.Account = null;
  public func script(b : Nat) : async () { balance := b; transfers := 0; queried := null };
  public func transferCalls() : async Nat { transfers };
  public func lastQueried() : async ?Types.Account { queried };
  public func icrc1_balance_of(a : Types.Account) : async Nat { queried := ?a; balance };
  public func icrc1_fee() : async Nat { 10_000 };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult { transfers += 1; #Ok(transfers) };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { transfers += 1; #Ok(transfers) };
};
let ledgerP = Principal.fromActor(ledger);

/// A manager holding one ICP session parked by an unknown deposit reject: deposited 50_000,
/// nothing consumed, #closing, with the 50_000 daily reservation openSession records.
func parked() : (Sessions.Sessions, Policy.Engine) {
  let policy = Policy.Engine();
  let m = Sessions.Sessions(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = ledgerP; symbol = "TKN"; decimals = 8 }]; evmChains = []; evmRpcCanister = null; ecdsaKeyName = null; nonceExpirySeconds = null },
    policy, Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
  );
  m.loadStable([{
    id = "sess-1"; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed = 0;
    remaining = 50_000; voucherCount = 0; status = #closing; openedAt = 0; lastActivityAt = 0;
    lastSequence = 0; lastCumulativeAmount = 0; subaccount = escrowSub; network = "icp:1";
    token = Principal.toText(ledgerP); recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout = null; evmDeposit = null;
  }]);
  policy.recordSpend(payerP, 50_000);
  (m, policy);
};

func status(m : Sessions.Sessions) : Types.SessionStatus {
  switch (m.getSession("sess-1")) { case (?s) { s.status }; case (null) { assert false; loop {} } };
};

func owedCount(m : Sessions.Sessions) : Nat { m.refundOwedToStable().size() };

await suite("2.21.0: reconcileSession resolves a deposit parked at open", func() : async () {

  await test("the deposit is in escrow → the session opens, the daily reservation stays", func() : async () {
    // Mutation: drop the consumed == 0 branch of the reopen message — the operator is told a
    // settle did not land, for a session that never settled anything.
    let (m, policy) = parked();
    await ledger.script(50_000);
    switch (await m.reconcileSession("sess-1")) {
      case (#ok(msg)) { assert Text.contains(msg, #text "the deposit landed") };
      case (#err(_)) { assert false };
    };
    assert status(m) == #open;
    assert (await ledger.lastQueried()) == ?{ owner = canisterP; subaccount = ?escrowSub }; // this session's escrow
    assert policy.getDailySpendAmount(payerP) == 50_000;
    assert owedCount(m) == 0;
    assert (await ledger.transferCalls()) == 0;
  });

  await test("the deposit never arrived → #closed, the daily reservation released, and nothing recorded as owed", func() : async () {
    // Mutation: remove the consumed == 0 guard — the close records deposited − fee (40_000) as
    // owed to the payer, out of an escrow that holds nothing.
    let (m, policy) = parked();
    await ledger.script(0);
    switch (await m.reconcileSession("sess-1")) {
      case (#ok(msg)) { assert Text.contains(msg, #text "nothing is owed") };
      case (#err(_)) { assert false };
    };
    assert status(m) == #closed;
    assert policy.getDailySpendAmount(payerP) == 0;
    assert owedCount(m) == 0;
    assert (await ledger.transferCalls()) == 0;
  });
});
