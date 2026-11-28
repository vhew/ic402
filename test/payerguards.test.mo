/// 2.21.1 — three guards on moving funds.
///
/// 1. The canister is never the payer of its own ICRC-2 pull. DFINITY ledgers treat a
///    transfer_from whose `from` is the caller's own account as a plain transfer (no allowance
///    check), so a charge or session deposit "from" the canister would be paid out of its own
///    funds. Gateway.settleCore and Escrow.depositCore refuse it.
/// 2. Two closes of one EVM session cannot both pass the re-close guard. The guard and the
///    `#closing` write now run in one message (closeEvmSessionInternal is inline), so the second
///    close is refused. The test uses a session with no EVM sender configured: the close then
///    stops right after writing `#closing`, which is all the guard needs.
///
/// Each test names the mutation that turns it red.
import Gateway "../src/ic402/Gateway";
import Sessions "../src/ic402/Sessions";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Policy "../src/ic402/Policy";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payer = "2vxsx-fae";

/// Counts transfer_from calls and answers #Ok.
let ledger = persistent actor {
  var calls = 0;
  public func reset() : async () { calls := 0 };
  public func pullCalls() : async Nat { calls };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult { calls += 1; #Ok(calls) };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult { #Ok(0) };
  public func icrc1_fee() : async Nat { 10_000 };
};
let ledgerP = Principal.fromActor(ledger);

let config : Types.Config = {
  recipient = { owner = canisterP; subaccount = null };
  tokens = [{ ledger = ledgerP; symbol = "TKN"; decimals = 6 : Nat8 }];
  evmChains = [];
  evmRpcCanister = null;
  ecdsaKeyName = null;
  nonceExpirySeconds = null;
};

func payment(gate : Gateway.Gateway, sender : Text) : Types.PaymentSignature {
  let req = gate.require({ token = ledgerP; amount = 5_000; network = "icp:1" });
  {
    scheme = "exact"; network = "icp:1"; signature = Blob.fromArray([]); publicKey = null;
    asset = null; sender; nonce = req.nonce; authorization = null;
  };
};

await suite("2.21.1: the canister is never the payer of its own pull", func() : async () {

  await test("settle naming the canister as sender is refused before the ledger, and the nonce stays usable", func() : async () {
    // Mutation: drop the selfPrincipal check in settleCore — the pull runs, and on a real ledger
    // the canister pays for the caller's resource.
    await ledger.reset();
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate, Principal.toText(canisterP));
    switch (await gate.settle(sig, ?5_000)) { case (#invalidSignature(_)) {}; case (_) { assert false } };
    assert (await ledger.pullCalls()) == 0;
    // The refusal unlocked the nonce: the real payer can still pay with it.
    switch (await gate.settle({ sig with sender = payer }, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    assert (await ledger.pullCalls()) == 1;
  });

  await test("a session deposit from the canister's own account is refused before the ledger", func() : async () {
    // Mutation: drop the canister check in Escrow.depositCore.
    await ledger.reset();
    let esc = Escrow.EscrowManager(canisterP);
    switch (await esc.deposit(ledger, { owner = canisterP; subaccount = null }, 5_000, Blob.fromArray([1]))) {
      case (#err(_)) {};
      case (#ok(_)) { assert false };
    };
    assert (await ledger.pullCalls()) == 0;
    // Control: any other depositor reaches the ledger.
    switch (await esc.deposit(ledger, { owner = Principal.fromText(payer); subaccount = null }, 5_000, Blob.fromArray([1]))) {
      case (#ok(_)) {};
      case (#err(_)) { assert false };
    };
    assert (await ledger.pullCalls()) == 1;
  });
});

await suite("2.21.1: two closes of one EVM session", func() : async () {

  await test("the second of two closes queued together is refused by the guard", func() : async () {
    // Mutation: run closeEvmSessionInternal as a self-call again (`async`/`await`) — both closes
    // pass the guard before either writes #closing.
    let m = Sessions.Sessions(
      canisterP, config, Policy.Engine(), Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), null,
      { get = func() : ?Text { ?"0x1111111111111111111111111111111111111111" } },
    );
    m.loadStable([{
      id = "sess-1"; payer = Principal.fromText(payer); payerPublicKey = Blob.fromArray([]); deposited = 50_000;
      consumed = 0; remaining = 50_000; voucherCount = 0; status = #open; openedAt = 0; lastActivityAt = 0;
      lastSequence = 0; lastCumulativeAmount = 0; subaccount = Blob.fromArray([]); network = "eip155:8453";
      token = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; recipient = "0x1111111111111111111111111111111111111111";
      autoClose = false; maxDuration = null; idleTimeout = null;
      evmDeposit = ?{ txHash = "0x01"; chainId = 8453; payerEvmAddress = "0x2222222222222222222222222222222222222222"; tokenAddress = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" };
    }]);
    let a = m.closeSessionInternal("sess-1");
    let b = m.closeSessionInternal("sess-1");
    let ra = await a;
    let rb = await b;
    var refused = 0;
    for (r in [ra, rb].vals()) {
      switch (r) {
        case (#settlementFailed(msg)) { if (Text.contains(msg, #text "a close is in progress")) { refused += 1 } };
        case (_) {};
      };
    };
    assert refused == 1;
  });
});
