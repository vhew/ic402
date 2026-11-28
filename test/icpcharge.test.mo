/// 2.22.0 — ICP charges: a settle in flight is not "funds may have moved"; an HTTP charge that
/// ends pending holds no daily reservation; a malformed sender is refused, not a trap.
///
/// 1. Nonces are predictable and not bound to a payer, so anyone can settle with someone else's
///    nonce: an HTTP `settle` naming any sender, or a `settleFrom` as himself. Until 2.22.0 that
///    attempt's lock made the real payer's concurrent settle answer #settlementPending ("…its
///    outcome is unknown — do NOT pay again"), which clients report as funds moved. Now a lock
///    whose attempt is still in flight for ANOTHER payer answers #policyDenied ("already in
///    progress — retry"); #settlementPending is kept for an attempt that ended with an unknown
///    outcome, for every lock restored by loadStable, and for an attempt in flight for the SAME
///    payer (it may be pulling this payer's funds: a client's re-send after a timeout must not
///    be told to pay again).
/// 2. Over HTTP the sender is only claimed, so the daily reservation of a charge that ends pending
///    there is released: junk settles during a ledger outage cannot fill a payer's maxPerDay.
/// 3. Principal.fromText traps on malformed text and try/catch does not catch traps, so an HTTP
///    settle with a malformed sender trapped. Utils.principalFromText parses without trapping.
///
/// The fake ledger is an in-file `persistent actor` (as in test/chargededup.test.mo). `hops`
/// makes icrc2_transfer_from yield that many times before answering, so a test can act while
/// the call is in flight. Its reject is `throw Error.reject`, code #canister_reject: an unknown
/// outcome. The interpreter aborts on a trap, so a test that traps fails.
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
let payerP = Principal.fromText(payer);
let stranger = "rrkah-fqaaa-aaaaa-aaaaq-cai";

let OK = 0; // answer #Ok
let REJECT = 1; // reject: an unknown outcome
let NO_ALLOWANCE = 2; // answer #Err(#InsufficientAllowance)

