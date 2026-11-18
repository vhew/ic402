/// Motoko unit tests for Access Grants (content delivery).
import Gateway "../src/ic402/Gateway";
import Types "../src/ic402/Types";
import Grants "../src/ic402/Grants";
import Utils "../src/ic402/Utils";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Int "mo:base/Int";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import SHA256 "mo:sha2/Sha256";
import HMAC "mo:hmac";
import { test; suite } "mo:test";

suite("AccessGrants", func() {

  let testPrincipal = Principal.fromText("aaaaa-aa");
  let config : Types.Config = {
    recipient = { owner = testPrincipal; subaccount = null };
    tokens = [];
    evmChains = [];
    evmRpcCanister = null;
    ecdsaKeyName = null;
    nonceExpirySeconds = null;
  };

  // H-1: Deterministic seed for tests — must be initialized before issueGrant
  let testSeed = "\de\ad\be\ef\de\ad\be\ef\de\ad\be\ef\de\ad\be\ef\de\ad\be\ef\de\ad\be\ef\de\ad\be\ef\de\ad\be\ef" : Blob;

  let sampleContentRef : Types.ContentRef = {
    id = "photo-001";
    mimeType = ?"image/jpeg";
    sizeBytes = ?2048;
    metadata = null;
  };

  let grantee = Principal.fromText("2vxsx-fae");

  test("issueGrant produces a valid grant", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);

    assert(grant.grantId == "grant-1");
    assert(grant.contentRef.id == "photo-001");
    assert(grant.grantee == grantee);
    assert(grant.receiptId == "rcpt-1");
    assert(grant.hmac.size() == 32);
  });

  test("verifyGrant returns #ok for valid grant", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);

    switch (gate.verifyGrant(grantee, grant)) {
      case (#ok) {};
      case (_) { assert(false) };
    };
  });

  test("verifyGrant returns #expired for expired grant", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", -1_000_000_000);

    switch (gate.verifyGrant(grantee, grant)) {
      case (#expired(_)) {};
      case (_) { assert(false) };
    };
  });

  test("verifyGrant returns #invalidGrant for tampered HMAC", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);

    let tampered : Types.AccessGrant = {
      grantId = grant.grantId;
      contentRef = grant.contentRef;
      grantee = grant.grantee;
      receiptId = grant.receiptId;
      issuedAt = grant.issuedAt;
      expiresAt = grant.expiresAt;
      hmac = Blob.fromArray([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);
    };

    switch (gate.verifyGrant(grantee, tampered)) {
      case (#invalidGrant(_)) {};
      case (_) { assert(false) };
    };
  });

  test("revokeGrant and verifyGrant returns #revoked", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);

    assert(gate.revokeGrant(grant.grantId));
    assert(not gate.revokeGrant(grant.grantId));

    switch (gate.verifyGrant(grantee, grant)) {
      case (#revoked(_)) {};
      case (_) { assert(false) };
    };
  });

  // H-8: grants are non-transferable — a non-grantee caller is rejected.
  test("verifyGrant rejects a caller who is not the grantee (H-8)", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);
    let attacker = Principal.fromText("aaaaa-aa");
    switch (gate.verifyGrant(attacker, grant)) {
      case (#invalidGrant(_)) {};
      case (_) { assert(false) };
    };
  });

  test("grant IDs are unique", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let g1 = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 300_000_000_000);
    let g2 = gate.issueGrant(sampleContentRef, grantee, "rcpt-2", 300_000_000_000);

    assert(g1.grantId != g2.grantId);
    assert(g1.hmac != g2.hmac);
  });

  // C-2: Verify that swapping contentRef.id invalidates the grant
  test("verifyGrant rejects swapped contentRef.id (C-2 HMAC binding)", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);

    // Swap the contentRef to a different ID
    let swappedRef : Types.ContentRef = {
      id = "photo-002"; // different from "photo-001"
      mimeType = ?"image/jpeg";
      sizeBytes = ?2048;
      metadata = null;
    };
    let swapped : Types.AccessGrant = {
      grantId = grant.grantId;
      contentRef = swappedRef;
      grantee = grant.grantee;
      receiptId = grant.receiptId;
      issuedAt = grant.issuedAt;
      expiresAt = grant.expiresAt;
      hmac = grant.hmac;
    };

    switch (gate.verifyGrant(grantee, swapped)) {
      case (#invalidGrant(_)) {};
      case (_) { assert(false) };
    };
  });

  // 2.22.0 (C3): issueGrant traps until the HMAC seed is set, and the seed comes from a timer
  // after install, so a host must be able to check before it settles a payment.
  test("2.22.0: grantsReady is false until the seed is set, and loadStable restores it", func() {
    // Mutation: grantsReady answers true before the seed is set — a host that checks it before
    // settling still settles, and issueGrant traps after the payment.
    let gate = Gateway.Gateway(config, testPrincipal);
    assert not gate.grantsReady();
    ignore gate.initHmacSeed(testSeed);
    assert gate.grantsReady();
    let gate2 = Gateway.Gateway(config, testPrincipal);
    gate2.loadStable(gate.toStable());
    assert gate2.grantsReady();
  });

  // 2.22.0 (C8a): revocations are forgotten after 7 days, so no grant may outlive that.
  test("2.22.0: a grant's lifetime is capped at the 7 days a revocation is kept", func() {
    // Mutation: drop the cap — a 30-day grant revoked today verifies again once the clean-up
    // forgets its revocation in 7 days.
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let DAY : Int = 86_400_000_000_000;
    let long = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 30 * DAY);
    assert long.expiresAt - long.issuedAt == 7 * DAY;
    assert Grants.MAX_GRANT_TTL_NS == 7 * DAY;
    let short = gate.issueGrant(sampleContentRef, grantee, "rcpt-2", DAY);
    assert short.expiresAt - short.issuedAt == DAY;
  });

  // 2.22.0 (I9): the HMAC message joins grantId, content id, grantee and expiry with '|'. A grant
  // for content "a|b" (grant-1) has the same message, so the same HMAC, as grant "grant-1|a" for
  // content "b". The test computes that HMAC itself, with the test seed, as issueGrant would.
  test("2.22.0: a grant with '|' in its id or content id is refused, even with a matching HMAC", func() {
    // Mutation: drop the '|' check in verifyGrant — the re-split grant verifies, for content "b"
    // the grantee never paid for.
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let legit = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);
    var seed : Nat = 0;
    for (b in Blob.toArray(testSeed).vals()) { seed := seed * 256 + Nat8.toNat(b) };
    let secret = Blob.toArray(SHA256.fromArray(#sha256, Array.append(Blob.toArray(Principal.toBlob(testPrincipal)), Utils.natToBytesBE(seed))));
    func hmacOf(grantId : Text, contentId : Text) : Blob {
      let msg = grantId # "|" # contentId # "|" # Principal.toText(grantee) # "|" # Int.toText(legit.expiresAt);
      HMAC.generate(secret, Blob.toArray(Text.encodeUtf8(msg)).vals(), #sha256);
    };
    // Control: the computed HMAC is issueGrant's.
    assert hmacOf(legit.grantId, legit.contentRef.id) == legit.hmac;
    let resplit : Types.AccessGrant = {
      legit with grantId = "grant-1|a";
      contentRef = { sampleContentRef with id = "b" };
      hmac = hmacOf("grant-1", "a|b");
    };
    switch (gate.verifyGrant(grantee, resplit)) { case (#invalidGrant(_)) {}; case (_) { assert false } };
    let pipedContent : Types.AccessGrant = {
      legit with contentRef = { sampleContentRef with id = "photo|001" };
      hmac = hmacOf(legit.grantId, "photo|001");
    };
    switch (gate.verifyGrant(grantee, pipedContent)) { case (#invalidGrant(_)) {}; case (_) { assert false } };
    assert not Grants.grantFieldOk("a|b") and Grants.grantFieldOk("photo-001");
  });

  test("stable state roundtrip preserves grants", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", 5 * 60 * 1_000_000_000);
    ignore gate.revokeGrant(grant.grantId);

    let snapshot = gate.toStable();
    let gate2 = Gateway.Gateway(config, testPrincipal);
    gate2.loadStable(snapshot);
    // gate2 has hmacSeedInitialized = true via loadStable (hmacSeed > 0)

    switch (gate2.verifyGrant(grantee, grant)) {
      case (#revoked(_)) {};
      case (_) { assert(false) };
    };

    let g2 = gate2.issueGrant(sampleContentRef, grantee, "rcpt-2", 300_000_000_000);
    assert(g2.grantId == "grant-2");
  });
});
