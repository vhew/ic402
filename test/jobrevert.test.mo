/// 2.17.6 — job-registry fixes found by adversarial review. 2.19.1 — the suites at the end.
///
///   1. A failed in-flight transfer must not undo a controller's resolveJob (below).
///   2. The expiry sweep must judge each job by its live record, not the iterator's copy.
///   3. A job left #Verified by a failed operator payment can be re-driven with resolveDispute.
///
/// resolveDispute (refund) and settleJob (operator payment) put a job in #Settling, await the
/// ledger, and on #Err revert it to its prior status for retry. resolveJob accepts any #Settling
/// job, so a controller can make it terminal DURING that await. The revert used to restore the
/// pre-await snapshot regardless, bringing a resolved job back as #Submitted/#Disputed (refundable,
/// or from #Submitted confirmable and settleable, a second time) or #Verified (which a later
/// resolveDispute would settle or refund a second time). It now reverts only a job still #Settling. Each race test resolves the job
/// to a terminal its own arm's success path would NOT write, so a guard narrowed to one terminal
/// (`!= #Refunded`, `!= #Settled`) still goes red.
///
/// The fake ledger is an in-file `persistent actor` (as in test/closeledger.test.mo): it parks
/// each icrc1_transfer for `hops` yields, so a test can act while the transfer is in flight, then
/// answers #Ok or #Err as scripted. Each test names the mutation that turns it red.
import ServiceRegistry "../src/ic402/ServiceRegistry";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat32 "mo:base/Nat32";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Error "mo:base/Error";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let buyerP = Principal.fromText("2vxsx-fae");
let operatorP = Principal.fromText("aaaaa-aa");

