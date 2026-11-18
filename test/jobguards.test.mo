/// 2.22.0 — service-marketplace fixes from the whole-library review.
///
///   M1  A #Submitted BuyerConfirm job is settled to the operator once its dispute window ends
///       (owner decision D1); before, the sweep refunded it at expiresAt and the buyer kept both
///       the result and the money. The window decides, not expiresAt; a window of 0 keeps the
///       old behaviour.
///   M3  The expiry sweep's refund: a ledger reject parks the job #Settling (unknown outcome) and
///       the sweep goes on; a definite #Err puts the job back for the next tick. Before, either
///       left it #Expired with the refund owed, for GC to drop after 24h. Round 2 bounds those
///       retries (suites at the end).
///   M5  submitResult is refused while the ZK verifier call is in flight (#Computing); a verifier
///       call that throws puts the job back to #Assigned for a resubmit.
///   M6  Buyer confirm/dispute (and the EVM-signed variants) apply to BuyerConfirm jobs only.
///   M8  resolveJob accepts any job carrying a parked tx, not only #Settling ones.
///   M10 registerService validates before consuming an id, refuses `svc-<n>` ids from callers
///       and oversized ids/keys; settleJob stamps completedAt at settlement.
///
/// The fake ledger and verifier are in-file `persistent actor`s (as in test/jobrevert.test.mo);
/// the EVM transfer hook is an in-file function playing a script.
/// Time.now() is a small constant under mo:test, so times here are relative: a dispute window that
/// ended is a submit time ten seconds in the past, an expired job has expiresAt = -1.
/// Each test names the mutation that turns it red.
import ServiceRegistry "../src/ic402/ServiceRegistry";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import Error "mo:base/Error";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let buyerP = Principal.fromText("2vxsx-fae");
let operatorP = Principal.fromText("aaaaa-aa");
let SEC : Int = 1_000_000_000;
let DAY : Int = 86_400 * SEC;
let FAR : Int = 9_999_999_999_999_999_999;
let NOT_BC = "Job's service does not use BuyerConfirm verification";

