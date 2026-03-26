/// Motoko unit tests for Access Grants (content delivery).
import Gateway "../src/ic402/Gateway";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
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

    switch (gate.verifyGrant(grant)) {
      case (#ok) {};
      case (_) { assert(false) };
    };
  });

  test("verifyGrant returns #expired for expired grant", func() {
    let gate = Gateway.Gateway(config, testPrincipal);
    ignore gate.initHmacSeed(testSeed);
    let grant = gate.issueGrant(sampleContentRef, grantee, "rcpt-1", -1_000_000_000);

    switch (gate.verifyGrant(grant)) {
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

    switch (gate.verifyGrant(tampered)) {
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

    switch (gate.verifyGrant(grant)) {
      case (#revoked(_)) {};
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

    switch (gate.verifyGrant(swapped)) {
      case (#invalidGrant(_)) {};
      case (_) { assert(false) };
    };
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

    switch (gate2.verifyGrant(grant)) {
      case (#revoked(_)) {};
      case (_) { assert(false) };
    };

    let g2 = gate2.issueGrant(sampleContentRef, grantee, "rcpt-2", 300_000_000_000);
    assert(g2.grantId == "grant-2");
  });
});
