/// 2.22.0 session guards that need no ledger:
///   - S6: a client idleTimeout may only shorten the operator's policy (effectiveIdleTimeout);
///   - S7: an ICP deposit parked at open counts against maxConcurrentSessions;
///   - S8: openSession refuses an intent token that does not resolve (no tokens[0] fallback);
///   - E8: reconcileSession and forceResolveSession refuse while an EVM close is in flight.
///
/// openSession cannot run to a successful open here (it arms the expiry sweep, and the interpreter
/// has no timer API — see test/expirytimer.test.mo), so the open tests stop at a refusal, and S6's
/// wiring into the two opens is covered by review; the helper itself is tested. Sessions are seeded
/// with loadStable, which arms nothing. Each test names the mutation that turns it red.
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import EvmSender "../src/ic402/EvmSender";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Time "mo:base/Time";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");
let ledgerP = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"); // configured, never called here

func mk(policy : Policy.Engine, sender : ?EvmSender.EvmSender) : Sessions.Sessions {
  Sessions.Sessions(
    canisterP,
    { recipient = { owner = canisterP; subaccount = null }; tokens = [{ ledger = ledgerP; symbol = "TKN"; decimals = 8 }]; evmChains = []; evmRpcCanister = null; ecdsaKeyName = null; nonceExpirySeconds = null },
    policy, Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(), sender, { get = func() : ?Text { null } },
  );
};

func stableSession(status : Types.SessionStatus, consumed : Nat, network : Text) : Types.StableSession = {
  id = "sess-1"; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed;
  remaining = 50_000 - consumed; voucherCount = 0; status; openedAt = 0; lastActivityAt = 0;
  lastSequence = 0; lastCumulativeAmount = consumed; subaccount = Blob.fromArray([]); network;
  token = Principal.toText(ledgerP); recipient = Principal.toText(canisterP); autoClose = false;
  maxDuration = null; idleTimeout = null; evmDeposit = null;
};

func intent(token : Text) : Types.SessionIntent = {
  network = "icp:1"; token; recipient = Principal.toText(canisterP); suggestedDeposit = 50_000;
  minDeposit = null; expiry = Time.now() + 3_600_000_000_000; costPerCall = null; description = null;
};

let clientCfg : Types.SessionConfig = { maxDeposit = 50_000; autoClose = false; idleTimeout = null };

// No publicKey: an open that gets past the policy and the token is refused at the key check,
// before any ledger call.
let noKey : Types.PaymentSignature = {
  scheme = "exact"; network = "icp:1"; signature = Blob.fromArray([]); publicKey = null;
  asset = null; sender = Principal.toText(payerP); nonce = ""; authorization = null;
};

await suite("S6: effectiveIdleTimeout", func() : async () {

  await test("a client value longer than the policy's is clamped to it; shorter ones and defaults pass through", func() : async () {
    // Mutation: keep the client's value when both are set (`case (?c, ?p) { ?c }`) — the 2.21.x
    // behaviour, where a client could hold an idle session open past the operator's limit.
    assert Sessions.effectiveIdleTimeout(?100, ?50) == ?50;
    assert Sessions.effectiveIdleTimeout(?30, ?50) == ?30;
    assert Sessions.effectiveIdleTimeout(null, ?50) == ?50;
    assert Sessions.effectiveIdleTimeout(?30, null) == ?30;
    assert Sessions.effectiveIdleTimeout(null, null) == null;
  });
});

await suite("S7: a deposit parked at open counts against maxConcurrentSessions", func() : async () {

  await test("a parked open (#closing, nothing consumed) blocks a second open; a parked close does not", func() : async () {
    // Mutation: count #open only in activeSessionCount — the payer opens a second session while the
    // first is parked, and reconcileSession then opens the first too: two open, limit one.
    let parked = mk(Policy.Engine(), null); // default policy: maxConcurrentSessions = ?1
    parked.loadStable([stableSession(#closing, 0, "icp:1")]);
    switch (await parked.openSession(payerP, intent(Principal.toText(ledgerP)), clientCfg, noKey)) {
      case (#err(#policyDenied(msg))) { assert Text.contains(msg, #text "Max concurrent sessions") };
      case (_) { assert false };
    };
    // Control: a session parked by a close (something consumed) is on its way out, not counted, so
    // the open goes on to the key check.
    let closing = mk(Policy.Engine(), null);
    closing.loadStable([stableSession(#closing, 1_000, "icp:1")]);
    switch (await closing.openSession(payerP, intent(Principal.toText(ledgerP)), clientCfg, noKey)) {
      case (#err(#invalidSignature(_))) {};
      case (_) { assert false };
    };
  });
});

await suite("S8: openSession refuses a token that does not resolve", func() : async () {

  await test("an intent token that is not a configured ledger is #tokenNotAccepted, before anything moves", func() : async () {
    // Mutation: fall back to config.tokens[0] again in openSession — the open goes on (here to the
    // key check) and, with a key, would pull the deposit on tokens[0] into a session whose close
    // and reconcile now refuse its token.
    let m = mk(Policy.Engine(), null);
    switch (await m.openSession(payerP, intent("ckUSDC"), clientCfg, noKey)) {
      case (#err(#tokenNotAccepted(msg))) { assert Text.contains(msg, #text "ckUSDC") };
      case (_) { assert false };
    };
  });
});

await suite("E8: an EVM close in flight", func() : async () {

  await test("forceResolveSession and reconcileSession refuse it; the close then reopens the session with nothing released", func() : async () {
    // Mutations: drop the evmClosesInFlight check from forceResolveSession (the force finalizes the
    // live close, releasing the daily reservation, and the close's pre-broadcast failure then
    // reopens the finalized session); drop it from reconcileSession (it answers "no parked tx — use
    // forceResolveSession", pointing the operator at exactly that); or never put the id in the set.
    // The close's settle goes to a malformed recipient, so EvmSender refuses it before any RPC:
    // the close suspends at the sender's await and then fails with nothing broadcast.
    let policy = Policy.Engine();
    let m = mk(policy, ?EvmSender.EvmSender("test_key", null));
    m.loadStable([{
      stableSession(#open, 1_000, "eip155:8453") with
      token = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; recipient = "0xbad";
      evmDeposit = ?{ txHash = "0x01"; chainId = 8453; payerEvmAddress = "0x2222222222222222222222222222222222222222"; tokenAddress = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" };
    }]);
    policy.recordSpend(payerP, 50_000);
    let close = m.closeSessionInternal("sess-1");
    func status() : Types.SessionStatus {
      switch (m.getSession("sess-1")) { case (?s) { s.status }; case (null) { assert false; loop {} } };
    };
    var n = 0; while (status() != #closing and n < 30) { await async {}; n += 1 };
    assert status() == #closing;
    switch (m.forceResolveSession("sess-1")) {
      case (#err(msg)) { assert Text.contains(msg, #text "still in flight") };
      case (#ok) { assert false };
    };
    switch (await m.reconcileSession("sess-1")) {
      case (#err(msg)) { assert Text.contains(msg, #text "still in flight") };
      case (#ok(_)) { assert false };
    };
    switch (await close) {
      case (#settlementFailed(msg)) { assert Text.contains(msg, #text "session reopened") };
      case (_) { assert false };
    };
    assert status() == #open;
    assert policy.getDailySpendAmount(payerP) == 50_000;
  });
});
