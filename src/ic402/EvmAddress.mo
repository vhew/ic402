/// ic402 — EVM address derivation and ECDSA recovery for secp256k1.
///
/// All EC point arithmetic is delegated to herumi's ecdsa library.
/// This module provides:
///   - Address derivation: compressed pubkey → keccak256 → EVM address
///   - ecRecover: recover pubkey from ECDSA signature (for EIP-3009)
///   - keccak256: thin wrapper around mo:sha3

import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import Result "mo:base/Result";
import Sha3 "mo:sha3/lib";
import EcdsaCurve "mo:ecdsa/Curve";

module {

  // secp256k1 curve order
  let SECP256K1_N : Nat = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
  let SECP256K1_P : Nat = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

  // ── Byte conversion ──

  func bytesToNat(bytes : [Nat8]) : Nat {
    var n : Nat = 0;
    for (b in bytes.values()) { n := n * 256 + Nat8.toNat(b) };
    n;
  };

  func natToBytes(n : Nat, len : Nat) : [Nat8] {
    let buf = Array.init<Nat8>(len, 0);
    var v = n;
    var i = len;
    while (i > 0) { i -= 1; buf[i] := Nat8.fromNat(v % 256); v := v / 256 };
    Array.freeze(buf);
  };

  /// EIP-2 low-S normalization: if `s` falls in the upper half of the curve order,
  /// replace it with n - s (the recovery point's y-parity flips accordingly — callers
  /// that normalize BEFORE `recoverYParity` need no manual flip). Returns the
  /// (possibly unchanged) 32-byte s and whether it was flipped.
  ///
  /// The IC's tECDSA normalizes s at the combine step and consensus rejects high-s
  /// combined signatures — but only in the dfinity/ic implementation, not the
  /// interface spec. Every post-Homestead EVM chain (EIP-2) and USDC's on-chain
  /// ECRecover reject high-s, and nothing downstream here would catch one
  /// (recoverYParity resolves a parity for high-s too), so every sign site
  /// normalizes the raw s from sign_with_ecdsa before use.
  /// An out-of-range s (0 or >= n) is returned unchanged — it is invalid either
  /// way and fails recovery downstream.
  public func normalizeS(sBytes : [Nat8]) : ([Nat8], Bool) {
    let s = bytesToNat(sBytes);
    if (s < SECP256K1_N and s > SECP256K1_N / 2) {
      (natToBytes(SECP256K1_N - s, 32), true);
    } else {
      (sBytes, false);
    };
  };

  // ── EC Recovery (using herumi's ecdsa library) ──

  /// True when s is in the lower half of the curve order (s <= n/2), the form USDC's
  /// ECRecover and OpenZeppelin's ECDSA require (EIP-2). Says nothing about s == 0.
  public func isLowS(sBytes : [Nat8]) : Bool = bytesToNat(sBytes) <= SECP256K1_N / 2;

  // Q = r^(-1) * (s*R - z*G) for the decompressed nonce point R = (rx, ry), as a compressed
  // SEC1 key. null when Q is the point at infinity.
  func recoverFromR(curve : EcdsaCurve.Curve, z : Nat, r : Nat, s : Nat, rx : Nat, ry : EcdsaCurve.FpElt) : ?[Nat8] {
    let rJac = curve.toJacobi(#affine(#fp(rx), ry));

    // u1 = -z * r^(-1) mod n, u2 = s * r^(-1) mod n
    let rInv = curve.Fr.inv(curve.Fr.fromNat(r));
    let u1 = curve.Fr.mul(curve.Fr.neg(curve.Fr.fromNat(z)), rInv);
    let u2 = curve.Fr.mul(curve.Fr.fromNat(s), rInv);

    // Q = u1*G + u2*R
    switch (curve.fromJacobi(curve.add(curve.mul_base(u1), curve.mul(rJac, u2)))) {
      case (#zero) { null };
      case (#affine(#fp(qx), #fp(qy))) {
        let prefix : Nat8 = if (qy % 2 == 0) 0x02 else 0x03;
        ?Array.append([prefix], natToBytes(qx, 32));
      };
    };
  };

  /// Recover the public key from an ECDSA signature, exactly as Ethereum's `ecrecover`
  /// precompile does. Use this for any signature the chain will check, so ic402 accepts what
  /// the chain accepts. It differs from ecRecover in the three places the chain does:
  ///   - v is the recovery id 0 or 1 (27/28 on chain); any other value returns null.
  ///   - R.x = r only: no r + n fallback.
  ///   - R takes the parity v gives and no other; the point at infinity returns null.
  /// s is used as given, and high s is accepted, as the precompile does. USDC's low-s rule
  /// belongs to the caller (Eip712.recoverAuthorizationSigner).
  /// Returns the compressed SEC1 public key (33 bytes) or null.
  public func ecRecoverEvm(msgHash : [Nat8], rBytes : [Nat8], sBytes : [Nat8], v : Nat8) : ?[Nat8] {
    if (v > 1) return null;
    let r = bytesToNat(rBytes);
    let s = bytesToNat(sBytes);
    if (r == 0 or r >= SECP256K1_N or s == 0 or s >= SECP256K1_N) return null;
    let curve = EcdsaCurve.Curve(#secp256k1);
    switch (curve.getYfromX(#fp(r), v == 0)) {
      case (null) { null };
      case (?ry) { recoverFromR(curve, bytesToNat(msgHash), r, s, r, ry) };
    };
  };

  /// Recover the public key from an ECDSA signature, more leniently than Ethereum's
  /// `ecrecover` (see ecRecoverEvm for the strict form). Returns the compressed SEC1 public
  /// key (33 bytes) or null.
  ///
  /// Algorithm: Q = r^(-1) * (s*R - z*G). Normalizes high s (flipping the parity), then
  /// tries R with v's parity and then the other one, each with x = r and, if that is not on
  /// the curve, x = r + n. test/secp256k1.test.mo pins where this differs from Ethereum.
  /// For signatures checked off chain only (ServiceRegistry buyer actions) and for finding
  /// the parity of the canister's own signatures (recoverYParity).
  public func ecRecover(msgHash : [Nat8], rBytes : [Nat8], sBytes : [Nat8], v : Nat8) : ?[Nat8] {
    let z = bytesToNat(msgHash);
    let r = bytesToNat(rBytes);
    var s = bytesToNat(sBytes);
    if (r == 0 or r >= SECP256K1_N or s == 0 or s >= SECP256K1_N) return null;

    // Normalize to low-S form (some libraries produce high-S signatures)
    var vAdj = v;
    if (s > SECP256K1_N / 2) {
      s := SECP256K1_N - s;
      vAdj := if (v == 0) 1 else 0;
    };

    let curve = EcdsaCurve.Curve(#secp256k1);
    let isEven = vAdj == 0 or vAdj == 2;

    // Try preferred parity first, then the other
    for (even in [isEven, not isEven].values()) {
      // Decompress R: try x=r, then x=r+n (rare overflow case)
      let rPoint = switch (curve.getYfromX(#fp(r), even)) {
        case (?y) { ?(r, y) };
        case (null) {
          let rPlusN = r + SECP256K1_N;
          if (rPlusN < SECP256K1_P) {
            switch (curve.getYfromX(#fp(rPlusN), even)) {
              case (?y) { ?(rPlusN, y) };
              case (null) { null };
            };
          } else { null };
        };
      };

      switch (rPoint) {
        case (null) {};
        case (?(rx, ry)) {
          // The point at infinity falls through to the other parity.
          switch (recoverFromR(curve, z, r, s, rx, ry)) {
            case (?q) { return ?q };
            case (null) {};
          };
        };
      };
    };
    null;
  };

  /// Determine yParity by trying both v=0 and v=1 and comparing
  /// the recovered public key to the known canister public key.
  public func recoverYParity(msgHash : [Nat8], rBytes : [Nat8], sBytes : [Nat8], knownPubKey : [Nat8]) : Nat8 {
    switch (ecRecover(msgHash, rBytes, sBytes, 0)) {
      case (?recovered) { if (recovered == knownPubKey) return 0 };
      case (null) {};
    };
    1;
  };

  // ── Hashing ──

  /// Compute the keccak256 hash of a byte array.
  public func keccak256(data : [Nat8]) : [Nat8] {
    let hasher = Sha3.Keccak(256);
    hasher.update(data);
    hasher.finalize();
  };

  /// Compute the keccak256 hash of a text string (UTF-8 encoded).
  public func keccak256Text(text : Text) : [Nat8] {
    keccak256(Blob.toArray(Text.encodeUtf8(text)));
  };

  // ── Encoding ──

  /// Encode a byte array as lowercase hex with 0x prefix.
  public func toHex(bytes : [Nat8]) : Text {
    let chars = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"];
    var hex = "0x";
    for (b in bytes.values()) {
      hex #= chars[Nat8.toNat(b / 16)] # chars[Nat8.toNat(b % 16)];
    };
    hex;
  };

  /// Derive an EVM address from a 33-byte compressed secp256k1 public key.
  /// Returns a checksumless 0x-prefixed lowercase hex address (42 chars).
  /// Pipeline: decompress (herumi) → keccak256(x || y) → last 20 bytes
  public func fromCompressedPublicKey(compressedKey : [Nat8]) : Result.Result<Text, Text> {
    if (compressedKey.size() != 33) return #err("Invalid key length");
    let prefix = compressedKey[0];
    if (prefix != 0x02 and prefix != 0x03) return #err("Invalid prefix");

    let x = bytesToNat(Array.subArray(compressedKey, 1, 32));
    let curve = EcdsaCurve.Curve(#secp256k1);
    let isEven = prefix == 0x02;

    let y = switch (curve.getYfromX(#fp(x), isEven)) {
      case (?#fp(yVal)) { yVal };
      case (null) { return #err("Point not on curve") };
    };

    // keccak256(x || y) → last 20 bytes
    let xBytes = Array.subArray(compressedKey, 1, 32);
    let yBytes = natToBytes(y, 32);
    let hash = keccak256(Array.append(xBytes, yBytes));
    let addrBytes = Array.subArray(hash, 12, 20);
    #ok(toHex(addrBytes));
  };
};
