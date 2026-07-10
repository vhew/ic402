/// Caller-binding primitive: IC self-authenticating principal from a raw Ed25519 key, and the
/// derived Sessions.sessionCallerBound view.
///
/// The GOLDEN VECTOR is the cross-boundary proof: the fixture (pubkey, principal) pair was
/// produced by @icp-sdk (agent-js) — Ed25519KeyIdentity.fromSecretKey(32×0x07) → getPublicKey()
/// .toRaw() / getPrincipal(). If our sha224(DER-SPKI(key)) ‖ 0x02 derivation disagrees with
/// agent-js in any byte, the first test fails — the same discipline as the voucher-payload
/// golden vector (a contract across the client/canister boundary must be pinned on both sides).
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

// @icp-sdk golden fixture (shared by both suites below):
// Ed25519KeyIdentity.fromSecretKey(new Uint8Array(32).fill(7)) — @icp-sdk/core@5.4.0;
// pubkey via getPublicKey().toRaw(), principal via getPrincipal(). Cross-verified with
// @noble/ed25519@3.1.0 and node:crypto (OpenSSL). Same fixture identity as the
// externally-signed voucher goldens in test/consumevoucher.test.mo.
let GOLDEN_PUBKEY : [Nat8] = [234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, 149, 71, 118, 174, 190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44];
let GOLDEN_PRINCIPAL : [Nat8] = [44, 110, 27, 148, 216, 192, 108, 139, 248, 170, 245, 246, 119, 171, 251, 101, 88, 66, 234, 75, 163, 126, 12, 155, 217, 71, 88, 146, 2];
let GOLDEN_TEXT = "tek7g-2zmny-nzjwg-ansf7-rkxv6-z32x6-3flbb-ous5d-pygjx-wkhlc-jae";

suite("Identity.selfAuthPrincipalOfEd25519", func() {

  test("matches the @icp-sdk golden vector byte-for-byte (and as principal text)", func() {
    switch (Identity.selfAuthPrincipalOfEd25519(Blob.fromArray(GOLDEN_PUBKEY))) {
      case (?p) {
        assert Array.equal<Nat8>(Blob.toArray(p), GOLDEN_PRINCIPAL, Nat8.equal);
        assert Principal.toText(Principal.fromBlob(p)) == GOLDEN_TEXT;
      };
      case (null) { assert false };
    };
  });

  test("rejects a key that is not exactly 32 bytes", func() {
    assert Identity.selfAuthPrincipalOfEd25519(Blob.fromArray([])) == null;
    assert Identity.selfAuthPrincipalOfEd25519(Blob.fromArray(Array.tabulate<Nat8>(31, func(_) = 1))) == null;
    assert Identity.selfAuthPrincipalOfEd25519(Blob.fromArray(Array.tabulate<Nat8>(33, func(_) = 1))) == null;
  });
});

