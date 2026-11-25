/// 2.24.0: split payees — the address of a 0xSplits push split (v2.2) that pays a finder its share
/// of a payment and this canister the rest, computed without an outcall, for Gateway.settleToSplit.
///
/// The split has no owner: it cannot be changed, paused or redirected, and it pays out only to its
/// two recipients, so the canister's share can only ever go to the canister. It arrives when
/// someone distributes the split (nothing in ic402 deploys or distributes splits). Not checked
/// here: that distribution always succeeds. A finder the token will not pay (a USDC-blacklisted
/// address, say) may block both shares, and that cannot be checked offline.
///
/// The address is the factory's deterministic one (createSplitDeterministic, owner 0, salt 0):
///   params  = ([finder, seller], [share, 10000 - share], 10000, 0)   — finder first
///   inner   = keccak256(abi.encode(params, address(0)) ++ 32 zero bytes)
///   address = last 20 bytes of keccak256(0xff ++ FACTORY ++ inner ++ INIT_CODE_HASH)
/// Pinned by test vectors that the deployed factory's predictDeterministicAddress returns on Base
/// and Base Sepolia (test/evmsplits.test.mo). A split created otherwise (the nonce-salted
/// createSplit, another owner, another factory) has another address and is refused.

import EvmAddress "EvmAddress";
import EvmUtils "EvmUtils";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";

module {

  /// The finder and its share of a payment, in basis points of TOTAL_ALLOCATION. The caller of
  /// settleToSplit takes both from its own records (the codes it honours), never from the payment.
  public type SplitPayee = { finder : Text; finderShareBps : Nat };

  /// The split's total allocation: shares are in basis points.
  public let TOTAL_ALLOCATION : Nat = 10_000;

  /// 0xSplits SplitFactoryV2 (push splits, v2.2), the same address on Base and Base Sepolia. Its
  /// SPLIT_WALLET_IMPLEMENTATION() is 0x1e2086a7e84a32482ac03000d56925f607ccb708.
  public let FACTORY : Text = "0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4";

  /// The init-code hash of the factory's split clones (the CREATE2 code hash).
  public let INIT_CODE_HASH : Text = "0x45b1cff75f6e3ad2b2df0c59635a8d507669cada88ba862dcce929e591ea7356";

  /// The chains whose factory and code hash are pinned: Base (8453) and Base Sepolia (84532).
  public func supportedChain(chainId : Nat) : Bool { chainId == 8453 or chainId == 84532 };

  /// The refusal while the operator has not set a share ceiling (Gateway.setEvmSplitCeiling).
  public let SPLITS_OFF : Text = "Split payees are off on this canister: the operator has not set a finder-share ceiling (setEvmSplitCeiling). Nothing was signed or sent.";

  // A 32-byte big-endian word (n < 2^256).
  func word(n : Nat) : [Nat8] {
    let out = Array.init<Nat8>(32, 0);
    var v = n;
    var i = 32;
    while (i > 0 and v > 0) {
      i -= 1;
      out[i] := Nat8.fromNat(v % 256);
      v /= 256;
    };
    Array.freeze(out);
  };

  // A 20-byte address left-padded to a word.
  func addressWord(a : [Nat8]) : [Nat8] { Array.append(Array.tabulate<Nat8>(12, func(_) = 0), a) };

  /// The address (20 bytes) of the push split paying `finderShareBps` of TOTAL_ALLOCATION to
  /// `finder` and the rest to `seller`; null unless both are 20-byte addresses and the share is at
  /// most TOTAL_ALLOCATION. splitPayTo adds the policy checks (ceiling, chain, finder).
  public func splitAddress(finder : [Nat8], seller : [Nat8], finderShareBps : Nat) : ?[Nat8] {
    if (finder.size() != 20 or seller.size() != 20 or finderShareBps > TOTAL_ALLOCATION) { return null };
    let b = Buffer.Buffer<Nat8>(416);
    func put(w : [Nat8]) { for (x in w.vals()) { b.add(x) } };
    // abi.encode(Split params, address owner): the tuple is dynamic, so its offset comes first.
    put(word(0x40)); // offset of params
    put(word(0)); // owner: none
    put(word(0x80)); // params.recipients offset
    put(word(0xe0)); // params.allocations offset
    put(word(TOTAL_ALLOCATION));
    put(word(0)); // distributionIncentive
    put(word(2));
    put(addressWord(finder));
    put(addressWord(seller));
    put(word(2));
    put(word(finderShareBps));
    put(word(Nat.sub(TOTAL_ALLOCATION, finderShareBps)));
    put(word(0)); // salt 0, concatenated after the encoding
    let inner = EvmAddress.keccak256(Buffer.toArray(b));
    let pre = Buffer.Buffer<Nat8>(85);
    pre.add(0xff);
    for (x in EvmUtils.hexToBytes(FACTORY).vals()) { pre.add(x) };
    for (x in inner.vals()) { pre.add(x) };
    for (x in EvmUtils.hexToBytes(INIT_CODE_HASH).vals()) { pre.add(x) };
    let h = EvmAddress.keccak256(Buffer.toArray(pre));
    ?Array.subArray(h, 12, 20);
  };

  /// The address a payment to the split of (`finder`, `seller`, `finderShareBps`) must be sent to,
  /// lowercase hex, or why that split is refused:
  /// - split payees off: no ceiling set (`ceiling` null);
  /// - a chain whose factory is not pinned (supportedChain);
  /// - a finder share of 0, above the operator's ceiling, or of the whole payment (TOTAL_ALLOCATION
  ///   or more, whatever ceiling is passed: the seller must keep a share);
  /// - a finder or seller that is not a 20-byte address, a zero-address finder, or a finder that is
  ///   the paid token (a split paying the token contract could not be distributed).
  public func splitPayTo(chainId : Nat, finder : Text, seller : Text, finderShareBps : Nat, token : Text, ceiling : ?Nat) : {
    #ok : Text;
    #err : Text;
  } {
    let cap = switch (ceiling) { case (?c) { c }; case (null) { return #err(SPLITS_OFF) } };
    if (not supportedChain(chainId)) {
      return #err("Split payees are supported on Base (8453) and Base Sepolia (84532) only, not on chain " # Nat.toText(chainId) # ". Nothing was signed or sent.");
    };
    if (finderShareBps == 0 or finderShareBps > cap or finderShareBps >= TOTAL_ALLOCATION) {
      return #err("The finder share must be between 1 and the operator's ceiling of " # Nat.toText(cap) # " basis points; got " # Nat.toText(finderShareBps) # ". Nothing was signed or sent.");
    };
    let f = EvmUtils.hexToBytes(finder);
    let s = EvmUtils.hexToBytes(seller);
    if (f.size() != 20 or s.size() != 20) {
      return #err("The finder and the seller must be 20-byte EVM addresses. Nothing was signed or sent.");
    };
    if (Array.find<Nat8>(f, func(x) = x != 0) == null) {
      return #err("The finder cannot be the zero address. Nothing was signed or sent.");
    };
    if (EvmUtils.addressesEqual(finder, token)) {
      return #err("The finder cannot be the paid token. Nothing was signed or sent.");
    };
    switch (splitAddress(f, s, finderShareBps)) {
      case (?a) { #ok(EvmUtils.bytesToHex(a)) };
      case (null) { #err("The split could not be computed. Nothing was signed or sent.") };
    };
  };
};
