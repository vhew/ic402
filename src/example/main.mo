/// Example canister demonstrating agentflow charge and session payments.
import Agentflow "../agentflow/lib";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Time "mo:base/Time";

persistent actor KnowledgeBase {

  var stableGateway : ?Agentflow.StableGatewayState = null;

  transient let gate = Agentflow.Gateway(
    {
      recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
      tokens = [{
        ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
        symbol = "ckUSDC";
        decimals = 6;
      }];
      erc8004 = null;
      avalanche = null;
    },
    Principal.fromActor(KnowledgeBase),
  );

  // Load stable state on init
  do {
    switch (stableGateway) {
      case (?data) { gate.loadStable(data) };
      case (null) {};
    };
  };

  // Set default policy
  do {
    gate.setPolicy(null, {
      maxPerTransaction = ?1_000_000;
      maxPerDay = ?10_000_000;
      rateLimitPerMinute = ?120;
      maxSessionDeposit = ?5_000_000;
      maxConcurrentSessions = ?1;
      maxSessionDuration = ?(24 * 60 * 60 * 1_000_000_000);
      sessionIdleTimeout = ?(60 * 60 * 1_000_000_000);
      allowedCallers = null;
      blockedCallers = null;
    });
  };

  // Start session expiry timer
  gate.startTimers<system>();

  system func preupgrade() {
    stableGateway := ?gate.toStable();
  };

  system func postupgrade() {
    stableGateway := null;
  };

  // ── Charge endpoint: 0.05 ckUSDC per call ──

  public shared func search(
    searchQuery : Text,
    paymentSig : ?Agentflow.PaymentSignature,
  ) : async {
    #paymentRequired : Agentflow.PaymentRequirement;
    #ok : [Text];
    #error : Text;
  } {
    let price : Agentflow.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount = 50_000;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(_)) { #ok(doSearch(searchQuery)) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // ── Session endpoints ──

  public shared func requestSession() : async Agentflow.SessionIntent {
    gate.offerSession({
      network = "icp:1";
      token = Principal.toText(Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"));
      recipient = Principal.toText(Principal.fromActor(KnowledgeBase));
      suggestedDeposit = 1_000_000;
      minDeposit = ?100_000;
      expiry = Time.now() + 300_000_000_000;
      costPerCall = ?1_000;
      description = ?"Knowledge base session — pay per query";
    });
  };

  public shared(msg) func openSession(
    config : Agentflow.SessionConfig,
    sig : Agentflow.PaymentSignature,
  ) : async { #ok : Agentflow.SessionState; #err : Text } {
    let intent = await requestSession();
    switch (await gate.openSession(msg.caller, intent, config, sig)) {
      case (#ok(state)) { #ok(state) };
      case (#err(#policyDenied(r))) { #err("Policy: " # r) };
      case (#err(#depositBelowMinimum(min))) { #err("Deposit below minimum: " # Nat.toText(min)) };
      case (#err(_)) { #err("Failed to open session") };
    };
  };

  public shared func sessionQuery(
    voucher : Agentflow.Voucher,
    question : Text,
  ) : async { #ok : Text; #error : Text } {
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_delta)) { #ok(doQuery(question)) };
      case (#insufficientDeposit) { #error("Budget exhausted") };
      case (#policyDenied(r)) { #error("Policy: " # r) };
      case (_) { #error("Invalid voucher") };
    };
  };

  public shared func endSession(sessionId : Text) : async Agentflow.PaymentResult {
    await gate.closeSession(sessionId);
  };

  // ── Admin ──

  public shared(msg) func setPolicy(p : Agentflow.SpendingPolicy) : async () {
    assert(Principal.isController(msg.caller));
    gate.setPolicy(null, p);
  };

  public shared(msg) func forceCloseSession(sessionId : Text) : async Agentflow.PaymentResult {
    assert(Principal.isController(msg.caller));
    await gate.closeSession(sessionId);
  };

  // ── Internal ──

  func doSearch(_q : Text) : [Text] { ["result 1", "result 2"] };
  func doQuery(question : Text) : Text { "Answer to: " # question };
};
