/// Example canister demonstrating ic402 payments for content and services.
///
/// Shows three content hosting patterns side by side:
///   1. In-canister (ContentStore) — encrypted blob storage
///   2. Asset canister — separate ICP canister via HTTP gateway
///   3. External (S3/IPFS/Arweave) — off-chain hosting
///
/// Plus a paid service endpoint (search), streaming sessions, and
/// ERC-8004 agent identity on Avalanche for cross-chain discovery.
import Ic402 "../ic402/lib";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Text "mo:base/Text";

persistent actor KnowledgeBase {

  // ── Stable state ──

  var stableGateway : ?Ic402.StableGatewayState = null;
  var stableContent : ?Ic402.StableContentStoreState = null;
  var stableIdentity : ?Ic402.StableIdentityState = null;

  // ── Gateway — handles payment for ALL patterns ──

  transient let gate = Ic402.Gateway(
    {
      recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
      tokens = [{
        ledger = Principal.fromText("txyno-ch777-77776-aaaaq-cai");
        symbol = "ckUSDC";
        decimals = 6;
      }];

      // ── Avalanche cross-chain payments ──
      //
      // Accept USDC on Avalanche C-Chain in addition to ICP ckUSDC.
      // Requires tECDSA for cross-chain settlement verification.
      //
      // Settlement flow:
      //   1. Client gets PaymentRequirement with network = "eip155:43113"
      //   2. Client sends USDC on Avalanche to the recipient address
      //   3. Client retries with PaymentSignature containing the tx hash
      //   4. Canister verifies the Avalanche tx via tECDSA + RPC
      //
      // Fuji testnet (chainId 43113, USDC 0x5425890298aed601595a70AB815c96711a31Bc65)
      // Mainnet values: chainId 43114, USDC 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
      avalanche = ?{
        chainId = 43113;  // Avalanche Fuji testnet
        recipient = "0xf029Dd535f674a8B081Ef5f5759462c4Ea682165"; // placeholder — replace with your address
        tokens = [{
          address = "0x5425890298aed601595a70AB815c96711a31Bc65"; // USDC on Fuji
          symbol = "USDC";
          decimals = 6 : Nat8;
        }];
      };
    },
    Principal.fromActor(KnowledgeBase),
  );

  // ── ContentStore — OPTIONAL, only needed for Pattern 1 ──

  transient let store = Ic402.ContentStore(Principal.fromActor(KnowledgeBase));

  // ── Identity — OPTIONAL, for ERC-8004 agent discovery on Avalanche ──
  //
  // Registers this canister as a discoverable agent on ERC-8004's
  // IdentityRegistry contract on Avalanche. Other agents and clients
  // can find this service by querying the registry for skills, domains,
  // or x402 support.
  //
  // The registration mints an ERC-721 on Avalanche using tECDSA — the
  // canister signs the EVM transaction directly, no external wallet needed.
  //
  // Discovery flow:
  //   1. This canister calls registerAgent() → mints ERC-721 on Avalanche
  //   2. The agent card (name, services, skills) is stored on-chain
  //   3. Other agents query IdentityRegistry.getAgent(agentId)
  //   4. They find this canister's endpoint and know it supports x402
  //   5. They call the endpoint, get a 402, pay, and receive the service
  //
  // Trust & Reputation:
  //   Agents accumulate on-chain reputation scores via the ERC-8004
  //   ReputationRegistry contract. The Gateway can enforce minimum
  //   reputation requirements via trustRequirements in the config:
  //
  //   gate.setTrustRequirements(?{
  //     minReputation = 60;
  //     requiredTags = ["verified"];
  //   });
  //
  //   This lets you restrict high-value endpoints to trusted agents only.

  transient let identity = Ic402.Identity({
    chain = #avalanche;
    card = {
      name = "KnowledgeBase";
      description = "Paid knowledge base — search, Q&A, and encrypted content delivery via ic402";
      services = [{
        name = "search";
        endpoint = "https://" # Principal.toText(Principal.fromActor(KnowledgeBase)) # ".icp0.io";
        version = "1.0";
        skills = ["search", "qa", "content-delivery"];
        domains = ["knowledge", "research"];
      }];
      x402Support = true;
    };
  });

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
    switch (stableIdentity) {
      case (?data) { identity.loadStable(data) };
      case (null) {};
    };
  };

  // Set default policy
  do {
    gate.setPolicy(null, {
      maxPerTransaction = ?50_000;      // 0.05 USDC
      maxPerDay = ?500_000;             // 0.50 USDC
      rateLimitPerMinute = ?120;
      maxSessionDeposit = ?100_000;     // 0.10 USDC
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
    stableIdentity := ?identity.toStable();
  };

  system func postupgrade() {
    stableGateway := null;
    stableContent := null;
    stableIdentity := null;
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Paid Service: Search (x402 charge)
  // ═══════════════════════════════════════════════════════════════════════

  public shared func search(
    searchQuery : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : [Text];
    #error : Text;
  } {
    let amount = 1_000;  // 0.001 USDC per search query
    let icpPrice : Ic402.Price = {
      token = Principal.fromText("txyno-ch777-77776-aaaaq-cai");
      amount;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) {
        // Return both ICP and Avalanche payment options
        let icpReq = gate.require(icpPrice);
        let options = switch (gate.requireAvax(amount)) {
          case (?avaxReq) { [icpReq, avaxReq] };
          case (null) { [icpReq] };
        };
        #paymentRequired(options);
      };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(_)) { #ok(doSearch(searchQuery)) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired([gate.require(icpPrice)]) };
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
      token = Principal.toText(Principal.fromText("txyno-ch777-77776-aaaaq-cai"));
      recipient = Principal.toText(Principal.fromActor(KnowledgeBase));
      suggestedDeposit = 50_000;   // 0.05 USDC — enough for 100 queries
      minDeposit = ?5_000;         // 0.005 USDC — enough for 10 queries
      expiry = Time.now() + 300_000_000_000;
      costPerCall = ?500;          // 0.0005 USDC per query
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
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let amount = 5_000;  // 0.005 USDC per content access
    let icpPrice : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) {
        let icpReq = gate.require(icpPrice);
        let options = switch (gate.requireAvax(amount)) {
          case (?avaxReq) { [icpReq, avaxReq] };
          case (null) { [icpReq] };
        };
        #paymentRequired(options);
      };
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
          case (_) { #paymentRequired([gate.require(icpPrice)]) };
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
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let amount = 5_000;  // 0.005 USDC per content access
    let icpPrice : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) {
        let icpReq = gate.require(icpPrice);
        let options = switch (gate.requireAvax(amount)) {
          case (?avaxReq) { [icpReq, avaxReq] };
          case (null) { [icpReq] };
        };
        #paymentRequired(options);
      };
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
            let delivery = #assetCanister({
              canisterId = Principal.fromText("aaaaa-aa");
              path = assetPath;
            });
            #ok({ grant; delivery });
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired([gate.require(icpPrice)]) };
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
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let amount = 5_000;  // 0.005 USDC per content access
    let icpPrice : Ic402.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount;
      network = "icp:1";
    };

    switch (paymentSig) {
      case (null) {
        let icpReq = gate.require(icpPrice);
        let options = switch (gate.requireAvax(amount)) {
          case (?avaxReq) { [icpReq, avaxReq] };
          case (null) { [icpReq] };
        };
        #paymentRequired(options);
      };
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

            let delivery = #httpUrl(
              "https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=1,quality=80,width=400,height=400/event-covers/v2/ceaf4fc5-d05b-49f0-8c88-f81bea8d9f46"
            );

            #ok({ grant; delivery });
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired([gate.require(icpPrice)]) };
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

  // ═══════════════════════════════════════════════════════════════════════
  // Identity: ERC-8004 Agent Discovery on Avalanche
  //
  // These endpoints expose the agent card for discovery and provide
  // on-chain registration. The agent card tells other agents:
  //   - What services this canister offers (search, Q&A, content)
  //   - The endpoint URL for making x402 payments
  //   - Skills and domains for capability-based discovery
  //
  // Registration (registerAgent) is an admin action that mints an
  // ERC-721 on Avalanche's IdentityRegistry contract via tECDSA.
  // Once registered, other agents can find this canister by querying
  // the Avalanche contract — no centralized directory needed.
  //
  // Cross-chain flow:
  //   1. Agent A queries IdentityRegistry on Avalanche for skill="search"
  //   2. Registry returns this canister's agent card with ICP endpoint
  //   3. Agent A calls the ICP endpoint, receives 402 + PaymentRequirement
  //   4. Agent A pays (ICP ckUSDC or Avalanche USDC) and gets the service
  //
  // Avalanche-specific considerations:
  //   - tECDSA key: the canister derives an ECDSA key via ICP's threshold
  //     ECDSA service, giving it a native Avalanche address
  //   - Gas: the canister's Avalanche address needs AVAX for registration tx
  //   - Contract addresses (Avalanche C-Chain mainnet):
  //     IdentityRegistry: 0x... (TBD — deploy post-hackathon)
  //     ReputationRegistry: 0x... (TBD)
  // ═══════════════════════════════════════════════════════════════════════

  /// Get the agent card (public, no auth required).
  /// Other agents and indexers call this to discover capabilities.
  public query func getAgentCard() : async Ic402.AgentCard {
    identity.getCard();
  };

  /// Get the registered agent ID on Avalanche (null if not yet registered).
  public query func getAgentId() : async ?Nat {
    identity.getAgentId();
  };

  /// Get the canister's tECDSA public key for Avalanche.
  /// Returns the SEC1 compressed secp256k1 public key (33 bytes).
  /// Use scripts/register-agent.ts to derive the AVAX address and register.
  public func getAvalanchePublicKey() : async Blob {
    await identity.getPublicKey("dfx_test_key"); // "key_1" on mainnet IC
  };

  /// Set the agent registration after external registration via
  /// scripts/register-agent.ts. Controller-only.
  public shared(msg) func setAgentRegistration(agentTokenId : Nat) : async () {
    assert(Principal.isController(msg.caller));
    identity.setAgentId(agentTokenId);
  };

  /// Register this canister as an agent on Avalanche's IdentityRegistry.
  /// Controller-only.
  ///
  /// Current flow (hackathon):
  ///   1. Call getAvalanchePublicKey() to get the canister's secp256k1 key
  ///   2. Run scripts/register-agent.ts to deploy contract + register on Fuji
  ///   3. Script calls setAgentRegistration() to store the token ID
  ///
  /// Future flow (on-canister EVM signing):
  ///   1. Canister encodes EVM tx calling IdentityRegistry.register(card)
  ///   2. Signs via tECDSA (Keccak-256 + RLP encoding in Motoko)
  ///   3. Submits to Avalanche via HTTPS outcall
  ///   4. Returns the minted ERC-721 token ID
  public shared(msg) func registerAgent() : async Nat {
    assert(Principal.isController(msg.caller));
    await identity.registerAgent();
  };

  // ═══════════════════════════════════════════════════════════════════════
  // HTTP: x402 payment-gated content serving
  //
  // The ICP HTTP gateway calls http_request (query) for GET requests.
  // If payment is needed, we return 402. If a payment header is present,
  // we upgrade to http_request_update (update call) to settle payment.
  //
  // Routes:
  //   GET /                    → canister info + agent card (free)
  //   GET /content/<id>        → paid content (402 → pay → 200)
  //   GET /search?q=<query>    → paid search (402 → pay → 200)
  // ═══════════════════════════════════════════════════════════════════════

  transient let Http = Ic402.HttpHandler;

  public query func http_request(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let path = Http.getPath(request.url);

    // GET / — free agent info
    if (path == "/" or path == "") {
      let card = identity.getCard();
      let json = "{\"name\":\"" # card.name # "\""
        # ",\"description\":\"" # card.description # "\""
        # ",\"x402Support\":" # (if (card.x402Support) "true" else "false")
        # ",\"canisterId\":\"" # Principal.toText(Principal.fromActor(KnowledgeBase)) # "\""
        # ",\"endpoints\":[\"/content/<id>\",\"/search?q=<query>\"]"
        # "}";
      return Http.http200Json(json);
    };

    // GET /content/<id> — check for payment header
    if (Text.startsWith(path, #text "/content/")) {
      let hasPayment = switch (Http.getHeader(request.headers, "x-payment")) {
        case (?_) { true };
        case (null) { false };
      };
      if (hasPayment) {
        // Need update call to settle payment
        return Http.httpUpgrade();
      };
      // No payment — return 402
      let amount = 5_000;
      let icpPrice : Ic402.Price = {
        token = Principal.fromText("txyno-ch777-77776-aaaaq-cai");
        amount;
        network = "icp:1";
      };
      let icpReq = gate.require(icpPrice);
      let options = switch (gate.requireAvax(amount)) {
        case (?avaxReq) { [icpReq, avaxReq] };
        case (null) { [icpReq] };
      };
      return Http.http402(options);
    };

    // GET /search?q=<query> — check for payment header
    if (Text.startsWith(path, #text "/search")) {
      let hasPayment = switch (Http.getHeader(request.headers, "x-payment")) {
        case (?_) { true };
        case (null) { false };
      };
      if (hasPayment) {
        return Http.httpUpgrade();
      };
      let amount = 1_000;
      let icpPrice : Ic402.Price = {
        token = Principal.fromText("txyno-ch777-77776-aaaaq-cai");
        amount;
        network = "icp:1";
      };
      let icpReq = gate.require(icpPrice);
      let options = switch (gate.requireAvax(amount)) {
        case (?avaxReq) { [icpReq, avaxReq] };
        case (null) { [icpReq] };
      };
      return Http.http402(options);
    };

    Http.httpError(404, "Not found");
  };

  public shared func http_request_update(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let path = Http.getPath(request.url);

    // Parse payment header
    let paymentJson = switch (Http.getHeader(request.headers, "x-payment")) {
      case (?p) { p };
      case (null) { return Http.httpError(400, "Missing X-PAYMENT header") };
    };

    let sig = switch (Http.parsePaymentHeader(paymentJson)) {
      case (?s) { s };
      case (null) { return Http.httpError(400, "Invalid X-PAYMENT header") };
    };

    // GET /content/<id> — settle payment + return content
    if (Text.startsWith(path, #text "/content/")) {
      let contentId = switch (Text.stripStart(path, #text "/content/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing content ID") };
      };

      switch (await gate.settle(sig)) {
        case (#ok(receipt)) {
          // Check content exists (after payment)
          let metadata = switch (store.getMetadata(contentId)) {
            case (null) { return Http.httpError(404, "Content not found: " # contentId) };
            case (?m) { m };
          };
          // Small content — inline delivery
          if (metadata.chunkCount <= 1) {
            switch (store.get(contentId)) {
              case (?blob) { return Http.http200(blob, metadata.mimeType) };
              case (null) { return Http.httpError(500, "Content read failed") };
            };
          } else {
            return Http.http200Json("{\"delivery\":\"chunked\",\"chunkCount\":" # Nat.toText(metadata.chunkCount) # ",\"receiptId\":\"" # receipt.id # "\"}");
          };
        };
        case (#policyDenied(r)) { return Http.httpError(403, "Policy: " # r) };
        case (_) { return Http.httpError(402, "Payment failed — retry") };
      };
    };

    // GET /search?q=<query> — settle payment + return results
    if (Text.startsWith(path, #text "/search")) {
      let searchTerm = switch (Http.getQueryParam(request.url, "q")) {
        case (?q) { q };
        case (null) { "ic402" };
      };

      switch (await gate.settle(sig)) {
        case (#ok(_)) {
          let results = doSearch(searchTerm);
          var json = "[";
          for (i in results.keys()) {
            if (i > 0) { json #= "," };
            json #= "\"" # results[i] # "\"";
          };
          json #= "]";
          return Http.http200Json("{\"results\":" # json # "}");
        };
        case (#policyDenied(r)) { return Http.httpError(403, "Policy: " # r) };
        case (_) { return Http.httpError(402, "Payment failed — retry") };
      };
    };

    Http.httpError(404, "Not found");
  };

  // ── Internal ──

  func doSearch(q : Text) : [Text] {
    [
      "ic402: drop-in payment library for ICP canisters — x402 charges, streaming sessions, encrypted content.",
      "Supports ckUSDC (ICRC-2) on ICP and USDC on Avalanche C-Chain via tECDSA cross-chain settlement.",
      "Sessions reduce settlement overhead 5,000x: deposit once, stream vouchers, settle on close.",
      "Query: " # q,
    ]
  };
  func doQuery(question : Text) : Text { "Answer to: " # question };
};
