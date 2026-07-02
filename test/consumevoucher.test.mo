/// Table tests for Sessions.consumeVoucher — the synchronous, per-call streaming-charge gate.
/// Builds a Sessions manager, loadStable()s one open session with a known Ed25519 key, and drives
/// the voucher-verification decision tree. Covers the gate that was previously untested despite
/// running on every metered session call.
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
