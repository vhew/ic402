/// ic402 — Policy engine for spending limits, rate limiting, and access control.
import Types "Types";
import Time "mo:base/Time";
import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Char "mo:base/Char";

module {

  public type SpendingPolicy = Types.SpendingPolicy;

  // Day number from nanosecond timestamp (86400 seconds per day)
  func dayNumber(timestamp : Int) : Int {
    timestamp / 86_400_000_000_000;
  };

  // Key for daily spend tracking: "dayNumber:principalText"
  func dailyKey(caller : Principal, day : Int) : Text {
    Int.toText(day) # ":" # Principal.toText(caller);
  };

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

    // Per-caller policy overrides
    var callerPolicies = HashMap.HashMap<Principal, SpendingPolicy>(8, Principal.equal, Principal.hash);

    // Daily spend tracking: key = "dayNumber:principalText", value = amount
    var dailySpend = HashMap.HashMap<Text, Nat>(64, Text.equal, Text.hash);

    // Rate limit tracking: key = "principalText", value = array of timestamps in current window
    var rateLimitLog = HashMap.HashMap<Text, [Int]>(64, Text.equal, Text.hash);

    // ── Policy getters/setters ──

    public func setGlobalPolicy(policy : SpendingPolicy) {
      globalPolicy := policy;
    };

    public func getGlobalPolicy() : SpendingPolicy {
      globalPolicy;
    };

    public func setCallerPolicy(caller : Principal, policy : SpendingPolicy) {
      callerPolicies.put(caller, policy);
    };

    public func removeCallerPolicy(caller : Principal) {
      callerPolicies.delete(caller);
    };

    /// Get effective policy: caller-specific if set, otherwise global.
    public func getEffectivePolicy(caller : Principal) : SpendingPolicy {
      switch (callerPolicies.get(caller)) {
        case (?p) { p };
        case (null) { globalPolicy };
      };
    };

    // ── Access control checks ──

    func checkAccess(policy : SpendingPolicy, caller : Principal) : { #ok; #denied : Text } {
      // Check blocked
      switch (policy.blockedCallers) {
        case (?blocked) {
          for (b in blocked.vals()) {
            if (Principal.equal(b, caller)) return #denied("Caller is blocked");
          };
        };
        case (null) {};
      };

      // Check allowed
      switch (policy.allowedCallers) {
        case (?allowed) {
          var found = false;
          for (a in allowed.vals()) {
            if (Principal.equal(a, caller)) found := true;
          };
          if (not found) return #denied("Caller not in allowlist");
        };
        case (null) {};
      };

      #ok;
    };

    // ── Rate limiting ──

    func checkRateLimit(policy : SpendingPolicy, caller : Principal) : { #ok; #denied : Text } {
      switch (policy.rateLimitPerMinute) {
        case (null) { #ok };
        case (?limit) {
          let key = Principal.toText(caller);
          let now = Time.now();
          let windowStart = now - 60_000_000_000; // 60 seconds in nanoseconds

          // Get existing timestamps, filter to window
          let existing = switch (rateLimitLog.get(key)) {
            case (null) { [] };
            case (?timestamps) {
              Array.filter<Int>(timestamps, func(t) { t > windowStart });
            };
          };

          if (existing.size() >= limit) {
            return #denied("Rate limit exceeded: " # Nat.toText(limit) # "/min");
          };

          // Record this request
          rateLimitLog.put(key, Array.append(existing, [now]));
          #ok;
        };
      };
    };

    // ── Daily spend tracking ──

    func getDailySpend(caller : Principal) : Nat {
      let day = dayNumber(Time.now());
      let key = dailyKey(caller, day);
      switch (dailySpend.get(key)) {
        case (null) { 0 };
        case (?amount) { amount };
      };
    };

    public func recordSpend(caller : Principal, amount : Nat) {
      let day = dayNumber(Time.now());
      let key = dailyKey(caller, day);
      let current = switch (dailySpend.get(key)) {
        case (null) { 0 };
        case (?a) { a };
      };
      dailySpend.put(key, current + amount);
    };

    func checkDailyLimit(policy : SpendingPolicy, caller : Principal, amount : Nat) : { #ok; #denied : Text } {
      switch (policy.maxPerDay) {
        case (null) { #ok };
        case (?max) {
          let current = getDailySpend(caller);
          if (current + amount > max) {
            #denied("Daily limit exceeded: " # Nat.toText(current + amount) # " > " # Nat.toText(max));
          } else {
            #ok;
          };
        };
      };
    };

    /// Clean up old daily entries (keep only today's data).
    public func gcDailySpend() {
      let today = dayNumber(Time.now());
      let toRemove = Iter.toArray(
        Iter.filter<(Text, Nat)>(
          dailySpend.entries(),
          func((key, _)) {
            // key format: "dayNumber:principalText"
            let dayText = extractDayPrefix(key);
            switch (textToInt(dayText)) {
              case (?d) { d < today };
              case (null) { true }; // malformed, remove
            };
          },
        )
      );
      for ((key, _) in toRemove.vals()) {
        dailySpend.delete(key);
      };
    };

    // ── Charge checks ──

    public func checkCharge(caller : Principal, amount : Nat) : { #ok; #denied : Text } {
      let policy = getEffectivePolicy(caller);

      switch (checkAccess(policy, caller)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      switch (checkRateLimit(policy, caller)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      // Check max per transaction
      switch (policy.maxPerTransaction) {
        case (?max) {
          if (amount > max) return #denied("Exceeds maxPerTransaction");
        };
        case (null) {};
      };

      switch (checkDailyLimit(policy, caller, amount)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      #ok;
    };

    // ── Session checks ──

    public func checkSessionOpen(caller : Principal, deposit : Nat, activeCount : Nat) : { #ok; #denied : Text } {
      let policy = getEffectivePolicy(caller);

      switch (checkAccess(policy, caller)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      // Check concurrent sessions
      switch (policy.maxConcurrentSessions) {
        case (?max) {
          if (activeCount >= max) return #denied("Max concurrent sessions reached");
        };
        case (null) {};
      };

      // Check session deposit limit
      switch (policy.maxSessionDeposit) {
        case (?max) {
          if (deposit > max) return #denied("Exceeds maxSessionDeposit");
        };
        case (null) {};
      };

      switch (checkDailyLimit(policy, caller, deposit)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      #ok;
    };

    // ── Voucher checks ──

    public func checkVoucher(caller : Principal, delta : Nat) : { #ok; #denied : Text } {
      let policy = getEffectivePolicy(caller);

      switch (checkRateLimit(policy, caller)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      switch (checkDailyLimit(policy, caller, delta)) {
        case (#denied(r)) { return #denied(r) };
        case (#ok) {};
      };

      #ok;
    };

    /// Get current daily spend for a caller.
    public func getDailySpendAmount(caller : Principal) : Nat {
      getDailySpend(caller);
    };

    // ── Stable state ──

    public func toStable() : Types.StablePolicyState {
      {
        globalPolicy;
        callerPolicies = Iter.toArray(callerPolicies.entries());
        dailySpendEntries = Iter.toArray(dailySpend.entries());
        rateLimitEntries = Iter.toArray(rateLimitLog.entries());
      };
    };

    public func loadStable(data : Types.StablePolicyState) {
      globalPolicy := data.globalPolicy;
      callerPolicies := HashMap.fromIter<Principal, SpendingPolicy>(
        data.callerPolicies.vals(), data.callerPolicies.size(),
        Principal.equal, Principal.hash,
      );
      dailySpend := HashMap.fromIter<Text, Nat>(
        data.dailySpendEntries.vals(), data.dailySpendEntries.size(),
        Text.equal, Text.hash,
      );
      rateLimitLog := HashMap.fromIter<Text, [Int]>(
        data.rateLimitEntries.vals(), data.rateLimitEntries.size(),
        Text.equal, Text.hash,
      );
    };
  };

  // ── Helpers ──

  /// Extract the day number prefix from a key like "12345:principalText".
  func extractDayPrefix(key : Text) : Text {
    var result = "";
    for (c in key.chars()) {
      if (c == ':') return result;
      result := result # Text.fromChar(c);
    };
    result;
  };

  func textToInt(t : Text) : ?Int {
    var result : Int = 0;
    var negative = false;
    var first = true;
    for (c in t.chars()) {
      if (first and c == '-') {
        negative := true;
      } else {
        let digit = Nat32.toNat(Char.toNat32(c));
        if (digit < 48 or digit > 57) return null;
        result := result * 10 + (digit - 48);
      };
      first := false;
    };
    if (negative) { ?(-result) } else { ?result };
  };
};
