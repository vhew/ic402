/// ic402 Example Canister
///
/// Demonstrates a paid knowledge base API with multiple optional features.
/// The required core is small — everything marked OPTIONAL can be removed.
///
/// Structure:
///   1. REQUIRED: Gateway + paid endpoint + HTTP 402 serving
///   2. OPTIONAL: Streaming sessions (escrow + vouchers)
///   3. OPTIONAL: Encrypted content store (in-canister)
///   4. OPTIONAL: x402 client (canister pays external APIs)
///   5. OPTIONAL: ERC-8004 identity (agent discovery on Base)

import Ic402 "../src/ic402/lib";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
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

  // The ckUSDC ledger principal (mainnet). Deploy scripts patch for testnet.
  let CKUSDC = "txyno-ch777-77776-aaaaq-cai";

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
        { chainId = 84532;  recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"; symbol = "USDC"; decimals = 6 : Nat8; name = ?"USDC"; version = null }] },
        { chainId = 11155111;     recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
        { chainId = 43113; recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x5425890298aed601595a70AB815c96711a31Bc65"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
        { chainId = 11155420;    recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x5fd84259d66Cd46123540766Be93DFE6D43130D7"; symbol = "USDC"; decimals = 6 : Nat8; name = ?"USDC"; version = null }] },
        { chainId = 421614; recipient = "0x0000000000000000000000000000000000000000";
          tokens = [{ address = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"; symbol = "USDC"; decimals = 6 : Nat8; name = null; version = null }] },
      ];

      // EVM RPC canister. Null = mainnet default (7hfb6-...).
      // Deploy scripts patch for local dev.
      evmRpcCanister = ?"t63gs-up777-77776-aaaba-cai";

      // tECDSA key for auto-deriving the canister's EVM address.
      // "dfx_test_key" for mainnet. Deploy scripts patch to "dfx_test_key" for local.
      // Set to null to disable EVM address derivation (ICP-only mode).
      ecdsaKeyName = ?"dfx_test_key";

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
    ecdsaKeyName = "dfx_test_key"; // patched to "dfx_test_key" for local
    evmRpcCanister = ?"t63gs-up777-77776-aaaba-cai";
    registryAddress = "0x140D228d099367c273fDCD3C4Bfd87342ad7a8D2";
    chainId = 84532;
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

  do {
    switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} };
    switch (stableContent) { case (?d) { store.loadStable(d) }; case (null) {} };
    switch (stableIdentity) { case (?d) { identity.loadStable(d) }; case (null) {} };
  };

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
  // OPTIONAL: x402 Client (canister pays external APIs)
  //
  // The canister acts as an x402 client — it can pay for content from
  // external x402-gated APIs using its tECDSA-derived EVM address.
  // Signs EIP-3009 TransferWithAuthorization, sends via X-Payment header.
  //
  // Requires: USDC at the canister's EVM address on the configured chain.
  // Remove this section if the canister only receives payments.
  // ═══════════════════════════════════════════════════════════════════════

  public query func httpTransform(args : { response : Ic402.HttpResponse_; context : Blob }) : async Ic402.HttpResponse_ {
    Ic402.X402Client.transformResponse(args.response);
  };

  transient let x402client = Ic402.X402Client.X402Client(
    "dfx_test_key",        // tECDSA key name. Deploy scripts patch to "dfx_test_key" for local.
    84532,          // Base Sepolia. Deploy scripts patch to 84532 (Sepolia) for local.
    "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // USDC on Base. Patched for testnet.
    ?httpTransform,
  );

  /// GET an external x402 endpoint. Controller-only to prevent USDC drain.
  public shared(msg) func fetchX402(url : Text) : async Ic402.X402Client.FetchResult {
    assert(Principal.isController(msg.caller));
    await x402client.fetchWithPayment(url, #get, null, [], null);
  };

  /// POST to an external x402 endpoint (e.g. AI APIs). Controller-only.
  public shared(msg) func fetchX402Post(url : Text, body : Text, contentType : Text) : async Ic402.X402Client.FetchResult {
    assert(Principal.isController(msg.caller));
    await x402client.fetchWithPayment(url, #post, ?Text.encodeUtf8(body), [{ name = "Content-Type"; value = contentType }], null);
  };

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIONAL: ERC-8004 Agent Identity on Base
  //
  // Registers this canister as a discoverable agent on Base's
  // IdentityRegistry contract. Other agents find this service by
  // querying the registry, then pay via x402.
  //
  // Requires: ETH at the canister's EVM address for gas (registration tx).
  // Remove this section if you don't need cross-chain agent discovery.
  // ═══════════════════════════════════════════════════════════════════════

  // (identity is declared at top for stable state loading)

  public query func getAgentCard() : async Ic402.AgentCard { identity.getCard() };
  public query func getAgentId() : async ?Nat { identity.getAgentId() };
  public func getEvmPublicKey() : async Blob { await identity.getPublicKey("dfx_test_key") };
  public func getEvmAddress() : async Text { await identity.getEvmAddress() };

  public shared(msg) func registerAgent() : async Ic402.RegisterAgentResult {
    assert(Principal.isController(msg.caller));
    await identity.registerAgent();
  };

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
