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
    for (b in bytes.vals()) { n := n * 256 + Nat8.toNat(b) };
    n;
  };

  func natToBytes(n : Nat, len : Nat) : [Nat8] {
    let buf = Array.init<Nat8>(len, 0);
    var v = n;
    var i = len;
    while (i > 0) { i -= 1; buf[i] := Nat8.fromNat(v % 256); v := v / 256 };
    Array.freeze(buf);
  };

  // ── EC Recovery (using herumi's ecdsa library) ──

  /// Recover the public key from an ECDSA signature.
  /// Returns compressed SEC1 public key (33 bytes) or null.
  ///
  /// Algorithm: Q = r^(-1) * (s*R - z*G)
  /// Tries both y-parities for R and handles high-S normalization.
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
    for (even in [isEven, not isEven].vals()) {
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
          let rJac = curve.toJacobi(#affine(#fp(rx), ry));

          // u1 = -z * r^(-1) mod n, u2 = s * r^(-1) mod n
          let rInv = curve.Fr.inv(curve.Fr.fromNat(r));
          let u1 = curve.Fr.mul(curve.Fr.neg(curve.Fr.fromNat(z)), rInv);
          let u2 = curve.Fr.mul(curve.Fr.fromNat(s), rInv);

          // Q = u1*G + u2*R
          let qJac = curve.add(curve.mul_base(u1), curve.mul(rJac, u2));

          switch (curve.fromJacobi(qJac)) {
            case (#zero) {};
            case (#affine(#fp(qx), #fp(qy))) {
              let prefix : Nat8 = if (qy % 2 == 0) 0x02 else 0x03;
              return ?Array.append([prefix], natToBytes(qx, 32));
            };
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
    for (b in bytes.vals()) {
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
