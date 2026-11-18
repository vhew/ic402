/// 2.22.0 — which ledger a stored ICP session's token names (Utils.findSessionLedger).
///
/// Before 2.22.0, openSession pulled the deposit on config.tokens[0] for every intent token that was
/// not a configured ledger's principal text — a symbol, "icp:*", any text — and stored that token.
/// So a close, reconcileSession or recoverEscrow of such a session must use tokens[0], even when the
/// stored text is now the symbol of ANOTHER configured token (findLedger matches symbols since
/// 2.22.0, which here would name the wrong ledger). A 2.22.0 open stores a symbol-matched token as
/// its ledger's principal text (storedSessionToken), so only legacy sessions and "icp:*" reach that
/// arm. A principal text that is no longer configured fails closed: test/closeledger.test.mo.
///
/// Two in-file fake ledgers (tokens[0] = A, tokens[1] = B) count the transfers they are asked for.
/// openSession cannot run to a stored session here (a successful open arms the expiry timer, which
/// the interpreter has no API for), so storedSessionToken is tested directly and its wiring into
/// openSession is covered by review. Each test names the mutation that turns it red.
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");

let ledgerA = persistent actor {
  var transfers = 0; var balance = 0;
  public func reset() : async () { transfers := 0; balance := 0 };
  public func setBalance(b : Nat) : async () { balance := b };
  public func icrc1_balance_of(_ : Types.Account) : async Nat { balance };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_fee() : async Nat { 10_000 };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult { transfers += 1; #Ok(transfers) };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { #Ok(1) };
};
let ledgerB = persistent actor {
  var transfers = 0; var balance = 0;
  public func reset() : async () { transfers := 0; balance := 0 };
  public func setBalance(b : Nat) : async () { balance := b };
  public func icrc1_balance_of(_ : Types.Account) : async Nat { balance };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_fee() : async Nat { 10_000 };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult { transfers += 1; #Ok(transfers) };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { #Ok(1) };
};
let ledgerAP = Principal.fromActor(ledgerA);
let ledgerBP = Principal.fromActor(ledgerB);

/// A manager with tokens [A "TKA", B "TKB"] holding one ICP session in `status` (deposited 50_000,
/// consumed 1_000) whose stored token is `token`.
func mkIn(status : Types.SessionStatus, token : Text) : Sessions.Sessions {
  let m = Sessions.Sessions(
    canisterP,
    {
      recipient = { owner = canisterP; subaccount = null };
      tokens = [{ ledger = ledgerAP; symbol = "TKA"; decimals = 8 }, { ledger = ledgerBP; symbol = "TKB"; decimals = 8 }];
      evmChains = []; evmRpcCanister = null; ecdsaKeyName = null; nonceExpirySeconds = null;
    },
    Policy.Engine(), Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
  );
  m.loadStable([{
    id = "sess-1"; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed = 1_000;
    remaining = 49_000; voucherCount = 1; status; openedAt = 0; lastActivityAt = 0;
    lastSequence = 1; lastCumulativeAmount = 1_000; subaccount = Blob.fromArray([]); network = "icp:1";
    token; recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout = null; evmDeposit = null;
  }]);
  m;
};

func mk(token : Text) : Sessions.Sessions { mkIn(#open, token) };

/// Close `token`'s session; returns the transfers each ledger was asked for (A, B).
func closeOn(token : Text) : async (Nat, Nat) {
  await ledgerA.reset();
  await ledgerB.reset();
  let m = mk(token);
  switch (await m.closeSessionInternal("sess-1")) { case (#ok(_)) {}; case (_) { assert false } };
  (await ledgerA.transferCalls(), await ledgerB.transferCalls());
};

await suite("2.22.0: a stored session token names the ledger its deposit is on", func() : async () {

  await test("a legacy session whose token is the symbol of a non-first token closes on tokens[0]", func() : async () {
    // Mutation: resolve a stored token with findLedger (symbols match) — the close settles and
    // refunds on B, where this pre-2.22.0 session never deposited (A holds its escrow).
    assert (await closeOn("TKB")) == (2, 0);
  });

  await test("a legacy session with any other text, or icp:*, closes on tokens[0] as in 2.21.0", func() : async () {
    // Mutation: return null (fail closed) for a token that is not a principal — such a session,
    // opened on tokens[0] by 2.21.0, could never close (an #expired one reopened every sweep tick).
    assert (await closeOn("ckUSDC-legacy")) == (2, 0);
    assert (await closeOn("icp:1")) == (2, 0);
  });

  await test("a 2.22.0 open stores a symbol as its ledger's principal text, and that session closes on that ledger", func() : async () {
    // Mutation: store the intent's token as given (`storedSessionToken` returns intentToken) — the
    // session would carry "TKB", which a close reads as a legacy session and closes on A.
    assert Sessions.storedSessionToken("TKB", ledgerBP) == Principal.toText(ledgerBP);
    assert Sessions.storedSessionToken(Principal.toText(ledgerBP), ledgerBP) == Principal.toText(ledgerBP);
    assert Sessions.storedSessionToken("icp:1", ledgerAP) == "icp:1";
    assert (await closeOn(Sessions.storedSessionToken("TKB", ledgerBP))) == (0, 2);
  });

  await test("reconcileSession and recoverEscrow of a legacy symbol session use tokens[0] too", func() : async () {
    // Mutations: resolve the stored token with findLedger in reconcileIcpClose — it reads B's
    // balance (0: "settle landed") instead of A's (the full deposit: reopen); or in recoverEscrow —
    // the payer's recovery on A, where the escrow is, is refused as the wrong ledger.
    await ledgerA.reset();
    await ledgerB.reset();
    await ledgerA.setBalance(50_000);
    let parked = mkIn(#closing, "TKB");
    switch (await parked.reconcileSession("sess-1")) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    switch (parked.getSession("sess-1")) { case (?st) { assert st.status == #open }; case (null) { assert false } };
    let closed = mkIn(#closed, "TKB");
    closed.loadRefundOwed([{ sessionId = "sess-1"; escrow = 39_000; fee = 10_000 }]);
    switch (await closed.recoverEscrow(payerP, ledgerA, "sess-1", 1_000)) { case (#ok(_)) {}; case (#err(_)) { assert false } };
    assert (await ledgerA.transferCalls()) == 1;
    assert (await ledgerB.transferCalls()) == 0;
  });
});