suite("Identity.verifyCallerEd25519 (ownership + possession)", func() {

  let privKey : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { Nat8.fromNat((i + 42) % 256) });
  let pubKey = Ed25519.ED25519.getPublicKey(privKey);
  // The key's OWN principal — internal-consistency use is fine here: the derivation itself is
  // pinned externally by the golden vector above.
  let boundCaller = switch (Identity.selfAuthPrincipalOfEd25519(Blob.fromArray(pubKey))) {
    case (?p) { Principal.fromBlob(p) };
    case (null) { Principal.fromText("aaaaa-aa") }; // unreachable (32-byte key)
  };
  let message : [Nat8] = [1, 2, 3, 4, 5];
  let signature = Ed25519.ED25519.sign(message, privKey);

  test("accepts the bound caller with a valid signature", func() {
    assert Identity.verifyCallerEd25519(boundCaller, Blob.fromArray(pubKey), Blob.fromArray(signature), Blob.fromArray(message));
  });

  test("rejects a different caller even with a valid signature (ownership fails)", func() {
    assert not Identity.verifyCallerEd25519(Principal.fromText("2vxsx-fae"), Blob.fromArray(pubKey), Blob.fromArray(signature), Blob.fromArray(message));
  });

  test("rejects a wrong message / another key's signature / wrong-length signature (possession fails)", func() {
    assert not Identity.verifyCallerEd25519(boundCaller, Blob.fromArray(pubKey), Blob.fromArray(signature), Blob.fromArray([9, 9, 9]));
    // A signature by a DIFFERENT key over the same message: a well-formed curve point (so the
    // underlying lib returns false rather than trapping — see the doc-comment's sharp edge),
    // but not the bound key's signature.
    let otherPriv : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { Nat8.fromNat((i + 99) % 256) });
    let otherSig = Ed25519.ED25519.sign(message, otherPriv);
    assert not Identity.verifyCallerEd25519(boundCaller, Blob.fromArray(pubKey), Blob.fromArray(otherSig), Blob.fromArray(message));
    // Wrong-length signature is guarded (returns false, never reaches the point decode).
    assert not Identity.verifyCallerEd25519(boundCaller, Blob.fromArray(pubKey), Blob.fromArray([1, 2, 3]), Blob.fromArray(message));
  });

  // EXTERNAL golden fixture C: the positive path pinned against a signature the canister-side
  // library did NOT create — this replaces reliance on self-signed (mo:ed25519-signed) cases for
  // the positive path, so a shared RFC-8032 deviation in mo:ed25519 can no longer pass silently.
  // Provenance: @icp-sdk/core@5.4.0 Ed25519KeyIdentity.fromSecretKey(new Uint8Array(32).fill(0x07))
  // .sign(Uint8Array [1,2,3,4,5]) — the GOLDEN_PUBKEY/GOLDEN_PRINCIPAL identity above. The
  // signature is byte-identical to @noble/ed25519@3.1.0 signAsync(msg, seed) and was independently
  // re-verified (and re-derived from the seed) with node:crypto (OpenSSL) — Ed25519 signing is
  // deterministic per RFC 8032.
  let GOLDEN_SIG_C : [Nat8] = [173, 11, 75, 100, 223, 67, 108, 0, 30, 141, 245, 141, 104, 109, 28, 3, 155, 109, 220, 162, 203, 159, 244, 10, 55, 30, 187, 107, 34, 87, 209, 52, 157, 201, 139, 204, 30, 59, 14, 201, 56, 77, 173, 234, 6, 181, 136, 106, 28, 142, 96, 162, 145, 52, 199, 126, 247, 60, 114, 234, 122, 141, 242, 7];

  test("accepts the externally-signed @icp-sdk golden fixture (caller = GOLDEN_PRINCIPAL)", func() {
    assert Identity.verifyCallerEd25519(
      Principal.fromBlob(Blob.fromArray(GOLDEN_PRINCIPAL)),
      Blob.fromArray(GOLDEN_PUBKEY),
      Blob.fromArray(GOLDEN_SIG_C),
      Blob.fromArray([1, 2, 3, 4, 5]),
    );
  });
});

suite("Sessions.sessionCallerBound (derived view)", func() {

  let canisterP = Principal.fromText("aaaaa-aa");
  let privKey : [Nat8] = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { Nat8.fromNat((i + 1) % 256) });
  let pubKey = Ed25519.ED25519.getPublicKey(privKey);
  let boundPayer = switch (Identity.selfAuthPrincipalOfEd25519(Blob.fromArray(pubKey))) {
    case (?p) { Principal.fromBlob(p) };
    case (null) { canisterP }; // unreachable
  };

  func mgrWith(payer : Principal) : Sessions.Sessions {
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
      payer;
      payerPublicKey = Blob.fromArray(pubKey);
      deposited = 10_000;
      consumed = 0;
      remaining = 10_000;
      voucherCount = 0;
      status = #open;
      openedAt = 0;
      lastActivityAt = 0;
      lastSequence = 0;
      lastCumulativeAmount = 0;
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

  test("?true when the voucher key derives the payer principal", func() {
    assert mgrWith(boundPayer).sessionCallerBound("sess-1") == ?true;
  });

  test("?false when the payer is a different principal (not identity-bound, not invalid)", func() {
    assert mgrWith(Principal.fromText("2vxsx-fae")).sessionCallerBound("sess-1") == ?false;
  });

  test("null for an unknown session id", func() {
    assert mgrWith(boundPayer).sessionCallerBound("nope") == null;
  });
});
