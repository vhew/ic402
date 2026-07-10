/// ic402 — EVM utility functions: RLP encoding, ABI encoding, EIP-1559 transactions.
///
/// Pure functions, no async, no state. Used by Identity.mo for on-canister
/// EVM transaction signing.

import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import EvmAddress "EvmAddress";
import Utils "Utils";

module {

  // ═══════════════════════════════════════════════════════════════════════
  // Hex Utilities
  // ═══════════════════════════════════════════════════════════════════════

  /// Encode bytes as lowercase hex with 0x prefix.
  public func bytesToHex(bytes : [Nat8]) : Text {
    EvmAddress.toHex(bytes);
  };

  /// Decode hex string (with or without 0x prefix) to bytes.
  /// Returns empty array on odd-length or invalid hex.
  public func hexToBytes(hex : Text) : [Nat8] {
    let chars = Iter.toArray(hex.chars());
    var start : Nat = 0;
    if (chars.size() >= 2 and chars[0] == '0' and (chars[1] == 'x' or chars[1] == 'X')) {
      start := 2;
    };
    let hexLen = Utils.satSub(chars.size(), start);
    if (hexLen % 2 != 0) return [];

    let buf = Buffer.Buffer<Nat8>(hexLen / 2);
    var i = start;
    while (i + 1 < chars.size()) {
      let hi = hexCharToNat(chars[i]);
      let lo = hexCharToNat(chars[i + 1]);
      if (hi == 255 or lo == 255) return [];
      buf.add(Nat8.fromNat(hi * 16 + lo));
      i += 2;
    };
    Buffer.toArray(buf);
  };

  func hexCharToNat(c : Char) : Nat {
    let n = Char.toNat32(c);
    if (n >= 48 and n <= 57) { Nat32.toNat(n - 48) }
    else if (n >= 97 and n <= 102) { Nat32.toNat(n - 87) }
    else if (n >= 65 and n <= 70) { Nat32.toNat(n - 55) }
    else { 255 }; // invalid
  };

  /// Parse a 0x-prefixed hex address to 20-byte array.
  public func addressToBytes(addr : Text) : [Nat8] {
    let bytes = hexToBytes(addr);
    assert(bytes.size() == 20);
    bytes;
  };

  /// C-1 (v2): Case-insensitive, prefix-tolerant equality of two EVM addresses.
  /// Compares the decoded 20-byte values, so "0xAbC…" == "abc…". Returns false
  /// if either side is not a valid 20-byte address (defensive — never treats a
  /// malformed address as a match).
  public func addressesEqual(a : Text, b : Text) : Bool {
    let ab = hexToBytes(a);
    let bb = hexToBytes(b);
    if (ab.size() != 20 or bb.size() != 20) return false;
    var i = 0;
    while (i < 20) {
      if (ab[i] != bb[i]) return false;
      i += 1;
    };
    true;
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Byte <-> Nat Conversion
  // ═══════════════════════════════════════════════════════════════════════

  /// Big-endian Nat to minimal byte array (no leading zeros).
  /// 0 returns empty array (correct for RLP integer encoding).
  public func natToMinBytes(n : Nat) : [Nat8] {
    if (n == 0) return [];
    var byteCount : Nat = 0;
    var v = n;
    while (v > 0) {
      byteCount += 1;
      v := v / 256;
    };
    let buf = Array.init<Nat8>(byteCount, 0 : Nat8);
    v := n;
    var i = byteCount;
    while (i > 0) {
      i -= 1;
      buf[i] := Nat8.fromNat(v % 256);
      v := v / 256;
    };
    Array.freeze(buf);
  };

  /// Big-endian Nat to fixed-length byte array (zero-padded on left).
  public func natToBytes(n : Nat, len : Nat) : [Nat8] {
    let buf = Array.init<Nat8>(len, 0 : Nat8);
    var v = n;
    var i = len;
    while (i > 0) {
      i -= 1;
      buf[i] := Nat8.fromNat(v % 256);
      v := v / 256;
    };
    Array.freeze(buf);
  };

  /// Big-endian byte array to Nat.
  public func bytesToNat(bytes : [Nat8]) : Nat {
    var n : Nat = 0;
    for (b in bytes.vals()) {
      n := n * 256 + Nat8.toNat(b);
    };
    n;
  };

  // ═══════════════════════════════════════════════════════════════════════
  // RLP Encoding (Ethereum Yellow Paper, Appendix B)
  // ═══════════════════════════════════════════════════════════════════════

  /// RLP-encode a byte string.
  public func rlpEncodeBytes(data : [Nat8]) : [Nat8] {
    let len = data.size();
    if (len == 1 and data[0] < 0x80) {
      // Single byte in [0x00, 0x7f]: encoded as itself
      data;
    } else if (len <= 55) {
      // Short string: 0x80 + len prefix
      Array.append([Nat8.fromNat(0x80 + len)], data);
    } else {
      // Long string: 0xb7 + length-of-length prefix
      let lenBytes = natToMinBytes(len);
      Array.append(
        Array.append([Nat8.fromNat(0xb7 + lenBytes.size())], lenBytes),
        data,
      );
    };
  };

  /// RLP-encode a Nat as its minimal big-endian byte representation.
  /// 0 encodes as empty string (RLP 0x80).
  public func rlpEncodeNat(n : Nat) : [Nat8] {
    rlpEncodeBytes(natToMinBytes(n));
  };

  /// RLP-encode a list of already-RLP-encoded items.
  public func rlpEncodeList(items : [[Nat8]]) : [Nat8] {
    let payload = concatArrays(items);
    let len = payload.size();
    if (len <= 55) {
      Array.append([Nat8.fromNat(0xc0 + len)], payload);
    } else {
      let lenBytes = natToMinBytes(len);
      Array.append(
        Array.append([Nat8.fromNat(0xf7 + lenBytes.size())], lenBytes),
        payload,
      );
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // ABI Encoding (Solidity ABI Specification)
  // ═══════════════════════════════════════════════════════════════════════

  /// Encode a Nat as uint256 (32 bytes, zero-padded big-endian).
  public func abiEncodeUint256(n : Nat) : [Nat8] {
    natToBytes(n, 32);
  };

  // ── ECDSA signature `v` representation ─────────────────────────────────────
  // Wallets sign EIP-3009 authorizations with v ∈ {27, 28} — the form Ethereum's on-chain
  // `ecrecover` (and USDC's `transferWithAuthorization`) require. ic402's internal `ecRecover`
  // uses the 0/1 recovery id instead. These two idempotent conversions NAME that seam so every
  // site declares which form it means, instead of a scattered `if v >= 27`: mixing them up
  // recovers the wrong signer (0/1 in on-chain calldata reverts every EIP-3009 transfer).

  /// As-signed v (27/28) → recovery id (0/1) for ic402's internal ecRecover. Idempotent.
  public func recoveryIdFromV(v : Nat8) : Nat8 { if (v >= 27) { v - 27 : Nat8 } else { v } };

  /// Recovery id (0/1) → on-chain signature v (27/28) that ecrecover requires. Idempotent.
  public func chainVFromRecoveryId(v : Nat8) : Nat8 { if (v < 27) { v + 27 : Nat8 } else { v } };

  /// Encode a Bool as uint256 (0 or 1).
  public func abiEncodeBool(b : Bool) : [Nat8] {
    abiEncodeUint256(if (b) 1 else 0);
  };

  /// Encode a Text as a dynamic ABI type (tail portion only).
  /// Returns: [length as uint256] [utf8 bytes right-padded to 32-byte boundary]
  public func abiEncodeString(s : Text) : [Nat8] {
    let utf8 = Blob.toArray(Text.encodeUtf8(s));
    let paddedLen = padTo32(utf8.size());
    let padded = Array.append(utf8, Array.freeze(Array.init<Nat8>(paddedLen - utf8.size(), 0 : Nat8)));
    Array.append(abiEncodeUint256(utf8.size()), padded);
  };

  /// Encode a string array as a dynamic ABI type (tail portion only).
  /// Returns: [count] [offset0, offset1, ...] [string0, string1, ...]
  public func abiEncodeStringArray(arr : [Text]) : [Nat8] {
    let count = arr.size();
    // Each string's tail is placed after all the offset words
    // Offsets: count * 32 bytes for the offset section
    let encodedStrings = Array.map<Text, [Nat8]>(arr, abiEncodeString);

    // Calculate offsets: first string starts at count * 32
    let offsets = Buffer.Buffer<[Nat8]>(count);
    var offset : Nat = count * 32;
    for (encoded in encodedStrings.vals()) {
      offsets.add(abiEncodeUint256(offset));
      offset += encoded.size();
    };

    // Assemble: count + offsets + string data
    var result = abiEncodeUint256(count);
    for (o in offsets.vals()) { result := Array.append(result, o) };
    for (encoded in encodedStrings.vals()) { result := Array.append(result, encoded) };
    result;
  };

  /// Compute the 4-byte function selector from a Solidity signature.
  public func functionSelector(sig : Text) : [Nat8] {
    let hash = EvmAddress.keccak256Text(sig);
    Array.subArray(hash, 0, 4);
  };

  /// ABI-encode a complete function call with mixed static and dynamic params.
  /// Each param is either #static_ (32-byte inline value) or #dynamic (variable-length tail data).
  /// Returns: selector ++ head ++ tail
  public func abiEncodeFunctionCall(
    selector : [Nat8],
    params : [{ #static_ : [Nat8]; #dynamic : [Nat8] }],
  ) : [Nat8] {
    let count = params.size();
    // Head: count * 32 bytes. Each slot is either the inline value or an offset to tail data.
    // Tail: dynamic data appended in order.
    let headSize = count * 32;
    let head = Buffer.Buffer<Nat8>(headSize);
    let tail = Buffer.Buffer<Nat8>(256);

    var tailOffset : Nat = headSize; // offset from start of params (after selector)

    for (p in params.vals()) {
      switch (p) {
        case (#static_(data)) {
          assert(data.size() == 32);
          for (b in data.vals()) { head.add(b) };
        };
        case (#dynamic(data)) {
          // Head contains offset pointer
          let offsetBytes = abiEncodeUint256(tailOffset);
          for (b in offsetBytes.vals()) { head.add(b) };
          // Tail accumulates data
          for (b in data.vals()) { tail.add(b) };
          tailOffset += data.size();
        };
      };
    };

    let result = Buffer.Buffer<Nat8>(selector.size() + head.size() + tail.size());
    for (b in selector.vals()) { result.add(b) };
    for (b in head.vals()) { result.add(b) };
    for (b in tail.vals()) { result.add(b) };
    Buffer.toArray(result);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // EIP-1559 (Type 2) Transaction Construction
  // ═══════════════════════════════════════════════════════════════════════

  /// Parameters for constructing an EIP-1559 (Type 2) transaction.
  public type TxParams = {
    chainId : Nat;
    nonce : Nat;
    maxPriorityFeePerGas : Nat;
    maxFeePerGas : Nat;
    gasLimit : Nat;
    to : [Nat8]; // 20-byte address
    value : Nat;
    data : [Nat8]; // calldata
  };

  /// Compute the signing hash for an EIP-1559 transaction.
  /// = keccak256(0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
  ///                          gasLimit, to, value, data, accessList]))
  public func unsignedTxHash(params : TxParams) : [Nat8] {
    let payload = rlpEncodeList([
      rlpEncodeNat(params.chainId),
      rlpEncodeNat(params.nonce),
      rlpEncodeNat(params.maxPriorityFeePerGas),
      rlpEncodeNat(params.maxFeePerGas),
      rlpEncodeNat(params.gasLimit),
      rlpEncodeBytes(params.to),
      rlpEncodeNat(params.value),
      rlpEncodeBytes(params.data),
      rlpEncodeList([]), // accessList: empty
    ]);
    // EIP-1559: hash = keccak256(0x02 || rlp_payload)
    EvmAddress.keccak256(Array.append([0x02 : Nat8], payload));
  };

  /// Build the signed raw transaction bytes.
  /// = 0x02 || rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
  ///                gasLimit, to, value, data, accessList, yParity, r, s])
  public func signedRawTx(params : TxParams, r : [Nat8], s : [Nat8], yParity : Nat8) : [Nat8] {
    let payload = rlpEncodeList([
      rlpEncodeNat(params.chainId),
      rlpEncodeNat(params.nonce),
      rlpEncodeNat(params.maxPriorityFeePerGas),
      rlpEncodeNat(params.maxFeePerGas),
      rlpEncodeNat(params.gasLimit),
      rlpEncodeBytes(params.to),
      rlpEncodeNat(params.value),
      rlpEncodeBytes(params.data),
      rlpEncodeList([]), // accessList: empty
      rlpEncodeNat(Nat8.toNat(yParity)),
      // signature_r / signature_s are RLP INTEGERS (EIP-2718/1559): minimal encoding,
      // leading zeros trimmed. Encoding the raw 32-byte slices as byte strings kept
      // leading zeros, which geth-family nodes reject as "rlp: non-canonical integer" —
      // an intermittent ~1-in-128 broadcast failure (P(leading zero in r or s) ≈ 0.78%),
      // whose locally derived tx hash could then never resolve.
      rlpEncodeNat(bytesToNat(r)),
      rlpEncodeNat(bytesToNat(s)),
    ]);
    Array.append([0x02 : Nat8], payload);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Internal helpers
  // ═══════════════════════════════════════════════════════════════════════

  /// Round up to next multiple of 32.
  func padTo32(n : Nat) : Nat {
    if (n == 0) return 32;
    ((n + 31) / 32) * 32;
  };

  /// Concatenate an array of byte arrays.
  func concatArrays(arrays : [[Nat8]]) : [Nat8] {
    let buf = Buffer.Buffer<Nat8>(256);
    for (arr in arrays.vals()) {
      for (b in arr.vals()) { buf.add(b) };
    };
    Buffer.toArray(buf);
  };
};
