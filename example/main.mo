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
import Cycles "mo:base/ExperimentalCycles";

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
  // A1: ckUSDC ICRC-1 transfer fee (atomic units). Buyers of marketplace services pay
  // `price + CKUSDC_FEE` so the canister can cover the outbound settle transfer to the operator
  // (the ledger deducts amount+fee). NOTE: at 10_000 the fee dwarfs sub-cent service prices —
  // the quote shows it so the (uneconomical) breakdown is visible.
  let CKUSDC_FEE : Nat = 10_000;

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
  // H-6: Seed the content store's encryption key from canister randomness on
  // first deploy (idempotent; no-op once seeded / restored from stable state).
  store.startTimers<system>();

  // ── Stable state lifecycle ──

  // OPTIONAL: Service marketplace (coordinator pattern)
  transient let registry = Ic402.ServiceRegistry(
    Principal.fromActor(KnowledgeBase),
    {
      recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
      tokens = [{ ledger = Principal.fromText(CKUSDC); symbol = "ckUSDC"; decimals = 6 : Nat8 }];
      ledgerFee = CKUSDC_FEE;
    },
  );
  registry.startTimers<system>();

  // 1a: wire the marketplace's on-chain settlement/refund to the Gateway's tECDSA EVM sender,
  // so EVM-paid jobs are refunded/settled on their native rail instead of the ICP pool (C3).
  registry.setEvmTransfer(
    func(chainId : Nat, token : Text, to : Text, amount : Nat) : async {
      #confirmed : Text;
      #reverted : Text;
      #pending : Text;
      #err : Text;
    } {
      // B2: confirmed transfer — the registry finalizes #Settled/#Refunded only after the
      // on-chain transfer is confirmed mined, not on a mempool ack.
      await gate.sendErc20TransferConfirmed(chainId, token, to, amount);
    }
  );

  // Recovery: wire the READ-ONLY confirm hook so reconcileJob can re-poll a parked tx without
  // re-broadcasting it (the confirm path can never send a transaction).
  registry.setEvmConfirm(
    func(chainId : Nat, txHash : Text) : async { #confirmed; #reverted; #pending; #err : Text } {
      await gate.confirmEvmTransaction(chainId, txHash);
    }
  );

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
        switch (await gate.settle(sig, ?amount)) {
          // A nonce binds amount/token/network but NOT the resource, so a nonce minted at a
          // cheaper endpoint could be redeemed here. Verify the settled amount covers THIS
          // resource's price (cross-resource underpayment).
          case (#ok(receipt)) {
            if (receipt.amount < amount) {
              return #error("Underpayment: search requires " # Nat.toText(amount) # ", settled " # Nat.toText(receipt.amount));
            };
            #ok(doSearch(searchQuery));
          };
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

    // CORS preflight for the v2 custom `PAYMENT-SIGNATURE` request header.
    if (request.method == "OPTIONS") { return Http.httpOptions() };

    // Facilitator POST endpoints run in the update context (verify reads chain config; settle
    // broadcasts), so upgrade the query to an update call.
    if (path == "/verify" or path == "/settle") { return Http.httpUpgrade() };

    // Free: canister info
    if (path == "/" or path == "") {
      return Http.http200Json("{\"name\":\"KnowledgeBase\",\"x402Support\":true}");
    };

    // H-9: Paid resources ALWAYS upgrade to an update call. The 402 challenge
    // (which mints + persists a server nonce via gate.requireAll) must be issued
    // from an update context — issuing it here in a query would discard the nonce,
    // so settlement could never match it and the GET→402→pay→200 loop never closed.
    if (Text.startsWith(path, #text "/content/")) { return Http.httpUpgrade() };
    if (Text.startsWith(path, #text "/search")) { return Http.httpUpgrade() };

    // Paid: service request — cheap existence/enabled check, then defer to update.
    if (Text.startsWith(path, #text "/service/")) {
      let serviceId = switch (Text.stripStart(path, #text "/service/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing service ID") };
      };
      switch (registry.getService(serviceId)) {
        case (null) { return Http.httpError(404, "Service not found") };
        case (?svc) {
          if (not svc.enabled) return Http.httpError(404, "Service not available");
          return Http.httpUpgrade();
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
            case (#Verified) { "verified" }; case (#Settling) { "settling" };
            case (#Settled) { "settled" };
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

    // x402 facilitator: advertise the (x402Version, scheme, network) kinds this canister can
    // settle, plus its on-chain signer address. ic402 self-hosts the facilitator role.
    if (path == "/supported") {
      return Http.http200Json(gate.supportedJson());
    };

    // x402 discovery (Bazaar): list the paid resources with their v2 accepts[] (non-minting —
    // describeAll advertises price/asset without burning a server nonce; clients hit the
    // resource for a live challenge).
    if (path == "/discovery/resources") {
      var items = Http.discoveryItemJson(
        Http.buildResourceUrl(request.headers, "/search"),
        "http",
        Http.acceptsArrayJson(gate.describeAll(1_000)),
      );
      for (entry in store.list().vals()) {
        items #= "," # Http.discoveryItemJson(
          Http.buildResourceUrl(request.headers, "/content/" # entry.id),
          "http",
          Http.acceptsArrayJson(gate.describeAll(5_000)),
        );
      };
      for (svc in registry.listServices(true).vals()) {
        let amt = switch (svc.pricing) {
          case (#Exact(p)) { p + CKUSDC_FEE };
          case (#Upto(p)) { p + CKUSDC_FEE };
          case (#Session) { 0 };
        };
        if (amt > 0) {
          items #= "," # Http.discoveryItemJson(
            Http.buildResourceUrl(request.headers, "/service/" # svc.id),
            "http",
            Http.acceptsArrayJson(gate.describeAll(amt)),
          );
        };
      };
      return Http.http200Json("{\"resources\":[" # items # "]}");
    };

    Http.httpError(404, "Not found");
  };

  // Map a settle PaymentResult to a v2 SettlementResponse JSON, mapping ic402's result variants
  // to the x402 v2 error-reason vocabulary. Used by the facilitator /settle endpoint and by HTTP
  // resource settlement failures.
  func settleResultJson(result : Ic402.PaymentResult, network : Text, payer : Text, amount : Nat) : Text {
    switch (result) {
      case (#ok(receipt)) { Http.settlementResponseJson(true, receipt.txHash, receipt.network, receipt.sender, receipt.amount, null) };
      case (#invalidSignature(_)) { Http.settlementResponseJson(false, null, network, payer, amount, ?"invalid_exact_evm_payload_authorization_signature") };
      case (#insufficientFunds(_)) { Http.settlementResponseJson(false, null, network, payer, amount, ?"insufficient_funds") };
      case (#expired(_)) { Http.settlementResponseJson(false, null, network, payer, amount, ?"invalid_exact_evm_payload_authorization_valid_before") };
      case (#networkNotSupported(_)) { Http.settlementResponseJson(false, null, network, payer, amount, ?"invalid_network") };
      case (#tokenNotAccepted(_)) { Http.settlementResponseJson(false, null, network, payer, amount, ?"unsupported_scheme") };
      case (#policyDenied(_)) { Http.settlementResponseJson(false, null, network, payer, amount, ?"unexpected_settle_error") };
      // settlementFailed (on-chain revert / RPC), settlementPending, and any other variant.
      case (_) { Http.settlementResponseJson(false, null, network, payer, amount, ?"invalid_transaction_state") };
    };
  };

  public shared func http_request_update(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let path = Http.getPath(request.url);
    if (request.method == "OPTIONS") { return Http.httpOptions() };

    // x402 v2 facilitator endpoints (POST { paymentPayload, paymentRequirements }).
    // /verify validates the exact/EVM authorization off-chain; /settle broadcasts on-chain.
    if (path == "/verify" or path == "/settle") {
      let body = switch (Text.decodeUtf8(request.body)) {
        case (?t) { t };
        case (null) { return Http.httpError(400, "Invalid request body") };
      };
      let parsed = switch (Http.parseFacilitatorRequest(body)) {
        case (?p) { p };
        case (null) { return Http.httpError(400, "Invalid facilitator request (need paymentPayload + paymentRequirements)") };
      };
      if (path == "/verify") {
        let v = gate.verifyPayment(parsed.sig, parsed.amount, parsed.payTo, parsed.asset);
        return Http.http200Json(Http.verifyResponseJson(v.isValid, v.invalidReason, v.payer));
      } else {
        let result = await gate.settle(parsed.sig, ?parsed.amount);
        return Http.http200Json(settleResultJson(result, parsed.sig.network, parsed.sig.sender, parsed.amount));
      };
    };

    // x402 v2 ResourceInfo.url — absolute URL built from the Host header (ICP request.url is path-only).
    let resourceUrl = Http.buildResourceUrl(request.headers, request.url);

    // v2: a stock client sends the payment in PAYMENT-SIGNATURE; accept the legacy x-payment as a
    // fallback. H-9: with no payment yet, issue the 402 challenge HERE (update context) so
    // gate.requireAll persists the server nonce that the ICP/legacy rail binds to.
    let paymentHeader = switch (Http.getHeader(request.headers, "payment-signature")) {
      case (?p) { p };
      case (null) {
        switch (Http.getHeader(request.headers, "x-payment")) {
          case (?p) { p };
          case (null) {
            if (Text.startsWith(path, #text "/content/")) { return Http.http402(gate.requireAll(5_000), resourceUrl) };
            if (Text.startsWith(path, #text "/search")) { return Http.http402(gate.requireAll(1_000), resourceUrl) };
            if (Text.startsWith(path, #text "/service/")) {
              let serviceId = switch (Text.stripStart(path, #text "/service/")) {
                case (?id) { id };
                case (null) { return Http.httpError(400, "Missing service ID") };
              };
              switch (registry.getService(serviceId)) {
                case (null) { return Http.httpError(404, "Service not found") };
                case (?svc) {
                  if (not svc.enabled) return Http.httpError(404, "Service not available");
                  switch (svc.pricing) {
                    // #Session is billed against an existing session deposit, not a
                    // per-request 402 charge — requireAll(0) would trap.
                    case (#Session) { return Http.httpError(400, "Service uses session billing — open a session instead") };
                    // A1: charge price + ledger fee so the canister can cover the outbound settle.
                    case (#Exact(p)) { return Http.http402(gate.requireAll(p + CKUSDC_FEE), resourceUrl) };
                    case (#Upto(p)) { return Http.http402(gate.requireAll(p + CKUSDC_FEE), resourceUrl) };
                  };
                };
              };
            };
            return Http.httpError(400, "Missing PAYMENT-SIGNATURE header");
          };
        };
      };
    };
    let sig = switch (Http.parseX402PaymentHeader(paymentHeader)) {
      case (?s) { s };
      case (null) {
        switch (Http.parsePaymentHeader(paymentHeader)) {
          case (?s) { s };
          case (null) { return Http.httpError(400, "Invalid PAYMENT-SIGNATURE header") };
        };
      };
    };

    // Settle payment and serve content
    if (Text.startsWith(path, #text "/content/")) {
      let contentId = switch (Text.stripStart(path, #text "/content/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing content ID") };
      };
      let contentResult = await gate.settle(sig, ?5_000);
      switch (contentResult) {
        case (#ok(receipt)) {
          // Cross-resource underpayment: the nonce binds amount/token/network but not the
          // resource, so reject a settlement that doesn't cover this content's price.
          if (receipt.amount < 5_000) {
            return Http.httpError(402, "Underpayment: content requires 5000, settled " # Nat.toText(receipt.amount));
          };
          let settlement = Http.settlementResponseJson(true, receipt.txHash, receipt.network, receipt.sender, receipt.amount, null);
          let metadata = switch (store.getMetadata(contentId)) {
            case (null) { return Http.httpError(404, "Content not found") };
            case (?m) { m };
          };
          if (metadata.chunkCount <= 1) {
            switch (store.get(contentId)) {
              case (?blob) { return Http.http200WithSettlement(blob, metadata.mimeType, settlement) };
              case (null) { return Http.httpError(500, "Read failed") };
            };
          } else {
            return Http.http200JsonWithSettlement("{\"delivery\":\"chunked\",\"chunkCount\":" # Nat.toText(metadata.chunkCount) # ",\"receiptId\":\"" # receipt.id # "\"}", settlement);
          };
        };
        // v2: emit a SettlementResponse (success:false + error reason) on any settle failure.
        case (_) { return Http.http402WithSettlement(settleResultJson(contentResult, sig.network, sig.sender, 5_000)) };
      };
    };

    if (Text.startsWith(path, #text "/search")) {
      let q = switch (Http.getQueryParam(request.url, "q")) { case (?q) { q }; case (null) { "ic402" } };
      let searchResult = await gate.settle(sig, ?1_000);
      switch (searchResult) {
        case (#ok(receipt)) {
          if (receipt.amount < 1_000) {
            return Http.httpError(402, "Underpayment: search requires 1000, settled " # Nat.toText(receipt.amount));
          };
          let settlement = Http.settlementResponseJson(true, receipt.txHash, receipt.network, receipt.sender, receipt.amount, null);
          let results = doSearch(q);
          var json = "[";
          for (i in results.keys()) {
            if (i > 0) { json #= "," };
            json #= "\"" # results[i] # "\"";
          };
          return Http.http200JsonWithSettlement("{\"results\":" # json # "]}", settlement);
        };
        case (_) { return Http.http402WithSettlement(settleResultJson(searchResult, sig.network, sig.sender, 1_000)) };
      };
    };

    // Service request: settle payment and create job
    if (Text.startsWith(path, #text "/service/")) {
      let serviceId = switch (Text.stripStart(path, #text "/service/")) {
        case (?id) { id };
        case (null) { return Http.httpError(400, "Missing service ID") };
      };
      let serviceResult = await gate.settle(sig, null);
      switch (serviceResult) {
        case (#ok(receipt)) {
          // C-5: receipt.sender is a principal (ICP) or a 0x EVM address (EVM).
          // Pass it through as Text — do NOT coerce to Principal (that trapped for
          // EVM senders AFTER the on-chain transfer had already executed).
          // submitRequest enforces receipt.amount >= price + fee (cross-resource safe).
          switch (registry.submitRequest(receipt.sender, serviceId, request.body, receipt, null)) {
            case (#ok(jobId)) {
              let settlement = Http.settlementResponseJson(true, receipt.txHash, receipt.network, receipt.sender, receipt.amount, null);
              return Http.http200JsonWithSettlement("{\"jobId\":\"" # jobId # "\",\"status\":\"pending\",\"pollUrl\":\"/job/" # jobId # "\"}", settlement);
            };
            case (#err(e)) { return Http.httpError(400, e) };
          };
        };
        // amount unknown on a failed service settle (varies per service); 0 in the response.
        case (_) { return Http.http402WithSettlement(settleResultJson(serviceResult, sig.network, sig.sender, 0)) };
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
    // Honour the rail the client signed for: an EVM (eip155:*) signature opens an EVM session
    // (deposit via EIP-3009, settle/refund on that chain via tECDSA); anything else is the default
    // ICP ckUSDC session. Previously this always built the ICP intent, so an "EVM session" silently
    // became an ICP one and the EIP-3009 authorization was ignored.
    let intent = if (Text.startsWith(sig.network, #text "eip155:")) {
      switch (gate.evmSessionParams(sig.network)) {
        case (?p) {
          gate.offerSession({
            network = sig.network;
            token = p.token;
            recipient = p.recipient;
            suggestedDeposit = 50_000;
            minDeposit = ?5_000;
            expiry = Time.now() + 300_000_000_000;
            costPerCall = ?500;
            description = ?"Knowledge base session (EVM)";
          });
        };
        case (null) {
          return #err("EVM session unavailable for " # sig.network # " (chain not configured or canister EVM address not derived yet)");
        };
      };
    } else {
      await requestSession();
    };
    switch (await gate.openSession(msg.caller, intent, config, sig)) {
      case (#ok(state)) { #ok(state) };
      case (#err(#policyDenied(r))) { #err("Policy: " # r) };
      case (#err(#depositBelowMinimum(min))) { #err("Min deposit: " # Nat.toText(min)) };
      case (#err(#settlementFailed(r))) { #err("Settlement failed: " # r) };
      case (#err(#settlementPending(r))) { #err("Settlement pending: " # r) };
      case (#err(#networkNotSupported(r))) { #err("Network not supported: " # r) };
      case (#err(#expired(r))) { #err("Expired: " # r) };
      case (#err(#tokenNotAccepted(r))) { #err("Token not accepted: " # r) };
      case (#err(#insufficientFunds(r))) { #err("Insufficient funds: " # r) };
      case (#err(#invalidSignature(r))) { #err("Invalid signature: " # r) };
      case (#err(_)) { #err("Failed to open session") };
    };
  };

  public shared func sessionQuery(voucher : Ic402.Voucher, question : Text) : async { #ok : Text; #error : Text } {
    // Surface the SPECIFIC voucher-rejection reason (the old catch-all "Invalid voucher" hid which
    // of signature / sequence / session-state / overflow failed, making the demo undiagnosable).
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_)) { #ok(doQuery(question)) };
      case (#insufficientDeposit) { #error("Budget exhausted: cumulative amount exceeds the deposit") };
      case (#policyDenied(r)) { #error("Policy: " # r) };
      case (#invalidSequence) { #error("Invalid voucher: sequence/cumulativeAmount not strictly increasing (each must exceed the previous voucher's)") };
      case (#invalidSignature) { #error("Invalid voucher: Ed25519 signature does not verify against the session's registered public key") };
      case (#sessionNotOpen) { #error("Invalid voucher: session not open (unknown id, closed, expired, or idle-timed-out)") };
      case (#payloadOverflow) { #error("Invalid voucher: cumulativeAmount or sequence exceeds the Nat64 maximum") };
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
        switch (await gate.settle(sig, ?amount)) {
          case (#ok(receipt)) {
            // Cross-resource underpayment: the nonce binds amount/token/network but not the
            // resource, so reject a settlement that doesn't cover this content's price.
            if (receipt.amount < amount) {
              return #error("Underpayment: content requires " # Nat.toText(amount) # ", settled " # Nat.toText(receipt.amount));
            };
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
                case (?blob) { #ok({ grant; delivery = #inline(blob); settlementTxHash = receipt.txHash }) };
                case (null) { #error("Read failed") };
              };
            } else {
              #ok({ grant; delivery = #canisterQuery({ method = "getChunk"; chunkCount = metadata.chunkCount }); settlementTxHash = receipt.txHash });
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

  // H-8/M-3: caller-aware — only the grantee may fetch chunks (grants are not
  // transferable bearer tokens). `shared query (msg)` exposes the caller.
  public shared query (msg) func getChunk(grant : Ic402.AccessGrant, index : Nat) : async ?Blob {
    switch (gate.verifyGrant(msg.caller, grant)) {
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
      // "ZkGroth16" = params-only public inputs (default). "ZkGroth16:bind" = also bind
      // SHA-256(result) as public input 0 — only with a circuit built to commit to it.
      case ("ZkGroth16" or "ZkGroth16:bind") {
        switch (verifierCanisterId, verificationKey) {
          case (?cid, ?vk) {
            #ZkGroth16({
              verifierCanister = Principal.fromText(cid);
              verificationKey = vk;
              bindResult = (verificationMethod == "ZkGroth16:bind");
            });
          };
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

  // C4: read-only price quote for a service. Lets a client (e.g. the MCP) discover the amount
  // to enforce its spend cap WITHOUT invoking the state-changing submitServiceRequest probe
  // (which mints a nonce). A query — no state change, no inter-canister calls.
  // A1: the quote is the transparency surface for the ledger fee. `amount` is the service
  // price; `fee` is the ckUSDC transfer fee added on top; `total` (= amount + fee) is what the
  // buyer must actually pay. #Session services bill against a deposit, so no per-request fee.
  public query func quoteServiceRequest(serviceId : Text) : async {
    #ok : { amount : Nat; fee : Nat; total : Nat; pricingKind : Text; enabled : Bool };
    #err : Text;
  } {
    switch (registry.getService(serviceId)) {
      case (null) { #err("Service not found") };
      case (?svc) {
        let (amount, kind) = switch (svc.pricing) {
          case (#Exact(p)) { (p, "Exact") };
          case (#Upto(p)) { (p, "Upto") };
          case (#Session) { (0, "Session") };
        };
        let fee = switch (svc.pricing) { case (#Session) { 0 }; case (_) { CKUSDC_FEE } };
        #ok({ amount; fee; total = amount + fee; pricingKind = kind; enabled = svc.enabled });
      };
    };
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
      // #Session pricing has amount 0 (billed against a session deposit) — guard
      // against requireAll(0), which traps.
      case (null) {
        if (amount == 0) { #error("Service uses session billing — open a session instead") } else {
          // A1: quote price + ledger fee (matches quoteServiceRequest.total).
          #paymentRequired(gate.requireAll(amount + CKUSDC_FEE));
        };
      };
      case (?sig) {
        switch (await gate.settle(sig, null)) {
          case (#ok(receipt)) {
            switch (registry.submitRequest(Principal.toText(msg.caller), serviceId, params, receipt, null)) {
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

  // 1a: operators register their EVM payout address so EVM-paid jobs they fulfil are settled
  // on-chain to it (rather than from the ICP pool — audit C3).
  public shared(msg) func setEvmPayout(address : Text) : async { #ok; #err : Text } {
    registry.setOperatorEvmPayout(msg.caller, address);
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

  // Observability (controller-only): list a service's jobs, optionally filtered by status —
  // e.g. statusFilter = ?#Settling to enumerate jobs parked mid-settlement.
  public shared query (msg) func listJobs(serviceId : Text, statusFilter : ?Ic402.JobStatus) : async [Ic402.Job] {
    assert(Principal.isController(msg.caller));
    registry.listJobs(serviceId, statusFilter);
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
      // register(string,string,string,string[],string[],bool) writes 5 strings/arrays and
      // emits AgentRegistered; 350_000 was insufficient (reverted out of gas, gasUsed ==
      // limit). An observed successful mint on Base Sepolia used ~396,621 gas; 600_000
      // gives headroom (unused gas is refunded — only consumed gas is charged).
      600_000,
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

  // Read back the LIVE global spending policy (the one set via setPolicy(null, _)).
  // Public read-only query: the limits are non-secret (they're advertised in the 402
  // challenge anyway) and this lets clients/the demo display the in-canister policy
  // instead of hardcoding it.
  public query func getPolicyConfig() : async Ic402.SpendingPolicy {
    // SEC-4: this is a PUBLIC query, so redact the access-control roster — the spend
    // limits are non-secret (advertised in the 402 challenge) but allowedCallers /
    // blockedCallers are an access-control list that shouldn't be world-readable.
    let p = gate.getGlobalPolicy();
    { p with allowedCallers = null; blockedCallers = null };
  };

  // Operator health / metrics (controller-only): cycle balance + job/session status counts.
  // NEW-4 observability: watch `jobs.parked` and `sessions.closing` — those are funds parked
  // mid-settlement (an EVM transfer that broadcast but hasn't confirmed); reconcileJob /
  // forceResolveSession clear them. Each EVM settle burns ~100B cycles (~7 EVM-RPC outcalls + a
  // tECDSA sign), so cyclesBalance is the other key thing to watch — and EvmSender refuses to
  // broadcast below a 120B floor (MIN_BROADCAST_CYCLES).
  public shared query (msg) func health() : async {
    cyclesBalance : Nat;
    jobs : { total : Nat; settling : Nat; settled : Nat; refunded : Nat; expired : Nat; active : Nat; parked : Nat };
    sessions : { total : Nat; open : Nat; closing : Nat; closed : Nat; expired : Nat };
  } {
    assert(Principal.isController(msg.caller));
    {
      cyclesBalance = Cycles.balance();
      jobs = registry.jobCounts();
      sessions = gate.sessionCounts();
    };
  };

  public shared(msg) func forceCloseSession(sessionId : Text) : async Ic402.PaymentResult {
    assert(Principal.isController(msg.caller));
    await gate.forceCloseSession(sessionId);
  };

  // Recovery (controller-only): CONFIRM-ONLY auto-reconcile of a job parked mid-settlement. Finds
  // the stored parked tx, re-polls it on-chain, and finalizes #Settled/#Refunded ONLY on a mined
  // status==1 — never re-broadcasts. Use `health`/`listJobs` to find parked jobs (#Settling).
  public shared(msg) func reconcileJob(jobId : Text) : async { #ok : Text; #err : Text } {
    assert(Principal.isController(msg.caller));
    await registry.reconcileJob(jobId);
  };

  // Manual escape hatches (controller-only) for a parked record whose tx is genuinely dead
  // (reverted / never mined, so reconcileJob can't finalize it). Verify the on-chain outcome
  // yourself, then force the record to a terminal state so it stops pinning memory. STATE
  // assertion only — these move NO funds; reconcile any real fund movement out-of-band.
  public shared(msg) func resolveJob(jobId : Text, terminal : Ic402.JobStatus) : async { #ok; #err : Text } {
    assert(Principal.isController(msg.caller));
    registry.resolveJob(jobId, terminal);
  };

  public shared(msg) func forceResolveSession(sessionId : Text) : async { #ok; #err : Text } {
    assert(Principal.isController(msg.caller));
    gate.forceResolveSession(sessionId);
  };

  // Recovery (controller-only): CONFIRM-ONLY auto-reconcile of an EVM session parked in #closing.
  // Re-polls the stored parked close tx and finalizes #closed only on a mined status==1 (never
  // re-broadcasts). A confirmed settle with a remainder still owed can't be auto-completed (the
  // refund is unsent) — use forceResolveSession + sweepEvm there. Find parked sessions via
  // `health` (sessions.closing).
  public shared(msg) func reconcileSession(sessionId : Text) : async { #ok : Text; #err : Text } {
    assert(Principal.isController(msg.caller));
    await gate.reconcileSession(sessionId);
  };

  // Operator EVM escape hatch (controller-only): transfer `amount` of an ERC-20 (e.g. USDC) from
  // the canister's OWN tECDSA-derived EVM address to `to` on `chainId`, via the confirmed-transfer
  // sender (reports #confirmed only after a mined status==1). Use it to evacuate the address on a
  // key/subnet-compromise suspicion, or to settle a never-landed refund for a job/session you had
  // to force-resolve. The operator supplies `amount` (read the on-chain balance off-chain) so no
  // balanceOf RPC is needed; the chain enforces the actual balance.
  public shared(msg) func sweepEvm(chainId : Nat, token : Text, to : Text, amount : Nat) : async {
    #confirmed : Text;
    #reverted : Text;
    #pending : Text;
    #err : Text;
  } {
    assert(Principal.isController(msg.caller));
    await gate.sendErc20TransferConfirmed(chainId, token, to, amount);
  };

  public shared query (msg) func verifyGrant(grant : Ic402.AccessGrant) : async Ic402.AccessGrantResult {
    gate.verifyGrant(msg.caller, grant);
  };

  // ── Internal stubs ──

  func doSearch(q : Text) : [Text] {
    ["ic402: payment library for ICP canisters", "Query: " # q]
  };
  func doQuery(question : Text) : Text { "Answer to: " # question };
};
