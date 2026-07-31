/// ic402 — Shared internal utilities (not exported via lib.mo).
import Types "Types";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Iter "mo:base/Iter";
import Principal "mo:base/Principal";

module {

  /// Saturating Nat subtraction: `a - b`, clamped to 0 — NEVER underflow-traps. Computed in Int so
  /// the subtraction itself can't trap; this replaces the `if (a > b) { a - b } else { 0 }` idiom
  /// and silences M0155 at the call site. Use ONLY where clamp-to-0 is the intended semantic (fees,
  /// refunds, remainders) — NOT for array bounds, where a trap on a broken precondition is correct.
  public func satSub(a : Nat, b : Nat) : Nat {
    let diff : Int = (a : Int) - (b : Int);
    if (diff > 0) { Int.abs(diff) } else { 0 };
  };

  /// Encode a Nat as a big-endian 8-byte array.
  /// WARNING: truncates to the low 64 bits. Use ONLY for genuine 64-bit counters
  /// (nonce counter, chunk index). Do NOT use for secret material — see M-1/M-8.
  public func natToBytes8(n : Nat) : [Nat8] {
    var value = n;
    let bytes = Array.init<Nat8>(8, 0);
    var i = 7 : Nat;
    while (i > 0) {
      bytes[i] := Nat8.fromNat(value % 256);
      value := value / 256;
      i -= 1;
    };
    bytes[0] := Nat8.fromNat(value % 256);
    Array.freeze(bytes);
  };

  /// M-1/M-8: Encode a Nat as its FULL minimal big-endian byte representation
  /// (no truncation). Used for secret/seed material that must preserve all
  /// entropy. Returns a single zero byte for n == 0.
  public func natToBytesBE(n : Nat) : [Nat8] {
    if (n == 0) return [0 : Nat8];
    var byteCount : Nat = 0;
    var v = n;
    while (v > 0) { byteCount += 1; v := v / 256 };
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

  /// Convert ASCII upper-case letters to lower-case.
  public func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
  };

  /// Escape special characters for embedding in a JSON string value.
  /// Prevents JSON injection when user-controlled data is interpolated into JSON.
  public func escapeJsonString(s : Text) : Text {
    var result = "";
    for (c in s.chars()) {
      let n = Char.toNat32(c);
      if (n == 34) { // double quote
        result #= "\\\"";
      } else if (n == 92) { // backslash
        result #= "\\\\";
      } else if (n == 10) { // newline
        result #= "\\n";
      } else if (n == 13) { // carriage return
        result #= "\\r";
      } else if (n == 9) { // tab
        result #= "\\t";
      } else {
        result #= Char.toText(c);
      };
    };
    result;
  };

  /// Extract a JSON string field value by key.
  /// Handles escaped quotes inside values.
  public func extractJsonField(json : Text, field : Text) : Text {
    let needle = "\"" # field # "\":\"";
    let chars = Iter.toArray(json.chars());
    let needleChars = Iter.toArray(needle.chars());
    let len = chars.size();
    let needleLen = needleChars.size();

    var i = 0;
    while (i + needleLen < len) {
      var match = true;
      var j = 0;
      while (j < needleLen) {
        if (chars[i + j] != needleChars[j]) {
          match := false;
          j := needleLen;
        } else {
          j += 1;
        };
      };
      if (match) {
        let start = i + needleLen;
        var end = start;
        // Handle escaped quotes: skip \" sequences
        while (end < len and chars[end] != '\"') {
          if (chars[end] == '\\' and end + 1 < len) {
            end += 2; // skip escaped character
          } else {
            end += 1;
          };
        };
        // M-10: Unescape JSON escape sequences in output
        var result = "";
        var k = start;
        while (k < end) {
          if (Char.toNat32(chars[k]) == 92 and k + 1 < end) { // backslash
            let nextN = Char.toNat32(chars[k + 1]);
            if (nextN == 34) { result #= "\""; k += 2; }       // \"
            else if (nextN == 92) { result #= "\\"; k += 2; }  // \\
            else if (nextN == 110) { result #= "\n"; k += 2; } // \n
            else if (nextN == 116) { result #= "\t"; k += 2; } // \t
            else { result #= Char.toText(chars[k]); k += 1; };
          } else {
            result #= Char.toText(chars[k]);
            k += 1;
          };
        };
        return result;
      };
      i += 1;
    };
    "";
  };

  /// Extract a JSON numeric field value by key (unquoted number).
  /// Handles both "field":123 and "field":"123" (quoted number string).
  public func extractJsonNatField(json : Text, field : Text) : Nat {
    // Try unquoted: "field":123
    let needle1 = "\"" # field # "\":";
    let chars = Iter.toArray(json.chars());
    let needleChars = Iter.toArray(needle1.chars());
    let len = chars.size();

    var i = 0;
    while (i + needleChars.size() < len) {
      var match = true;
      var j = 0;
      while (j < needleChars.size()) {
        if (chars[i + j] != needleChars[j]) { match := false; j := needleChars.size() }
        else { j += 1 };
      };
      if (match) {
        let start = i + needleChars.size();
        // Skip whitespace and opening quote if present
        var pos = start;
        while (pos < len and (chars[pos] == ' ' or chars[pos] == '\"')) { pos += 1 };
        // Parse digits
        var result : Nat = 0;
        while (pos < len) {
          let d = Nat32.toNat(Char.toNat32(chars[pos]));
          if (d >= 48 and d <= 57) { result := result * 10 + (d - 48); pos += 1 }
          else { return result };
        };
        return result;
      };
      i += 1;
    };
    0;
  };

  // ── Base64 ──

  let base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  func base64CharValue(c : Char) : Nat8 {
    let n = Char.toNat32(c);
    if (n >= 65 and n <= 90) { Nat8.fromNat(Nat32.toNat(n - 65)) }       // A-Z
    else if (n >= 97 and n <= 122) { Nat8.fromNat(Nat32.toNat(n - 71)) }  // a-z
    else if (n >= 48 and n <= 57) { Nat8.fromNat(Nat32.toNat(n + 4)) }    // 0-9
    else if (n == 43 or n == 45) { 62 : Nat8 }  // + (standard) or - (base64url)
    else if (n == 47 or n == 95) { 63 : Nat8 }  // / (standard) or _ (base64url)
    else { 255 : Nat8 };             // padding or invalid
  };

  /// Decode a base64-encoded string to bytes — STRICT: any character outside the
  /// standard/URL-safe alphabets (including whitespace), or a misplaced '=', rejects
  /// the WHOLE input (returns []). Unpadded input is accepted (the final 2-/3-char
  /// group decodes); a dangling single char (length % 4 == 1 after padding) is invalid.
  ///
  /// Strictness is deliberate: the previous decoder skipped/truncated around stray
  /// bytes on fixed 4-char windows, so the same header could decode to DIFFERENT bytes
  /// here than in lenient upstream decoders (Node/browsers strip-and-realign) — the
  /// classic parser-differential surface. Reject-all removes it; callers already treat
  /// [] as "invalid header" (fail-closed).
  public func base64Decode(encoded : Text) : [Nat8] {
    let chars = Iter.toArray(encoded.chars());
    // Strip at most two trailing '=' padding chars; any other '=' is rejected below.
    var dataLen = chars.size();
    if (dataLen > 0 and chars[dataLen - 1] == '=') { dataLen -= 1 };
    if (dataLen > 0 and chars[dataLen - 1] == '=') { dataLen -= 1 };
    if (dataLen % 4 == 1) { return [] }; // no byte count yields a lone trailing char
    let buf = Buffer.Buffer<Nat8>(dataLen * 3 / 4);
    var i = 0;
    var acc : Nat = 0; // bit accumulator
    var bits : Nat = 0; // bits currently held in acc
    while (i < dataLen) {
      let v = base64CharValue(chars[i]);
      if (v == 255) { return [] };
      acc := acc * 64 + Nat8.toNat(v);
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        buf.add(Nat8.fromNat((acc / (2 ** bits)) % 256));
        acc := acc % (2 ** bits);
      };
      i += 1;
    };
    Buffer.toArray(buf);
  };

  /// Encode bytes as base64.
  public func base64Encode(data : [Nat8]) : Text {
    let b64 = Iter.toArray(base64Chars.chars());
    var result = "";
    var i = 0;
    while (i + 2 < data.size()) {
      let a = Nat8.toNat(data[i]);
      let b = Nat8.toNat(data[i + 1]);
      let c = Nat8.toNat(data[i + 2]);
      result #= Text.fromChar(b64[a / 4]);
      result #= Text.fromChar(b64[(a % 4) * 16 + b / 16]);
      result #= Text.fromChar(b64[(b % 16) * 4 + c / 64]);
      result #= Text.fromChar(b64[c % 64]);
      i += 3;
    };
    if (i + 1 == data.size()) {
      let a = Nat8.toNat(data[i]);
      result #= Text.fromChar(b64[a / 4]);
      result #= Text.fromChar(b64[(a % 4) * 16]);
      result #= "==";
    } else if (i + 2 == data.size()) {
      let a = Nat8.toNat(data[i]);
      let b = Nat8.toNat(data[i + 1]);
      result #= Text.fromChar(b64[a / 4]);
      result #= Text.fromChar(b64[(a % 4) * 16 + b / 16]);
      result #= Text.fromChar(b64[(b % 16) * 4]);
      result #= "=";
    };
    result;
  };

  // ── Shared helpers (used by Gateway and Sessions) ──

  /// Check if a CAIP-2 network string is an EVM network (eip155:*).
  public func isEvmNetwork(network : Text) : Bool {
    Text.startsWith(network, #text "eip155:");
  };

  /// Extract the chain ID from a CAIP-2 EVM network string (e.g., "eip155:8453" -> ?8453).
  public func extractChainId(network : Text) : ?Nat {
    let parts = Text.split(network, #char ':');
    let arr = Iter.toArray(parts);
    if (arr.size() != 2) return null;
    // Simple decimal parse
    var result : Nat = 0;
    for (c in arr[1].chars()) {
      let d = Nat32.toNat(Char.toNat32(c));
      if (d < 48 or d > 57) return null;
      result := result * 10 + (d - 48);
    };
    ?result;
  };

  /// What a self-arming expiry sweep should do at the end of a tick. Pure (module-level →
  /// unit-testable without a live timer, which is why the decision lives here rather than inline
  /// in the callback: a timer callback never fires under `mops test`).
  ///
  /// A recurring timer is billed per TICK — the message-execution base fee — regardless of what
  /// its callback does, so a sweep with nothing to sweep should stop ticking rather than guard
  /// inside the body. `idlePollSeconds == 0` means "disarm outright" (safe only when every path
  /// that creates work can arm the timer back); otherwise the sweep drops to a slow poll that
  /// notices work created by a path that could not arm it.
  public type ExpiryCadence = {
    #stay; // already on the right cadence
    #switchToFast; // idle poll found work → resume the working cadence
    #switchToIdle; // working cadence found nothing left → drop to the slow poll
    #disarm; // nothing left and no idle poll configured → stop ticking entirely
  };

  public func expiryCadence(hasWork : Bool, fastMode : Bool, idlePollSeconds : Nat) : ExpiryCadence {
    if (hasWork) { if (fastMode) { #stay } else { #switchToFast } } else if (idlePollSeconds == 0) {
      #disarm;
    } else if (fastMode) { #switchToIdle } else { #stay };
  };

  /// Find a token config by principal text or CAIP-2 network prefix.
  /// Accepts both "ryjl3-tyaaa-..." (principal) and "icp:1" (network).
  /// For ICP networks, returns the first configured token since ICP
  /// canister configs typically have a single ledger.
  public func findLedger(tokens : [Types.TokenConfig], identifier : Text) : ?Types.TokenConfig {
    for (t in tokens.vals()) {
      if (Principal.toText(t.ledger) == identifier) return ?t;
    };
    // CAIP-2 network match: "icp:*" matches any configured ICP token
    if (Text.startsWith(identifier, #text "icp:")) {
      if (tokens.size() > 0) return ?tokens[0];
    };
    null;
  };
};