type Outcome = { #ok; #err; #reject };

let ledger = persistent actor {
  var outcomes : [Outcome] = [#ok]; var transfers = 0;
  /// One outcome per transfer, in order; the last repeats.
  public func script(seq : [Outcome]) : async () { outcomes := seq; transfers := 0 };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult {
    transfers += 1;
    switch (outcomes[Nat.min(transfers, outcomes.size()) - 1 : Nat]) {
      case (#ok) { #Ok(transfers) };
      case (#err) { #Err(#TemporarilyUnavailable) };
      case (#reject) { throw Error.reject("ledger is stopped") };
    };
  };
};

let verifier = persistent actor {
  var hops = 0; var outcomes : [Outcome] = [#ok]; var calls = 0;
  /// Each call yields `h` times (so a test can act while it is in flight), then answers.
  public func script(h : Nat, seq : [Outcome]) : async () { hops := h; outcomes := seq; calls := 0 };
  public func verifyCalls() : async Nat { calls };
  public func verify_groth16(_ : Blob, _ : [Blob], _ : Blob) : async { #ok; #err : Text } {
    calls += 1;
    let o = outcomes[Nat.min(calls, outcomes.size()) - 1 : Nat];
    var i = 0; while (i < hops) { await async {}; i += 1 };
    switch (o) {
      case (#ok) { #ok };
      case (#err) { #err("bad proof") };
      case (#reject) { throw Error.reject("verifier is stopped") };
    };
  };
};

func service(id : Text, verification : Types.VerificationMethod) : (Text, Types.ServiceDefinition) {
  (id, {
    id; name = "s"; description = ""; serviceType = #Async; pricing = #Exact(990); verification;
    delivery = #Poll; timeout = 300; operatorId = operatorP; enabled = true; createdAt = 0;
  });
};

func buyerConfirm(windowSeconds : Nat) : (Text, Types.ServiceDefinition) {
  service("svc-bc", #BuyerConfirm({ disputeWindowSeconds = windowSeconds }));
};

let zk = service("svc-zk", #ZkGroth16({ verificationKey = Blob.fromArray([1]); verifierCanister = Principal.fromActor(verifier); bindResult = false }));

/// An ICP job of `serviceId`: amount 1_000 (ledgerFee 10), claimed by the operator.
func job(id : Text, serviceId : Text, status : Types.JobStatus, completedAt : ?Int, expiresAt : Int) : (Text, Types.Job) {
  (id, {
    id; serviceId; buyer = Principal.toText(buyerP); operator = ?operatorP;
    params = Blob.fromArray([1]); paymentReceiptId = "rcpt-" # id; amount = 1_000; actualCost = null;
    status; result = ?Blob.fromArray([7]); proof = ?Blob.fromArray([9]); createdAt = 0; expiresAt; completedAt;
    deliveryCallback = null; parkedTx = null;
  });
};

func mk(services : [(Text, Types.ServiceDefinition)], jobs : [(Text, Types.Job)]) : ServiceRegistry.ServiceRegistry {
  let reg = ServiceRegistry.ServiceRegistry(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = Principal.fromActor(ledger); symbol = "TKN"; decimals = 6 }]; ledgerFee = 10 },
  );
  reg.loadStable({ services; jobs; serviceCounter = 0; jobCounter = jobs.size(); evmRails = null; operatorPayouts = null });
  reg;
};

func status(reg : ServiceRegistry.ServiceRegistry) : ?Types.JobStatus { reg.getJobStatus("job-1") };

// ── M1 ──────────────────────────────────────────────────────────────────────────────────────

await suite("M1: a BuyerConfirm job's dispute window (D1)", func() : async () {

  await test("a #Submitted job whose window has ended is settled to the operator by the sweep", func() : async () {
    // Mutation: never auto-settle (`if (now > windowEnd)` -> `if (false)`) — the job stays
    // #Submitted, and the buyer keeps result and money.
    await ledger.script([#ok]);
    let reg = mk([buyerConfirm(1)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), FAR)]);
    assert (await reg.expireJobs()) == [];
    assert status(reg) == ?#Settled;
    assert (await ledger.transferCalls()) == 1; // the operator's payment, nothing else
  });

  await test("the window wins over expiresAt: a job inside its window is neither refunded nor settled", func() : async () {
    // Mutation: drop the `continue sweep` after the window check — the job past expiresAt falls
    // through to the expiry refund, inside the window the buyer was promised.
    await ledger.script([#ok]);
    let reg = mk([buyerConfirm(3600)], [job("job-1", "svc-bc", #Submitted, ?0, -1)]);
    assert (await reg.expireJobs()) == [];
    assert status(reg) == ?#Submitted;
    assert (await ledger.transferCalls()) == 0;
    assert reg.hasExpiryWork(); // the sweep stays at its working cadence until the window ends
  });

  await test("a window of 0 keeps the pre-2.22.0 behaviour: refunded at expiresAt", func() : async () {
    // Mutation: drop the `disputeWindowSeconds == 0` case — a 0 window ends at submit time and
    // the job is paid to the operator on the first tick.
    await ledger.script([#ok]);
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), -1)]);
    assert (await reg.expireJobs()) == ["job-1"];
    assert status(reg) == ?#Refunded;
  });

  await test("a #Disputed job is not settled when the window ends: it is refunded at expiresAt", func() : async () {
    // Mutation: apply the window to #Disputed jobs too — a disputed job is paid to the operator.
    await ledger.script([#ok]);
    let reg = mk([buyerConfirm(1)], [job("job-1", "svc-bc", #Disputed, ?(-10 * SEC), -1)]);
    assert (await reg.expireJobs()) == ["job-1"];
    assert status(reg) == ?#Refunded;
  });

  await test("an auto-settle the ledger rejects leaves the job #Settling, and the sweep does not throw", func() : async () {
    // Mutation: rethrow in the auto-settle's catch — one rejected payment ends the whole tick.
    await ledger.script([#reject]);
    let reg = mk([buyerConfirm(1)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), FAR)]);
    try { ignore await reg.expireJobs() } catch (_) { assert false };
    assert status(reg) == ?#Settling;
  });
});

// ── M3 ──────────────────────────────────────────────────────────────────────────────────────

await suite("M3: the expiry sweep's refund outcomes", func() : async () {

  await test("a rejected refund parks the job #Settling; the sweep does not throw; resolveJob closes it", func() : async () {
    // Mutation: rethrow in the refund's catch, or leave the job #Expired there — the job sits
    // #Expired, refused by resolveJob/resolveDispute/reconcileJob, until GC drops it.
    await ledger.script([#reject]);
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Disputed, null, -1)]);
    let swept = try { await reg.expireJobs() } catch (_) { assert false; [] };
    assert swept == [];
    assert status(reg) == ?#Settling;
    assert reg.hasExpiryWork();
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
  });

  await test("a refused refund (#Err) puts the job back as it was; the next tick refunds it", func() : async () {
    // Mutation: leave the job #Expired on #Err — no tick retries it, and GC drops the owed refund.
    await ledger.script([#err, #ok]);
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Disputed, null, -1)]);
    assert (await reg.expireJobs()) == [];
    assert status(reg) == ?#Disputed;
    assert (await reg.expireJobs()) == ["job-1"];
    assert status(reg) == ?#Refunded;
    assert (await ledger.transferCalls()) == 2;
  });
});

// ── M5 ──────────────────────────────────────────────────────────────────────────────────────

await suite("M5: submitResult and the ZK verifier call", func() : async () {

  await test("a second submitResult while the verifier call is in flight is refused", func() : async () {
    // Mutation: accept #Computing in submitResult again — the operator swaps result and cost under
    // the verifier call and is paid 990 for a record the proof did not bind.
    await ledger.script([#ok]);
    await verifier.script(40, [#ok]);
    let reg = mk([zk], [job("job-1", "svc-zk", #Assigned, null, FAR)]);
    let first = reg.submitResult(operatorP, "job-1", Blob.fromArray([1]), ?Blob.fromArray([2]), ?100);
    var n = 0; while ((await verifier.verifyCalls()) < 1 and n < 100) { await async {}; n += 1 };
    assert status(reg) == ?#Computing;
    switch (await reg.submitResult(operatorP, "job-1", Blob.fromArray([3]), ?Blob.fromArray([2]), ?990)) {
      case (#err(_)) {}; case (#ok) { assert false };
    };
    switch (await first) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Settled;
    switch (reg.getJob("job-1")) {
      case (?j) { assert j.actualCost == ?100; assert j.result == ?Blob.fromArray([1]) };
      case (null) { assert false };
    };
  });

  await test("a verifier call that throws puts the job back to #Assigned; the operator resubmits", func() : async () {
    // Mutation: leave the job #Computing in the verifier's catch — the resubmit is refused, and
    // the job waits for the expiry refund.
    await ledger.script([#ok]);
    await verifier.script(0, [#reject, #ok]);
    let reg = mk([zk], [job("job-1", "svc-zk", #Assigned, null, FAR)]);
    switch (await reg.submitResult(operatorP, "job-1", Blob.fromArray([1]), ?Blob.fromArray([2]), null)) {
      case (#err(_)) {}; case (#ok) { assert false };
    };
    assert status(reg) == ?#Assigned;
    switch (await reg.submitResult(operatorP, "job-1", Blob.fromArray([1]), ?Blob.fromArray([2]), null)) {
      case (#ok) {}; case (#err(_)) { assert false };
    };
    assert status(reg) == ?#Settled;
  });
});

// ── M6 ──────────────────────────────────────────────────────────────────────────────────────

await suite("M6: buyer confirm/dispute are for BuyerConfirm jobs only", func() : async () {

  await test("all four buyer entry points refuse a #Submitted AutoSettle job", func() : async () {
    // Mutation: drop the BuyerConfirm check from any one of disputeJob, confirmJob, disputeJobEvm,
    // confirmJobEvm — that call disputes or pays out a job outside its verification (the EVM ones
    // then fail on the signature instead, with a different error).
    await ledger.script([#ok]);
    let reg = mk([service("svc-auto", #AutoSettle)], [job("job-1", "svc-auto", #Submitted, ?0, FAR)]);
    let sig = Array.tabulate<Nat8>(65, func(_) { 1 });
    assert reg.disputeJob(buyerP, "job-1", "x") == #err(NOT_BC);
    assert (await reg.confirmJob(buyerP, "job-1")) == #err(NOT_BC);
    assert reg.disputeJobEvm("job-1", sig, "x") == #err(NOT_BC);
    assert (await reg.confirmJobEvm("job-1", sig)) == #err(NOT_BC);
    assert status(reg) == ?#Submitted;
    assert (await ledger.transferCalls()) == 0;
  });
});

// ── M8 ──────────────────────────────────────────────────────────────────────────────────────

await suite("M8: resolveJob and parked txs outside #Settling", func() : async () {

  func parkedRefund(reg : ServiceRegistry.ServiceRegistry) {
    let s = reg.toStable();
    reg.loadStable({ s with jobs = Array.map<(Text, Types.Job), (Text, Types.Job)>(s.jobs, func((id, j)) {
      (id, { j with parkedTx = ?{ txHash = "0xdead"; leg = #Refund; chainId = 8453; token = "0x22"; parkedAt = 0 } });
    }) });
  };

  await test("resolveJob closes a refund parked on an #Expired job and clears the park", func() : async () {
    // Mutation: resolveJob back to #Settling-only — a parked tx that reverted (reconcileJob says
    // "use resolveJob") has no exit, and the job is never GC'd.
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Expired, ?0, -1)]);
    parkedRefund(reg);
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Refunded;
    switch (reg.getJob("job-1")) { case (?j) { assert j.parkedTx == null }; case (null) { assert false } };
  });

  await test("resolveJob still refuses a terminal job with nothing parked", func() : async () {
    // Mutation: let resolveJob act on any job — a controller could rewrite a settled job's outcome.
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Settled, ?0, -1)]);
    switch (reg.resolveJob("job-1", #Refunded)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Settled;
  });
});

// ── M10 ─────────────────────────────────────────────────────────────────────────────────────

func def(id : Text) : Types.ServiceDefinition {
  { service(id, #AutoSettle).1 with enabled = false };
};

func registered(r : { #ok : Text; #err : Text }) : ?Text {
  switch (r) { case (#ok(id)) { ?id }; case (#err(_)) { null } };
};

await suite("M10: registerService and settlement time", func() : async () {

  await test("a refused registration does not consume an auto id", func() : async () {
    // Mutation: advance the counter on the timeout refusal — the next service is svc-2.
    let reg = mk([], []);
    assert registered(reg.registerService(operatorP, { def("") with timeout = 0 })) == null;
    assert registered(reg.registerService(operatorP, def(""))) == ?"svc-1";
  });

  await test("a caller-chosen id of the svc-<number> form is refused; other ids are not", func() : async () {
    // Mutation: isAutoServiceId always false — a caller squats svc-7, and the 7th auto id fails.
    let reg = mk([], []);
    assert registered(reg.registerService(operatorP, def("svc-7"))) == null;
    assert registered(reg.registerService(operatorP, def("svc-7b"))) == ?"svc-7b";
    assert registered(reg.registerService(operatorP, def("my-svc"))) == ?"my-svc";
  });

  await test("an auto id skips one already taken (a squat from before 2.22.0)", func() : async () {
    // Mutation: no skip — "Service ID already exists: svc-1", on every auto registration.
    let reg = mk([("svc-1", def("svc-1"))], []);
    assert registered(reg.registerService(operatorP, def(""))) == ?"svc-2";
  });

  await test("ids and verification keys are capped", func() : async () {
    // Mutation: drop either cap — a 65-char id or a 16 KiB + 1 key is stored.
    let reg = mk([], []);
    let id64 = Text.join("", Array.tabulate<Text>(64, func(_) { "a" }).vals());
    assert registered(reg.registerService(operatorP, def(id64 # "a"))) == null;
    assert registered(reg.registerService(operatorP, def(id64))) == ?id64;
    func zkDef(size : Nat) : Types.ServiceDefinition {
      { def("") with verification = #ZkGroth16({ verificationKey = Blob.fromArray(Array.tabulate<Nat8>(size, func(_) { 1 })); verifierCanister = canisterP; bindResult = false }) };
    };
    assert registered(reg.registerService(operatorP, zkDef(16_385))) == null;
    assert registered(reg.registerService(operatorP, zkDef(16_384))) != null;
  });

  await test("a job confirmed long after its result is kept 24h from settlement, not from submission", func() : async () {
    // Mutation: drop completedAt from settleJob's #Settled write — completedAt stays the submit
    // time two days ago, and the next GC deletes the job right after it settled.
    await ledger.script([#ok]);
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Submitted, ?(-2 * DAY), FAR)]);
    switch (await reg.confirmJob(buyerP, "job-1")) { case (#ok) {}; case (#err(_)) { assert false } };
    assert reg.gcTerminalJobs() == 0;
    assert status(reg) == ?#Settled;
  });
});

// ── 2.22.0 round 2: what the sweep retries on its own ──────────────────────────────────────
//
// A refund or operator payment that fails definitively (an ICP ledger #Err, an EVM send refused
// before broadcast) is retried by later ticks, at most MAX_AUTO_ATTEMPTS (5) times. One that no
// retry can fix (no hook, no payout address, …) is not retried. One that REVERTED on-chain is
// never sent again: the reverted tx is recorded on the job. A #Verified job — left by a failed
// settle — is now settled by the sweep too (before, only a controller could move it).

type EvmOutcome = { #confirmed; #reverted; #pending; #err };
var evmScript : [EvmOutcome] = [#confirmed];
var evmCalls = 0;
func evmPlay(seq : [EvmOutcome]) { evmScript := seq; evmCalls := 0 };

func evmHook(_ : Nat, _ : Text, _ : Text, _ : Nat) : async { #confirmed : Text; #reverted : Text; #pending : Text; #err : Text } {
  evmCalls += 1;
  switch (evmScript[Nat.min(evmCalls, evmScript.size()) - 1 : Nat]) {
    case (#confirmed) { #confirmed("0xok") };
    case (#reverted) { #reverted("0xbad") };
    case (#pending) { #pending("0xwait") };
    case (#err) { #err("rpc down before broadcast") };
  };
};

let EVM_BUYER = "0x1111111111111111111111111111111111111111";
let EVM_PAYOUT = "0x3333333333333333333333333333333333333333";

/// `jobs` paid on Base by an EVM buyer. `payout`: the operator has an EVM payout address;
/// `hook`: the transfer hook is wired (it plays evmScript).
func mkEvm(services : [(Text, Types.ServiceDefinition)], jobs : [(Text, Types.Job)], payout : Bool, hook : Bool) : ServiceRegistry.ServiceRegistry {
  let reg = mk(services, []);
  reg.loadStable({
    services; serviceCounter = 0; jobCounter = jobs.size();
    jobs = Array.map<(Text, Types.Job), (Text, Types.Job)>(jobs, func((id, j)) { (id, { j with buyer = EVM_BUYER }) });
    evmRails = ?Array.map<(Text, Types.Job), (Text, Types.EvmRail)>(jobs, func((id, _)) { (id, { network = "eip155:8453"; token = "0x2222222222222222222222222222222222222222" }) });
    operatorPayouts = if (payout) { ?[(operatorP, EVM_PAYOUT)] } else { null };
  });
  if (hook) reg.setEvmTransfer(evmHook);
  reg;
};

func parkedHash(reg : ServiceRegistry.ServiceRegistry) : ?Text {
  switch (reg.getJob("job-1")) { case (?j) { switch (j.parkedTx) { case (?p) { ?p.txHash }; case (null) { null } } }; case (null) { null } };
};

func sweeps(reg : ServiceRegistry.ServiceRegistry, n : Nat) : async () {
  var i = 0; while (i < n) { ignore await reg.expireJobs(); i += 1 };
};

await suite("round 2: reverted EVM payments are never sent again", func() : async () {

  await test("an expiry refund that reverts is parked #Expired with its tx; later ticks send nothing", func() : async () {
    // Mutation: refundOnRail maps #reverted to #err again — the sweep restores the job and signs
    // and broadcasts the refund again every tick.
    evmPlay([#reverted]);
    let reg = mkEvm([buyerConfirm(0)], [job("job-1", "svc-bc", #Disputed, null, -1)], true, true);
    assert (await reg.expireJobs()) == [];
    assert status(reg) == ?#Expired;
    assert parkedHash(reg) == ?"0xbad";
    await sweeps(reg, 2);
    assert evmCalls == 1;
    assert not reg.hasExpiryWork(); // terminal: it does not hold the sweep at its working cadence
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert parkedHash(reg) == null;
  });

  await test("an operator payment that reverts is recorded on the #Verified job; later ticks send nothing", func() : async () {
    // Mutation: settleJob's #reverted arm rolls back to a plain #Verified (no record) — the sweep
    // re-drives the job and broadcasts the payment again every tick.
    evmPlay([#reverted]);
    let reg = mkEvm([buyerConfirm(1)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), FAR)], true, true);
    ignore await reg.expireJobs();
    assert status(reg) == ?#Verified;
    assert parkedHash(reg) == ?"0xbad";
    await sweeps(reg, 2);
    assert evmCalls == 1;
  });

  await test("a controller's resolveDispute sends it again and drops the record of the revert", func() : async () {
    // Mutation: resolveDispute keeps the parked tx on its forward writes — the job ends #Settled
    // still carrying the reverted tx, counted as parked and never GC'd.
    evmPlay([#reverted, #confirmed]);
    let reg = mkEvm([buyerConfirm(0)], [job("job-1", "svc-bc", #Submitted, ?0, FAR)], true, true);
    switch (await reg.resolveDispute("job-1", false)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert parkedHash(reg) == ?"0xbad";
    switch (await reg.resolveDispute("job-1", false)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Settled;
    assert parkedHash(reg) == null;
  });
});

await suite("round 2: bounded retries of definite failures", func() : async () {

  await test("a refund that keeps failing (#Err) is tried 5 times, then left as it was for a controller", func() : async () {
    // Mutation: drop the give-up check on the refund path — one ledger call per tick, forever.
    await ledger.script([#err]);
    let reg = mk([buyerConfirm(0)], [job("job-1", "svc-bc", #Disputed, null, -1)]);
    await sweeps(reg, 7);
    assert (await ledger.transferCalls()) == 5;
    assert status(reg) == ?#Disputed;
    await ledger.script([#ok]);
    switch (await reg.resolveDispute("job-1", true)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Refunded;
  });

  await test("an auto-settle that fails (#Err) is settled by the next tick", func() : async () {
    // Mutation: the sweep skips a #Verified job it finds — before round 2, the job sat #Verified
    // with the operator unpaid and the buyer not refunded, and nothing told anyone.
    await ledger.script([#err, #ok]);
    let reg = mk([buyerConfirm(1)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), FAR)]);
    ignore await reg.expireJobs();
    assert status(reg) == ?#Verified;
    ignore await reg.expireJobs();
    assert status(reg) == ?#Settled;
    assert (await ledger.transferCalls()) == 2;
  });

  await test("an operator payment that keeps failing is tried 5 times, then left #Verified", func() : async () {
    // Mutation: drop the give-up check on the settle path — one payment attempt per tick, forever.
    evmPlay([#err]);
    let reg = mkEvm([buyerConfirm(1)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), FAR)], true, true);
    await sweeps(reg, 7);
    assert evmCalls == 5;
    assert status(reg) == ?#Verified;
    assert parkedHash(reg) == null;
  });
});

await suite("round 2: failures no retry can fix are not retried", func() : async () {

  await test("a settle with no operator payout address is not retried, even once one is set", func() : async () {
    // Mutation: count it as a transient failure — the next tick tries again (here it then pays;
    // with the cause unfixed it would fail every tick). A controller re-drives with resolveDispute.
    evmPlay([#confirmed]);
    let reg = mkEvm([buyerConfirm(1)], [job("job-1", "svc-bc", #Submitted, ?(-10 * SEC), FAR)], false, true);
    ignore await reg.expireJobs();
    assert status(reg) == ?#Verified;
    ignore reg.setOperatorEvmPayout(operatorP, EVM_PAYOUT);
    ignore await reg.expireJobs();
    assert evmCalls == 0;
    switch (await reg.resolveDispute("job-1", false)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Settled;
  });

  await test("a refund with no transfer hook is not retried, even once one is wired", func() : async () {
    // Mutation: count it as a transient failure — the next tick tries again.
    evmPlay([#confirmed]);
    let reg = mkEvm([buyerConfirm(0)], [job("job-1", "svc-bc", #Disputed, null, -1)], true, false);
    ignore await reg.expireJobs();
    assert status(reg) == ?#Disputed;
    reg.setEvmTransfer(evmHook);
    ignore await reg.expireJobs();
    assert evmCalls == 0;
    assert status(reg) == ?#Disputed;
  });
});

await suite("round 2: the EVM rail follows the receipt's network", func() : async () {

  await test("an EVM payer spelled 0X… or as bare hex is put on the EVM rail; an ICP payer is not", func() : async () {
    // Mutation: key the rail on the buyer starting with "0x" again — the 0X and bare-hex payers
    // land on the ICP rail, where their refund can never be paid.
    let reg = mk([buyerConfirm(0)], []);
    func receipt(network : Text, sender : Text) : Types.PaymentReceipt {
      { id = "r"; amount = 1_000; token = "0x2222222222222222222222222222222222222222"; sender; recipient = "c"; network; timestamp = 0; txHash = null; sessionId = null; refunded = null };
    };
    let upper = "0XABCDEF0000000000000000000000000000000001";
    let bare = "abcdef0000000000000000000000000000000002";
    let a = reg.createJobFromReceipt(upper, "svc-bc", Blob.fromArray([]), receipt("eip155:8453", upper), null);
    let b = reg.createJobFromReceipt(bare, "svc-bc", Blob.fromArray([]), receipt("eip155:8453", bare), null);
    let c = reg.createJobFromReceipt(Principal.toText(buyerP), "svc-bc", Blob.fromArray([]), receipt("icp:1", Principal.toText(buyerP)), null);
    assert reg.getEvmRail(a) == ?{ network = "eip155:8453"; token = "0x2222222222222222222222222222222222222222" };
    assert reg.getEvmRail(b) != null;
    assert reg.getEvmRail(c) == null;
  });
});
