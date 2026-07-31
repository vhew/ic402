/// SELF-ARMING EXPIRY TIMERS — the cycle-cost defect fixed in 2.11.0.
///
/// A recurring timer is billed per TICK (the message-execution base fee), not per unit of work
/// done, so the two always-on 60s sweeps cost a canister ~2.8B cycles/hour whether or not it ever
/// opened a session or created a job — measured on mainnet by a consumer running one canister per
/// user (~23.6M cycles/tick × 120 ticks/hour). Guarding inside the callback saves nothing; the
/// timer itself has to stop.
///
/// TEST-ENVIRONMENT LIMIT — read before adding to this file. `mops test` CANNOT arm a timer:
/// the interpreter has no timer system API (`Value.prim: global_timer_set` → hard failure the
/// moment armExpiryTimer/startTimers is called), and `// @testmode wasi` is not an escape either
/// because -wasi-system-api rejects the async functions in Escrow.mo/Sessions.mo. So nothing here
/// may call armExpiryTimer, startTimers, or a setter that re-arms a LIVE timer. The same limit is
/// why no unit test can drive a successful openSession: it now arms the sweep.
///
/// What that leaves testable here — and it is the part where a bug would be silent: the pure
/// cadence decision (exhaustive), each module's work predicate against real state, and the fact
/// that configuration alone never arms anything. Covered elsewhere: the arm SITES by
/// scripts/check-expiry-arm-sites.sh (source gate, CI) and the live arm/disarm behaviour by the
/// replica-backed integration suite (health().timers).
import Utils "../src/ic402/Utils";
import Sessions "../src/ic402/Sessions";
import ServiceRegistry "../src/ic402/ServiceRegistry";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let ledgerP = Principal.fromText("2vxsx-fae");
let buyerP = Principal.fromText("2vxsx-fae");

let cfg : Types.Config = {
  recipient = { owner = canisterP; subaccount = null };
  tokens = [];
  evmChains = [];
  evmRpcCanister = null;
  ecdsaKeyName = null;
  nonceExpirySeconds = null;
};

func mkSessions() : Sessions.Sessions {
  Sessions.Sessions(
    canisterP,
    cfg,
    Policy.Engine(),
    Escrow.EscrowManager(canisterP),
    EvmEscrow.EvmEscrowManager(),
    null,
    { get = func() : ?Text { null } },
  );
};

func mkRegistry() : ServiceRegistry.ServiceRegistry {
  ServiceRegistry.ServiceRegistry(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = []; ledgerFee = 0 },
  );
};

func mkServiceDef() : Types.ServiceDefinition = {
  id = "";
  name = "Test Service";
  description = "A test service";
  serviceType = #Async;
  pricing = #Exact(1000);
  verification = #AutoSettle;
  delivery = #Poll;
  timeout = 300;
  operatorId = canisterP;
  enabled = false;
  createdAt = 0;
};

func mkReceipt(amount : Nat) : Types.PaymentReceipt = {
  id = "rcpt-1";
  amount;
  token = "ckUSDC";
  sender = Principal.toText(buyerP);
  recipient = Principal.toText(canisterP);
  network = "icp:1";
  timestamp = 0;
  txHash = null;
  sessionId = null;
  refunded = null;
};

// ── The pure decision the tick takes in its atomic tail ──

await suite("Utils.expiryCadence", func() : async () {

  await test("work present: resume the working cadence, or stay on it", func() : async () {
    // Already sweeping → nothing to change (idle-poll setting is irrelevant while work exists).
    assert Utils.expiryCadence(true, true, 0) == #stay;
    assert Utils.expiryCadence(true, true, 3600) == #stay;
    // The idle poll found work created by a path that could not arm the timer → speed back up.
    assert Utils.expiryCadence(true, false, 3600) == #switchToFast;
    assert Utils.expiryCadence(true, false, 0) == #switchToFast;
  });

  await test("no work: disarm outright only when no idle poll is configured", func() : async () {
    // Sessions' configuration (idlePoll = 0): the last session is gone → stop ticking entirely.
    assert Utils.expiryCadence(false, true, 0) == #disarm;
    assert Utils.expiryCadence(false, false, 0) == #disarm;
    // ServiceRegistry's configuration (idlePoll = 3600): drop to the slow poll, don't disarm —
    // its job-creating entry point is synchronous and so cannot arm the timer back.
    assert Utils.expiryCadence(false, true, 3600) == #switchToIdle;
    // Already idling with nothing to do → stay there (do NOT re-arm every tick).
    assert Utils.expiryCadence(false, false, 3600) == #stay;
  });

  await test("the decision never leaves work unattended", func() : async () {
    // Exhaustive over the whole input space that matters: whenever there is work, the outcome
    // must be a cadence that keeps sweeping — never #disarm, never #switchToIdle. This is the
    // dangerous direction (a missed sweep leaves deposits escrowed past their deadline); the
    // opposite direction only wastes cycles.
    for (fast in [true, false].vals()) {
      for (idle in [0, 1, 60, 3600].vals()) {
        let d = Utils.expiryCadence(true, fast, idle);
        assert d == #stay or d == #switchToFast;
      };
    };
  });
});

