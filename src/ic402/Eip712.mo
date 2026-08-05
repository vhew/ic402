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
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import Buffer "mo:base/Buffer";
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
    // L19/L28: reject malformed field lengths HERE (return false) rather than letting the ABI
    // encoders below assert-trap. tokenAddress/from/to must be 20-byte addresses; nonce/r/s must be
    // 32-byte words. These arrive as caller-controlled hex on the UNAUTHENTICATED verify / settle /
    // openEvmSession paths, so a bad length must be a graceful verification failure, not a canister
    // trap (a trap also rolls back the SEC-1 admission-token decrement in the same message, leaving
    // the malformed flood unmetered).
    if (
      tokenAddress.size() != 20 or from.size() != 20 or to.size() != 20
      or nonce.size() != 32 or r.size() != 32 or s.size() != 32
    ) {
      return false;
    };
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
  // Field-driven encoding (generic flat structs)
  // ═══════════════════════════════════════════════════════════════════════
  //
  // A caller-supplied ordered [(fieldName, solidityType)] plus matching values, encoded per
  // EIP-712: canonical type string → typeHash → encodeData → hashStruct. Pair the result with
  // domainSeparator()/digest() above and EvmSigner.signTypedData — the struct's CONTENTS are
  // then visible and validated at the signing boundary, instead of arriving as an opaque
  // 32-byte hash nothing can audit.
  //
  // DELIBERATELY FLAT AND ATOMIC: address, bool, string, bytes, bytes1..32, uint8..256 — no
  // arrays, no nested structs, no int*. Nested/array support drags in transitive type
  // collection and the alphabetical dependency-sorting rule, whose failure mode is the
  // dangerous one: a VALID signature over the WRONG struct. Requests for those types are
  // rejected at the boundary with an error saying so, which is strictly better than encoding
  // them subtly wrong. Every entry point is trap-free (#err, never assert) — inputs may be
  // relayed from untrusted callers.
  //
  // AUDIT NOTE for layers rendering "what am I signing": `string`/`bytes` words in encodeData
  // are keccak256 DIGESTS of the contents (per spec). Render human-readable views from the
  // FieldValues themselves, never by decoding encodeData — a digest rendered as data would
  // show garbage while still verifying.

  /// A value for one field of a flat EIP-712 struct. The tag must match the field's DECLARED
  /// type (`#uint` for `uint8..256`, `#fixedBytes` for `bytes1..32`, `#bytes` only for dynamic
  /// `bytes`, …) — a mismatch is an #err, not a coercion.
  public type FieldValue = {
    #address : Text; // 0x-prefixed 40-hex-char EVM address (any case; encoded as raw bytes)
    #uint : Nat; // range-checked against the declared uintN width
    #bool : Bool;
    #string : Text; // dynamic: encoded as keccak256(utf8 bytes)
    #bytes : [Nat8]; // dynamic: encoded as keccak256(contents)
    #fixedBytes : [Nat8]; // bytesN: size must EQUAL the declared N; right-padded to 32
  };

  // Parsed form of a declared solidity type (whitelist — see the module note on exclusions).
  type ParsedType = {
    #address;
    #bool;
    #string;
    #bytes;
    #uint : Nat; // bit width 8..256, multiple of 8
    #fixedBytes : Nat; // byte width 1..32
  };

  // Strict decimal parse: pure digits, no leading zero (solidity type names never carry one —
  // "uint08"/"bytes08" are not types, and accepting them would let two spellings of one type
  // produce different canonical strings).
  func parseWidth(t : Text) : ?Nat {
    let chars = Iter.toArray(t.chars());
    if (chars.size() == 0 or chars.size() > 3) return null;
    if (chars[0] == '0') return null;
    var n = 0;
    for (c in chars.vals()) {
      if (c < '0' or c > '9') return null;
      n := n * 10 + (Nat32.toNat(Char.toNat32(c)) - 48);
    };
    ?n;
  };

  // True when every char is a decimal digit (and non-empty) — used to tell a signed-integer
  // TYPE ("int", "int256") from an int-prefixed IDENTIFIER ("intent"), so rejections name the
  // real reason.
  func isAllDigits(t : Text) : Bool {
    var any = false;
    for (c in t.chars()) { if (c < '0' or c > '9') return false; any := true };
    any;
  };

  func parseFieldType(t : Text) : { #ok : ParsedType; #err : Text } {
    // Array check FIRST: 'uint256[]' must be rejected AS AN ARRAY, not as a bad uint width —
    // an error claiming "invalid width" about a valid width would send the caller retrying
    // uint128[]/uint64[]… without ever learning that arrays are categorically out of scope.
    if (Text.contains(t, #char '[')) {
      return #err("array type '" # t # "' is DELIBERATELY unsupported (flat atomic fields only — arrays require encoding rules this encoder refuses to risk getting subtly wrong)");
    };
    if (t == "address") return #ok(#address);
    if (t == "bool") return #ok(#bool);
    if (t == "string") return #ok(#string);
    if (t == "bytes") return #ok(#bytes);
    switch (Text.stripStart(t, #text "uint")) {
      case (?rest) {
        switch (parseWidth(rest)) {
          case (?n) { if (n >= 8 and n <= 256 and n % 8 == 0) return #ok(#uint(n)) };
          case (null) {};
        };
        if (rest == "") return #err("type 'uint' is not canonical EIP-712 — spell it 'uint256'");
        if (isAllDigits(rest)) return #err("invalid uint width in '" # t # "' (uint8..uint256, multiples of 8)");
      };
      case (null) {};
    };
    switch (Text.stripStart(t, #text "bytes")) {
      case (?rest) {
        switch (parseWidth(rest)) {
          case (?n) { if (n >= 1 and n <= 32) return #ok(#fixedBytes(n)) };
          case (null) {};
        };
        if (isAllDigits(rest)) return #err("invalid bytes width in '" # t # "' (bytes1..bytes32, or dynamic 'bytes')");
      };
      case (null) {};
    };
    if (t == "int" or (Text.stripStart(t, #text "int") != null and isAllDigits(Option.get(Text.stripStart(t, #text "int"), "")))) {
      return #err("signed type '" # t # "' is DELIBERATELY unsupported (flat unsigned/atomic fields only)");
    };
    #err("type '" # t # "' is not a supported atomic type — nested structs and non-atomic types are DELIBERATELY unsupported (they require transitive type collection + alphabetical dependency sorting, whose failure mode is a valid signature over the wrong struct)");
  };

  // Identifier check for struct and field names: [A-Za-z_][A-Za-z0-9_]*. This is
  // SECURITY-CRITICAL, not cosmetics: names are interpolated into the canonical type string,
  // so a name like "a,address evil)Other(" would alias a DIFFERENT type than the one any
  // auditor reviewed — a valid signature over an unreviewed struct.
  func isIdentifier(t : Text) : Bool {
    let chars = Iter.toArray(t.chars());
    if (chars.size() == 0) return false;
    var i = 0;
    for (c in chars.vals()) {
      let alpha = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
      let digit = c >= '0' and c <= '9';
      if (not (alpha or (i > 0 and digit))) return false;
      i += 1;
    };
    true;
  };

  // Hard cap on field count. Real EIP-712 structs have a handful of fields (venue order
  // structs run ~10-20); the cap exists because validation below is O(n²) in fields.size()
  // (the duplicate-name scan) and the module promises NEVER to trap on relayed untrusted
  // input — an uncapped multi-thousand-field list would blow the IC per-message instruction
  // limit inside the loop, and a trap rolls back the caller's SEC-1 admission-token decrement
  // (the exact metering bypass the L19/L28 comment on verifyAuthorization guards against).
  let MAX_FIELDS : Nat = 64;

  // Validate the struct shape shared by every entry point: identifiers, whitelisted types,
  // no duplicate field names, at least one field, bounded field count, and a struct NAME that
  // no standard EIP-712 implementation treats specially.
  func validateFields(structName : Text, fields : [(Text, Text)]) : { #ok : [ParsedType]; #err : Text } {
    if (not isIdentifier(structName)) {
      return #err("struct name '" # structName # "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*) — names are interpolated into the canonical type string, so anything else could alias a different type");
    };
    // Reserved: EIP-712 gives "EIP712Domain" protocol semantics. viem/ethers DROP the struct
    // part of the digest when primaryType is EIP712Domain (domain-only signing), so no
    // standard tool could ever verify a digest built from this struct — and worse, its
    // hashStruct over the standard domain fields IS a byte-identical domain separator, ripe
    // for parameter-swap confusion in digest(domainSep, structHash).
    if (structName == "EIP712Domain") {
      return #err("struct name 'EIP712Domain' is reserved by EIP-712 — standard implementations sign the DOMAIN ONLY for this primaryType, so a digest built from it is unverifiable everywhere; name your struct something else");
    };
    // Atomic-shadowing names: in an EIP-712 `types` map a struct named "address"/"uint256"/…
    // SHADOWS the atomic type, so viem refuses such names outright (InvalidStructTypeError —
    // exact "address"/"bool"/"string" or any "bytes"/"uint"/"int" prefix) the moment the name
    // is referenced, which the standard domain fields (string/uint256/address) always do.
    // A signature over such a struct would be unverifiable by standard tooling; reject to
    // match viem's rule exactly.
    if (
      structName == "address" or structName == "bool" or structName == "string"
      or Text.startsWith(structName, #text "bytes") or Text.startsWith(structName, #text "uint")
      or Text.startsWith(structName, #text "int")
    ) {
      return #err("struct name '" # structName # "' shadows a solidity atomic type family — viem/ethers reject or misencode types maps containing it, so a signature over this struct would be unverifiable by standard tooling; choose a name not starting with 'uint'/'bytes'/'int' and not 'address'/'bool'/'string'");
    };
    if (fields.size() == 0) {
      return #err("empty field list — a zero-field struct signs nothing reviewable; declare at least one field");
    };
    if (fields.size() > MAX_FIELDS) {
      return #err("too many fields (" # Nat.toText(fields.size()) # " > " # Nat.toText(MAX_FIELDS) # ") — real EIP-712 structs have a handful; the cap keeps validation safely inside the IC per-message instruction budget on relayed input");
    };
    let parsed = Buffer.Buffer<ParsedType>(fields.size());
    var i = 0;
    for ((name, ty) in fields.vals()) {
      if (not isIdentifier(name)) {
        return #err("field name '" # name # "' is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)");
      };
      var j = 0;
      for ((other, _) in fields.vals()) {
        if (j < i and other == name) {
          return #err("duplicate field name '" # name # "' — an audit rendering could not distinguish the two");
        };
        j += 1;
      };
      switch (parseFieldType(ty)) {
        case (#ok(p)) { parsed.add(p) };
        case (#err(e)) { return #err("field '" # name # "': " # e) };
      };
      i += 1;
    };
    #ok(Buffer.toArray(parsed));
  };

  /// (a) The canonical EIP-712 type string: `Name(type1 field1,type2 field2,…)`.
  /// This is the reviewable artifact — an audit/registration layer should store and display
  /// exactly this string, because its keccak256 is the typeHash the signature commits to.
  public func encodeTypeString(structName : Text, fields : [(Text, Text)]) : { #ok : Text; #err : Text } {
    switch (validateFields(structName, fields)) {
      case (#err(e)) { return #err(e) };
      case (#ok(_)) {};
    };
    var s = structName # "(";
    var first = true;
    for ((name, ty) in fields.vals()) {
      if (not first) { s #= "," };
      s #= ty # " " # name;
      first := false;
    };
    #ok(s # ")");
  };

  /// (b) keccak256 of the canonical type string.
  public func typeHashOf(structName : Text, fields : [(Text, Text)]) : { #ok : [Nat8]; #err : Text } {
    switch (encodeTypeString(structName, fields)) {
      case (#ok(s)) { #ok(EvmAddress.keccak256Text(s)) };
      case (#err(e)) { #err(e) };
    };
  };

  // Encode one validated (type, value) pair to its 32-byte word.
  func encodeWord(name : Text, ty : ParsedType, v : FieldValue) : { #ok : [Nat8]; #err : Text } {
    switch (ty, v) {
      case (#address, #address(hex)) {
        if (not Text.startsWith(hex, #text "0x")) {
          return #err("field '" # name # "': address must be 0x-prefixed");
        };
        let bytes = EvmUtils.hexToBytes(hex);
        if (bytes.size() != 20) {
          return #err("field '" # name # "': address must be exactly 20 bytes of hex (40 hex chars)");
        };
        #ok(Array.append(Array.freeze(Array.init<Nat8>(12, 0 : Nat8)), bytes));
      };
      case (#uint(width), #uint(n)) {
        if (n >= 2 ** width) {
          return #err("field '" # name # "': value does not fit uint" # Nat.toText(width));
        };
        #ok(EvmUtils.natToBytes(n, 32));
      };
      case (#bool, #bool(b)) {
        #ok(EvmUtils.natToBytes(if (b) { 1 } else { 0 }, 32));
      };
      case (#string, #string(s)) {
        #ok(EvmAddress.keccak256Text(s)); // dynamic: hash of contents, per spec
      };
      case (#bytes, #bytes(b)) {
        #ok(EvmAddress.keccak256(b)); // dynamic: hash of contents, per spec
      };
      case (#fixedBytes(width), #fixedBytes(b)) {
        if (b.size() != width) {
          return #err("field '" # name # "': bytes" # Nat.toText(width) # " value must be exactly " # Nat.toText(width) # " bytes (got " # Nat.toText(b.size()) # ") — no implicit padding of the VALUE; the word is right-padded per spec");
        };
        #ok(Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { if (i < width) { b[i] } else { 0 } }));
      };
      case (_, _) {
        #err("field '" # name # "': supplied value tag does not match the declared type — no coercion (e.g. dynamic 'bytes' takes #bytes, 'bytes32' takes #fixedBytes)");
      };
    };
  };

  /// (c) encodeData per EIP-712: the concatenation of each field's 32-byte word, in declared
  /// order. Does NOT include the typeHash (hashStructOf prepends it). `string`/`bytes` words
  /// are keccak256 digests of the contents — see the module audit note.
  public func encodeData(structName : Text, fields : [(Text, Text)], values : [FieldValue]) : { #ok : [Nat8]; #err : Text } {
    let parsed = switch (validateFields(structName, fields)) {
      case (#ok(p)) { p };
      case (#err(e)) { return #err(e) };
    };
    if (values.size() != fields.size()) {
      return #err("field/value arity mismatch: " # Nat.toText(fields.size()) # " fields, " # Nat.toText(values.size()) # " values");
    };
    let out = Buffer.Buffer<Nat8>(fields.size() * 32);
    var i = 0;
    for ((name, _) in fields.vals()) {
      switch (encodeWord(name, parsed[i], values[i])) {
        case (#ok(word)) { for (b in word.vals()) { out.add(b) } };
        case (#err(e)) { return #err(e) };
      };
      i += 1;
    };
    #ok(Buffer.toArray(out));
  };

  /// hashStruct = keccak256(typeHash ‖ encodeData) — the value to pair with domainSeparator()
  /// in digest(), and what EvmSigner.signTypedData should be handed as structHash.
  public func hashStructOf(structName : Text, fields : [(Text, Text)], values : [FieldValue]) : { #ok : [Nat8]; #err : Text } {
    let th = switch (typeHashOf(structName, fields)) {
      case (#ok(h)) { h };
      case (#err(e)) { return #err(e) };
    };
    switch (encodeData(structName, fields, values)) {
      case (#ok(data)) { #ok(EvmAddress.keccak256(Array.append(th, data))) };
      case (#err(e)) { #err(e) };
    };
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
