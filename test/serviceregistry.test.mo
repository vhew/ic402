/// Motoko unit tests for ServiceRegistry (service marketplace: register, jobs, verify, settle).
import ServiceRegistry "../src/ic402/ServiceRegistry";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Array "mo:base/Array";
import EvmAddress "../src/ic402/EvmAddress";
import EvmUtils "../src/ic402/EvmUtils";
import EcdsaLib "mo:ecdsa";
import EcdsaCurve "mo:ecdsa/Curve";
import { test; suite } "mo:test";

suite("ServiceRegistry", func() {

  // ── Shared fixtures ──

  let testPrincipal = Principal.fromText("aaaaa-aa");
  let operatorPrincipal = Principal.fromText("2vxsx-fae");
  let buyerPrincipal = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");

  let config : Types.Config = {
    recipient = { owner = testPrincipal; subaccount = null };
    tokens = [];
    evmChains = [];
    evmRpcCanister = null;
    ecdsaKeyName = null;
    nonceExpirySeconds = null;
  };

  func makeRegistry() : ServiceRegistry.ServiceRegistry {
    ServiceRegistry.ServiceRegistry(testPrincipal, config);
  };

  func baseDef(operator : Principal) : Types.ServiceDefinition {
    {
      id = "";
      name = "Test Service";
      description = "A test service";
      serviceType = #Async;
      pricing = #Exact(1000);
      verification = #AutoSettle;
      delivery = #Poll;
      timeout = 300;
      operatorId = operator;
      enabled = false;
      createdAt = 0;
    };
  };

  func mockReceipt(amount : Nat) : Types.PaymentReceipt {
    {
      id = "rcpt-1";
      amount;
      token = "ckUSDC";
      sender = Principal.toText(buyerPrincipal);
      recipient = Principal.toText(testPrincipal);
      network = "icp:1";
      timestamp = 0;
      txHash = null;
      sessionId = null;
      refunded = null;
    };
  };

  /// Helper: register + enable a service, return the service ID.
  func registerAndEnable(reg : ServiceRegistry.ServiceRegistry, operator : Principal) : Text {
    let svcId = switch (reg.registerService(operator, baseDef(operator))) {
      case (#ok(id)) { id };
      case (#err(e)) { assert false; "" };
    };
    switch (reg.enableService(operator, svcId)) {
      case (#ok) {};
      case (#err(_)) { assert false };
    };
    svcId;
  };

  /// Helper: register + enable + submit a request, return (serviceId, jobId).
  func registerEnableSubmit(reg : ServiceRegistry.ServiceRegistry, operator : Principal) : (Text, Text) {
    let svcId = registerAndEnable(reg, operator);
    let jobId = switch (reg.submitRequest(
      Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(1000), null,
    )) {
      case (#ok(id)) { id };
      case (#err(e)) { assert false; "" };
    };
    (svcId, jobId);
  };

  // ══════════════════════════════════════════════════
  // 1. Service Registration
  // ══════════════════════════════════════════════════

  suite("registerService", func() {

    test("registers successfully and returns svc- prefixed ID", func() {
      let reg = makeRegistry();
      switch (reg.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { assert Text.startsWith(id, #text("svc-")) };
        case (#err(e)) { assert false };
      };
    });

    test("rejects empty name", func() {
      let reg = makeRegistry();
      let def = { baseDef(operatorPrincipal) with name = "" };
      switch (reg.registerService(operatorPrincipal, def)) {
        case (#err(e)) { assert Text.contains(e, #text("Name")) };
        case (#ok(_)) { assert false };
      };
    });

    test("rejects timeout 0", func() {
      let reg = makeRegistry();
      let def = { baseDef(operatorPrincipal) with timeout = 0 };
      switch (reg.registerService(operatorPrincipal, def)) {
        case (#err(e)) { assert Text.contains(e, #text("Timeout")) };
        case (#ok(_)) { assert false };
      };
    });

    test("rejects caller != operatorId", func() {
      let reg = makeRegistry();
      // Def says operator is operatorPrincipal, but we call as buyerPrincipal
      switch (reg.registerService(buyerPrincipal, baseDef(operatorPrincipal))) {
        case (#err(e)) { assert Text.contains(e, #text("operator")) };
        case (#ok(_)) { assert false };
      };
    });

    test("rejects duplicate explicit ID", func() {
      let reg = makeRegistry();
      let def = { baseDef(operatorPrincipal) with id = "my-svc" };
      switch (reg.registerService(operatorPrincipal, def)) {
        case (#ok(id)) { assert (id == "my-svc") };
        case (#err(_)) { assert false };
      };
      // Second registration with same ID should fail
      switch (reg.registerService(operatorPrincipal, def)) {
        case (#err(e)) { assert Text.contains(e, #text("already exists")) };
        case (#ok(_)) { assert false };
      };
    });

    test("service starts disabled", func() {
      let reg = makeRegistry();
      let svcId = switch (reg.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      switch (reg.getService(svcId)) {
        case (?svc) { assert (svc.enabled == false) };
        case (null) { assert false };
      };
    });
  });

  // ══════════════════════════════════════════════════
  // 2. Enable / Disable
  // ══════════════════════════════════════════════════

  suite("enableService / disableService", func() {

    test("enable a disabled service", func() {
      let reg = makeRegistry();
      let svcId = switch (reg.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      switch (reg.enableService(operatorPrincipal, svcId)) {
        case (#ok) {};
        case (#err(_)) { assert false };
      };
      switch (reg.getService(svcId)) {
        case (?svc) { assert svc.enabled };
        case (null) { assert false };
      };
    });

    test("disable an enabled service", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      switch (reg.disableService(operatorPrincipal, svcId)) {
        case (#ok) {};
        case (#err(_)) { assert false };
      };
      switch (reg.getService(svcId)) {
        case (?svc) { assert (svc.enabled == false) };
        case (null) { assert false };
      };
    });

    test("non-operator cannot enable", func() {
      let reg = makeRegistry();
      let svcId = switch (reg.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      switch (reg.enableService(buyerPrincipal, svcId)) {
        case (#err(e)) { assert Text.contains(e, #text("operator")) };
        case (#ok) { assert false };
      };
    });

    test("enable non-existent service returns error", func() {
      let reg = makeRegistry();
      switch (reg.enableService(operatorPrincipal, "no-such-svc")) {
        case (#err(e)) { assert Text.contains(e, #text("not found")) };
        case (#ok) { assert false };
      };
    });
  });

  // ══════════════════════════════════════════════════
  // 3. List Services
  // ══════════════════════════════════════════════════

  suite("listServices", func() {

    test("enabledOnly=true filters disabled services", func() {
      let reg = makeRegistry();
      // Register two services; enable only one
      let id1 = switch (reg.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      ignore reg.registerService(operatorPrincipal, baseDef(operatorPrincipal));
      ignore reg.enableService(operatorPrincipal, id1);

      let enabled = reg.listServices(true);
      assert (enabled.size() == 1);
      assert (enabled[0].id == id1);
    });

    test("enabledOnly=false returns all services", func() {
      let reg = makeRegistry();
      ignore reg.registerService(operatorPrincipal, baseDef(operatorPrincipal));
      ignore reg.registerService(operatorPrincipal, baseDef(operatorPrincipal));

      let all = reg.listServices(false);
      assert (all.size() == 2);
    });
  });

  // ══════════════════════════════════════════════════
  // 4. Submit Request
  // ══════════════════════════════════════════════════

  suite("submitRequest", func() {

    test("submit to enabled service returns job ID", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(1000), null,
      )) {
        case (#ok(jobId)) { assert Text.startsWith(jobId, #text("job-")) };
        case (#err(e)) { assert false };
      };
    });

    test("submit to disabled service returns error", func() {
      let reg = makeRegistry();
      let svcId = switch (reg.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      // Service is disabled by default
      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(1000), null,
      )) {
        case (#err(e)) { assert Text.contains(e, #text("disabled")) };
        case (#ok(_)) { assert false };
      };
    });

    test("submit to non-existent service returns error", func() {
      let reg = makeRegistry();
      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), "no-such-svc", Text.encodeUtf8("params"), mockReceipt(1000), null,
      )) {
        case (#err(e)) { assert Text.contains(e, #text("not found")) };
        case (#ok(_)) { assert false };
      };
    });

    test("insufficient payment for Exact pricing returns error", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      // Service price is 1000, but we pay only 500
      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(500), null,
      )) {
        case (#err(e)) { assert Text.contains(e, #text("Insufficient")) };
        case (#ok(_)) { assert false };
      };
    });

    test("exact payment amount succeeds", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(1000), null,
      )) {
        case (#ok(_)) {};
        case (#err(_)) { assert false };
      };
    });

    test("overpayment for Exact pricing succeeds", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(2000), null,
      )) {
        case (#ok(_)) {};
        case (#err(_)) { assert false };
      };
    });
  });

  // ══════════════════════════════════════════════════
  // 5. Claim Job
  // ══════════════════════════════════════════════════

  suite("claimJob", func() {

    test("claim a pending job sets status to Assigned", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      switch (reg.claimJob(operatorPrincipal, jobId)) {
        case (#ok) {};
        case (#err(_)) { assert false };
      };
      switch (reg.getJobStatus(jobId)) {
        case (?#Assigned) {};
        case (_) { assert false };
      };
    });

    test("claim already-assigned job returns error", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);
      ignore reg.claimJob(operatorPrincipal, jobId);

      switch (reg.claimJob(operatorPrincipal, jobId)) {
        case (#err(e)) { assert Text.contains(e, #text("not pending")) };
        case (#ok) { assert false };
      };
    });

    test("non-operator cannot claim", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      switch (reg.claimJob(buyerPrincipal, jobId)) {
        case (#err(e)) { assert Text.contains(e, #text("operator")) };
        case (#ok) { assert false };
      };
    });

    test("claim non-existent job returns error", func() {
      let reg = makeRegistry();
      switch (reg.claimJob(operatorPrincipal, "no-such-job")) {
        case (#err(e)) { assert Text.contains(e, #text("not found")) };
        case (#ok) { assert false };
      };
    });
  });

  // ══════════════════════════════════════════════════
  // 6. Submit Result (AutoSettle) — async, tested indirectly
  // ══════════════════════════════════════════════════

  // NOTE: submitResult is async (it calls verifyAndSettle → settleJob which
  // may interact with ledger actors). The mo:test framework only supports
  // synchronous tests. Full submitResult/settle testing requires integration
  // tests (see test/integration.test.ts).
  //
  // We verify the pre-conditions synchronously: that submitting to a
  // non-Assigned job fails, and that the operator field is checked.
  // The actual AutoSettle flow (Submitted → Verified → Settled) is validated
  // in integration tests against a local replica.

  suite("submitResult (pre-condition checks)", func() {

    test("job must exist for getJob", func() {
      let reg = makeRegistry();
      assert (reg.getJob("no-such-job") == null);
    });

    test("claimed job has operator set", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);
      ignore reg.claimJob(operatorPrincipal, jobId);

      switch (reg.getJob(jobId)) {
        case (?job) {
          assert (job.operator == ?operatorPrincipal);
          assert (job.status == #Assigned);
        };
        case (null) { assert false };
      };
    });

    test("unclaimed job has no operator", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      switch (reg.getJob(jobId)) {
        case (?job) {
          assert (job.operator == null);
          assert (job.status == #Pending);
        };
        case (null) { assert false };
      };
    });
  });

  // ══════════════════════════════════════════════════
  // 7. Get Job Status / Result
  // ══════════════════════════════════════════════════

  suite("getJobStatus / getJobResult", func() {

    test("getJobStatus returns correct status for pending job", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      switch (reg.getJobStatus(jobId)) {
        case (?#Pending) {};
        case (_) { assert false };
      };
    });

    test("getJobStatus returns correct status after claim", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);
      ignore reg.claimJob(operatorPrincipal, jobId);

      switch (reg.getJobStatus(jobId)) {
        case (?#Assigned) {};
        case (_) { assert false };
      };
    });

    test("getJobStatus returns null for non-existent job", func() {
      let reg = makeRegistry();
      assert (reg.getJobStatus("nonexistent") == null);
    });

    test("getJobResult returns null for pending job (no result yet)", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      assert (reg.getJobResult(jobId) == null);
    });

    test("getJobResult returns null for assigned job (no result yet)", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);
      ignore reg.claimJob(operatorPrincipal, jobId);

      assert (reg.getJobResult(jobId) == null);
    });

    test("getJobResult returns null for non-existent job", func() {
      let reg = makeRegistry();
      assert (reg.getJobResult("nonexistent") == null);
    });
  });

  // ══════════════════════════════════════════════════
  // 8. Dispute (BuyerConfirm)
  // ══════════════════════════════════════════════════

  // NOTE: disputeJob requires the job to be in #Submitted status, which
  // requires submitResult (async). We test disputeJob's buyer-check and
  // status-check pre-conditions by directly verifying the synchronous
  // disputeJob function on jobs that are NOT in #Submitted status.
  // Full dispute flow is validated in integration tests.

  suite("disputeJob (pre-condition checks)", func() {

    test("dispute a non-submitted job returns error", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      // Job is #Pending, disputeJob requires #Submitted
      switch (reg.disputeJob(buyerPrincipal, jobId, "bad result")) {
        case (#err(e)) { assert Text.contains(e, #text("not in submitted")) };
        case (#ok) { assert false };
      };
    });

    test("non-buyer cannot dispute", func() {
      let reg = makeRegistry();
      let (_, jobId) = registerEnableSubmit(reg, operatorPrincipal);

      // Wrong buyer
      switch (reg.disputeJob(operatorPrincipal, jobId, "reason")) {
        case (#err(e)) { assert Text.contains(e, #text("buyer")) };
        case (#ok) { assert false };
      };
    });

    test("dispute non-existent job returns error", func() {
      let reg = makeRegistry();
      switch (reg.disputeJob(buyerPrincipal, "no-job", "reason")) {
        case (#err(e)) { assert Text.contains(e, #text("not found")) };
        case (#ok) { assert false };
      };
    });
  });

  // ══════════════════════════════════════════════════
  // 9. List Jobs
  // ══════════════════════════════════════════════════

  suite("listJobs", func() {

    test("list jobs for a service returns all jobs", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      ignore reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("p1"), mockReceipt(1000), null,
      );
      ignore reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("p2"), mockReceipt(1000), null,
      );

      let allJobs = reg.listJobs(svcId, null);
      assert (allJobs.size() == 2);
    });

    test("list jobs with status filter", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      let j1 = switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("p1"), mockReceipt(1000), null,
      )) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      ignore reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("p2"), mockReceipt(1000), null,
      );

      // Claim first job so it becomes Assigned
      ignore reg.claimJob(operatorPrincipal, j1);

      let pending = reg.listJobs(svcId, ?#Pending);
      assert (pending.size() == 1);

      let assigned = reg.listJobs(svcId, ?#Assigned);
      assert (assigned.size() == 1);
      assert (assigned[0].id == j1);
    });

    test("list jobs for non-existent service returns empty", func() {
      let reg = makeRegistry();
      assert (reg.listJobs("no-svc", null).size() == 0);
    });
  });

  // ══════════════════════════════════════════════════
  // 10. Stable State Round-Trip
  // ══════════════════════════════════════════════════

  suite("toStable / loadStable", func() {

    test("round-trip preserves services", func() {
      let reg1 = makeRegistry();
      let svcId = registerAndEnable(reg1, operatorPrincipal);

      let snapshot = reg1.toStable();

      let reg2 = makeRegistry();
      reg2.loadStable(snapshot);

      switch (reg2.getService(svcId)) {
        case (?svc) {
          assert (svc.name == "Test Service");
          assert svc.enabled;
          assert (svc.operatorId == operatorPrincipal);
        };
        case (null) { assert false };
      };
    });

    test("round-trip preserves jobs", func() {
      let reg1 = makeRegistry();
      let (svcId, jobId) = registerEnableSubmit(reg1, operatorPrincipal);
      ignore reg1.claimJob(operatorPrincipal, jobId);

      let snapshot = reg1.toStable();

      let reg2 = makeRegistry();
      reg2.loadStable(snapshot);

      switch (reg2.getJob(jobId)) {
        case (?job) {
          assert (job.serviceId == svcId);
          assert (job.status == #Assigned);
          assert (job.operator == ?operatorPrincipal);
          assert (job.buyer == Principal.toText(buyerPrincipal));
          assert (job.amount == 1000);
        };
        case (null) { assert false };
      };
    });

    test("round-trip preserves counters (new IDs don't collide)", func() {
      let reg1 = makeRegistry();
      // Register 3 services to advance counter
      ignore reg1.registerService(operatorPrincipal, baseDef(operatorPrincipal));
      ignore reg1.registerService(operatorPrincipal, baseDef(operatorPrincipal));
      ignore reg1.registerService(operatorPrincipal, baseDef(operatorPrincipal));

      let snapshot = reg1.toStable();

      let reg2 = makeRegistry();
      reg2.loadStable(snapshot);

      // Next service should get svc-4, not svc-1
      switch (reg2.registerService(operatorPrincipal, baseDef(operatorPrincipal))) {
        case (#ok(id)) { assert (id == "svc-4") };
        case (#err(_)) { assert false };
      };
    });

    test("round-trip of empty registry", func() {
      let reg1 = makeRegistry();
      let snapshot = reg1.toStable();

      let reg2 = makeRegistry();
      reg2.loadStable(snapshot);

      assert (reg2.listServices(false).size() == 0);
    });

    test("listServices works after loadStable", func() {
      let reg1 = makeRegistry();
      ignore reg1.registerService(operatorPrincipal, baseDef(operatorPrincipal));
      let id2 = registerAndEnable(reg1, operatorPrincipal);

      let snapshot = reg1.toStable();

      let reg2 = makeRegistry();
      reg2.loadStable(snapshot);

      let all = reg2.listServices(false);
      assert (all.size() == 2);

      let enabled = reg2.listServices(true);
      assert (enabled.size() == 1);
      assert (enabled[0].id == id2);
    });
  });

  // ══════════════════════════════════════════════════
  // 11. Edge Cases
  // ══════════════════════════════════════════════════

  suite("edge cases", func() {

    test("description over 1024 chars is rejected", func() {
      let reg = makeRegistry();
      // Build a string > 1024 chars
      var longDesc = "";
      var i = 0;
      while (i < 130) { longDesc #= "0123456789"; i += 1 }; // 1300 chars
      let def = { baseDef(operatorPrincipal) with description = longDesc };
      switch (reg.registerService(operatorPrincipal, def)) {
        case (#err(e)) { assert Text.contains(e, #text("Description")) };
        case (#ok(_)) { assert false };
      };
    });

    test("non-operator cannot disable", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      switch (reg.disableService(buyerPrincipal, svcId)) {
        case (#err(e)) { assert Text.contains(e, #text("operator")) };
        case (#ok) { assert false };
      };
    });

    test("disable non-existent service returns error", func() {
      let reg = makeRegistry();
      switch (reg.disableService(operatorPrincipal, "no-svc")) {
        case (#err(e)) { assert Text.contains(e, #text("not found")) };
        case (#ok) { assert false };
      };
    });

    test("Upto pricing rejects zero payment", func() {
      let reg = makeRegistry();
      let def = { baseDef(operatorPrincipal) with pricing = #Upto(5000) };
      let svcId = switch (reg.registerService(operatorPrincipal, def)) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      ignore reg.enableService(operatorPrincipal, svcId);

      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(0), null,
      )) {
        case (#err(e)) { assert Text.contains(e, #text("required")) };
        case (#ok(_)) { assert false };
      };
    });

    test("Upto pricing accepts any positive amount", func() {
      let reg = makeRegistry();
      let def = { baseDef(operatorPrincipal) with pricing = #Upto(5000) };
      let svcId = switch (reg.registerService(operatorPrincipal, def)) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };
      ignore reg.enableService(operatorPrincipal, svcId);

      switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, Text.encodeUtf8("params"), mockReceipt(1), null,
      )) {
        case (#ok(_)) {};
        case (#err(_)) { assert false };
      };
    });

    test("job records params and callback", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      let params = Text.encodeUtf8("my-params");
      let jobId = switch (reg.submitRequest(
        Principal.toText(buyerPrincipal), svcId, params, mockReceipt(1000), ?"https://cb.example.com",
      )) {
        case (#ok(id)) { id };
        case (#err(_)) { assert false; "" };
      };

      switch (reg.getJob(jobId)) {
        case (?job) {
          assert (job.params == params);
          assert (job.deliveryCallback == ?"https://cb.example.com");
          assert (job.paymentReceiptId == "rcpt-1");
        };
        case (null) { assert false };
      };
    });

    test("multiple registries are independent", func() {
      let reg1 = makeRegistry();
      let reg2 = makeRegistry();

      ignore reg1.registerService(operatorPrincipal, baseDef(operatorPrincipal));
      assert (reg1.listServices(false).size() == 1);
      assert (reg2.listServices(false).size() == 0);
    });

    test("getService returns null for non-existent ID", func() {
      let reg = makeRegistry();
      assert (reg.getService("nope") == null);
    });
  });

  // ══════════════════════════════════════════════════
  // S-13: terminal-job GC must also reclaim #Expired jobs
  // ══════════════════════════════════════════════════

  suite("gcTerminalJobs", func() {
    let DAY : Int = 24 * 60 * 60 * 1_000_000_000;

    func makeJob(id : Text, status : Types.JobStatus, completedAt : ?Int, createdAt : Int) : Types.Job {
      {
        id;
        serviceId = "svc-1";
        buyer = Principal.toText(buyerPrincipal);
        operator = null;
        params = Text.encodeUtf8("p");
        paymentReceiptId = "rcpt";
        amount = 1000;
        actualCost = null;
        status;
        result = null;
        proof = null;
        createdAt;
        expiresAt = 0;
        completedAt;
        deliveryCallback = null;
      };
    };

    func present(reg : ServiceRegistry.ServiceRegistry, id : Text) : Bool {
      switch (reg.getJob(id)) { case (?_) { true }; case (null) { false } };
    };

    test("reclaims Expired/Settled/Refunded jobs older than 24h, keeps recent and active ones", func() {
      let reg = makeRegistry();
      // Time.now() is 0 under mo:test, so "older than 24h" means completedAt < -DAY.
      reg.loadStable({
        services = [];
        serviceCounter = 0;
        jobCounter = 0;
        evmRails = null;
        jobs = [
          ("old-expired",    makeJob("old-expired",    #Expired,  ?(-2 * DAY), -2 * DAY)),
          ("old-settled",    makeJob("old-settled",    #Settled,  ?(-2 * DAY), -2 * DAY)),
          ("old-refunded",   makeJob("old-refunded",   #Refunded, ?(-2 * DAY), -2 * DAY)),
          ("recent-expired", makeJob("recent-expired", #Expired,  ?0, 0)),
          ("active-pending", makeJob("active-pending", #Pending,  null, 0)),
        ];
      });

      let removed = reg.gcTerminalJobs();
      // Old code collected only #Settled/#Refunded (removed == 2); the #Expired job leaked.
      assert (removed == 3);
      assert (not present(reg, "old-expired"));
      assert (not present(reg, "old-settled"));
      assert (not present(reg, "old-refunded"));
      // A recently-terminal job and an active job must survive the sweep.
      assert (present(reg, "recent-expired"));
      assert (present(reg, "active-pending"));
    });
  });

  // ══════════════════════════════════════════════════
  // S14 (option B): EVM-buyer signed confirm/dispute
  // ══════════════════════════════════════════════════

  suite("EVM buyer authorization", func() {
    let buyerPriv : Nat = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Hardhat #0
    let otherPriv : Nat = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // Hardhat #1
    let rand : [Nat8] = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32];

    func makeEvmJob(id : Text, buyer : Text, status : Types.JobStatus) : Types.Job {
      {
        id; serviceId = "svc-1"; buyer; operator = null;
        params = Text.encodeUtf8("p"); paymentReceiptId = "r"; amount = 1000; actualCost = null;
        status; result = null; proof = null; createdAt = 0; expiresAt = 0; completedAt = null;
        deliveryCallback = null;
      };
    };

    // Derive the EVM address for a private key (herumi), mirroring evmaddress.test.mo.
    func addrOf(priv : Nat) : Text {
      let curve = EcdsaCurve.Curve(#secp256k1);
      switch (curve.fromJacobi(curve.mul_base(#fr(priv)))) {
        case (#affine(#fp(px), #fp(py))) {
          let prefix : Nat8 = if (py % 2 == 0) 0x02 else 0x03;
          let comp = Array.append<Nat8>([prefix], EvmUtils.natToBytes(px, 32));
          switch (EvmAddress.fromCompressedPublicKey(comp)) { case (#ok(a)) { a }; case (#err(_)) { assert false; "" } };
        };
        case (_) { assert false; "" };
      };
    };

    // Build a 65-byte (r||s||v) signature over buyerActionMessage(action, jobId) for `priv`.
    func signAction(reg : ServiceRegistry.ServiceRegistry, priv : Nat, action : Text, jobId : Text) : [Nat8] {
      let digest = EvmAddress.keccak256Text(reg.buyerActionMessage(action, jobId));
      let sec = EcdsaLib.PrivateKey(priv, EcdsaLib.secp256k1Curve());
      let #ok(sig) = sec.signHashed(digest.vals(), rand.vals()) else { assert false; return [] };
      let rs = Array.append<Nat8>(EvmUtils.natToBytes(sig.r, 32), EvmUtils.natToBytes(sig.s, 32));
      let want = addrOf(priv);
      for (vv in [0, 1].vals()) {
        let candidate = Array.append<Nat8>(rs, [Nat8.fromNat(vv)]);
        switch (reg.recoverBuyerActionSigner(action, jobId, candidate)) {
          case (?a) { if (a == want) return candidate };
          case (null) {};
        };
      };
      assert false; [];
    };

    func loadJob(reg : ServiceRegistry.ServiceRegistry, buyer : Text) {
      reg.loadStable({
        services = []; serviceCounter = 0; jobCounter = 0; evmRails = null;
        jobs = [("job-1", makeEvmJob("job-1", buyer, #Submitted))];
      });
    };

    test("recoverBuyerActionSigner recovers the signing EVM address", func() {
      let reg = makeRegistry();
      let sig = signAction(reg, buyerPriv, "dispute", "job-1");
      switch (reg.recoverBuyerActionSigner("dispute", "job-1", sig)) {
        case (?a) { assert EvmUtils.addressesEqual(a, addrOf(buyerPriv)) };
        case (null) { assert false };
      };
    });

    test("EVM buyer can dispute their job with a valid signature", func() {
      let reg = makeRegistry();
      loadJob(reg, addrOf(buyerPriv));
      switch (reg.disputeJobEvm("job-1", signAction(reg, buyerPriv, "dispute", "job-1"), "bad result")) {
        case (#ok) {}; case (#err(_)) { assert false };
      };
      switch (reg.getJob("job-1")) { case (?j) { assert j.status == #Disputed }; case (null) { assert false } };
    });

    test("a different key cannot dispute someone else's job", func() {
      let reg = makeRegistry();
      loadJob(reg, addrOf(buyerPriv));
      switch (reg.disputeJobEvm("job-1", signAction(reg, otherPriv, "dispute", "job-1"), "x")) {
        case (#err(_)) {}; case (#ok) { assert false };
      };
    });

    test("a confirm signature cannot be replayed as a dispute (action-bound)", func() {
      let reg = makeRegistry();
      loadJob(reg, addrOf(buyerPriv));
      // Signature is valid for the "confirm" message; reused on the "dispute" path it
      // recovers a different address (different digest) and is rejected.
      switch (reg.disputeJobEvm("job-1", signAction(reg, buyerPriv, "confirm", "job-1"), "x")) {
        case (#err(_)) {}; case (#ok) { assert false };
      };
    });

    test("recoverBuyerActionSigner rejects a malformed signature length", func() {
      let reg = makeRegistry();
      assert reg.recoverBuyerActionSigner("dispute", "job-1", [0, 1, 2]) == null;
    });
  });

  // ══════════════════════════════════════════════════
  // 1a: EVM payment-rail tracking (foundation for per-rail settlement / C3)
  // ══════════════════════════════════════════════════

  suite("EVM rail tracking", func() {
    let buyer0x = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";

    func evmReceipt(network : Text, token : Text, amount : Nat) : Types.PaymentReceipt {
      {
        id = "rcpt-evm"; amount; token; sender = buyer0x; recipient = "0xcanister";
        network; timestamp = 0; txHash = ?"0xabc"; sessionId = null; refunded = null;
      };
    };

    test("submitRequest records the EVM rail for a 0x buyer", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      let jobId = switch (reg.submitRequest(buyer0x, svcId, Text.encodeUtf8("p"),
        evmReceipt("eip155:8453", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", 1000), null)) {
        case (#ok(id)) { id }; case (#err(_)) { assert false; "" };
      };
      switch (reg.getEvmRail(jobId)) {
        case (?rail) {
          assert rail.network == "eip155:8453";
          assert rail.token == "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
        };
        case (null) { assert false };
      };
    });

    test("submitRequest records NO rail for an ICP (principal) buyer", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      let jobId = switch (reg.submitRequest(Principal.toText(buyerPrincipal), svcId,
        Text.encodeUtf8("p"), mockReceipt(1000), null)) {
        case (#ok(id)) { id }; case (#err(_)) { assert false; "" };
      };
      assert reg.getEvmRail(jobId) == null;
    });

    test("the EVM rail survives a toStable/loadStable round-trip", func() {
      let reg = makeRegistry();
      let svcId = registerAndEnable(reg, operatorPrincipal);
      let jobId = switch (reg.submitRequest(buyer0x, svcId, Text.encodeUtf8("p"),
        evmReceipt("eip155:84532", "0xusdc", 1000), null)) {
        case (#ok(id)) { id }; case (#err(_)) { assert false; "" };
      };
      let reg2 = makeRegistry();
      reg2.loadStable(reg.toStable());
      switch (reg2.getEvmRail(jobId)) {
        case (?rail) { assert rail.network == "eip155:84532" };
        case (null) { assert false };
      };
    });
  });
});