let ledger = persistent actor {
  var mode = 0; var hops = 0; var calls = 0;
  public func script(m : Nat, h : Nat) : async () { mode := m; hops := h; calls := 0 };
  public func setMode(m : Nat) : async () { mode := m; hops := 0 };
  public func pullCalls() : async Nat { calls };
  public func icrc2_transfer_from(_ : Types.TransferFromArg) : async Types.TransferFromResult {
    calls += 1;
    var i = 0; while (i < hops) { await async {}; i += 1 };
    if (mode == 1) { throw Error.reject("ledger is stopped") };
    if (mode == 2) { return #Err(#InsufficientAllowance({ allowance = 0 })) };
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

/// A payment for 5_000 from `payer` against a nonce `gate` just issued.
func payment(gate : Gateway.Gateway) : Types.PaymentSignature {
  let req = gate.require({ token = ledgerP; amount = 5_000; network = "icp:1" });
  {
    scheme = "exact"; network = "icp:1"; signature = Blob.fromArray([]); publicKey = null;
    asset = null; sender = payer; nonce = req.nonce; authorization = null;
  };
};

/// Yield until the fake ledger has seen a call.
func untilLedgerCalled() : async () {
  var n = 0; while ((await ledger.pullCalls()) == 0 and n < 50) { await async {}; n += 1 };
};

let BUSY = "A settlement with this payment is already in progress — retry this same payment in a few seconds; do not pay with a new nonce.";
func isBusy(r : Types.PaymentResult) : Bool { r == #policyDenied(BUSY) };
func isPending(r : Types.PaymentResult) : Bool { switch (r) { case (#settlementPending(_)) { true }; case (_) { false } } };

func dailyHeld(gate : Gateway.Gateway) : Nat {
  var total = 0;
  for ((_, v) in gate.toStable().policy.dailySpendEntries.values()) { total += v };
  total;
};

await suite("2.22.0: a settle in flight answers 'busy', not 'outcome unknown'", func() : async () {

  await test("a stranger's in-flight settle with the payer's nonce: the payer's own settle is told to retry, and then settles", func() : async () {
    // Mutation: drop the outcomeIsUnknown check in settleCore — the payer is told a settlement
    // with this payment may have moved funds, while all that moved is a stranger's junk request.
    await ledger.script(NO_ALLOWANCE, 3);
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate);
    let junk = gate.settle({ sig with sender = stranger }, ?5_000); // HTTP, names any sender
    await untilLedgerCalled();
    assert isBusy(await gate.settleFrom(payerP, sig, ?5_000));
    assert (await ledger.pullCalls()) == 1; // the payer's settle sent nothing
    switch (await junk) { case (#insufficientFunds(_)) {}; case (_) { assert false } };
    await ledger.setMode(OK);
    switch (await gate.settleFrom(payerP, sig, ?5_000)) { case (#ok(r)) { assert r.sender == payer }; case (_) { assert false } };
  });

  await test("the payer's own duplicate while its first settle is in flight is pending, and sends nothing", func() : async () {
    // Mutation: answer every in-flight lock as busy (drop the heldBy check) — over HTTP that is
    // `unexpected_settle_error`, which the SDK reports as nothing moved, so a client re-sending
    // after a timeout pays anew while its first attempt is pulling the funds.
    await ledger.script(OK, 3);
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate);
    let first = gate.settle(sig, ?5_000); // HTTP, names the payer
    await untilLedgerCalled();
    assert isPending(await gate.settle(sig, ?5_000)); // the HTTP re-send
    assert isPending(await gate.settleFrom(payerP, sig, ?5_000)); // the payer's own Candid call
    assert (await ledger.pullCalls()) == 1;
    switch (await first) { case (#ok(_)) {}; case (_) { assert false } };
  });

  await test("after another payer's settle ends with an unknown reject, this payer hears pending, not 'busy' forever", func() : async () {
    // Mutation: drop markOutcomeUnknown in the ICP reject catch — the lock still names the other
    // payer, so this payer is told to "retry this same payment in a few seconds" until the lock
    // is cleaned up 24 h past expiry, although nothing is in flight any more.
    await ledger.setMode(REJECT);
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate);
    assert isPending(await gate.settle({ sig with sender = stranger }, ?5_000)); // HTTP, unknown outcome
    let r = await gate.settleFrom(payerP, sig, ?5_000);
    assert isPending(r);
    assert not isBusy(r);
    await ledger.setMode(OK);
  });

  await test("chargePayerKey: one EVM payer whatever the hex spelling; ICP is the sender text", func() : async () {
    // Mutation: key EVM payers on the `from` text as given — a re-send that spells the payer's
    // address in another case (or without 0x) is told "busy", and pays anew.
    let addr = "0x52908400098527886E0F7030069857D2E4169EE7";
    func evm(from : Text) : Types.PaymentSignature {
      {
        scheme = "exact"; network = "eip155:8453"; signature = Blob.fromArray([]); publicKey = null;
        asset = null; sender = ""; nonce = Blob.fromArray([1]);
        authorization = ?{
          from; to = addr; value = 1; validAfter = 0; validBefore = 1; nonce = Blob.fromArray([]);
          v = 27; r = Blob.fromArray([]); s = Blob.fromArray([]);
        };
      };
    };
    let k = Gateway.chargePayerKey(evm(addr));
    assert Gateway.chargePayerKey(evm("0x52908400098527886e0f7030069857d2e4169ee7")) == k;
    assert Gateway.chargePayerKey(evm("0X52908400098527886E0F7030069857D2E4169EE7")) == k;
    assert Gateway.chargePayerKey(evm("52908400098527886e0f7030069857d2e4169ee7")) == k;
    assert Gateway.chargePayerKey(evm("0x52908400098527886e0f7030069857d2e4169ee8")) != k;
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate);
    assert Gateway.chargePayerKey(sig) == Gateway.chargePayerKey({ sig with sender = payer });
    assert Gateway.chargePayerKey(sig) != Gateway.chargePayerKey({ sig with sender = stranger });
  });

  await test("after loadStable, a restored lock answers pending: nothing is in flight across an upgrade", func() : async () {
    // Mutation: do not mark restored locks in Nonce.loadStable — a charge whose outcome was
    // unknown before the upgrade answers "retry in a few seconds" forever after it.
    await ledger.script(REJECT, 0);
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate);
    assert isPending(await gate.settle(sig, ?5_000));
    let upgraded = Gateway.Gateway(config, canisterP);
    upgraded.loadStable(gate.toStable());
    await ledger.setMode(OK);
    assert isPending(await upgraded.settleFrom(payerP, sig, ?5_000));
    assert (await ledger.pullCalls()) == 1;
  });
});

await suite("2.22.0: an HTTP charge that ends pending holds no daily reservation", func() : async () {

  await test("junk HTTP settles naming the payer during an outage do not use up the payer's maxPerDay", func() : async () {
    // Mutation: drop the releaseDaily on the pending path — the junk reservation stays for the
    // rest of the UTC day and the payer's own payment is refused as over the daily limit.
    await ledger.script(REJECT, 0);
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    gate.setPolicy(null, {
      maxPerTransaction = null; maxPerDay = ?5_000; rateLimitPerMinute = null; maxSessionDeposit = null;
      maxConcurrentSessions = null; maxSessionDuration = null; sessionIdleTimeout = null;
      allowedCallers = null; blockedCallers = null;
    });
    assert isPending(await gate.settle(payment(gate), ?5_000));
    assert dailyHeld(gate) == 0;
    await ledger.setMode(OK);
    switch (await gate.settleFrom(payerP, payment(gate), ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
  });
});

await suite("2.22.0: a malformed sender is refused, not a trap", func() : async () {

  await test("settle with a malformed sender of 5+ characters answers #invalidSignature and leaves the nonce usable", func() : async () {
    // Mutation: parse the sender with Principal.fromText again — the settle traps (a 5xx over
    // HTTP) instead of answering.
    await ledger.script(OK, 0);
    let gate = Gateway.Gateway(config, canisterP);
    gate.setIcpOverHttp(true); // drives ICP through settle (the HTTP path), which is opt-in
    let sig = payment(gate);
    for (bad in ["rrkah-fqaaa-aaaaa-aaaab-cai", "RRKAH-FQAAA-AAAAA-AAAAQ-CAI", "not-a-principal"].vals()) {
      switch (await gate.settle({ sig with sender = bad }, ?5_000)) { case (#invalidSignature(_)) {}; case (_) { assert false } };
    };
    assert (await ledger.pullCalls()) == 0;
    switch (await gate.settle(sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
  });

  await test("Utils.principalFromText: null for bad checksum, alphabet, case, dashes, length; equal to Principal.fromText otherwise", func() : async () {
    // Mutations: drop the round-trip comparison (a bad checksum or misplaced dash parses), or the
    // 33-byte bound (a 30-byte principal reaches Principal.fromBlob, which traps).
    for (t in [
      "aaaaa-aa", // the management canister: no bytes
      "2vxsx-fae", // anonymous
      stranger,
      "ryjl3-tyaaa-aaaaa-aaaba-cai",
      "2mhjn-ayaae-bagba-faydq-qcikb-mga2d-qpcai-reeyu-culbo-gazdi-nry", // 29 bytes, the maximum
    ].vals()) {
      assert Utils.principalFromText(t) == ?Principal.fromText(t);
    };
    for (t in [
      "", "-", "aaaa", "aaaaa-ab", // too short; unused low bits set
      "rrkah-fqaaa-aaaaa-aaaab-cai", // checksum mismatch
      "rrkah-fqaaa-aaaaa-aaaa1-cai", "rrkah-fqaaa-aaaaa-aaaa8-cai", // not base32
      "RRKAH-FQAAA-AAAAA-AAAAQ-CAI", // upper case
      "rrkahfqaaaaaaaaaaaaqcai", "rrkah-fqaaa-aaaaa-aaaaq-cai-", "rrka-hfqaaa-aaaaa-aaaaq-cai", // dashes
      "qqbbt-lybae-aqcai-baeaq-caiba-eaqca-ibaea-qcaib-aeaqc-aibae-aqcai", // 30 bytes, checksum valid
      "qqbbtlybaeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcaibaeaqcai", // the same without dashes: 55 characters, so only the byte bound refuses it
      "2mhjn-ayaae-bagba-faydq-qcikb-mga2d-qpcai-reeyu-culbo-gazdi-nry-aaaaa-aaaaa-aaaaa", // over 63 characters
    ].vals()) {
      assert Utils.principalFromText(t) == null;
    };
  });
});

await suite("ICP through settle (the caller-less HTTP path) is opt-in", func() : async () {

  await test("off by default: settle naming a payer is refused before anything is locked, reserved or pulled", func() : async () {
    // Mutation: drop the icpOverHttp check at the top of settleCore — anyone holding a nonce can
    // name a principal that has approved this canister and spend its allowance (here: #ok, and
    // the ledger is called).
    await ledger.script(OK, 0);
    let gate = Gateway.Gateway(config, canisterP);
    assert not gate.icpOverHttpEnabled();
    let sig = payment(gate);
    switch (await gate.settle({ sig with sender = payer }, ?5_000)) {
      case (#networkNotSupported(_)) {};
      case (_) { assert false };
    };
    assert (await ledger.pullCalls()) == 0;
    assert dailyHeld(gate) == 0;
    // The nonce was not locked: the payer's own Candid payment with it still settles.
    switch (await gate.settleFrom(payerP, sig, ?5_000)) { case (#ok(r)) { assert r.sender == payer }; case (_) { assert false } };
  });

  await test("requireForHttp / describeForHttp advertise ICP only while setIcpOverHttp is on", func() : async () {
    // Mutation: either helper returning the full list regardless — an HTTP 402 or discovery
    // listing offers a rail that settle refuses.
    let gate = Gateway.Gateway(config, canisterP);
    func hasIcp(rs : [Types.PaymentRequirement]) : Bool {
      for (r in rs.vals()) { if (r.network == "icp:1") return true };
      false;
    };
    assert hasIcp(gate.requireAll(5_000)) and hasIcp(gate.describeAll(5_000));
    assert not hasIcp(gate.requireForHttp(5_000));
    assert not hasIcp(gate.describeForHttp(5_000));
    gate.setIcpOverHttp(true);
    assert hasIcp(gate.requireForHttp(5_000));
    assert hasIcp(gate.describeForHttp(5_000));
  });
});
