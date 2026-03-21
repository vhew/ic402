/// Example canister demonstrating agentflow charge and session payments.
import Agentflow "../agentflow/lib";
import Principal "mo:base/Principal";
import Time "mo:base/Time";

actor KnowledgeBase {

  let gate = Agentflow.Gateway({
    recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
    tokens = [{
      ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      symbol = "ckUSDC";
      decimals = 6;
    }];
    erc8004 = null;
    avalanche = null;
  });

  // ── Charge endpoint: 0.05 ckUSDC per call ──

  public shared(msg) func search(
    query : Text,
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
          case (#ok(_)) { #ok(["result 1", "result 2"]) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // ── Session endpoint ──

  public shared(msg) func requestSession() : async Agentflow.SessionIntent {
    gate.offerSession({
      network = "icp:1";
      token = Principal.toText(Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"));
      recipient = Principal.toText(Principal.fromActor(KnowledgeBase));
      suggestedDeposit = 1_000_000;
      minDeposit = ?100_000;
      expiry = Time.now() + 300_000_000_000;
      costPerCall = ?1_000;
      description = ?"Knowledge base — pay per query";
    });
  };

  public shared(msg) func sessionQuery(
    voucher : Agentflow.Voucher,
    question : Text,
  ) : async { #ok : Text; #error : Text } {
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_delta)) { #ok("Answer to: " # question) };
      case (#insufficientDeposit) { #error("Budget exhausted") };
      case (#policyDenied(r)) { #error("Policy: " # r) };
      case (_) { #error("Invalid voucher") };
    };
  };
};
