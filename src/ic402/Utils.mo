// ic402 — Shared internal utilities (not exported via lib.mo).
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Iter "mo:base/Iter";

module {

  // Encode a Nat as a big-endian 8-byte array.
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

  // Convert ASCII upper-case letters to lower-case.
  public func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
  };

  // Escape special characters for embedding in a JSON string value.
  // Prevents JSON injection when user-controlled data is interpolated into JSON.
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

  // Extract a JSON string field value by key.
  // Handles escaped quotes inside values.
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

  // Extract a JSON numeric field value by key (unquoted number).
  // Handles both "field":123 and "field":"123" (quoted number string).
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
    else if (n == 43) { 62 : Nat8 }  // +
    else if (n == 47) { 63 : Nat8 }  // /
    else { 255 : Nat8 };             // padding or invalid
  };

  // Decode a base64-encoded string to bytes. Returns empty on invalid input.
  public func base64Decode(encoded : Text) : [Nat8] {
    let chars = Iter.toArray(encoded.chars());
    let buf = Buffer.Buffer<Nat8>(chars.size() * 3 / 4);
    var i = 0;
    while (i + 3 < chars.size()) {
      let a = base64CharValue(chars[i]);
      let b = base64CharValue(chars[i + 1]);
      let c = base64CharValue(chars[i + 2]);
      let d = base64CharValue(chars[i + 3]);
      if (a == 255 or b == 255) { return Buffer.toArray(buf) };

      buf.add(Nat8.fromNat(Nat8.toNat(a) * 4 + Nat8.toNat(b) / 16));
      if (c != 255) {
        buf.add(Nat8.fromNat((Nat8.toNat(b) % 16) * 16 + Nat8.toNat(c) / 4));
        if (d != 255) {
          buf.add(Nat8.fromNat((Nat8.toNat(c) % 4) * 64 + Nat8.toNat(d)));
        };
      };
      i += 4;
    };
    Buffer.toArray(buf);
  };

  // Encode bytes as base64.
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
};
