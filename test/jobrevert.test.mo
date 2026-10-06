/// 2.17.6 — a failed in-flight transfer must not undo a controller's resolveJob.
///
/// resolveDispute (refund) and settleJob (operator payment) put a job in #Settling, await the
/// ledger, and on #Err revert it to its prior status for retry. resolveJob accepts any #Settling
/// job, so a controller can make it terminal DURING that await. The revert used to restore the
/// pre-await snapshot regardless, bringing a resolved job back as #Submitted/#Disputed (refundable,
/// or from #Submitted confirmable and settleable, a second time) or #Verified (stuck unfinished:
/// nothing re-drives it). It now reverts only a job still #Settling. Each race test resolves the job
/// to a terminal its own arm's success path would NOT write, so a guard narrowed to one terminal
/// (`!= #Refunded`, `!= #Settled`) still goes red.
///
/// The fake ledger is an in-file `persistent actor` (as in test/closeledger.test.mo): it parks
/// each icrc1_transfer for `hops` yields, so the test can call resolveJob while the transfer is
/// in flight, then answers #Err. Each test names the mutation that turns it red.
import ServiceRegistry "../src/ic402/ServiceRegistry";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let buyerP = Principal.fromText("2vxsx-fae");
let operatorP = Principal.fromText("aaaaa-aa");

let ledger = persistent actor {
  var hops = 0; var transfers = 0;
  public func script(h : Nat) : async () { hops := h; transfers := 0 };
  public func transferCalls() : async Nat { transfers };
  public func icrc1_transfer(_ : Types.TransferArg) : async Types.TransferResult {
    transfers += 1;
    var i = 0; while (i < hops) { await async {}; i += 1 };
    #Err(#TemporarilyUnavailable);
  };
};

/// A registry holding one #Disputed ICP job (buyer and operator principals, no EVM rail).
func mk() : ServiceRegistry.ServiceRegistry {
  let reg = ServiceRegistry.ServiceRegistry(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = Principal.fromActor(ledger); symbol = "TKN"; decimals = 6 }]; ledgerFee = 10 },
  );
  reg.loadStable({
    services = []; serviceCounter = 0; jobCounter = 1; evmRails = null; operatorPayouts = null;
    jobs = [("job-1", {
      id = "job-1"; serviceId = "svc-1"; buyer = Principal.toText(buyerP); operator = ?operatorP;
      params = Blob.fromArray([]); paymentReceiptId = "rcpt-1"; amount = 1_000; actualCost = null;
      status = #Disputed; result = null; proof = null; createdAt = 0; expiresAt = 0; completedAt = null;
      deliveryCallback = null; parkedTx = null;
    })];
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
    await ledger.script(40);
    let reg = mk();
    let f = reg.resolveDispute("job-1", true);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Expired)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Expired;
    assert not reg.hasExpiryWork();
  });

  await test("settle: resolveJob lands mid-transfer, the payment fails, the job stays terminal", func() : async () {
    // Mutation: drop the still-#Settling guard on settleJob's #err arm — the job comes back
    // #Verified and is stuck there unfinished.
    await ledger.script(40);
    let reg = mk();
    let f = reg.resolveDispute("job-1", false);
    await untilTransferring(reg);
    switch (reg.resolveJob("job-1", #Refunded)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (await f) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Refunded;
    assert not reg.hasExpiryWork();
  });

  await test("refund: with no resolveJob, a failed refund still reverts for retry", func() : async () {
    // Mutation: never revert (or invert the guard) — the job would rest in #Settling.
    await ledger.script(0);
    let reg = mk();
    switch (await reg.resolveDispute("job-1", true)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Disputed;
  });

  await test("settle: with no resolveJob, a failed payment still rolls back to #Verified", func() : async () {
    // Mutation: as above, on settleJob's arm.
    await ledger.script(0);
    let reg = mk();
    switch (await reg.resolveDispute("job-1", false)) { case (#err(_)) {}; case (#ok) { assert false } };
    assert status(reg) == ?#Verified;
  });
});
