/// ic402 — Virtual escrow accounting for EVM session deposits.
///
/// Tracks how much of the canister's shared EVM address balance is
/// allocated to active sessions. Prevents over-allocation when multiple
/// EVM sessions are open concurrently.

import Types "Types";
import HashMap "mo:base/HashMap";
import Text "mo:base/Text";
import Iter "mo:base/Iter";

module {

  type Allocation = {
    chainId : Nat;
    token : Text;
    amount : Nat;
  };

  public class EvmEscrowManager() {

    var allocations = HashMap.HashMap<Text, Allocation>(8, Text.equal, Text.hash);

    /// Reserve a deposit amount for a session.
    public func allocate(sessionId : Text, chainId : Nat, token : Text, amount : Nat) : { #ok; #err : Text } {
      switch (allocations.get(sessionId)) {
        case (?_) { #err("Session " # sessionId # " already has an EVM allocation") };
        case (null) {
          allocations.put(sessionId, { chainId; token; amount });
          #ok;
        };
      };
    };

    /// Release a session's allocation. Returns the allocation details for settlement.
    public func deallocate(sessionId : Text) : ?Allocation {
      allocations.remove(sessionId);
    };

    /// Get a session's allocation amount.
    public func getAllocation(sessionId : Text) : ?Nat {
      switch (allocations.get(sessionId)) {
        case (?a) { ?a.amount };
        case (null) { null };
      };
    };

    /// Total allocated across all sessions for a specific chain+token.
    public func totalAllocated(chainId : Nat, token : Text) : Nat {
      var total : Nat = 0;
      for ((_, a) in allocations.entries()) {
        if (a.chainId == chainId and a.token == token) {
          total += a.amount;
        };
      };
      total;
    };

    public func toStable() : [Types.StableEvmAllocation] {
      Iter.toArray(
        Iter.map<(Text, Allocation), Types.StableEvmAllocation>(
          allocations.entries(),
          func((sid, a)) : Types.StableEvmAllocation {
            { sessionId = sid; chainId = a.chainId; token = a.token; amount = a.amount };
          },
        )
      );
    };

    public func loadStable(data : [Types.StableEvmAllocation]) {
      allocations := HashMap.HashMap<Text, Allocation>(data.size(), Text.equal, Text.hash);
      for (entry in data.vals()) {
        allocations.put(entry.sessionId, {
          chainId = entry.chainId;
          token = entry.token;
          amount = entry.amount;
        });
      };
    };
  };
};
