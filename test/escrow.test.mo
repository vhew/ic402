/// Motoko unit tests for Escrow (deterministic subaccount derivation).
import Escrow "../src/ic402/Escrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Array "mo:base/Array";
import SHA256 "mo:sha2/Sha256";
import { test; suite } "mo:test";

suite("Escrow", func() {

  let testPrincipal = Principal.fromText("aaaaa-aa");
  let escrow = Escrow.EscrowManager(testPrincipal);

  test("deriveSubaccount produces 32-byte blob", func() {
    let sub = escrow.deriveSubaccount("session-001");
    assert(sub.size() == 32);
  });

  test("deriveSubaccount is deterministic", func() {
    let sub1 = escrow.deriveSubaccount("session-abc");
    let sub2 = escrow.deriveSubaccount("session-abc");
    assert(sub1 == sub2);
  });

  test("different session IDs produce different subaccounts", func() {
    let sub1 = escrow.deriveSubaccount("session-001");
    let sub2 = escrow.deriveSubaccount("session-002");
    assert(sub1 != sub2);
  });

  test("empty session ID produces valid 32-byte blob", func() {
    let sub = escrow.deriveSubaccount("");
    assert(sub.size() == 32);
  });

  test("subaccount matches manual sha256 computation", func() {
    let sessionId = "test-session";
    let prefix = Blob.toArray(Text.encodeUtf8("ic402-escrow"));
    let idBytes = Blob.toArray(Text.encodeUtf8(sessionId));
    let expected = SHA256.fromArray(#sha256, Array.append(prefix, idBytes));
    let actual = escrow.deriveSubaccount(sessionId);
    assert(actual == expected);
  });

  test("escrow subaccounts don't collide with job subaccounts", func() {
    // Escrow uses prefix "ic402-escrow", ServiceRegistry uses "ic402-job-escrow".
    // Verify same ID produces different subaccounts due to different prefixes.
    let sessionId = "shared-id-001";

    // Escrow derivation: sha256("ic402-escrow" ++ sessionId)
    let escrowSub = escrow.deriveSubaccount(sessionId);

    // Job derivation: sha256("ic402-job-escrow" ++ sessionId)
    let jobPrefix = Blob.toArray(Text.encodeUtf8("ic402-job-escrow"));
    let idBytes = Blob.toArray(Text.encodeUtf8(sessionId));
    let jobSub = SHA256.fromArray(#sha256, Array.append(jobPrefix, idBytes));

    assert(escrowSub != jobSub);
  });

  test("different principals produce same subaccount for same session", func() {
    // The subaccount derivation is independent of the canister principal —
    // it only depends on the session ID. This is by design: the principal
    // determines the account owner, the subaccount identifies the session.
    let escrow2 = Escrow.EscrowManager(Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"));
    let sub1 = escrow.deriveSubaccount("session-xyz");
    let sub2 = escrow2.deriveSubaccount("session-xyz");
    assert(sub1 == sub2);
  });

  test("long session ID produces valid 32-byte blob", func() {
    // SHA-256 always outputs 32 bytes regardless of input length
    let longId = "a]very-long-session-identifier-that-exceeds-typical-lengths-and-tests-hash-behavior-with-extended-input-data-1234567890";
    let sub = escrow.deriveSubaccount(longId);
    assert(sub.size() == 32);
  });
});
