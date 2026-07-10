/// Table tests for Sessions.consumeVoucher — the synchronous, per-call streaming-charge gate.
/// Builds a Sessions manager, loadStable()s one open session with a known Ed25519 key, and drives
/// the voucher-verification decision tree. Covers the gate that was previously untested despite
/// running on every metered session call.
///
/// The second suite pins EXTERNALLY-SIGNED golden fixtures: Ed25519 signatures produced by
/// @icp-sdk/core@5.4.0 (the exact library + call path the production client uses —
/// Ed25519KeyIdentity.sign over the raw CBOR voucher payload), cross-verified byte-identical and
/// valid with @noble/ed25519@3.1.0 and independently with node:crypto (OpenSSL). Until these
/// fixtures, every voucher-signature test signed with mo:ed25519 itself, so a shared RFC-8032
/// deviation in mo:ed25519 would have passed hermetically.
import Identity "../src/ic402/Identity";
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Ed25519 "mo:ed25519";
import { test; suite } "mo:test";

suite("Sessions.consumeVoucher", func() {

  let canisterP = Principal.fromText("aaaaa-aa");
  let privKey : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { Nat8.fromNat((i + 1) % 256) });
  let pubKey = Ed25519.ED25519.getPublicKey(privKey);

  // Fresh manager + one open session per test (consumeVoucher mutates on #ok, so isolate).
  // deposited 10_000, already-consumed 1_000 at sequence 1.
  func freshMgr() : Sessions.Sessions {
    let config : Types.Config = {
      recipient = { owner = canisterP; subaccount = null };
      tokens = [];
      evmChains = [];
      evmRpcCanister = null;
      ecdsaKeyName = null;
      nonceExpirySeconds = null;
    };
    let mgr = Sessions.Sessions(
      canisterP, config, Policy.Engine(), Escrow.EscrowManager(canisterP),
      EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
    );
    mgr.loadStable([{
      id = "sess-1";
      payer = canisterP;
      payerPublicKey = Blob.fromArray(pubKey);
      deposited = 10_000;
      consumed = 1_000;
      remaining = 9_000;
      voucherCount = 1;
      status = #open;
      openedAt = 0;
      lastActivityAt = 0;
      lastSequence = 1;
      lastCumulativeAmount = 1_000;
      subaccount = Blob.fromArray([]);
      network = "icp:1";
      token = "tok";
      recipient = "r";
      autoClose = false;
      maxDuration = null;
      idleTimeout = null;
      evmDeposit = null;
    }]);
    mgr;
  };

  func payloadFor(sessionId : Text, cumulative : Nat, sequence : Nat) : [Nat8] {
    switch (Sessions.encodeVoucherPayload(Principal.toText(canisterP), sessionId, cumulative, sequence)) {
      case (?p) { p };
      case (null) { assert false; [] };
    };
  };

  func voucher(sessionId : Text, cumulative : Nat, sequence : Nat, key : [Nat8]) : Types.Voucher {
    {
      sessionId;
      cumulativeAmount = cumulative;
      sequence;
      signature = Blob.fromArray(Ed25519.ED25519.sign(payloadFor(sessionId, cumulative, sequence), key));
    };
  };

  test("valid cumulative voucher -> #ok(delta)", func() {
    switch (freshMgr().consumeVoucher(voucher("sess-1", 2_000, 2, privKey))) {
      case (#ok(delta)) { assert delta == 1_000 }; // 2_000 - already-consumed 1_000
      case (_) { assert false };
    };
  });

  test("non-increasing sequence -> #invalidSequence", func() {
    switch (freshMgr().consumeVoucher(voucher("sess-1", 2_000, 1, privKey))) {
      case (#invalidSequence) {};
      case (_) { assert false };
    };
  });

  test("non-increasing cumulative -> #invalidSequence", func() {
    switch (freshMgr().consumeVoucher(voucher("sess-1", 1_000, 2, privKey))) {
      case (#invalidSequence) {};
      case (_) { assert false };
    };
  });

  test("cumulative over deposit -> #insufficientDeposit", func() {
    switch (freshMgr().consumeVoucher(voucher("sess-1", 20_000, 2, privKey))) {
      case (#insufficientDeposit) {};
      case (_) { assert false };
    };
  });

  test("unknown session id -> #sessionNotOpen", func() {
    switch (freshMgr().consumeVoucher(voucher("nope", 2_000, 2, privKey))) {
      case (#sessionNotOpen) {};
      case (_) { assert false };
    };
  });

  test("signature by the wrong key -> #invalidSignature", func() {
    let wrongKey : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { Nat8.fromNat((i + 99) % 256) });
    switch (freshMgr().consumeVoucher(voucher("sess-1", 2_000, 2, wrongKey))) {
      case (#invalidSignature) {};
      case (_) { assert false };
    };
  });
});

suite("externally-signed voucher goldens (@icp-sdk, cross-verified @noble + node:crypto)", func() {

  let canisterP = Principal.fromText("aaaaa-aa");

  // Same fixture identity as test/selfauth.test.mo GOLDEN_PUBKEY: @icp-sdk/core@5.4.0
  // Ed25519KeyIdentity.fromSecretKey(new Uint8Array(32).fill(0x07)), pubkey via
  // getPublicKey().toRaw(). Independently re-derived from the seed with node:crypto (OpenSSL).
  let GOLDEN_PUBKEY : [Nat8] = [234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, 149, 71, 118, 174, 190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44];
  // The identity's self-authenticating principal text, as pinned in test/selfauth.test.mo.
  let GOLDEN_TEXT = "tek7g-2zmny-nzjwg-ansf7-rkxv6-z32x6-3flbb-ous5d-pygjx-wkhlc-jae";

  // The pinned voucher payload — CBOR ["aaaaa-aa", "sess-1", 1000, 2], hex
  // 846861616161612d616166736573732d311903e802. Same cross-boundary golden vector as
  // test/sessions.test.mo ("matches the cross-boundary golden vector") and
  // packages/client/test/voucher.test.ts; reproduced by cborg@5.1.1 at fixture-generation time.
  let PINNED_PAYLOAD : [Nat8] = [132, 104, 97, 97, 97, 97, 97, 45, 97, 97, 102, 115, 101, 115, 115, 45, 49, 25, 3, 232, 2];

  // Fixture A: Ed25519 signature over PINNED_PAYLOAD by the GOLDEN_PUBKEY identity (seed 32×0x07).
  // Produced by @icp-sdk/core@5.4.0 Ed25519KeyIdentity.sign(payload) — pure raw RFC-8032 over the
  // CBOR bytes, no prehash/domain-prefix/DER-wrapping. Byte-identical to @noble/ed25519@3.1.0
  // signAsync(msg, seed) and accepted by node:crypto verify over an SPKI-wrapped GOLDEN_PUBKEY.
  let SIG_A : [Nat8] = [188, 82, 107, 188, 115, 179, 18, 0, 244, 127, 130, 118, 39, 109, 115, 83, 37, 175, 24, 180, 197, 26, 38, 83, 135, 8, 117, 185, 193, 123, 79, 139, 116, 216, 66, 13, 205, 48, 127, 136, 246, 93, 97, 223, 125, 92, 101, 5, 122, 115, 94, 204, 37, 182, 15, 100, 101, 101, 232, 75, 188, 97, 14, 12];

  // Fixture B: a VALID Ed25519 signature over the SAME payload by a DIFFERENT identity
  // (seed 32×0x2A, pubkey 197f6b23…368d61), @icp-sdk/core@5.4.0. Verifies under its own pubkey but
  // is REJECTED under GOLDEN_PUBKEY by both @noble/ed25519@3.1.0 and node:crypto — a genuine
  // wrong-key negative control, not a corrupted signature.
  let SIG_B : [Nat8] = [217, 226, 19, 30, 47, 180, 79, 13, 193, 72, 30, 78, 214, 51, 94, 130, 141, 228, 43, 191, 196, 254, 222, 212, 155, 145, 151, 197, 197, 67, 78, 152, 79, 152, 255, 69, 89, 228, 110, 197, 19, 181, 100, 58, 235, 200, 93, 163, 221, 234, 192, 159, 131, 8, 159, 234, 201, 32, 206, 88, 63, 27, 148, 4];

  test("cross-file link: GOLDEN_PUBKEY is the selfauth.test.mo fixture (derives the same principal)", func() {
    // Byte-equality with test/selfauth.test.mo's GOLDEN_PUBKEY, pinned executably: both literals
    // must derive the same self-authenticating principal text (sha224(DER-SPKI(key)) ‖ 0x02).
    switch (Identity.selfAuthPrincipalOfEd25519(Blob.fromArray(GOLDEN_PUBKEY))) {
      case (?p) { assert Principal.toText(Principal.fromBlob(p)) == GOLDEN_TEXT };
      case (null) { assert false };
    };
  });

  test("payload pin: encodeVoucherPayload reproduces the externally-signed bytes exactly", func() {
    switch (Sessions.encodeVoucherPayload("aaaaa-aa", "sess-1", 1000, 2)) {
      case (?bytes) { assert Array.equal<Nat8>(bytes, PINNED_PAYLOAD, Nat8.equal) };
      case (null) { assert false };
    };
  });

  test("mo:ed25519 accepts the external @icp-sdk signature over the pinned payload", func() {
    assert Ed25519.ED25519.verify(SIG_A, PINNED_PAYLOAD, GOLDEN_PUBKEY);
  });

  test("mo:ed25519 rejects a valid signature by the WRONG key over the same payload", func() {
    assert not Ed25519.ED25519.verify(SIG_B, PINNED_PAYLOAD, GOLDEN_PUBKEY);
  });

  test("mo:ed25519 rejects the external signature over a different payload", func() {
    let different = switch (Sessions.encodeVoucherPayload("aaaaa-aa", "sess-1", 1001, 2)) {
      case (?p) { p };
      case (null) { assert false; [] };
    };
    assert not Ed25519.ED25519.verify(SIG_A, different, GOLDEN_PUBKEY);
  });

  // END-TO-END: session keyed to GOLDEN_PUBKEY, state chosen so cumulativeAmount 1000 / sequence 2
  // (the pinned payload's values, with canisterId "aaaaa-aa") is the next valid voucher:
  // lastSequence 1 < 2, lastCumulativeAmount 500 < 1000 ≤ deposited 10_000.
  func goldenMgr() : Sessions.Sessions {
    let config : Types.Config = {
      recipient = { owner = canisterP; subaccount = null };
      tokens = [];
      evmChains = [];
      evmRpcCanister = null;
      ecdsaKeyName = null;
      nonceExpirySeconds = null;
    };
    let mgr = Sessions.Sessions(
      canisterP, config, Policy.Engine(), Escrow.EscrowManager(canisterP),
      EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { null } },
    );
    mgr.loadStable([{
      id = "sess-1";
      payer = canisterP;
      payerPublicKey = Blob.fromArray(GOLDEN_PUBKEY);
      deposited = 10_000;
      consumed = 500;
      remaining = 9_500;
      voucherCount = 1;
      status = #open;
      openedAt = 0;
      lastActivityAt = 0;
      lastSequence = 1;
      lastCumulativeAmount = 500;
      subaccount = Blob.fromArray([]);
      network = "icp:1";
      token = "tok";
      recipient = "r";
      autoClose = false;
      maxDuration = null;
      idleTimeout = null;
      evmDeposit = null;
    }]);
    mgr;
  };

  test("consumeVoucher ACCEPTS the externally-signed voucher (first non-self-signed acceptance)", func() {
    switch (goldenMgr().consumeVoucher({ sessionId = "sess-1"; cumulativeAmount = 1000; sequence = 2; signature = Blob.fromArray(SIG_A) })) {
      case (#ok(delta)) { assert delta == 500 }; // 1000 − lastCumulativeAmount 500
      case (_) { assert false };
    };
  });

  test("consumeVoucher rejects the wrong-key external signature -> #invalidSignature", func() {
    switch (goldenMgr().consumeVoucher({ sessionId = "sess-1"; cumulativeAmount = 1000; sequence = 2; signature = Blob.fromArray(SIG_B) })) {
      case (#invalidSignature) {};
      case (_) { assert false };
    };
  });
});
