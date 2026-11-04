/// 2.20.0 — an ICP settle whose ledger call is rejected after it may have run is UNKNOWN, not "not
/// paid". The DFINITY ledgers commit a transfer and then await their archive inside the same call,
/// so a reject can follow a committed charge; before 2.20.0 Gateway.settle unlocked the nonce and
/// returned #settlementFailed, so re-submitting the same payment could charge the payer twice.
///
/// The fake ledger is an in-file `persistent actor` (as in test/closeledger.test.mo). Its reject is
/// `throw Error.reject`, code #canister_reject: an UNKNOWN code. The interpreter cannot raise the
/// system codes that mean "never ran" (#destination_invalid, #system_transient, #call_error), so
/// that branch is covered by the classifier test at the end, not end to end.
///
/// Each test names the mutation that turns it red.
import Gateway "../src/ic402/Gateway";
import Types "../src/ic402/Types";
import Utils "../src/ic402/Utils";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payer = "2vxsx-fae";

/// `reject = true` makes icrc2_transfer_from throw; otherwise it answers #Ok. `calls` counts them.
let ledger = persistent actor {
  var reject = false; var calls = 0;
  public func script(r : Bool) : async () { reject := r; calls := 0 };
  public func pullCalls() : async Nat { calls };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult {
    calls += 1;
    if (reject) { throw Error.reject("ledger is stopped") };
    #Ok(calls);
  };
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

/// A fresh gateway and a payment for 5_000 against a nonce it just issued.
func setup() : (Gateway.Gateway, Types.PaymentSignature) {
  let gate = Gateway.Gateway(config, canisterP);
  let req = gate.require({ token = ledgerP; amount = 5_000; network = "icp:1" });
  (gate, {
    scheme = "exact"; network = "icp:1"; signature = Blob.fromArray([]); publicKey = null;
    asset = null; sender = payer; nonce = req.nonce; authorization = null;
  });
};

func dailyHeld(gate : Gateway.Gateway) : Nat {
  var total = 0;
  for ((_, v) in gate.toStable().policy.dailySpendEntries.values()) { total += v };
  total;
};

await suite("2.20.0: a rejected ICP settle is unknown, not 'not paid'", func() : async () {

  await test("control: the ledger answers #Ok and the settle issues a receipt", func() : async () {
    await ledger.script(false);
    let (gate, sig) = setup();
    switch (await gate.settle(sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    assert (await ledger.pullCalls()) == 1;
  });

  await test("a reject returns #settlementPending, not #settlementFailed", func() : async () {
    // Mutation: restore the pre-2.20.0 catch (unlock, release, #settlementFailed), or make
    // Utils.rejectedBeforeExecution return true for #canister_reject.
    await ledger.script(true);
    let (gate, sig) = setup();
    switch (await gate.settle(sig, ?5_000)) { case (#settlementPending(_)) {}; case (_) { assert false } };
  });

  await test("after the reject, the same payment cannot be re-submitted (nonce stays locked)", func() : async () {
    // Mutation: unlock the nonce on an unknown reject — the second settle reaches the ledger
    // again, which is the double charge this release closes.
    await ledger.script(true);
    let (gate, sig) = setup();
    ignore await gate.settle(sig, ?5_000);
    await ledger.script(false);
    switch (await gate.settle(sig, ?5_000)) { case (#expired(_)) {}; case (_) { assert false } };
    assert (await ledger.pullCalls()) == 0;
  });

  await test("after the reject, the payer's daily reservation stays held", func() : async () {
    // Mutation: release the daily reservation on an unknown reject.
    await ledger.script(true);
    let (gate, sig) = setup();
    ignore await gate.settle(sig, ?5_000);
    assert dailyHeld(gate) == 5_000;
  });
});

await suite("Utils.rejectedBeforeExecution", func() : async () {
  await test("only rejects raised before the callee ran count as 'never ran'", func() : async () {
    // Mutation: add any other code to the true arm, or drop one of the three.
    assert Utils.rejectedBeforeExecution(#destination_invalid);
    assert Utils.rejectedBeforeExecution(#system_transient);
    assert Utils.rejectedBeforeExecution(#call_error({ err_code = 1 }));
    assert not Utils.rejectedBeforeExecution(#canister_error); // a trap — or a STOPPED ledger
    assert not Utils.rejectedBeforeExecution(#canister_reject);
    assert not Utils.rejectedBeforeExecution(#system_fatal);
    assert not Utils.rejectedBeforeExecution(#system_unknown);
    assert not Utils.rejectedBeforeExecution(#future(7));
  });
});
