/// ic402 — Shared internal utilities (not exported via lib.mo).
import Nat8 "mo:base/Nat8";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Iter "mo:base/Iter";

module {

  /// Encode a Nat as a big-endian 8-byte array.
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

  /// Convert ASCII upper-case letters to lower-case.
  public func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
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
        var result = "";
        var k = start;
        while (k < end) {
          result := result # Char.toText(chars[k]);
          k += 1;
        };
        return result;
      };
      i += 1;
    };
    "";
  };
};