// What the fake ledger does with a transfer: answer #Ok, answer #Err, or reject the call. The
// reject is an explicit one (#canister_reject); a real stopped ledger answers CANISTER_ERROR. The
// registry must not catch either: see payFromMainAccount.
type Outcome = { #ok; #err; #reject };

let ledger = persistent actor {
  var hops = 0; var outcomes : [Outcome] = [#err]; var transfers = 0;
  public func script(h : Nat, o : Bool) : async () { hops := h; outcomes := [if o #ok else #err]; transfers := 0 };
  /// One outcome per transfer, in order; the last repeats.
  public func scriptSeq(h : Nat, seq : [Outcome]) : async () { hops := h; outcomes := seq; transfers := 0 };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult {
    transfers += 1;
    let n = transfers;
    let o = outcomes[Nat.min(n, outcomes.size()) - 1 : Nat];
    var i = 0; while (i < hops) { await async {}; i += 1 };
    switch (o) {
      case (#ok) { #Ok(n) };
      case (#err) { #Err(#TemporarilyUnavailable) };
      case (#reject) { throw Error.reject("ledger is stopped") };
    };
  };
};

/// A registry holding ICP jobs (id, status, expiresAt), all with the same buyer and operator.
func mk(specs : [(Text, Types.JobStatus, Int)]) : ServiceRegistry.ServiceRegistry {
  let reg = ServiceRegistry.ServiceRegistry(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = Principal.fromActor(ledger); symbol = "TKN"; decimals = 6 }]; ledgerFee = 10 },
  );
  reg.loadStable({
    services = []; serviceCounter = 0; jobCounter = specs.size(); evmRails = null; operatorPayouts = null;
    jobs = Array.map<(Text, Types.JobStatus, Int), (Text, Types.Job)>(specs, func((id, status, expiresAt)) {
      (id, {
        id; serviceId = "svc-1"; buyer = Principal.toText(buyerP); operator = ?operatorP;
        params = Blob.fromArray([]); paymentReceiptId = "rcpt-" # id; amount = 1_000; actualCost = null;
        status; result = null; proof = null; createdAt = 0; expiresAt; completedAt = null;
        deliveryCallback = null; parkedTx = null;
      });
    });
  });
  reg;
};

func status(reg : ServiceRegistry.ServiceRegistry) : ?Types.JobStatus { reg.getJobStatus("job-1") };

/// Yield until the job's transfer is in flight (the job is then #Settling).
func untilTransferring(reg : ServiceRegistry.ServiceRegistry) : async () {
  var n = 0; while ((await ledger.transferCalls()) < 1 and n < 100) { await async {}; n += 1 };
  assert (await ledger.transferCalls()) == 1;
  assert status(reg) == ?#Settling;
};

await suite("a failed transfer does not undo resolveJob (2.17.6)", func() : async () {

  await test("refund: resolveJob lands mid-transfer, the refund fails, the job stays terminal", func() : async () {
    // Mutation: drop the still-#Settling guard on resolveDispute's refund #err arm — the job comes
    // back #Disputed, open to a second refund.
    await ledger.script(40, false);
    let reg = mk([("job-1", #Disputed, 0)]);
    let f = reg.resolveDispute("job-1", true);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Expired)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Expired;
    assert not reg.hasExpiryWork();
  });

  await test("settle: resolveJob lands mid-transfer, the payment fails, the job stays terminal", func() : async () {
    // Mutation: drop the still-#Settling guard on settleJob's #err arm — the job comes back
    // #Verified, where a later resolveDispute would pay it a second time.
    await ledger.script(40, false);
    let reg = mk([("job-1", #Disputed, 0)]);
    let f = reg.resolveDispute("job-1", false);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Refunded;
    assert not reg.hasExpiryWork();
  });

  await test("refund: with no resolveJob, a failed refund still reverts for retry", func() : async () {
    // Mutation: never revert (or invert the guard) — the job would rest in #Settling.
    await ledger.script(0, false);
    let reg = mk([("job-1", #Disputed, 0)]);
    switch (await reg.resolveDispute("job-1", true)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Disputed;
  });

  await test("settle: with no resolveJob, a failed payment still rolls back to #Verified", func() : async () {
    // Mutation: as above, on settleJob's arm.
    await ledger.script(0, false);
    let reg = mk([("job-1", #Disputed, 0)]);
    switch (await reg.resolveDispute("job-1", false)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Verified;
  });
});

await suite("the expiry sweep judges each job by its live record (2.17.6)", func() : async () {

  await test("a job confirmed while the sweep refunds another is not also refunded", func() : async () {
    // Mutation: iterate with `for ((id, job) in jobs.entries())` again (no live re-read) — the job
    // confirmed mid-sweep is expired from the iterator's stale #Submitted copy and its buyer
    // refunded on top of the operator payment (3 transfers, not 2).
    // The stale copy needs job-21 and job-14 in the same HashMap bucket. job-y (never expires) is
    // written first so the table has already grown to 6 slots before the sweep starts; the
    // precondition is asserted, so a change in mo:base's hash fails here loudly, not vacuously.
    assert Nat32.toNat(Text.hash("job-21")) % 6 == Nat32.toNat(Text.hash("job-14")) % 6;
    await ledger.script(40, true);
    let reg = mk([("job-21", #Submitted, 0), ("job-14", #Submitted, 0), ("job-y", #Submitted, 9_999_999_999_999_999_999)]);
    switch (reg.disputeJob(buyerP, "job-y", "resize")) { case (#ok) {}; case (#err(_)) { assert false } };
    // The sweep visits the two timed-out jobs in iteration order: W first, then X.
    let order = Array.filter<Text>(Array.map<Types.Job, Text>(reg.listJobs("svc-1", null), func(j) { j.id }), func(id) { id != "job-y" });
    assert order.size() == 2;
    let (w, x) = (order[0], order[1]);
    let sweep = reg.expireJobs();
    var n = 0; while ((await ledger.transferCalls()) < 1 and n < 100) { await async {}; n += 1 };
    assert reg.getJobStatus(w) == ?#Expired; // W's refund is in flight
    let confirm = reg.confirmJob(buyerP, x); // X: #Submitted -> #Verified -> settle to the operator
    switch (await confirm) { case (#ok) {}; case (#err(_)) { assert false } };
    let swept = await sweep;
    assert swept == [w];
    assert (await ledger.transferCalls()) == 2; // W's refund and X's operator payment, nothing else
    assert reg.getJobStatus(x) == ?#Settled;
  });
});

await suite("a job left #Verified by a failed payment can be re-driven (2.17.6)", func() : async () {

  await test("resolveDispute(false) retries the settle once the cause is fixed", func() : async () {
    // Mutation: drop #Verified from resolveDispute's resolvable states — the job stays stuck.
    await ledger.script(0, false);
    let reg = mk([("job-1", #Submitted, 9_999_999_999_999_999_999)]);
    switch (await reg.confirmJob(buyerP, "job-1")) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Verified; // "Settlement failed: …", nothing moved
    await ledger.script(0, true);
    switch (await reg.resolveDispute("job-1", false)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Settled;
    assert (await ledger.transferCalls()) == 1;
  });

  await test("a second resolveDispute while the refund is in flight is rejected; one transfer", func() : async () {
    // Mutation: widen resolveDispute's resolvable states to #Settling (or to every status) — the
    // second call is accepted and refunds the buyer a second time.
    await ledger.script(40, true);
    let reg = mk([("job-1", #Disputed, 0)]);
    let f = reg.resolveDispute("job-1", true);
    await untilTransferring(reg);
    switch (await reg.resolveDispute("job-1", true)) { case (#err(_)) {}; case (#ok) { assert false } };
    switch (await f) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Refunded;
    assert (await ledger.transferCalls()) == 1;
  });

  await test("a terminal job is rejected; nothing moves", func() : async () {
    // Mutation: as above.
    await ledger.script(0, true);
    let reg = mk([("job-1", #Refunded, 0)]);
    switch (await reg.resolveDispute("job-1", true)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Refunded;
    assert (await ledger.transferCalls()) == 0;
  });

  await test("resolveDispute(true) refunds it instead", func() : async () {
    // Mutation: as above.
    await ledger.script(0, true);
    let reg = mk([("job-1", #Verified, 9_999_999_999_999_999_999)]);
    switch (await reg.resolveDispute("job-1", true)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert status(reg) == ?#Refunded;
    assert (await ledger.transferCalls()) == 1;
  });
});

// ── 2.19.1 ──────────────────────────────────────────────────────────────────────────────────

/// A registry with one ICP job "job-1" (status, actualCost). amount 1_000, ledgerFee 10, so an
/// Upto job with actualCost ?100 pays the operator 100 and refunds the buyer 880 (two transfers).
func mkUpto(status : Types.JobStatus, actualCost : ?Nat) : ServiceRegistry.ServiceRegistry {
  let reg = mk([("job-1", status, 9_999_999_999_999_999_999)]);
  let s = reg.toStable();
  reg.loadStable({ s with jobs = Array.map<(Text, Types.Job), (Text, Types.Job)>(s.jobs, func((id, j)) { (id, { j with actualCost }) }) });
  reg;
};

/// Yield until `n` transfers have been sent.
func untilCalls(n : Nat) : async () {
  var k = 0; while ((await ledger.transferCalls()) < n and k < 200) { await async {}; k += 1 };
  assert (await ledger.transferCalls()) == n;
};

await suite("2.19.1 review: a ledger reject is not caught, so the job stays #Settling", func() : async () {
  // A reject does not prove the transfer failed: the DFINITY ledgers commit, then await their
  // archive, so a trap after that rejects a transfer that landed. Rolling back would let a retry
  // pay twice. The job must stay #Settling for a controller to check and resolveJob.

  await test("settle: the ledger rejects, the call rejects too, and the job stays #Settling", func() : async () {
    // Mutation: catch the reject in payFromMainAccount and return #err — the job rolls back to
    // #Verified and this call returns instead of rejecting.
    await ledger.scriptSeq(0, [#reject]);
    let reg = mk([("job-1", #Disputed, 9_999_999_999_999_999_999)]);
    var rejected = false;
    try { ignore await reg.resolveDispute("job-1", false) } catch (_) { rejected := true };
    assert rejected;
    assert status(reg) == ?#Settling;
    switch (reg.resolveJob("job-1", #Settled)) { case (#ok) {}; case (#err(_)) { assert false } };
  });

  await test("dispute refund: the ledger rejects, and the job stays #Settling", func() : async () {
    // Mutation: as above, on the refund leg (refundOnRail shares payFromMainAccount).
    await ledger.scriptSeq(0, [#reject]);
    let reg = mk([("job-1", #Disputed, 0)]);
    var rejected = false;
    try { ignore await reg.resolveDispute("job-1", true) } catch (_) { rejected := true };
    assert rejected;
    assert status(reg) == ?#Settling;
  });
});

await suite("2.19.1: a payout that completes after resolveJob leaves the job as resolved", func() : async () {

  await test("settle: resolveJob lands mid-transfer, the payment succeeds, the job stays terminal", func() : async () {
    // Mutation: drop both the #ok-arm and the final guard in settleJob — the controller's
    // #Refunded is overwritten with #Settled.
    await ledger.script(40, true);
    let reg = mk([("job-1", #Disputed, 0)]);
    let f = reg.resolveDispute("job-1", false);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Refunded;
  });

  await test("settle (Upto): resolved during the operator payment, no remainder refund is sent", func() : async () {
    // Mutation: drop the guard on settleJob's operator #ok arm — the remainder refund still goes
    // out after the controller resolved the job (a second transfer).
    await ledger.script(40, true);
    let reg = mkUpto(#Disputed, ?100);
    let f = reg.resolveDispute("job-1", false);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Refunded;
    assert (await ledger.transferCalls()) == 1;
  });

  await test("settle (Upto): resolved during the remainder refund, which succeeds; the job stays terminal", func() : async () {
    // Mutation: drop settleJob's final guard — #Expired is overwritten with #Settled.
    await ledger.script(40, true);
    let reg = mkUpto(#Disputed, ?100);
    let f = reg.resolveDispute("job-1", false);
    await untilCalls(2);
    switch (reg.resolveJob("job-1", #Expired)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Expired;
  });

  await test("settle (Upto): resolved during the remainder refund, which fails; the job stays terminal", func() : async () {
    // Mutation: drop the guard on the remainder #err arm — #Expired is overwritten with #Settled.
    await ledger.scriptSeq(40, [#ok, #err]);
    let reg = mkUpto(#Disputed, ?100);
    let f = reg.resolveDispute("job-1", false);
    await untilCalls(2);
    switch (reg.resolveJob("job-1", #Expired)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Expired;
  });

  await test("dispute refund: resolveJob lands mid-transfer, the refund succeeds, the job stays terminal", func() : async () {
    // Mutation: drop the guard on resolveDispute's refund #ok arm — #Expired becomes #Refunded.
    await ledger.script(40, true);
    let reg = mk([("job-1", #Disputed, 0)]);
    let f = reg.resolveDispute("job-1", true);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Expired)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Expired;
  });
});

/// A registry with one EVM-paid job "job-1" whose transfer hook, on call number `resolveOn`,
/// resolves the job to `terminal` and then answers #pending (a broadcast left unconfirmed);
/// other calls answer #confirmed. The hook runs inside the payout's await, so this is the same
/// interleaving as a resolveJob landing while a real broadcast is in flight.
func mkEvm(status : Types.JobStatus, actualCost : ?Nat, resolveOn : Nat, terminal : Types.JobStatus) : ServiceRegistry.ServiceRegistry {
  let reg = mkUpto(status, actualCost);
  let s = reg.toStable();
  reg.loadStable({
    s with
    jobs = Array.map<(Text, Types.Job), (Text, Types.Job)>(s.jobs, func((id, j)) { (id, { j with buyer = "0x1111111111111111111111111111111111111111" }) });
    evmRails = ?[("job-1", { network = "eip155:8453"; token = "0x2222222222222222222222222222222222222222" })];
    operatorPayouts = ?[(operatorP, "0x3333333333333333333333333333333333333333")];
  });
  var calls = 0;
  reg.setEvmTransfer(func(_ : Nat, _ : Text, _ : Text, _ : Nat) : async { #confirmed : Text; #reverted : Text; #pending : Text; #err : Text } {
    calls += 1;
    if (calls == resolveOn) {
      switch (reg.resolveJob("job-1", terminal)) { case (#ok) {}; case (#err(_)) { assert false } };
      #pending("0xpending");
    } else { #confirmed("0xconfirmed") };
  });
  reg;
};

func parkedHash(reg : ServiceRegistry.ServiceRegistry) : ?Text {
  switch (reg.getJob("job-1")) { case (?j) { switch (j.parkedTx) { case (?p) { ?p.txHash }; case (null) { null } } }; case (null) { null } };
};

await suite("2.19.1 review: a pending broadcast after resolveJob is still recorded for reconcileJob", func() : async () {
  // The tx hash is the only handle reconcileJob has on a broadcast that may land, so it is kept
  // even though a controller resolved the job meanwhile (the job is re-parked, as before 2.19.1).

  await test("settle: the operator transfer is pending, the job is re-parked with its hash", func() : async () {
    // Mutation: return early on settleJob's #pending arm when the job is no longer #Settling —
    // the job stays #Refunded with no parked tx, and the hash is lost.
    let reg = mkEvm(#Disputed, null, 1, #Refunded);
    switch (await reg.resolveDispute("job-1", false)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Settling;
    assert parkedHash(reg) == ?"0xpending";
  });

  await test("settle (Upto): the remainder refund is pending, the job is #Settled and parked", func() : async () {
    // Mutation: as above, on the remainder #pending arm.
    let reg = mkEvm(#Disputed, ?100, 2, #Expired);
    switch (await reg.resolveDispute("job-1", false)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Settled;
    assert parkedHash(reg) == ?"0xpending";
  });

  await test("dispute refund: the refund is pending, the job is re-parked with its hash", func() : async () {
    // Mutation: as above, on resolveDispute's refund #pending arm.
    let reg = mkEvm(#Disputed, null, 1, #Expired);
    switch (await reg.resolveDispute("job-1", true)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Settling;
    assert parkedHash(reg) == ?"0xpending";
  });
});
