/// agentflow — Main gateway class. Handles charges, sessions, and policy.
import Types "Types";
import Policy "Policy";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Random "mo:base/Random";

module {

  public class Gateway(config : Types.Config) {

    let policy = Policy.Engine();

    // ── Charge (x402 "exact") ──

    /// Generate a 402 payment requirement for a given price.
    public func require(price : Types.Price) : Types.PaymentRequirement {
      {
        scheme = "exact";
        network = price.network;
        token = Principal.toText(price.token);
        amount = price.amount;
        recipient = switch (config.recipient.subaccount) {
          case (null) { Principal.toText(config.recipient.owner) };
          case (?_) { Principal.toText(config.recipient.owner) };
        };
        // TODO: generate random nonce
        nonce = "\00\00\00\00";
        expiry = Time.now() + 300_000_000_000; // 5 minutes
      };
    };

    /// Verify and settle a charge payment.
    public func settle(signature : Types.PaymentSignature) : async Types.PaymentResult {
      // TODO: verify signature, check policy, call icrc2_transfer_from
      #settlementFailed("Not yet implemented");
    };

    // ── Session ──

    /// Generate a session offer for 402 response.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
      intent;
    };

    /// Open a session with ICRC-2 escrow deposit.
    public func openSession(
      caller : Principal,
      intent : Types.SessionIntent,
      clientConfig : Types.SessionConfig,
      sig : Types.PaymentSignature,
    ) : async { #ok : Types.SessionState; #err : Types.PaymentResult } {
      // TODO: check policy, calculate deposit, call icrc2_transfer_from to escrow
      #err(#settlementFailed("Not yet implemented"));
    };

    /// Verify a cumulative voucher and return the delta.
    public func consumeVoucher(voucher : Types.Voucher) : Types.VoucherResult {
      // TODO: verify signature, check sequence, compute delta
      #sessionNotOpen;
    };

    /// Close a session: settle consumed, refund remainder.
    public func closeSession(sessionId : Text) : async Types.PaymentResult {
      // TODO: find session, transfer consumed to recipient, refund rest to payer
      #settlementFailed("Not yet implemented");
    };

    // ── Policy ──

    public func setPolicy(caller : ?Principal, p : Types.SpendingPolicy) {
      // TODO: support per-caller policies
      policy.setGlobalPolicy(p);
    };

    public func getPolicy(caller : Principal) : Types.SpendingPolicy {
      policy.getGlobalPolicy();
    };

    public func dailySpend(caller : Principal) : Nat {
      // TODO: track daily spend
      0;
    };
  };
};
