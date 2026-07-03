/// Motoko unit tests for Sessions pure functions.
import Sessions "../src/ic402/Sessions";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import { test; suite } "mo:test";

suite("Sessions", func() {

  // ── encodeVoucherPayload ──

  suite("encodeVoucherPayload", func() {

    test("basic encoding returns Some", func() {
      switch (Sessions.encodeVoucherPayload("cid-1", "sess-1", 100, 1)) {
        case (?bytes) {
          // CBOR array(4): should start with 0x84 (major type 4, length 3)
          assert(bytes.size() > 0);
          assert(bytes[0] == 0x84);
        };
        case (null) { assert(false) };
      };
    });

    test("zero values encode successfully", func() {
      switch (Sessions.encodeVoucherPayload("cid-1", "sess-1", 0, 0)) {
        case (?bytes) {
          assert(bytes.size() > 0);
          assert(bytes[0] == 0x84);
        };
        case (null) { assert(false) };
      };
    });

    test("H-2: overflow returns null for cumulativeAmount > Nat64 max", func() {
      let maxNat64 : Nat = 18_446_744_073_709_551_615;
      switch (Sessions.encodeVoucherPayload("cid-1", "sess-1", maxNat64 + 1, 1)) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });

    test("H-2: overflow returns null for sequence > Nat64 max", func() {
      let maxNat64 : Nat = 18_446_744_073_709_551_615;
      switch (Sessions.encodeVoucherPayload("cid-1", "sess-1", 1, maxNat64 + 1)) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });

    test("max Nat64 edge case succeeds", func() {
      let maxNat64 : Nat = 18_446_744_073_709_551_615;
      switch (Sessions.encodeVoucherPayload("cid-1", "s", maxNat64, maxNat64)) {
        case (?bytes) { assert(bytes.size() > 0) };
        case (null) { assert(false) };
      };
    });

    test("different inputs produce different outputs", func() {
      let a = Sessions.encodeVoucherPayload("cid-1", "sess-1", 100, 1);
      let b = Sessions.encodeVoucherPayload("cid-1", "sess-1", 200, 1);
      let c = Sessions.encodeVoucherPayload("cid-1", "sess-2", 100, 1);

      switch (a, b) {
        case (?ba, ?bb) { assert(ba != bb) };
        case (_, _) { assert(false) };
      };
      switch (a, c) {
        case (?ba, ?bc) { assert(ba != bc) };
        case (_, _) { assert(false) };
      };
    });

    // CROSS-BOUNDARY GOLDEN VECTOR: packages/client/test/voucher.test.ts asserts the client's cborg
    // encoder produces this SAME byte string. mo:cbor (here) and cborg (client) must agree exactly or
    // a signed voucher will not verify — the check that was missing when a voucher-payload divergence
    // (e.g. the M-7 canisterId binding) could only surface on a live session.
    test("matches the cross-boundary golden vector (aaaaa-aa / sess-1 / 1000 / 2)", func() {
      let expected : [Nat8] = [132, 104, 97, 97, 97, 97, 97, 45, 97, 97, 102, 115, 101, 115, 115, 45, 49, 25, 3, 232, 2];
      switch (Sessions.encodeVoucherPayload("aaaaa-aa", "sess-1", 1000, 2)) {
        case (?bytes) { assert Array.equal<Nat8>(bytes, expected, Nat8.equal) };
        case (null) { assert(false) };
      };
    });
  });

  // ── sessionReconcileDecision (v2.1.1 recovery — two-phase close) ──

  suite("sessionReconcileDecision (confirm-only close matrix)", func() {
    // GOLDEN RULE: finalize ONLY on #confirmed; never on #pending/#reverted/#err.
    test("#pending / #reverted / #err always stay parked", func() {
      switch (Sessions.sessionReconcileDecision(#pending, #Settle, 100)) { case (#stay(_)) {}; case (_) { assert false } };
      switch (Sessions.sessionReconcileDecision(#pending, #Refund, 0)) { case (#stay(_)) {}; case (_) { assert false } };
      switch (Sessions.sessionReconcileDecision(#reverted, #Settle, 0)) { case (#stay(_)) {}; case (_) { assert false } };
      switch (Sessions.sessionReconcileDecision(#reverted, #Refund, 100)) { case (#stay(_)) {}; case (_) { assert false } };
      switch (Sessions.sessionReconcileDecision(#err("rpc"), #Refund, 0)) { case (#stay(_)) {}; case (_) { assert false } };
    });
    // A confirmed REFUND always completes the close (settle already confirmed before refund ran).
    test("#confirmed #Refund -> finalizeClose for any refundOwed", func() {
      switch (Sessions.sessionReconcileDecision(#confirmed, #Refund, 0)) { case (#finalizeClose(_)) {}; case (_) { assert false } };
      switch (Sessions.sessionReconcileDecision(#confirmed, #Refund, 100)) { case (#finalizeClose(_)) {}; case (_) { assert false } };
    });
    // A confirmed SETTLE completes the close ONLY when no remainder is owed.
    test("#confirmed #Settle with no remainder -> finalizeClose", func() {
      switch (Sessions.sessionReconcileDecision(#confirmed, #Settle, 0)) { case (#finalizeClose(_)) {}; case (_) { assert false } };
    });
    test("#confirmed #Settle WITH remainder owed -> settleDoneRefundOwed (no auto-broadcast)", func() {
      switch (Sessions.sessionReconcileDecision(#confirmed, #Settle, 100)) { case (#settleDoneRefundOwed(_)) {}; case (_) { assert false } };
    });
  });
});
