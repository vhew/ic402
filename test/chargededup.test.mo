/// 2.21.0 — resolving a pending ICP charge through the ledger's deduplication
/// (Gateway.setLedgerDedup).
///
/// 2.20.0 made an ICP charge whose ledger call is rejected with an unknown outcome
/// #settlementPending, with the nonce locked. With the switch on, the charge carries the ledger fee,
/// the nonce as memo and a created_at_time. Re-submitting the same payment sends that exact
/// transfer again, and the ledger's answer decides: #Ok (the first had not landed) or #Duplicate
/// (it had) both give one receipt. Only a charge made through settleFrom (the caller is the payer)
/// keeps its transfer, and only settleFrom re-sends it: over `settle` (HTTP) `sender` is only a
/// claim, so nothing is stored or resolved there.
///
/// Limit: the interpreter's clock never moves, so no test here can tell a re-send that reuses the
/// stored created_at_time from one that takes a fresh one. The re-send passing `p.args` unchanged
/// is pinned by review; what is pinned here is that it reuses the fee (one fee query).
///
/// The fake ledger is an in-file `persistent actor` (as in test/settlereject.test.mo). It
/// deduplicates the way DFINITY's ledgers do when `dedups` is on: an identical argument record
/// that carries a created_at_time answers #Duplicate with the first block. Its rejects are
/// `throw Error.reject`, code #canister_reject: an unknown outcome.
///
/// Each test names the mutation that turns it red.
import Gateway "../src/ic402/Gateway";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import Array "mo:base/Array";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payer = "2vxsx-fae";

let OK = 0; // commit, answer #Ok
let COMMIT_THEN_REJECT = 1; // commit, then reject (a trap after the ledger's archive await)
let REJECT = 2; // reject without committing (e.g. a stopped ledger)
let ANSWER_ERR = 3; // answer `errAnswer`, commit nothing

