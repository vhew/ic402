/// Pins EvmAddress.ecRecoverEvm (Ethereum's ecrecover) and the EIP-3009 payment path built on it,
/// Eip712.recoverAuthorizationSigner. See test/secp256k1.test.mo for the shared fixtures and for
/// ecRecover, the lenient recovery.
///
/// Runs in the interpreter on purpose, like test/secp256k1.test.mo (see the note there): compiled
/// to wasi, recovery-heavy tests peaked at 7 GB and killed the CI runner. Each of the ~510
/// recoveries here is done once and every test reads the results.
import EvmAddress "../src/ic402/EvmAddress";
import EvmUtils "../src/ic402/EvmUtils";
import Eip712 "../src/ic402/Eip712";
import V "fixtures/secp256k1/Vectors";
import EcdsaCurve "mo:ecdsa/Curve";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Debug "mo:base/Debug";
import { test; suite } "mo:test";

let secpN : Nat = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

// The two Wycheproof-valid signatures neither recovery can recover (recovery id 2/3).
let refusedByPolicy : [Nat] = [115, 247];
func contains(xs : [Nat], x : Nat) : Bool = Array.find<Nat>(xs, func(y) = y == x) != null;

func opt(k : ?Blob) : ?[Nat8] = switch (k) {
  case (?b) { ?Blob.toArray(b) };
  case (null) { null };
};

type Strict = { w : V.Wycheproof; evm0 : ?[Nat8]; evm1 : ?[Nat8] };

// ecRecoverEvm for both v of every vector, once (504 recoveries).
let strict : [Strict] = Array.map<V.Wycheproof, Strict>(
  V.wycheproof,
  func(w) {
    let sig = Blob.toArray(w.sig);
    if (sig.size() != 64) return { w; evm0 = null; evm1 = null };
    let h = Blob.toArray(w.hash);
    let r = Array.subArray(sig, 0, 32);
    let s = Array.subArray(sig, 32, 32);
    { w; evm0 = EvmAddress.ecRecoverEvm(h, r, s, 0); evm1 = EvmAddress.ecRecoverEvm(h, r, s, 1) };
  },
);

suite("ecRecoverEvm — Ethereum's ecrecover, for every signature the chain checks", func() {
  test("returns exactly ecrecover's key, or none, for both v of all 252 Wycheproof vectors", func() {
    // The strongest pin: not "is it the signer?" but the exact key, including for the wrong v,
    // high s (which ecrecover accepts) and every edge case Wycheproof carries.
    var mismatches = 0;
    var keys = 0;
    for (x in strict.values()) {
      for ((id, got, want) in [(0 : Nat8, x.evm0, x.w.evm0), (1 : Nat8, x.evm1, x.w.evm1)].values()) {
        if (got != null) keys += 1;
        if (got != opt(want)) {
          Debug.print("  MISMATCH tcId " # debug_show(x.w.tcId) # " v " # debug_show(id));
          mismatches += 1;
        };
      };
    };
    assert mismatches == 0;
    assert keys == 360; // the count ecrecover gives; catches a fixture that went all-null
  });

  test("accepts the same Wycheproof signatures as ecRecover: 165, none invalid, not 115/247", func() {
    var accepted = 0;
    for (x in strict.values()) {
      let pub = ?Blob.toArray(x.w.pub);
      if (x.evm0 == pub or x.evm1 == pub) {
        accepted += 1;
        assert x.w.valid and not contains(refusedByPolicy, x.w.tcId);
      };
    };
    assert accepted == 165;
  });

  test("v other than 0 and 1 returns null, even where that parity would recover the key", func() {
    // ecRecover reads v = 2 as even and v = 27 as odd; ecrecover's 27/28 arrive here as 0/1.
    // A low-s one, so ecRecover's high-s flip does not change what v = 2 means.
    let ?v = Array.find<V.Wycheproof>(
      V.wycheproof,
      func(w) = w.recId == ?0 and EvmAddress.isLowS(Array.subArray(Blob.toArray(w.sig), 32, 32)),
    ) else {
      assert false;
      return;
    };
    let sig = Blob.toArray(v.sig);
    let h = Blob.toArray(v.hash);
    let r = Array.subArray(sig, 0, 32);
    let s = Array.subArray(sig, 32, 32);
    assert EvmAddress.ecRecoverEvm(h, r, s, 0) == ?Blob.toArray(v.pub);
    assert EvmAddress.ecRecover(h, r, s, 2) == ?Blob.toArray(v.pub);
    for (bad in ([2, 3, 27, 28, 255] : [Nat8]).values()) {
      assert EvmAddress.ecRecoverEvm(h, r, s, bad) == null;
    };
  });

  for (p in V.policy.values()) {
    let h = Blob.toArray(p.hash);
    let r = Blob.toArray(p.r);
    let s = Blob.toArray(p.s);
    test(p.name # ": v = 0 and v = 1 return what ecrecover does", func() {
      assert EvmAddress.ecRecoverEvm(h, r, s, 0) == opt(p.evm0);
      assert EvmAddress.ecRecoverEvm(h, r, s, 1) == opt(p.evm1);
    });
  };
});

suite("Eip712.recoverAuthorizationSigner recovers as ecrecover does", func() {
  test("no signer where only ecRecover's parity fallthrough would find one", func() {
    // Pins the payment path to ecRecoverEvm. Builds a fallthrough signature over a real EIP-712
    // digest: R = kG and s = z/k, so under R's own parity r^-1 (sR - zG) is the point at
    // infinity. ecrecover returns nothing there; ecRecover would return the other parity's key.
    let curve = EcdsaCurve.Curve(#secp256k1);
    let from = Array.tabulate<Nat8>(20, func(_) = 0xab);
    let token = Array.tabulate<Nat8>(20, func(_) = 0xcc);
    let nonce = Array.tabulate<Nat8>(32, func(_) = 0x01);
    let digest = Eip712.digest(
      Eip712.domainSeparator("USD Coin", "2", 8453, token),
      Eip712.hashTransferWithAuthorization(from, from, 1, 0, 1, nonce),
    );
    let k = 7;
    let #affine(#fp(rx), #fp(ry)) = curve.fromJacobi(curve.mul_base(#fr(k))) else {
      assert false;
      return;
    };
    assert rx < secpN;
    var s = curve.Fr.toNat(curve.Fr.mul(curve.Fr.fromNat(EvmUtils.bytesToNat(digest)), curve.Fr.inv(#fr(k))));
    var v : Nat8 = if (ry % 2 == 0) 0 else 1;
    if (s > secpN / 2) { s := secpN - s; v := 1 - v }; // k -> n - k: R flips, so its parity does
    let r = EvmUtils.natToBytes(rx, 32);
    let sb = EvmUtils.natToBytes(s, 32);
    let recover = func(v : Nat8) : ?[Nat8] = Eip712.recoverAuthorizationSigner(
      8453, token, from, from, 1, 0, 1, nonce, v, r, sb, ?"USD Coin", ?"2",
    );

    assert EvmAddress.ecRecoverEvm(digest, r, sb, v) == null;
    assert EvmAddress.ecRecover(digest, r, sb, v) != null; // the fallthrough
    assert recover(v) == null;
    assert recover(v + 27) == null;
    assert recover(1 - v) != null; // the other parity is a real recovery, on chain too
  });
});
