/// ic402 Example Canister
///
/// Demonstrates a paid knowledge base API with multiple optional features.
/// The required core is small — everything marked OPTIONAL can be removed.
///
/// Structure:
///   1. REQUIRED: Gateway + paid endpoint + HTTP 402 serving
///   2. OPTIONAL: Streaming sessions (escrow + vouchers)
///   3. OPTIONAL: Encrypted content store (in-canister)
///   4. OPTIONAL: EVM remote signer (canister signs, client broadcasts)
///   5. OPTIONAL: ERC-8004 identity metadata

import Ic402 "../src/ic402/lib";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Text "mo:base/Text";

persistent actor KnowledgeBase {

  // ═══════════════════════════════════════════════════════════════════════
  // REQUIRED: Gateway Configuration
  //
  // The Gateway handles payment verification and settlement.
  // This is the only ic402 component you must configure.
  // ═══════════════════════════════════════════════════════════════════════

  // Stable state — survives canister upgrades
  var stableGateway : ?Ic402.StableGatewayState = null;
  var stableContent : ?Ic402.StableContentStoreState = null;  // OPTIONAL
  var stableIdentity : ?Ic402.StableIdentityState = null;     // OPTIONAL
  var stableServices : ?Ic402.StableServiceRegistryState = null; // OPTIONAL

  // The ckUSDC ledger principal (mainnet). Deploy scripts patch for testnet.
  let CKUSDC = "xevnm-gaaaa-aaaar-qafnq-cai";

  transient let gate = Ic402.Gateway(
    {
      // ICP payment recipient — this canister
      recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };

      // ICP tokens accepted (ckUSDC via ICRC-2)
      tokens = [{
        ledger = Principal.fromText(CKUSDC);
        symbol = "ckUSDC";
        decimals = 6;
      }];

      // EVM chains accepted (USDC on 5 chains). Set to [] for ICP-only.
      // Deploy scripts patch recipient address and chain IDs for testnet.
      // Source has MAINNET values.
      evmChains = [
        { chainId = 8453;  recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
        { chainId = 1;     recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
        { chainId = 43114; recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
        { chainId = 10;    recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
        { chainId = 42161; recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
      ];

      // EVM RPC canister. Null = mainnet default (7hfb6-...).
      // Deploy scripts patch for local dev.
      evmRpcCanister = null;

      // tECDSA key for auto-deriving the canister's EVM address.
      // "key_1" for mainnet. Deploy scripts patch to "dfx_test_key" for local.
      // Set to null to disable EVM address derivation (ICP-only mode).
      ecdsaKeyName = ?"key_1";

      // Nonce validity window. Null = 300 seconds (5 minutes).
      nonceExpirySeconds = null;
    },
    Principal.fromActor(KnowledgeBase),
  );

  // OPTIONAL components — declared early so stable state loading can reference them.
  // Remove any you don't use (and their stableX / loadStable / toStable lines).
  transient let store = Ic402.ContentStore(Principal.fromActor(KnowledgeBase));
  transient let identity = Ic402.Identity({
    chain = #base;
    card = {
      name = "KnowledgeBase";
      description = "Paid knowledge base with x402 payments";
      services = [{
        name = "search";
        endpoint = "https://" # Principal.toText(Principal.fromActor(KnowledgeBase)) # ".icp0.io";
        version = "1.0"; skills = ["search", "qa"]; domains = ["knowledge"];
      }];
      x402Support = true;
    };
    ecdsaKeyName = "key_1"; // patched to "dfx_test_key" for local
    evmRpcCanister = null;
    registryAddress = "0x140D228d099367c273fDCD3C4Bfd87342ad7a8D2";
    chainId = 84532; // Base Sepolia — actual registry deployment
    gasConfig = null;
  });

  // Spending limits
  do {
    gate.setPolicy(null, {
      maxPerTransaction = ?50_000;      // $0.05 USDC
      maxPerDay = ?500_000;             // $0.50 USDC
      rateLimitPerMinute = ?120;
      maxSessionDeposit = ?100_000;     // $0.10 USDC
      maxConcurrentSessions = ?1;
      maxSessionDuration = ?(24 * 60 * 60 * 1_000_000_000);
      sessionIdleTimeout = ?(60 * 60 * 1_000_000_000);
      allowedCallers = null;
      blockedCallers = null;
    });
  };

  // Start background timers (session expiry, EVM address derivation)
  gate.startTimers<system>();

  // ── Stable state lifecycle ──

  // OPTIONAL: Service marketplace (coordinator pattern)
  transient let registry = Ic402.ServiceRegistry(
    Principal.fromActor(KnowledgeBase),
    {
      recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
      tokens = [{ ledger = Principal.fromText(CKUSDC); symbol = "ckUSDC"; decimals = 6 : Nat8 }];
    },
  );
  registry.startTimers<system>();

  do {
    switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} };
    switch (stableContent) { case (?d) { store.loadStable(d) }; case (null) {} };
    switch (stableIdentity) { case (?d) { identity.loadStable(d) }; case (null) {} };
    switch (stableServices) { case (?d) { registry.loadStable(d) }; case (null) {} };
  };

  system func preupgrade() {
    stableGateway := ?gate.toStable();
    stableContent := ?store.toStable();
    stableIdentity := ?identity.toStable();
    stableServices := ?registry.toStable();
  };

  system func postupgrade() {
    stableGateway := null;
    stableContent := null;
    stableIdentity := null;
    stableServices := null;
  };

  // ═══════════════════════════════════════════════════════════════════════
  // REQUIRED: Paid Endpoint (Candid RPC)
  //
  // The simplest payment pattern: charge per call via gate.requireAll()
  // and gate.settle(). Works with both ICP and EVM payments.
  // ═══════════════════════════════════════════════════════════════════════

  public shared func search(
    searchQuery : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : [Text];
    #error : Text;
  } {
    let amount = 1_000;  // $0.001 USDC

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.requireAll(amount)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(_)) { #ok(doSearch(searchQuery)) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.requireAll(amount)) };
        };
      };
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // REQUIRED: HTTP x402 Serving
  //
  // Serves content via ICP's HTTP gateway with standard x402 responses.
  // GET → 402 with payment options → client pays → retries with
  // X-PAYMENT header → canister settles → 200 with content.
  // ═══════════════════════════════════════════════════════════════════════

  transient let Http = Ic402.HttpHandler;

  public query func http_request(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let path = Http.getPath(request.url);

    // Free: canister info
    if (path == "/" or path == "") {
      return Http.http200Json("{\"name\":\"KnowledgeBase\",\"x402Support\":true}");
    };

    // Paid: content delivery
    if (Text.startsWith(path, #text "/content/")) {
      switch (Http.getHeader(request.headers, "x-payment")) {
        case (?_) { return Http.httpUpgrade() };  // has payment → upgrade to update call
        case (null) { return Http.http402(gate.requireAll(5_000)) }; // no payment → 402
      };
    };

    // Paid: search
    if (Text.startsWith(path, #text "/search")) {
      switch (Http.getHeader(request.headers, "x-payment")) {
        case (?_) { return Http.httpUpgrade() };
        case (null) { return Http.http402(gate.requireAll(1_000)) };
      };
    };

    // Paid: service request
    if (Text.startsWith(path, #text "/service/")) {
      let serviceId = switch (Text.stripStart(path, #text "/service/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing service ID") };
      };
      switch (registry.getService(serviceId)) {
        case (null) { return Http.httpError(404, "Service not found") };
        case (?svc) {
          if (not svc.enabled) return Http.httpError(404, "Service not available");
          let amount = switch (svc.pricing) {
            case (#Exact(p)) { p };
            case (#Upto(p)) { p };
            case (#Session) { 0 };
          };
          switch (Http.getHeader(request.headers, "x-payment")) {
            case (?_) { return Http.httpUpgrade() };
            case (null) { return Http.http402(gate.requireAll(amount)) };
          };
        };
      };
    };

    // Free: job status polling
    if (Text.startsWith(path, #text "/job/")) {
      let jobId = switch (Text.stripStart(path, #text "/job/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing job ID") };
      };
      switch (registry.getJob(jobId)) {
        case (null) { return Http.httpError(404, "Job not found") };
        case (?job) {
          let statusText = switch (job.status) {
            case (#Pending) { "pending" }; case (#Assigned) { "assigned" };
            case (#Computing) { "computing" }; case (#Submitted) { "submitted" };
            case (#Verified) { "verified" }; case (#Settled) { "settled" };
            case (#Disputed) { "disputed" }; case (#Expired) { "expired" };
            case (#Refunded) { "refunded" };
          };
          var json = "{\"id\":\"" # job.id # "\",\"status\":\"" # statusText # "\"";
          switch (job.completedAt) {
            case (?t) { json #= ",\"completedAt\":" # Int.toText(t) };
            case (null) {};
          };
          json #= "}";
          return Http.http200Json(json);
        };
      };
    };

    Http.httpError(404, "Not found");
  };

  public shared func http_request_update(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let path = Http.getPath(request.url);

    // Parse payment header — supports x402 v2 (base64) and legacy ic402 (raw JSON)
    let paymentHeader = switch (Http.getHeader(request.headers, "x-payment")) {
      case (?p) { p };
      case (null) { return Http.httpError(400, "Missing X-PAYMENT header") };
    };
    let sig = switch (Http.parseX402PaymentHeader(paymentHeader)) {
      case (?s) { s };
      case (null) {
        switch (Http.parsePaymentHeader(paymentHeader)) {
          case (?s) { s };
          case (null) { return Http.httpError(400, "Invalid X-PAYMENT header") };
        };
      };
    };

    // Settle payment and serve content
    if (Text.startsWith(path, #text "/content/")) {
      let contentId = switch (Text.stripStart(path, #text "/content/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing content ID") };
      };
      switch (await gate.settle(sig)) {
        case (#ok(receipt)) {
          let metadata = switch (store.getMetadata(contentId)) {
            case (null) { return Http.httpError(404, "Content not found") };
            case (?m) { m };
          };
          if (metadata.chunkCount <= 1) {
            switch (store.get(contentId)) {
              case (?blob) { return Http.http200(blob, metadata.mimeType) };
              case (null) { return Http.httpError(500, "Read failed") };
            };
          } else {
            return Http.http200Json("{\"delivery\":\"chunked\",\"chunkCount\":" # Nat.toText(metadata.chunkCount) # ",\"receiptId\":\"" # receipt.id # "\"}");
          };
        };
        case (#policyDenied(r)) { return Http.httpError(403, "Policy: " # r) };
        case (_) { return Http.httpError(402, "Payment failed") };
      };
    };

    if (Text.startsWith(path, #text "/search")) {
      let q = switch (Http.getQueryParam(request.url, "q")) { case (?q) { q }; case (null) { "ic402" } };
      switch (await gate.settle(sig)) {
        case (#ok(_)) {
          let results = doSearch(q);
          var json = "[";
          for (i in results.keys()) {
            if (i > 0) { json #= "," };
            json #= "\"" # results[i] # "\"";
          };
          return Http.http200Json("{\"results\":" # json # "]}");
        };
        case (#policyDenied(r)) { return Http.httpError(403, "Policy: " # r) };
        case (_) { return Http.httpError(402, "Payment failed") };
      };
    };

    // Service request: settle payment and create job
    if (Text.startsWith(path, #text "/service/")) {
      let serviceId = switch (Text.stripStart(path, #text "/service/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing service ID") };
      };
      switch (await gate.settle(sig)) {
        case (#ok(receipt)) {
          switch (registry.submitRequest(Principal.fromText(receipt.sender), serviceId, request.body, receipt, null)) {
            case (#ok(jobId)) {
              return Http.http202Json("{\"jobId\":\"" # jobId # "\",\"status\":\"pending\",\"pollUrl\":\"/job/" # jobId # "\"}");
            };
            case (#err(e)) { return Http.httpError(400, e) };
          };
        };
        case (#policyDenied(r)) { return Http.httpError(403, "Policy: " # r) };
        case (_) { return Http.httpError(402, "Payment failed") };
      };
    };

    Http.httpError(404, "Not found");
  };

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIONAL: Streaming Sessions
  //
  // For high-frequency access (e.g., AI agents querying thousands of
  // times per day). Reduces on-chain transactions from N to 2.
  //
  // Flow:
  //   1. Deposit: client signs EIP-3009 (EVM) or ICRC-2 approve (ICP)
  //   2. Stream: client sends Ed25519-signed vouchers per call (off-chain, free)
  //   3. Close: canister settles consumed amount + refunds remainder via tECDSA
  //
  // Remove this section if you only need per-request charges.
  // ═══════════════════════════════════════════════════════════════════════

  public shared func requestSession() : async Ic402.SessionIntent {
    gate.offerSession({
      network = "icp:1";
      token = CKUSDC;
      recipient = Principal.toText(Principal.fromActor(KnowledgeBase));
      suggestedDeposit = 50_000;
      minDeposit = ?5_000;
      expiry = Time.now() + 300_000_000_000;
      costPerCall = ?500;
      description = ?"Knowledge base session";
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
      case (#err(#depositBelowMinimum(min))) { #err("Min deposit: " # Nat.toText(min)) };
      case (#err(#settlementFailed(r))) { #err("Settlement failed: " # r) };
      case (#err(#expired(r))) { #err("Expired: " # r) };
      case (#err(#tokenNotAccepted(r))) { #err("Token not accepted: " # r) };
      case (#err(#insufficientFunds(r))) { #err("Insufficient funds: " # r) };
      case (#err(#invalidSignature(r))) { #err("Invalid signature: " # r) };
      case (#err(_)) { #err("Failed to open session") };
    };
  };

  public shared func sessionQuery(voucher : Ic402.Voucher, question : Text) : async { #ok : Text; #error : Text } {
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_)) { #ok(doQuery(question)) };
      case (#insufficientDeposit) { #error("Budget exhausted") };
      case (#policyDenied(r)) { #error("Policy: " # r) };
      case (_) { #error("Invalid voucher") };
    };
  };

  public shared(msg) func endSession(sessionId : Text) : async Ic402.PaymentResult {
    await gate.closeSession(msg.caller, sessionId);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIONAL: Encrypted Content Store
  //
  // In-canister content storage with encryption at rest. Content is
  // encrypted with a per-content key derived from the canister's secret.
  // Supports inline delivery (small files) and chunked delivery (large).
  //
  // Remove this section if you serve content from external sources.
  // ═══════════════════════════════════════════════════════════════════════

  // (store is declared at top for stable state loading)

  // Admin: upload/delete (controller-only)
  public shared(msg) func uploadContent(id : Text, mimeType : Text, data : Blob) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller)); store.put(id, mimeType, data);
  };
  public shared(msg) func uploadContentInit(id : Text, mimeType : Text, totalSize : Nat, chunkCount : Nat) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller)); store.putChunkedInit(id, mimeType, totalSize, chunkCount);
  };
  public shared(msg) func uploadContentChunk(id : Text, index : Nat, data : Blob) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller)); store.putChunk(id, index, data);
  };
  public shared(msg) func deleteContent(id : Text) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller)); store.delete(id);
  };
  public query func listContent() : async [Ic402.ContentEntry] { store.list() };

  // Paid delivery
  public shared(msg) func getContent(
    contentId : Text,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : Ic402.ContentDelivery;
    #error : Text;
  } {
    let amount = 5_000;  // $0.005 USDC
    switch (paymentSig) {
      case (null) { #paymentRequired(gate.requireAll(amount)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(receipt)) {
            let metadata = switch (store.getMetadata(contentId)) {
              case (null) { return #error("Not found") };
              case (?m) { m };
            };
            let contentRef = switch (store.toContentRef(contentId)) {
              case (?ref) { ref };
              case (null) { return #error("Not found") };
            };
            let grant = gate.issueGrant(contentRef, msg.caller, receipt.id, 5 * 60 * 1_000_000_000);
            if (metadata.chunkCount <= 1) {
              switch (store.get(contentId)) {
                case (?blob) { #ok({ grant; delivery = #inline(blob) }) };
                case (null) { #error("Read failed") };
              };
            } else {
              #ok({ grant; delivery = #canisterQuery({ method = "getChunk"; chunkCount = metadata.chunkCount }) });
            };
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (#invalidSignature(r)) { #error("Invalid signature: " # r) };
          case (#networkNotSupported(r)) { #error("Network: " # r) };
          case (#settlementFailed(r)) { #error("Settlement: " # r) };
          case (#expired(r)) { #error("Expired: " # r) };
          case (#insufficientFunds(r)) { #error("Funds: " # r) };
          case (_) { #paymentRequired(gate.requireAll(amount)) };
        };
      };
    };
  };

  public query func getChunk(grant : Ic402.AccessGrant, index : Nat) : async ?Blob {
    switch (gate.verifyGrant(grant)) {
      case (#ok) { store.getChunk(grant.contentRef.id, index) };
      case (_) { null };
    };
  };

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIONAL: Service Marketplace (Coordinator Pattern)
  //
  // The canister coordinates paid services. Operators register services,
  // buyers pay via x402, operators compute off-chain, canister verifies
  // results and settles payment. The canister never does the work — it
  // holds funds and ensures the buyer gets what they paid for.
  //
  // Remove this section if you only need content or sync charges.
  // ═══════════════════════════════════════════════════════════════════════

  // (registry is declared at top for stable state loading)

  // Admin: register and manage services
  public shared(msg) func registerService(
    name : Text,
    description : Text,
    serviceType : Ic402.ServiceType,
    pricing : Ic402.PricingScheme,
    verificationMethod : Text, // "AutoSettle", "HashMatch", "BuyerConfirm:300", "ZkGroth16"
    verifierCanisterId : ?Text,
    verificationKey : ?Blob,
    delivery : Ic402.ServiceDeliveryMethod,
    timeout : Nat,
  ) : async { #ok : Text; #err : Text } {
    assert(Principal.isController(msg.caller));
    let verification : Ic402.VerificationMethod = switch (verificationMethod) {
      case ("AutoSettle") { #AutoSettle };
      case ("HashMatch") { #HashMatch };
      case ("ZkGroth16") {
        switch (verifierCanisterId, verificationKey) {
          case (?cid, ?vk) { #ZkGroth16({ verifierCanister = Principal.fromText(cid); verificationKey = vk }) };
          case (_, _) { return #err("ZkGroth16 requires verifierCanisterId and verificationKey") };
        };
      };
      case (other) {
        if (Text.startsWith(other, #text "BuyerConfirm:")) {
          let seconds = switch (Text.stripStart(other, #text "BuyerConfirm:")) {
            case (?s) { switch (Nat.fromText(s)) { case (?n) { n }; case (null) { 3600 } } };
            case (null) { 3600 };
          };
          #BuyerConfirm({ disputeWindowSeconds = seconds });
        } else {
          #AutoSettle;
        };
      };
    };
    registry.registerService(msg.caller, {
      id = "";
      name;
      description;
      serviceType;
      pricing;
      verification;
      delivery;
      timeout;
      operatorId = msg.caller;
      enabled = false;
      createdAt = 0;
    });
  };

  public shared(msg) func enableService(id : Text) : async { #ok; #err : Text } {
    assert(Principal.isController(msg.caller));
    registry.enableService(msg.caller, id);
  };

  public shared(msg) func disableService(id : Text) : async { #ok; #err : Text } {
    assert(Principal.isController(msg.caller));
    registry.disableService(msg.caller, id);
  };

  public query func listServices() : async [Ic402.ServiceDefinition] {
    registry.listServices(true);
  };

  // Paid: submit a service request (charge per request, then create job)
  public shared(msg) func submitServiceRequest(
    serviceId : Text,
    params : Blob,
    paymentSig : ?Ic402.PaymentSignature,
  ) : async {
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : { jobId : Text };
    #error : Text;
  } {
    let svc = switch (registry.getService(serviceId)) {
      case (null) { return #error("Service not found") };
      case (?s) { s };
    };
    let amount = switch (svc.pricing) {
      case (#Exact(p)) { p };
      case (#Upto(p)) { p };
      case (#Session) { 0 };
    };
    switch (paymentSig) {
      case (null) { #paymentRequired(gate.requireAll(amount)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(receipt)) {
            switch (registry.submitRequest(msg.caller, serviceId, params, receipt, null)) {
              case (#ok(jobId)) { #ok({ jobId }) };
              case (#err(e)) { #error(e) };
            };
          };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (#expired(r)) { #error("Nonce expired: " # r) };
          case (#invalidSignature(r)) { #error("Invalid signature: " # r) };
          case (#insufficientFunds(r)) { #error("Insufficient funds: " # r) };
          case (#settlementFailed(r)) { #error("Settlement failed: " # r) };
          case (#networkNotSupported(r)) { #error("Network not supported: " # r) };
          case (#tokenNotAccepted(r)) { #error("Token not accepted: " # r) };
          case (_) { #error("Payment settlement failed") };
        };
      };
    };
  };

  // Operator: claim and fulfill jobs
  public shared(msg) func claimJob(jobId : Text) : async { #ok; #err : Text } {
    registry.claimJob(msg.caller, jobId);
  };

  public shared(msg) func submitJobResult(jobId : Text, result : Blob, proof : ?Blob, actualCost : ?Nat) : async { #ok; #err : Text } {
    await registry.submitResult(msg.caller, jobId, result, proof, actualCost);
  };

  // Buyer: confirm or dispute
  public shared(msg) func confirmJob(jobId : Text) : async { #ok; #err : Text } {
    await registry.confirmJob(msg.caller, jobId);
  };

  public shared(msg) func disputeJob(jobId : Text, reason : Text) : async { #ok; #err : Text } {
    registry.disputeJob(msg.caller, jobId, reason);
  };

  // Query: job status and results
  public query func getJobStatus(jobId : Text) : async ?Ic402.JobStatus {
    registry.getJobStatus(jobId);
  };

  public query func getJob(jobId : Text) : async ?Ic402.Job {
    registry.getJob(jobId);
  };

  public query func getJobResult(jobId : Text) : async ?Blob {
    registry.getJobResult(jobId);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIONAL: EVM Remote Signer
  //
  // The canister signs EVM transactions using tECDSA. The client handles
  // RPC submission, receipt polling, and HTTP requests. This eliminates
  // EVM RPC calls from the canister.
  //
  // Requires: USDC/ETH at the canister's EVM address on the target chain.
  // Remove this section if you only need ICP payments.
  // ═══════════════════════════════════════════════════════════════════════

  transient let signer = Ic402.EvmSigner.EvmSigner("key_1");

  /// Sign an EIP-3009 authorization for x402 payment.
  /// Client probes the URL, extracts chain/token/recipient/amount from the 402, and calls this.
  /// Canister signs → returns header → client retries with header.
  public shared(msg) func signX402Payment(
    chainId : Nat,
    tokenAddress : Text,
    recipient : Text,
    amount : Nat,
    tokenName : Text,
    tokenVersion : Text,
  ) : async { #ok : Ic402.SignedAuthorization; #err : Text } {
    assert(Principal.isController(msg.caller));
    await signer.signEip3009Authorization(chainId, tokenAddress, recipient, amount, tokenName, tokenVersion);
  };

  /// Sign an ERC-20 transfer. Client provides nonce + gas from their RPC.
  public shared(msg) func signErc20Transfer(
    chainId : Nat,
    tokenAddress : Text,
    recipientAddress : Text,
    amount : Nat,
    nonce : Nat,
    maxFeePerGas : Nat,
    maxPriorityFeePerGas : Nat,
  ) : async { #ok : Ic402.SignedTransaction; #err : Text } {
    assert(Principal.isController(msg.caller));
    await signer.signErc20Transfer(chainId, tokenAddress, recipientAddress, amount, nonce, maxFeePerGas, maxPriorityFeePerGas);
  };

  /// Sign a native ETH transfer. Client provides nonce + gas from their RPC.
  public shared(msg) func signEthTransfer(
    chainId : Nat,
    recipientAddress : Text,
    amountWei : Nat,
    gasLimit : Nat,
    nonce : Nat,
    maxFeePerGas : Nat,
    maxPriorityFeePerGas : Nat,
  ) : async { #ok : Ic402.SignedTransaction; #err : Text } {
    assert(Principal.isController(msg.caller));
    await signer.signEthTransfer(chainId, recipientAddress, amountWei, gasLimit, nonce, maxFeePerGas, maxPriorityFeePerGas);
  };

  /// Sign an ERC-8004 agent registration tx.
  /// Client provides nonce + gas from their RPC, broadcasts + polls receipt.
  public shared(msg) func signAgentRegistration(
    nonce : Nat,
    maxFeePerGas : Nat,
    maxPriorityFeePerGas : Nat,
  ) : async { #ok : Ic402.SignedTransaction; #err : Text } {
    assert(Principal.isController(msg.caller));
    await signer.signRegistration(
      "0x140D228d099367c273fDCD3C4Bfd87342ad7a8D2",
      84532,
      identity.getCard(),
      350_000,
      nonce,
      maxFeePerGas,
      maxPriorityFeePerGas,
    );
  };

  /// Sign arbitrary EIP-712 typed data. The generic primitive for DEX integration.
  /// The caller provides pre-computed domainSeparator and structHash (32 bytes each).
  /// The canister computes the EIP-712 digest and signs with tECDSA.
  public shared(msg) func signTypedData(
    domainSeparator : [Nat8],
    structHash : [Nat8],
  ) : async { #ok : Ic402.SignedTypedData; #err : Text } {
    assert(Principal.isController(msg.caller));
    await signer.signTypedData(domainSeparator, structHash);
  };

  /// Helper: compute keccak256 hash of a byte array. Useful for building type hashes.
  public query func keccak256(data : [Nat8]) : async [Nat8] {
    Ic402.EvmAddress.keccak256(data);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIONAL: ERC-8004 Identity Metadata
  //
  // Stores agent metadata for discovery. Registration is done via
  // signAgentRegistration() + client-side broadcast.
  //
  // Remove this section if you don't need cross-chain agent discovery.
  // ═══════════════════════════════════════════════════════════════════════

  // (identity is declared at top for stable state loading)

  public query func getAgentCard() : async Ic402.AgentCard { identity.getCard() };
  public query func getAgentId() : async ?Nat { identity.getAgentId() };
  public func getEvmPublicKey() : async Blob { await identity.getPublicKey("key_1") };
  public func getEvmAddress() : async Text { await identity.getEvmAddress() };

  // Admin
  // ═══════════════════════════════════════════════════════════════════════

  public shared(msg) func setPolicy(p : Ic402.SpendingPolicy) : async () {
    assert(Principal.isController(msg.caller));
    gate.setPolicy(null, p);
  };

  public shared(msg) func forceCloseSession(sessionId : Text) : async Ic402.PaymentResult {
    assert(Principal.isController(msg.caller));
    await gate.forceCloseSession(sessionId);
  };

  public query func verifyGrant(grant : Ic402.AccessGrant) : async Ic402.AccessGrantResult {
    gate.verifyGrant(grant);
  };

  // ── Internal stubs ──

  func doSearch(q : Text) : [Text] {
    ["ic402: payment library for ICP canisters", "Query: " # q]
  };
  func doQuery(question : Text) : Text { "Answer to: " # question };
};