/// `mode` decides what icrc2_transfer_from does; `hops` makes it yield that many times after
/// counting the call and before answering. `charged` sums committed amounts.
let ledger = persistent actor {
  var mode = 0; var hops = 0; var errAnswer : Types.TransferFromError = #TemporarilyUnavailable;
  var calls = 0; var charged = 0; var blocks = 0; var feeReject = false; var feeCalls = 0;
  var seen : [(Text, Nat)] = [];
  var lastArgs : ?Types.TransferFromArg = null;
  public func script(m : Nat) : async () {
    mode := m; hops := 0; calls := 0; charged := 0; blocks := 0; seen := []; lastArgs := null; feeReject := false; feeCalls := 0;
  };
  public func setMode(m : Nat) : async () { mode := m };
  public func setHops(h : Nat) : async () { hops := h };
  public func setErr(e : Types.TransferFromError) : async () { mode := 3; errAnswer := e };
  public func setFeeReject(b : Bool) : async () { feeReject := b };
  public func stats() : async { calls : Nat; charged : Nat } { { calls; charged } };
  public func last() : async ?Types.TransferFromArg { lastArgs };
  public func feeQueries() : async Nat { feeCalls };
  public func icrc1_fee() : async Nat {
    feeCalls += 1;
    if (feeReject) { throw Error.reject("fee query rejected") };
    10_000;
  };
  public func icrc2_transfer_from(a : Types.TransferFromArg) : async Types.TransferFromResult {
    calls += 1;
    lastArgs := ?a;
    var i = 0; while (i < hops) { await async {}; i += 1 };
    if (mode == 2) { throw Error.reject("ledger is stopped") };
    if (mode == 3) { return #Err(errAnswer) };
    let key = debug_show (a);
    if (a.created_at_time != null) {
      for ((k, b) in seen.vals()) { if (k == key) { return #Err(#Duplicate({ duplicate_of = b })) } };
    };
    blocks += 1;
    charged += a.amount;
    seen := Array.append(seen, [(key, blocks)]);
    if (mode == 1) { throw Error.reject("trapped after commit") };
    #Ok(blocks);
  };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult { #Ok(0) };
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

/// A fresh gateway (switch as given) and a payment for 5_000 against a nonce it just issued.
func setup(dedup : Bool) : (Gateway.Gateway, Types.PaymentSignature) {
  let gate = Gateway.Gateway(config, canisterP);
  gate.setLedgerDedup(dedup);
  let req = gate.require({ token = ledgerP; amount = 5_000; network = "icp:1" });
  (gate, {
    scheme = "exact"; network = "icp:1"; signature = Blob.fromArray([]); publicKey = null;
    asset = null; sender = payer; nonce = req.nonce; authorization = null;
  });
};

let payerP = Principal.fromText(payer);

/// The payer's own Candid settle: the only path that stores and re-sends a pending charge.
func pay(gate : Gateway.Gateway, sig : Types.PaymentSignature, price : ?Nat) : async Types.PaymentResult {
  await gate.settleFrom(payerP, sig, price);
};

func isPending(r : Types.PaymentResult) : Bool { switch (r) { case (#settlementPending(_)) { true }; case (_) { false } } };

await suite("2.21.0: a pending ICP charge resolves through the ledger's deduplication", func() : async () {

  await test("charged, then rejected: re-submitting the same payment gives the receipt, and the payer is charged once", func() : async () {
    // Mutations: answer #Duplicate as still pending; re-send without created_at_time (the ledger
    // takes it as a new transfer and charges again); or re-query the fee for the re-send.
    await ledger.script(COMMIT_THEN_REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    switch (await pay(gate, sig, ?5_000)) {
      case (#ok(r)) { assert r.txHash == ?"1"; assert r.amount == 5_000 }; // the first transfer's block
      case (_) { assert false };
    };
    assert (await ledger.stats()) == { calls = 2; charged = 5_000 };
    assert (await ledger.feeQueries()) == 1; // the re-send reuses the stored fee
  });

  await test("rejected before it was charged: the re-submit charges it once", func() : async () {
    // Mutation: treat #Ok on the re-send as still pending (only #Duplicate resolves).
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    switch (await pay(gate, sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    assert (await ledger.stats()) == { calls = 2; charged = 5_000 };
  });

  await test("after the receipt, another re-submit is #expired and sends nothing", func() : async () {
    // Mutation: drop consumeLocked from the receipt path — the nonce stays locked and the payment
    // reads as pending forever.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    ignore await pay(gate, sig, ?5_000);
    await ledger.setMode(OK);
    ignore await pay(gate, sig, ?5_000);
    switch (await pay(gate, sig, ?5_000)) { case (#expired(_)) {}; case (_) { assert false } };
    assert (await ledger.stats()).calls == 2;
  });

  await test("switch on: the charge carries the ledger fee, the nonce as memo and a created_at_time", func() : async () {
    // Mutations: send `fee = null` (the ICP ledger would then key on whatever fee it charges at
    // the re-send), or `memo = null` (two equal charges in one round would share a key).
    await ledger.script(OK);
    let (gate, sig) = setup(true);
    switch (await pay(gate, sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    switch (await ledger.last()) {
      case (?a) {
        assert a.fee == ?10_000;
        assert a.memo == ?sig.nonce;
        assert a.created_at_time != null;
      };
      case (null) { assert false };
    };
  });

  await test("switch off: exactly 2.20.0 — no dedup fields, and a re-submit sends nothing", func() : async () {
    // Mutations: store the transfer whatever the switch says; or send the dedup fields when off.
    await ledger.script(COMMIT_THEN_REJECT);
    let (gate, sig) = setup(false);
    assert isPending(await pay(gate, sig, ?5_000));
    switch (await ledger.last()) {
      case (?a) { assert a.fee == null and a.memo == null and a.created_at_time == null };
      case (null) { assert false };
    };
    await ledger.setMode(OK);
    assert isPending(await pay(gate, sig, ?5_000));
    assert (await ledger.stats()) == { calls = 1; charged = 5_000 };
  });

  await test("turning the switch on while a charge is in flight stores nothing", func() : async () {
    // Mutation: decide whether to store the transfer from the live switch instead of the value
    // read before the awaits — the stored record has no created_at_time, the ledger cannot
    // deduplicate it, and the re-submit charges a second time.
    await ledger.script(COMMIT_THEN_REJECT);
    await ledger.setHops(3);
    let (gate, sig) = setup(false);
    let first = gate.settleFrom(payerP, sig, ?5_000);
    var n = 0; while ((await ledger.stats()).calls == 0 and n < 50) { await async {}; n += 1 };
    gate.setLedgerDedup(true); // the transfer call is in flight
    assert isPending(await first);
    await ledger.setHops(0);
    await ledger.setMode(OK);
    assert isPending(await pay(gate, sig, ?5_000));
    assert (await ledger.stats()) == { calls = 1; charged = 5_000 };
  });

  await test("another principal's settleFrom with the nonce sends nothing; the payer's own still resolves", func() : async () {
    // Mutation: drop the sender comparison — the other principal's settleFrom sends the payer's
    // transfer and collects the receipt for it.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await gate.settleFrom(canisterP, { sig with sender = "aaaaa-aa" }, ?5_000));
    assert (await ledger.stats()).calls == 1;
    switch (await pay(gate, sig, ?5_000)) { case (#ok(r)) { assert r.sender == payer }; case (_) { assert false } };
  });

  await test("a re-submit at another price sends nothing", func() : async () {
    // Mutation: drop the expectedAmount comparison.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await pay(gate, sig, ?6_000));
    assert (await ledger.stats()).calls == 1;
  });

  await test("HTTP: a charge made through settle stores nothing, so even the payer's settleFrom cannot re-send it", func() : async () {
    // Mutation: store the transfer whatever the path — an HTTP request naming any payer would leave
    // a transfer that a later settleFrom re-sends.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await gate.settle(sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await pay(gate, sig, ?5_000));
    assert (await ledger.stats()).calls == 1;
  });

  await test("HTTP: a settle naming the payer never re-sends a settleFrom charge; the payer's settleFrom does", func() : async () {
    // Mutation: resolve on any path — whoever presents the nonce and names the payer over HTTP
    // collects the receipt for the payer's transfer.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await gate.settle(sig, ?5_000));
    assert (await ledger.stats()).calls == 1;
    switch (await pay(gate, sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    assert (await ledger.stats()) == { calls = 2; charged = 5_000 };
  });

  await test("a re-submit on another network sends nothing", func() : async () {
    // Mutation: drop the network comparison.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await pay(gate, { sig with network = "icp:2" }, ?5_000));
    assert (await ledger.stats()).calls == 1;
  });

  await test("a re-submit with no price (expectedAmount = null) resolves at the nonce's bound amount", func() : async () {
    // Mutation: treat a null expectedAmount as a mismatch — a consumer that relies on the bound
    // amount could never resolve its pending charges.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    switch (await pay(gate, sig, null)) { case (#ok(r)) { assert r.amount == 5_000 }; case (_) { assert false } };
    assert (await ledger.stats()) == { calls = 2; charged = 5_000 };
  });

  await test("two re-submits at once: the transfer is re-sent once, one receipt", func() : async () {
    // Mutation: put the stored transfer back before the re-send's await instead of after — the
    // second re-submit re-sends it too, and both get a receipt.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    await ledger.setHops(3);
    let a = gate.settleFrom(payerP, sig, ?5_000);
    let b = gate.settleFrom(payerP, sig, ?5_000);
    let ra = await a;
    let rb = await b;
    var receipts = 0;
    for (r in [ra, rb].vals()) { switch (r) { case (#ok(_)) { receipts += 1 }; case (_) { assert isPending(r) } } };
    assert receipts == 1;
    assert (await ledger.stats()) == { calls = 2; charged = 5_000 };
  });

  await test("a re-send that is itself rejected stays pending, and a later re-submit resolves", func() : async () {
    // Mutation: do not store the transfer again after a rejected re-send — every later
    // re-submit answers pending without trying.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    assert isPending(await pay(gate, sig, ?5_000)); // the ledger is still stopped
    await ledger.setMode(OK);
    switch (await pay(gate, sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    assert (await ledger.stats()) == { calls = 3; charged = 5_000 };
  });

  await test("a re-send answered with a fixable #Err (allowance) stays pending, and a later re-submit resolves", func() : async () {
    // Mutation: do not store the transfer again in the catch-all #Err arm.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setErr(#InsufficientAllowance({ allowance = 0 }));
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    switch (await pay(gate, sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
    assert (await ledger.stats()) == { calls = 3; charged = 5_000 };
  });

  await test("#TooOld: the window passed — still pending, the nonce stays locked, and nothing is re-sent again", func() : async () {
    // Mutations: keep the stored transfer after #TooOld (every re-submit makes a ledger call that
    // cannot decide anything); or unlock the nonce (the next re-submit starts a NEW charge).
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setErr(#TooOld);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await pay(gate, sig, ?5_000));
    assert (await ledger.stats()) == { calls = 2; charged = 0 };
  });

  await test("#BadFee: the fee changed — still pending, and nothing is re-sent again", func() : async () {
    // Mutation: keep the stored transfer after #BadFee.
    await ledger.script(REJECT);
    let (gate, sig) = setup(true);
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setErr(#BadFee({ expected_fee = 20_000 }));
    assert isPending(await pay(gate, sig, ?5_000));
    await ledger.setMode(OK);
    assert isPending(await pay(gate, sig, ?5_000));
    assert (await ledger.stats()) == { calls = 2; charged = 0 };
  });

  await test("the fee query fails: nothing is sent, and the nonce is free for a retry", func() : async () {
    // Mutation: keep the nonce locked when the fee query fails — the payer's retry reads as
    // pending although nothing moved.
    await ledger.script(OK);
    await ledger.setFeeReject(true);
    let (gate, sig) = setup(true);
    switch (await pay(gate, sig, ?5_000)) { case (#settlementFailed(_)) {}; case (_) { assert false } };
    assert (await ledger.stats()).calls == 0;
    await ledger.setFeeReject(false);
    switch (await pay(gate, sig, ?5_000)) { case (#ok(_)) {}; case (_) { assert false } };
  });
});
