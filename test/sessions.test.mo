/// Motoko unit tests for Sessions pure functions.
import Sessions "../src/ic402/Sessions";
import { test; suite } "mo:test";

suite("Sessions", func() {

  // ── encodeVoucherPayload ──

  suite("encodeVoucherPayload", func() {

    test("basic encoding returns Some", func() {
      switch (Sessions.encodeVoucherPayload("sess-1", 100, 1)) {
        case (?bytes) {
          // CBOR array(3): should start with 0x83 (major type 4, length 3)
          assert(bytes.size() > 0);
          assert(bytes[0] == 0x83);
        };
        case (null) { assert(false) };
      };
    });

    test("zero values encode successfully", func() {
      switch (Sessions.encodeVoucherPayload("sess-1", 0, 0)) {
        case (?bytes) {
          assert(bytes.size() > 0);
          assert(bytes[0] == 0x83);
        };
        case (null) { assert(false) };
      };
    });

    test("H-2: overflow returns null for cumulativeAmount > Nat64 max", func() {
      let maxNat64 : Nat = 18_446_744_073_709_551_615;
      switch (Sessions.encodeVoucherPayload("sess-1", maxNat64 + 1, 1)) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });

    test("H-2: overflow returns null for sequence > Nat64 max", func() {
      let maxNat64 : Nat = 18_446_744_073_709_551_615;
      switch (Sessions.encodeVoucherPayload("sess-1", 1, maxNat64 + 1)) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });

    test("max Nat64 edge case succeeds", func() {
      let maxNat64 : Nat = 18_446_744_073_709_551_615;
      switch (Sessions.encodeVoucherPayload("s", maxNat64, maxNat64)) {
        case (?bytes) { assert(bytes.size() > 0) };
        case (null) { assert(false) };
      };
    });

    test("different inputs produce different outputs", func() {
      let a = Sessions.encodeVoucherPayload("sess-1", 100, 1);
      let b = Sessions.encodeVoucherPayload("sess-1", 200, 1);
      let c = Sessions.encodeVoucherPayload("sess-2", 100, 1);

      switch (a, b) {
        case (?ba, ?bb) { assert(ba != bb) };
        case (_, _) { assert(false) };
      };
      switch (a, c) {
        case (?ba, ?bc) { assert(ba != bc) };
        case (_, _) { assert(false) };
      };
    });
  });
});