// ── Sessions: strict disarm (the module owns its arm sites) ──

await suite("Sessions expiry timer", func() : async () {

  await test("a fresh instance is unarmed and has nothing to sweep", func() : async () {
    let mgr = mkSessions();
    // The whole point: constructing the subsystem must not start a timer. Only a session-creating
    // path (or startTimers) may, and both are unreachable from here.
    assert not mgr.expiryTimerArmed();
    assert not mgr.hasExpiryWork();
  });

  await test("an empty session map makes the tick disarm (idle poll off by default)", func() : async () {
    let mgr = mkSessions();
    // This is what the callback's atomic tail evaluates, with the real predicate. Sessions leaves
    // idlePoll at 0 because both of its session-creating paths are async and arm the timer
    // themselves — nothing can create work behind the timer's back.
    assert Utils.expiryCadence(mgr.hasExpiryWork(), true, 0) == #disarm;
  });

  await test("configuration is validated, and never arms anything by itself", func() : async () {
    let mgr = mkSessions();
    assert mgr.setExpiryIntervalSeconds<system>(0) == #err("expiry interval must be at least 1 second");
    switch (mgr.setExpiryIntervalSeconds<system>(300)) { case (#ok) {}; case (#err(_)) { assert false } };
    switch (mgr.setExpiryIdlePollSeconds<system>(900)) { case (#ok) {}; case (#err(_)) { assert false } };
    // Configuring a cadence is not a reason to start burning cycles on a canister that has
    // nothing to sweep — the setters only re-arm a timer that is ALREADY running.
    assert not mgr.expiryTimerArmed();
  });

  await test("an opt-in idle poll turns the disarm into a poll", func() : async () {
    let mgr = mkSessions();
    switch (mgr.setExpiryIdlePollSeconds<system>(900)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert Utils.expiryCadence(mgr.hasExpiryWork(), true, 900) == #switchToIdle;
  });
});

// ── ServiceRegistry: idle poll (its job-creating entry point is synchronous) ──

await suite("ServiceRegistry expiry timer", func() : async () {

  await test("a fresh registry is unarmed and has nothing to sweep", func() : async () {
    let reg = mkRegistry();
    assert not reg.expiryTimerArmed();
    assert not reg.expiryTimerActive();
    assert not reg.hasExpiryWork();
  });

  await test("creating a job makes the sweep's predicate true", func() : async () {
    let reg = mkRegistry();
    let svcId = switch (reg.registerService(canisterP, mkServiceDef())) {
      case (#ok(id)) { id };
      case (#err(_)) { assert false; "" };
    };
    switch (reg.enableService(canisterP, svcId)) { case (#ok) {}; case (#err(_)) { assert false } };

    assert not reg.hasExpiryWork();
    switch (reg.submitRequest(Principal.toText(buyerP), svcId, Blob.fromArray([]), mkReceipt(1000), null)) {
      case (#ok(_)) {};
      case (#err(_)) { assert false };
    };
    assert reg.hasExpiryWork();

    // With a job present the tick must keep sweeping at the working cadence, whichever cadence
    // it is on — including the idle poll, which is how a job created by a caller that did not
    // call armExpiryTimer gets picked up.
    assert Utils.expiryCadence(reg.hasExpiryWork(), true, 3600) == #stay;
    assert Utils.expiryCadence(reg.hasExpiryWork(), false, 3600) == #switchToFast;
  });

  await test("with no jobs the tick drops to the idle poll rather than disarming", func() : async () {
    let reg = mkRegistry();
    // Default idle poll = 3600 (one tick/hour): the safety net for jobs created through the
    // synchronous createJobFromReceipt, which cannot arm a timer.
    assert Utils.expiryCadence(reg.hasExpiryWork(), true, 3600) == #switchToIdle;
    // Opting out (0) is only safe when every job-creating call site arms the timer itself.
    switch (reg.setExpiryIdlePollSeconds<system>(0)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert Utils.expiryCadence(reg.hasExpiryWork(), true, 0) == #disarm;
  });

  await test("interval is validated", func() : async () {
    let reg = mkRegistry();
    assert reg.setExpiryIntervalSeconds<system>(0) == #err("expiry interval must be at least 1 second");
    switch (reg.setExpiryIntervalSeconds<system>(120)) { case (#ok) {}; case (#err(_)) { assert false } };
    assert not reg.expiryTimerArmed();
  });
});
