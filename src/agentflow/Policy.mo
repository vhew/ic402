/// agentflow — Policy engine for spending limits, rate limiting, and access control.
import Types "Types";
import Time "mo:base/Time";
import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";

module {

  public type SpendingPolicy = Types.SpendingPolicy;

  public class Engine() {

    var globalPolicy : SpendingPolicy = {
      maxPerTransaction = null;
      maxPerDay = null;
      rateLimitPerMinute = ?60;
      maxSessionDeposit = null;
      maxConcurrentSessions = ?1;
      maxSessionDuration = ?(24 * 60 * 60 * 1_000_000_000);
      sessionIdleTimeout = ?(60 * 60 * 1_000_000_000);
      allowedCallers = null;
      blockedCallers = null;
    };

    // TODO: per-caller policies, daily spend tracking, rate limit counters

    public func setGlobalPolicy(policy : SpendingPolicy) {
      globalPolicy := policy;
    };

    public func getGlobalPolicy() : SpendingPolicy {
      globalPolicy;
    };

    public func checkCharge(caller : Principal, amount : Nat) : { #ok; #denied : Text } {
      // Check blocked
      switch (globalPolicy.blockedCallers) {
        case (?blocked) {
          for (b in blocked.vals()) {
            if (Principal.equal(b, caller)) return #denied("Caller is blocked");
          };
        };
        case (null) {};
      };

      // Check allowed
      switch (globalPolicy.allowedCallers) {
        case (?allowed) {
          var found = false;
          for (a in allowed.vals()) {
            if (Principal.equal(a, caller)) found := true;
          };
          if (not found) return #denied("Caller not in allowlist");
        };
        case (null) {};
      };

      // Check max per transaction
      switch (globalPolicy.maxPerTransaction) {
        case (?max) {
          if (amount > max) return #denied("Exceeds maxPerTransaction");
        };
        case (null) {};
      };

      // TODO: check maxPerDay, rateLimitPerMinute

      #ok;
    };
  };
};
