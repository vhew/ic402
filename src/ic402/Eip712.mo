/// ic402 — EIP-712 typed data hashing for EIP-3009 TransferWithAuthorization.
///
/// Implements the EIP-712 signature verification needed for standard x402
/// payment settlement. The canister verifies that a payer's signature
/// authorizes a USDC transfer, then executes it on-chain.
///
/// References:
///   EIP-712: https://eips.ethereum.org/EIPS/eip-712
///   EIP-3009: https://eips.ethereum.org/EIPS/eip-3009

import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import EvmAddress "EvmAddress";
import EvmUtils "EvmUtils";

module {

  // ═══════════════════════════════════════════════════════════════════════
  // Constants (precomputed keccak256 hashes)
  // ═══════════════════════════════════════════════════════════════════════

  // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
  let EIP712_DOMAIN_TYPEHASH : [Nat8] = [
    0x8b, 0x73, 0xc3, 0xc6, 0x9b, 0xb8, 0xfe, 0x3d,
    0x51, 0x2e, 0xcc, 0x4c, 0xf7, 0x59, 0xcc, 0x79,
    0x23, 0x9f, 0x7b, 0x17, 0x9b, 0x0f, 0xfa, 0xca,
    0xa9, 0xa7, 0x5d, 0x52, 0x2b, 0x39, 0x40, 0x0f,
  ];

  // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
  let TRANSFER_WITH_AUTH_TYPEHASH : [Nat8] = [
    0x7c, 0x7c, 0x6c, 0xdb, 0x67, 0xa1, 0x87, 0x43,
    0xf4, 0x9e, 0xc6, 0xfa, 0x9b, 0x35, 0xf5, 0x0d,
    0x52, 0xed, 0x05, 0xcb, 0xed, 0x4c, 0xc5, 0x92,
    0xe1, 0x3b, 0x44, 0x50, 0x1c, 0x1a, 0x22, 0x67,
  ];

  // keccak256("USD Coin")
  let USDC_NAME_HASH : [Nat8] = [
    0x52, 0x87, 0x8b, 0x20, 0x7a, 0xad, 0xdb, 0xfc,
    0x15, 0xea, 0x7b, 0xeb, 0xcd, 0xa6, 0x81, 0xeb,
    0x8c, 0xcd, 0x30, 0x6e, 0x22, 0x27, 0xb6, 0x1c,
    0xef, 0x68, 0x50, 0x5c, 0x8c, 0x05, 0x63, 0x41,
  ];

  // keccak256("2")
  let USDC_VERSION_HASH : [Nat8] = [
    0xad, 0x7c, 0x5b, 0xef, 0x02, 0x78, 0x16, 0xa8,
    0x00, 0xda, 0x17, 0x36, 0x44, 0x4f, 0xb5, 0x8a,
    0x80, 0x7e, 0xf4, 0xc9, 0x60, 0x3b, 0x78, 0x48,
    0x67, 0x3f, 0x7e, 0x3a, 0x68, 0xeb, 0x14, 0xa5,
  ];

  // ═══════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════

  /// Compute the EIP-712 domain separator for a USDC contract.
  /// USDC uses name="USD Coin", version="2" across all chains.
  public func usdcDomainSeparator(chainId : Nat, tokenAddress : [Nat8]) : [Nat8] {
    // keccak256(abi.encode(typeHash, nameHash, versionHash, chainId, verifyingContract))
    let encoded = abiEncodeWords([
      EIP712_DOMAIN_TYPEHASH,
      USDC_NAME_HASH,
      USDC_VERSION_HASH,
      EvmUtils.natToBytes(chainId, 32),
      leftPadAddress(tokenAddress),
    ]);
    EvmAddress.keccak256(encoded);
  };

  /// Compute the EIP-712 domain separator from custom name/version (non-USDC tokens).
  public func domainSeparator(name : Text, version : Text, chainId : Nat, tokenAddress : [Nat8]) : [Nat8] {
    let nameHash = EvmAddress.keccak256Text(name);
    let versionHash = EvmAddress.keccak256Text(version);
    let encoded = abiEncodeWords([
      EIP712_DOMAIN_TYPEHASH,
      nameHash,
      versionHash,
      EvmUtils.natToBytes(chainId, 32),
      leftPadAddress(tokenAddress),
    ]);
    EvmAddress.keccak256(encoded);
  };

  /// Hash the TransferWithAuthorization struct.
  public func hashTransferWithAuthorization(
    from : [Nat8],    // 20 bytes
    to : [Nat8],      // 20 bytes
    value : Nat,
    validAfter : Nat,
    validBefore : Nat,
    nonce : [Nat8],   // 32 bytes
  ) : [Nat8] {
    let encoded = abiEncodeWords([
      TRANSFER_WITH_AUTH_TYPEHASH,
      leftPadAddress(from),
      leftPadAddress(to),
      EvmUtils.natToBytes(value, 32),
      EvmUtils.natToBytes(validAfter, 32),
      EvmUtils.natToBytes(validBefore, 32),
      nonce,
    ]);
    EvmAddress.keccak256(encoded);
  };

  /// Compute the full EIP-712 digest: keccak256("\x19\x01" || domainSeparator || structHash)
  public func digest(domainSep : [Nat8], structHash : [Nat8]) : [Nat8] {
    let prefix : [Nat8] = [0x19, 0x01];
    let middle = Array.append<Nat8>(prefix, domainSep);
    EvmAddress.keccak256(Array.append<Nat8>(middle, structHash));
  };

  /// Get the TransferWithAuthorization type hash.
  public func transferWithAuthorizationTypeHash() : [Nat8] {
    TRANSFER_WITH_AUTH_TYPEHASH;
  };

  /// Recover the signer of a TransferWithAuthorization EIP-712 signature.
  /// Uses custom token name/version for the domain separator (handles testnet USDC).
  /// Returns the recovered signer address (20 bytes) or null if verification fails.
  public func recoverAuthorizationSigner(
    chainId : Nat,
    tokenAddress : [Nat8],
    from : [Nat8],
    to : [Nat8],
    value : Nat,
    validAfter : Nat,
    validBefore : Nat,
    nonce : [Nat8],
    v : Nat8,
    r : [Nat8],
    s : [Nat8],
    tokenName : ?Text,
    tokenVersion : ?Text,
  ) : ?[Nat8] {
    let name = switch (tokenName) { case (?n) { n }; case (null) { "USD Coin" } };
    let version = switch (tokenVersion) { case (?v) { v }; case (null) { "2" } };
    let domSep = domainSeparator(name, version, chainId, tokenAddress);
    let structHash = hashTransferWithAuthorization(from, to, value, validAfter, validBefore, nonce);
    let msgHash = digest(domSep, structHash);

    // ecRecover tries both y-parities internally, so we just normalize v
    // to 0/1 range and pass the original s (ecRecover handles high-S via
    // its parity loop).
    let recoveryBit : Nat8 = if (v >= 27) { v - 27 } else { v };
    let recoveredPubKey = switch (EvmAddress.ecRecover(msgHash, r, s, recoveryBit)) {
      case (?pk) { pk };
      case (null) { return null };
    };

    switch (EvmAddress.fromCompressedPublicKey(recoveredPubKey)) {
      case (#ok(addrHex)) { ?EvmUtils.hexToBytes(addrHex) };
      case (#err(_)) { null };
    };
  };

  /// Verify that the authorization is signed by the `from` address.
  /// Accepts optional token name/version for testnet USDC domain separators.
  public func verifyAuthorization(
    chainId : Nat,
    tokenAddress : [Nat8],
    from : [Nat8],
    to : [Nat8],
    value : Nat,
    validAfter : Nat,
    validBefore : Nat,
    nonce : [Nat8],
    v : Nat8,
    r : [Nat8],
    s : [Nat8],
    tokenName : ?Text,
    tokenVersion : ?Text,
  ) : Bool {
    switch (recoverAuthorizationSigner(chainId, tokenAddress, from, to, value, validAfter, validBefore, nonce, v, r, s, tokenName, tokenVersion)) {
      case (?recovered) { equalBytes(recovered, from) };
      case (null) { false };
    };
  };

  /// Function selector for transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)
  public func transferWithAuthorizationSelector() : [Nat8] {
    // 0xe3ee160e
    [0xe3, 0xee, 0x16, 0x0e];
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Internal helpers
  // ═══════════════════════════════════════════════════════════════════════

  // Concatenate 32-byte words into a single byte array.
  func abiEncodeWords(words : [[Nat8]]) : [Nat8] {
    var result : [Nat8] = [];
    for (w in words.vals()) {
      assert(w.size() == 32);
      result := Array.append(result, w);
    };
    result;
  };

  // Left-pad a 20-byte address to 32 bytes.
  func leftPadAddress(addr : [Nat8]) : [Nat8] {
    assert(addr.size() == 20);
    Array.append(Array.freeze(Array.init<Nat8>(12, 0 : Nat8)), addr);
  };

  // Constant-time byte array comparison.
  func equalBytes(a : [Nat8], b : [Nat8]) : Bool {
    if (a.size() != b.size()) return false;
    var acc : Nat8 = 0;
    var i = 0;
    while (i < a.size()) {
      acc := acc | (a[i] ^ b[i]);
      i += 1;
    };
    acc == 0;
  };
};
