/// Example canister demonstrating ic402 payments for content and services.
///
/// Shows three content hosting patterns side by side:
///   1. In-canister (ContentStore) — encrypted blob storage
///   2. Asset canister — separate ICP canister via HTTP gateway
///   3. External (S3/IPFS/Arweave) — off-chain hosting
///
/// Plus a paid service endpoint (search) and streaming sessions.
import Ic402 "../ic402/lib";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Text "mo:base/Text";

persistent actor KnowledgeBase {

  // ── Stable state ──

  var stableGateway : ?Ic402.StableGatewayState = null;
  var stableContent : ?Ic402.StableContentStoreState = null;

  // ── Gateway — handles payment for ALL patterns ──

  transient let gate = Ic402.Gateway(
    {
      recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
      tokens = [{
        ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
        symbol = "ckUSDC";
        decimals = 6;
      }];
      avalanche = null;
    },
    Principal.fromActor(KnowledgeBase),
  );

  // ── ContentStore — OPTIONAL, only needed for Pattern 1 ──

  transient let store = Ic402.ContentStore(Principal.fromActor(KnowledgeBase));

  // Load stable state on init
  do {
    switch (stableGateway) {
      case (?data) { gate.loadStable(data) };
      case (null) {};
    };
    switch (stableContent) {
      case (?data) { store.loadStable(data) };
      case (null) {};
    };
  };

  // Set default policy
  do {
    gate.setPolicy(null, {
      maxPerTransaction = ?1_000_000;
      maxPerDay = ?10_000_000;
      rateLimitPerMinute = ?120;
      maxSessionDeposit = ?5_000_000;
      maxConcurrentSessions = ?1;
      maxSessionDuration = ?(24 * 60 * 60 * 1_000_000_000);
      sessionIdleTimeout = ?(60 * 60 * 1_000_000_000);
      allowedCallers = null;
      blockedCallers = null;
    });
  };

  // Start session expiry timer
  gate.startTimers<system>();

  system func preupgrade() {
    stableGateway := ?gate.toStable();
    stableContent := ?store.toStable();
  };

  system func postupgrade() {
    stableGateway := null;
    stableContent := null;
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Paid Service: Search (x402 charge)
  // ═══════════════════════════════════════════════════════════════════════

  public shared func search(
    searchQuery : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : Ic402.PaymentRequirement;
    #ok : [Text];
    #error : Text;
  } {
    let price : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount = 50_000;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(_)) { #ok(doSearch(searchQuery)) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Session endpoints (escrow + streaming vouchers)
  // ═══════════════════════════════════════════════════════════════════════

  public shared func requestSession() : async Ic402.SessionIntent {
    gate.offerSession({
      network = "icp:1";
      token = Principal.toText(Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"));
      recipient = Principal.toText(Principal.fromActor(KnowledgeBase));
      suggestedDeposit = 1_000_000;
      minDeposit = ?100_000;
      expiry = Time.now() + 300_000_000_000;
      costPerCall = ?1_000;
      description = ?"Knowledge base session — pay per query";
    });
  };

  public shared(msg) func openSession(
    config : Ic402.SessionConfig,
    sig : Ic402.PaymentSignature,
  ) : async { #ok : Ic402.SessionState; #err : Text } {
    let intent = await requestSession();
    switch (await gate.openSession(msg.caller, intent, config, sig)) {
      case (#ok(state)) { #ok(state) };
      case (#err(#policyDenied(r))) { #err("Policy: " # r) };
      case (#err(#depositBelowMinimum(min))) { #err("Deposit below minimum: " # Nat.toText(min)) };
      case (#err(_)) { #err("Failed to open session") };
    };
  };

  public shared func sessionQuery(
    voucher : Ic402.Voucher,
    question : Text,
  ) : async { #ok : Text; #error : Text } {
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_delta)) { #ok(doQuery(question)) };
      case (#insufficientDeposit) { #error("Budget exhausted") };
      case (#policyDenied(r)) { #error("Policy: " # r) };
      case (_) { #error("Invalid voucher") };
    };
  };

  public shared func endSession(sessionId : Text) : async Ic402.PaymentResult {
    await gate.closeSession(sessionId);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Pattern 1: In-Canister Content (ContentStore)
  //
  // Best for: small catalogs, fully on-chain, no external dependencies.
  // Content is encrypted at rest — only this canister can decrypt.
  // The ContentStore module is optional — import only if you need it.
  // ═══════════════════════════════════════════════════════════════════════

  // ── Admin: Content management (controller-only) ──

  public shared(msg) func uploadContent(id : Text, mimeType : Text, data : Blob) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller));
    store.put(id, mimeType, data);
  };

  public shared(msg) func uploadContentInit(id : Text, mimeType : Text, totalSize : Nat, chunkCount : Nat) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller));
    store.putChunkedInit(id, mimeType, totalSize, chunkCount);
  };

  public shared(msg) func uploadContentChunk(id : Text, index : Nat, data : Blob) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller));
    store.putChunk(id, index, data);
  };

  public shared(msg) func deleteContent(id : Text) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller));
    store.delete(id);
  };

  public query func listContent() : async [Ic402.ContentEntry] {
    store.list();
  };

  // ── Delivery: getContent ──

  public shared(msg) func getContent(
    contentId : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : Ic402.PaymentRequirement;
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let price : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount = 100_000;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(receipt)) {
            // Check content exists (after payment — don't leak existence for free)
            let metadata = switch (store.getMetadata(contentId)) {
              case (null) { return #error("Content not found: " # contentId) };
              case (?m) { m };
            };
            let contentRef = switch (store.toContentRef(contentId)) {
              case (?ref) { ref };
              case (null) { return #error("Content disappeared") };
            };
            let grant = gate.issueGrant(
              contentRef, msg.caller, receipt.id, 5 * 60 * 1_000_000_000,
            );

            if (metadata.chunkCount <= 1) {
              // Small content — inline delivery
              switch (store.get(contentId)) {
                case (?blob) { #ok({ grant; delivery = #inline(blob) }) };
                case (null) { #error("Content read failed") };
              };
            } else {
              // Large content — chunked delivery via getChunk query
              #ok({
                grant;
                delivery = #canisterQuery({
                  method = "getChunk";
                  chunkCount = metadata.chunkCount;
                });
              });
            };
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  /// Chunk query — verifies AccessGrant HMAC, decrypts + returns chunk.
  /// Called by the client SDK when delivery is #canisterQuery.
  public query func getChunk(grant : Ic402.AccessGrant, index : Nat) : async ?Blob {
    switch (gate.verifyGrant(grant)) {
      case (#ok) { store.getChunk(grant.contentRef.id, index) };
      case (_) { null };
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Pattern 2: Asset Canister Content Delivery
  //
  // Best for: large file collections, images, videos, static sites.
  // Content lives in a separate ICP asset canister, served via HTTP gateway.
  //
  // Setup:
  //   1. Create an asset canister:
  //        icp canister create my_assets -e local
  //   2. Upload your files:
  //        icp asset upload my_assets ./content/ -e local
  //      Files are served at https://<canisterId>.icp0.io/<path>
  //
  //   3. Access control — choose one:
  //
  //      a) PUBLIC assets (simplest):
  //         The asset canister serves files to anyone. The AccessGrant is
  //         client-side proof of payment — honest clients check it, but the
  //         asset canister itself doesn't enforce it. Good for low-value
  //         content where the payment is a social contract.
  //
  //      b) PROXY through this canister (moderate security):
  //         Instead of returning #assetCanister, fetch the asset via an
  //         inter-canister call and return #inline(blob). The client never
  //         gets the direct URL. Cost: one inter-canister call per request.
  //
  //      c) CUSTOM asset canister with grant verification (strongest):
  //         Fork the asset canister to import ic402 and call
  //         gate.verifyGrant() in its http_request handler. Reject
  //         requests without a valid grant in the query string or header.
  //
  // Encryption:
  //   For sensitive content, encrypt files BEFORE uploading to the asset
  //   canister. On payment, return the decryption key alongside the grant.
  //   The asset canister serves ciphertext; only paying clients can decrypt.
  //   Use AES-256-GCM with a per-file key derived from a canister secret.
  // ═══════════════════════════════════════════════════════════════════════

  public shared(msg) func getAssetContent(
    assetPath : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : Ic402.PaymentRequirement;
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let price : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount = 100_000;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(receipt)) {
            let contentRef : Ic402.ContentRef = {
              id = assetPath;
              mimeType = null;
              sizeBytes = null;
              metadata = null;
            };
            let grant = gate.issueGrant(
              contentRef, msg.caller, receipt.id, 5 * 60 * 1_000_000_000,
            );
            // TODO: replace with your asset canister ID
            let delivery = #assetCanister({
              canisterId = Principal.fromText("aaaaa-aa");
              path = assetPath;
            });
            #ok({ grant; delivery });
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Pattern 3: Off-Chain Content Delivery (S3 / IPFS / Arweave)
  //
  // Best for: existing cloud infrastructure, large media, permanent storage.
  // Content lives off-chain; the canister gates access via payment.
  //
  // ─── Option A: S3 / Cloud Storage (pre-signed URLs) ───
  //
  //   1. Store content in an S3 bucket (or GCS, Azure Blob, R2, etc.)
  //   2. On payment, generate a pre-signed URL with short expiry:
  //      - Match the URL expiry to the AccessGrant TTL (e.g., 5 minutes)
  //      - The URL is the access mechanism; the grant is proof of payment
  //   3. Signing the URL from inside the canister:
  //      - Use tECDSA (ICP threshold ECDSA) to sign AWS Signature V4
  //        requests without storing AWS credentials in the canister
  //      - OR use vetKD to derive a signing key deterministically
  //      - OR store an IAM access key as a canister secret (less secure)
  //   4. Encryption (recommended):
  //      - Enable S3 server-side encryption (SSE-S3 or SSE-KMS)
  //      - The pre-signed URL grants time-limited decrypted access
  //      - No client-side decryption needed
  //
  // ─── Option B: IPFS / Arweave (content-addressed, immutable) ───
  //
  //   1. Content is public by CID — anyone with the CID can fetch it
  //   2. Encryption is MANDATORY for access control:
  //      - Encrypt each file with AES-256-GCM before uploading
  //      - Use a unique key per content item:
  //          key = HKDF(canister_master_secret, content_id)
  //      - Store the CID in contentRef.metadata
  //   3. On payment, return the decryption key to the client:
  //      - The grant proves payment occurred
  //      - The key is the actual access mechanism
  //      - Client decrypts locally after fetching the ciphertext from IPFS
  //   4. Revocation:
  //      - You cannot delete content from IPFS/Arweave
  //      - Revocation = stop issuing the decryption key
  //      - Use a unique key per item (not a shared master key) so
  //        revoking one item doesn't affect others
  //
  // ─── Security Model ───
  //
  //   - The AccessGrant proves payment occurred (HMAC-verified)
  //   - The URL or decryption key is the actual access mechanism
  //   - Grant TTL should match or be shorter than URL expiry
  //   - For encrypted content, key is returned once per payment —
  //     client caches locally for the session duration
  //   - Never return the master secret; always derive per-content keys
  // ═══════════════════════════════════════════════════════════════════════

  public shared(msg) func getExternalContent(
    contentId : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : Ic402.PaymentRequirement;
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let price : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount = 100_000;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(receipt)) {
            let contentRef : Ic402.ContentRef = {
              id = contentId;
              mimeType = null;
              sizeBytes = null;
              metadata = null;
            };
            let grant = gate.issueGrant(
              contentRef, msg.caller, receipt.id, 5 * 60 * 1_000_000_000,
            );

            // S3 example — in production, generate via tECDSA:
            //   let presignedUrl = await generatePresignedUrl(contentId, 300);
            let presignedUrl = "https://my-bucket.s3.amazonaws.com/" # contentId
              # "?X-Amz-Expires=300&X-Amz-Signature=TODO";
            let delivery = #httpUrl(presignedUrl);

            // IPFS example (encrypted):
            // let cid = lookupCid(contentId);
            // let decryptionKey = deriveKey(contentId);
            // let delivery = #httpUrl("https://ipfs.io/ipfs/" # cid);

            #ok({ grant; delivery });
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Admin
  // ═══════════════════════════════════════════════════════════════════════

  public shared(msg) func setPolicy(p : Ic402.SpendingPolicy) : async () {
    assert(Principal.isController(msg.caller));
    gate.setPolicy(null, p);
  };

  public shared(msg) func forceCloseSession(sessionId : Text) : async Ic402.PaymentResult {
    assert(Principal.isController(msg.caller));
    await gate.closeSession(sessionId);
  };

  /// Verify a grant (usable from query calls or http_request handlers).
  public query func verifyGrant(grant : Ic402.AccessGrant) : async Ic402.AccessGrantResult {
    gate.verifyGrant(grant);
  };

  // ── Internal ──

  func doSearch(_q : Text) : [Text] { ["result 1", "result 2"] };
  func doQuery(question : Text) : Text { "Answer to: " # question };
};
