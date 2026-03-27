// ic402 — Escrow manager for session deposits using ICRC-2 subaccounts.
import Types "Types";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import SHA256 "mo:sha2/Sha256";

module {

  // ICRC-2 escrow manager using deterministic subaccounts for session deposits.
  public class EscrowManager(canisterPrincipal : Principal) {

    /// Derive a deterministic 32-byte subaccount for a session.
    /// subaccount = sha256("ic402-escrow" ++ sessionId)
    public func deriveSubaccount(sessionId : Text) : Blob {
      let prefix = Blob.toArray(Text.encodeUtf8("ic402-escrow"));
      let idBytes = Blob.toArray(Text.encodeUtf8(sessionId));
      let input = Array.append(prefix, idBytes);
      SHA256.fromArray(#sha256, input);
    };

    /// Deposit funds from payer to escrow subaccount via icrc2_transfer_from.
    public func deposit(
      ledger : Types.LedgerActor,
      from : Types.Account,
      amount : Nat,
      subaccount : Blob,
    ) : async { #ok : Nat; #err : Text } {
      let result = await ledger.icrc2_transfer_from({
        spender_subaccount = null;
        from;
        to = {
          owner = canisterPrincipal;
          subaccount = ?subaccount;
        };
        amount;
        fee = null;
        memo = null;
        created_at_time = null;
      });
      switch (result) {
        case (#Ok(blockIndex)) { #ok(blockIndex) };
        case (#Err(#InsufficientFunds({ balance }))) {
          #err("Insufficient funds: balance=" # debug_show(balance));
        };
        case (#Err(#InsufficientAllowance({ allowance }))) {
          #err("Insufficient allowance: allowance=" # debug_show(allowance));
        };
        case (#Err(err)) { #err("Transfer failed: " # debug_show(err)) };
      };
    };

    /// Settle consumed amount: transfer from escrow subaccount to recipient.
    public func settle(
      ledger : Types.LedgerActor,
      subaccount : Blob,
      recipient : Types.Account,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      if (amount == 0) return #ok(0);

      let result = await ledger.icrc1_transfer({
        from_subaccount = ?subaccount;
        to = recipient;
        amount;
        fee = null;
        memo = null;
        created_at_time = null;
      });
      switch (result) {
        case (#Ok(blockIndex)) { #ok(blockIndex) };
        case (#Err(err)) { #err("Settlement failed: " # debug_show(err)) };
      };
    };

    /// Refund remainder: transfer from escrow subaccount back to payer.
    public func refund(
      ledger : Types.LedgerActor,
      subaccount : Blob,
      payer : Types.Account,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      if (amount == 0) return #ok(0);

      let result = await ledger.icrc1_transfer({
        from_subaccount = ?subaccount;
        to = payer;
        amount;
        fee = null;
        memo = null;
        created_at_time = null;
      });
      switch (result) {
        case (#Ok(blockIndex)) { #ok(blockIndex) };
        case (#Err(err)) { #err("Refund failed: " # debug_show(err)) };
      };
    };
  };
};
