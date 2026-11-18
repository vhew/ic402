/// ic402 — Service marketplace: register services, manage jobs, verify results, settle payments.
///
/// The canister acts as a trusted coordinator: it holds funds in escrow,
/// assigns jobs to operators, optionally verifies results (ZK, hash, or
/// buyer confirmation), and settles payment on completion.
///
/// ```motoko
/// transient let registry = Ic402.ServiceRegistry(
///   Principal.fromActor(self), config, policy, escrowManager,
/// );
/// ```

import Types "Types";
import HashMap "mo:base/HashMap";
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Utils "Utils";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Timer "mo:base/Timer";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import SHA256 "mo:sha2/Sha256";
import Principal "mo:base/Principal";
import Char "mo:base/Char";
import Nat32 "mo:base/Nat32";
import EvmAddress "EvmAddress";
import EvmUtils "EvmUtils";

module {

  /// Service marketplace: register services, manage jobs, verify and settle.
  /// Minimal config for ServiceRegistry — only the fields it uses.
  public type ServiceConfig = {
    recipient : Types.Account;
    tokens : [Types.TokenConfig];
    // A1: the ICP ledger transfer fee (e.g. ckUSDC = 10_000). Buyers pay `price + ledgerFee`
    // so the pool can cover the outbound settle/refund transfer (the ledger deducts amount+fee).
    // Without collecting it, every settle is short by one fee and fails (the audit fee finding).
    ledgerFee : Nat;
  };

  /// Service marketplace: register services, claim/settle/refund jobs, and reconcile parked
  /// EVM settlements. ICP-only unless the consuming canister wires the EVM transfer/confirm hooks.
  public class ServiceRegistry(
    _canisterPrincipal : Principal,
    config : ServiceConfig,
  ) {
    var services = HashMap.HashMap<Text, Types.ServiceDefinition>(16, Text.equal, Text.hash);
    var jobs = HashMap.HashMap<Text, Types.Job>(64, Text.equal, Text.hash);
    var serviceCounter : Nat = 0;
    var jobCounter : Nat = 0;
    // 1a: payment rail (chain + token) for EVM-paid jobs, keyed by jobId. Lets the registry
    // settle/refund an EVM job on-chain on the rail it was paid on, rather than from the ICP
    // pool (audit C3). Keyed separately so the public Job type / Candid interface is unchanged.
    var evmJobRail = HashMap.HashMap<Text, Types.EvmRail>(16, Text.equal, Text.hash);

    // 1a: optional on-chain ERC-20 transfer capability (tECDSA), injected by the consuming
    // canister (e.g. wired to its Gateway/EvmSender). The registry has no EVM capability of
    // its own; left null it stays ICP-only. Signature: (chainId, token, toAddress, amount).
    // B2: the hook CONFIRMS the transfer mined before returning, so the registry can
    // finalize a job's terminal state only on a confirmed on-chain transfer (not on a
    // mere mempool ack). #confirmed/#reverted/#pending/#err mirror EvmSender.
    /// Injected on-chain ERC-20 transfer hook to settle/refund EVM-paid jobs. It CONFIRMS the tx
    /// mined before returning (#confirmed/#reverted/#pending/#err), so a job finalizes only on
    /// a confirmed transfer. Args: (chainId, token, toAddress, amount).
    public type EvmTransferFn = (Nat, Text, Text, Nat) -> async {
      #confirmed : Text;
      #reverted : Text;
      #pending : Text;
      #err : Text;
    };
    var evmTransfer : ?EvmTransferFn = null;

    /// Wire the on-chain ERC-20 transfer used to settle/refund EVM-paid jobs. Call once at init.
    public func setEvmTransfer(fn : EvmTransferFn) {
      evmTransfer := ?fn;
    };

    // Recovery: a READ-ONLY confirm hook (re-polls a tx receipt; NEVER broadcasts). Distinct from
    // evmTransfer precisely so reconcileJob can never re-broadcast a parked tx (no double-pay).
    /// Injected READ-ONLY tx-confirmation hook for reconcileJob — re-polls a receipt and NEVER
    /// broadcasts, so a parked tx can't be double-paid. Args: (chainId, txHash).
    public type EvmConfirmFn = (Nat, Text) -> async { #confirmed; #reverted; #pending; #err : Text };
    var evmConfirm : ?EvmConfirmFn = null;

    /// Wire the read-only EVM tx-confirmation used by reconcileJob. Call once at init.
    public func setEvmConfirm(fn : EvmConfirmFn) {
      evmConfirm := ?fn;
    };

    // 1a: operator EVM payout addresses, keyed by operator principal. An EVM-paid job is
    // settled on-chain to its operator's registered payout address (no ServiceDefinition /
    // Candid change). Without one, EVM settlement can't pay the operator and rolls back.
    var operatorEvmPayout = HashMap.HashMap<Principal, Text>(8, Principal.equal, Principal.hash);
    // L23: bound the payout map — it is stable-persisted, keyed by an attacker-mintable principal,
    // and never GC'd, so without a cap an attacker could grow the canister heap + stable snapshot
    // without bound. 10_000 operators (~150 bytes each) is far above any real operator set.
    let MAX_OPERATOR_PAYOUTS : Nat = 10_000;

    /// Register the calling operator's EVM payout address (0x, 20 bytes). The consuming
    /// canister passes msg.caller and should require the caller be a registered operator.
    public func setOperatorEvmPayout(caller : Principal, address : Text) : { #ok; #err : Text } {
      if (not Text.startsWith(address, #text "0x") or address.size() != 42) {
        return #err("Invalid EVM payout address: must be a 0x-prefixed 20-byte address");
      };
      // L23: reject a NEW principal's entry once the cap is reached (existing operators can still
      // update their address). Bounds unbounded growth from mintable principals.
      switch (operatorEvmPayout.get(caller)) {
        case (null) {
          if (operatorEvmPayout.size() >= MAX_OPERATOR_PAYOUTS) {
            return #err("Operator payout registry is full");
          };
        };
        case (?_) {};
      };
      operatorEvmPayout.put(caller, address);
      #ok;
    };

    /// The operator's registered EVM payout address, if any.
    public func getOperatorEvmPayout(operator : Principal) : ?Text {
      operatorEvmPayout.get(operator);
    };

    /// Parse a CAIP-2 EVM network string ("eip155:8453") to its chain id, or null.
    public func parseChainId(network : Text) : ?Nat {
      let prefix = "eip155:";
      if (not Text.startsWith(network, #text prefix)) return null;
      let rest = Text.replace(network, #text prefix, "");
      var n : Nat = 0;
      var any = false;
      for (c in rest.chars()) {
        let d = Char.toNat32(c);
        if (d < 48 or d > 57) return null;
        n := n * 10 + Nat32.toNat(d - 48);
        any := true;
      };
      if (any) { ?n } else { null };
    };

    // 2.22.0: the outcome of one outbound transfer (settle or refund), classified for the expiry
    // sweep's automatic retries:
    //   #pending     broadcast, unconfirmed: it may land, so never re-sent (parked for reconcileJob).
    //   #reverted    mined with status 0: nothing moved, but it is never re-sent automatically
    //                (whatever made it revert will most likely do so again, and each try signs and
    //                pays gas). The message is the pre-2.22.0 #err text.
    //   #err         definite, nothing moved, and a retry may succeed (an ICP ledger #Err, or an
    //                EVM send refused before broadcast).
    //   #unavailable definite, nothing moved, and no retry can succeed until something is set up
    //                (no transfer hook, an unparseable chain, no payout address, no token, a buyer
    //                with no rail).
    type TxRef = { txHash : Text; chainId : Nat; token : Text };
    type Payout = { #ok; #pending : TxRef; #reverted : (Text, TxRef); #err : Text; #unavailable : Text };

    /// 1a: settle `cost` to the job's operator on the rail it was paid on. ICP jobs pay the
    /// operator principal from the pool; EVM jobs pay the operator's registered EVM payout
    /// address on-chain — fixing the settle half of the cross-rail flaw (C3).
    func settleToOperator(jobId : Text, job : Types.Job, cost : Nat) : async Payout {
      switch (evmJobRail.get(jobId)) {
        case (?rail) {
          let payout = switch (job.operator) { case (?op) { operatorEvmPayout.get(op) }; case (null) { null } };
          switch (evmTransfer, parseChainId(rail.network), payout) {
            case (?transfer, ?chainId, ?addr) {
              // B2: finalize only on a CONFIRMED on-chain transfer. #reverted -> no funds
              // moved (treat as #err, caller rolls back); #pending -> broadcast but
              // unconfirmed (it may have landed, so caller must NOT re-drive -> double-pay).
              switch (await transfer(chainId, rail.token, addr, cost)) {
                case (#confirmed(_)) { #ok };
                case (#reverted(h)) { #reverted("EVM settle to operator reverted on-chain (tx " # h # ")", { txHash = h; chainId; token = rail.token }) };
                case (#pending(h)) { #pending({ txHash = h; chainId; token = rail.token }) };
                case (#err(e)) { #err("EVM settle to operator: " # e) };
              };
            };
            case (?_, _, null) { #unavailable("operator has no registered EVM payout address (call setEvmPayout)") };
            case (_, _, _) { #unavailable("EVM settle unavailable (no transfer hook / unparseable chain)") };
          };
        };
        case (null) {
          switch (job.operator) {
            case (?op) {
              switch (await* payFromMainAccount({ owner = op; subaccount = null }, cost)) {
                case (#ok(_)) { #ok };
                case (#err(e)) { #err(e) };
                case (#unavailable(e)) { #unavailable(e) };
              };
            };
            case (null) { #unavailable("job has no assigned operator") };
          };
        };
      };
    };

    /// 1a: refund `amount` to the job's buyer on the rail it paid on. ICP buyers via the
    /// ckUSDC pool; EVM buyers via an on-chain tECDSA transfer to their 0x address (the
    /// injected hook). Fixes the EVM-buyer refund stranding (S14) and the refund half of the
    /// cross-rail flaw (C3).
    func refundOnRail(jobId : Text, job : Types.Job, amount : Nat) : async Payout {
      switch (evmJobRail.get(jobId)) {
        case (?rail) {
          switch (evmTransfer, parseChainId(rail.network)) {
            case (?transfer, ?chainId) {
              // B2: finalize only on #confirmed (see settleToOperator).
              switch (await transfer(chainId, rail.token, job.buyer, amount)) {
                case (#confirmed(_)) { #ok };
                case (#reverted(h)) { #reverted("EVM refund reverted on-chain (tx " # h # ")", { txHash = h; chainId; token = rail.token }) };
                case (#pending(h)) { #pending({ txHash = h; chainId; token = rail.token }) };
                case (#err(e)) { #err("EVM refund: " # e) };
              };
            };
            case (_, _) { #unavailable("EVM refund unavailable (no transfer hook / unparseable chain)") };
          };
        };
        case (null) {
          switch (buyerIcpAccount(job.buyer)) {
            case (?acct) {
              switch (await* payFromMainAccount(acct, amount)) {
                case (#ok(_)) { #ok };
                case (#err(e)) { #err(e) };
                case (#unavailable(e)) { #unavailable(e) };
              };
            };
            case (null) { #unavailable("buyer is not ICP-refundable and has no EVM rail") };
          };
        };
      };
    };

    // ── Service Registration ──

    // 2.22.0: bounds on the caller-supplied fields that had none. A service definition is returned
    // by listServices (a public query in the example), so one oversized key could push that reply
    // past the query response limit. 16 KiB is far above a Groth16 BN254 key with hundreds of
    // public inputs (~300 bytes compressed for one).
    let MAX_SERVICE_ID_CHARS : Nat = 64;
    let MAX_VERIFICATION_KEY_BYTES : Nat = 16_384;

    // An id of the form `svc-<digits>`: the form auto-assigned ids take.
    func isAutoServiceId(id : Text) : Bool {
      switch (Text.stripStart(id, #text "svc-")) {
        case (?n) {
          for (c in n.chars()) { if (c < '0' or c > '9') return false };
          n.size() > 0;
        };
        case (null) { false };
      };
    };

    /// Register a new service. Starts disabled; call enableService to activate.
    /// `def.id = ""` assigns the next free `svc-<n>`. 2.22.0: a caller-chosen id is at most 64
    /// characters and may not take the `svc-<digits>` form (it would squat a future auto id); a
    /// #ZkGroth16 verification key is at most 16 KiB; everything is validated before an id is
    /// consumed, so a refused registration no longer advances the counter.
    public func registerService(caller : Principal, def : Types.ServiceDefinition) : { #ok : Text; #err : Text } {
      if (def.operatorId != caller) return #err("Caller must be the operator");
      if (def.name.size() == 0 or def.name.size() > 128) return #err("Name must be 1-128 chars");
      if (def.description.size() > 1024) return #err("Description too long (max 1024)");
      if (def.timeout == 0) return #err("Timeout must be > 0");
      if (def.id.size() > MAX_SERVICE_ID_CHARS) return #err("Service ID too long (max " # Nat.toText(MAX_SERVICE_ID_CHARS) # " chars)");
      if (isAutoServiceId(def.id)) return #err("Service IDs of the form svc-<number> are reserved for auto-assigned IDs");
      switch (def.verification) {
        case (#ZkGroth16({ verificationKey })) {
          if (verificationKey.size() > MAX_VERIFICATION_KEY_BYTES) return #err("Verification key too large (max " # Nat.toText(MAX_VERIFICATION_KEY_BYTES) # " bytes)");
        };
        case (_) {};
      };

      let id = if (def.id == "") {
        // Skip an id already taken: one a caller chose before 2.22.0 refused the auto form.
        var n = serviceCounter + 1;
        while (services.get("svc-" # Nat.toText(n)) != null) { n += 1 };
        serviceCounter := n;
        "svc-" # Nat.toText(n);
      } else { def.id };

      switch (services.get(id)) {
        case (?_) { return #err("Service ID already exists: " # id) };
        case (null) {};
      };

      let service : Types.ServiceDefinition = {
        def with
        id = id;
        enabled = false;
        createdAt = Time.now();
      };
      services.put(id, service);
      #ok(id);
    };

    /// Enable a service (makes it available for purchase).
    public func enableService(caller : Principal, id : Text) : { #ok; #err : Text } {
      switch (services.get(id)) {
        case (null) { #err("Service not found: " # id) };
        case (?svc) {
          if (svc.operatorId != caller) return #err("Not the operator");
          services.put(id, { svc with enabled = true });
          #ok;
        };
      };
    };

    /// Disable a service (stops accepting new requests; existing jobs continue).
    public func disableService(caller : Principal, id : Text) : { #ok; #err : Text } {
      switch (services.get(id)) {
        case (null) { #err("Service not found: " # id) };
        case (?svc) {
          if (svc.operatorId != caller) return #err("Not the operator");
          services.put(id, { svc with enabled = false });
          #ok;
        };
      };
    };

    /// List services, optionally filtered by enabled status.
    public func listServices(enabledOnly : Bool) : [Types.ServiceDefinition] {
      let result = Buffer.Buffer<Types.ServiceDefinition>(16);
      for ((_, svc) in services.entries()) {
        if (not enabledOnly or svc.enabled) { result.add(svc) };
      };
      Buffer.toArray(result);
    };

    /// Get a single service definition.
    public func getService(id : Text) : ?Types.ServiceDefinition {
      services.get(id);
    };

    /// The ICP ledger transfer fee this registry's settle economics assume (config.ledgerFee).
    /// Settle-first consumers should derive expectedAmount = price + ledgerFee() from HERE —
    /// validateSubmittable checks against this same value, so a consumer that mirrors its own fee
    /// constant instead can drift and get an insufficient-payment rejection (or, pre-Option-A,
    /// a stranded payment).
    public func ledgerFee() : Nat { config.ledgerFee };

    // ── Job Lifecycle ──

    // C-4 (v2): Funds are custodied at the platform recipient account (where
    // Gateway.settle deposits the buyer's payment), NOT in a per-job escrow
    // subaccount. The previous code transferred from an unfunded subaccount, so
    // every settle/refund failed with InsufficientFunds and funds were stranded.
    // All settlement/refund transfers therefore source from config.recipient.
    // 2.18.1: `async*` — runs inline in refundOnRail's / settleToOperator's own message (no self-call, one
    // outstanding call fewer). Its only trap source is Candid-decoding a non-ICRC-1 ledger reply, and both
    // callers are separate messages themselves, so their callers see a reject either way. refundOnRail itself stays a separate message: it parses
    // the buyer principal before its first await, and that isolation keeps one malformed job from wedging
    // the job sweep.
    // A REJECT of the ledger call is deliberately NOT caught: it propagates, leaving the job in
    // #Settling for a controller to check on the ledger and resolveJob. A reject does not prove the
    // transfer failed. The DFINITY ICP and ICRC-1 ledgers commit the transfer and then await
    // archive_blocks inside the same icrc1_transfer call, so a trap after that await would reject
    // a transfer that landed; they are written not to trap there, but a library that accepts any
    // ledger cannot rely on it. And the common reject, a stopped ledger, carries the same code
    // (CANISTER_ERROR) as such a trap. Only the ledger's #Err replies are definite "not paid".
    // test/jobrevert.test.mo pins this (2.19.1 review).
    func payFromMainAccount(to : Types.Account, amount : Nat) : async* { #ok : Nat; #err : Text; #unavailable : Text } {
      if (amount == 0) return #ok(0);
      if (config.tokens.size() == 0) return #unavailable("No token configured");
      let ledger : Types.LedgerActor = actor (Principal.toText(config.tokens[0].ledger));
      let result = await ledger.icrc1_transfer({
        from_subaccount = config.recipient.subaccount;
        to;
        amount;
        fee = null;
        memo = null;
        created_at_time = null;
      });
      switch (result) {
        case (#Ok(b)) { #ok(b) };
        case (#Err(e)) { #err(debug_show(e)) };
      };
    };

    // Best-effort principal-text validation (charset + structure). Not a full
    // CRC check, but rejects the malformed strings that would otherwise TRAP
    // Principal.fromText in the refund path / expireJobs timer (Principal.fromText
    // traps un-catchably on bad input). submitRequest rejects anything that is
    // neither a 0x address nor principal-shaped, so stored buyers are well-formed.
    func looksLikePrincipal(t : Text) : Bool {
      let n = t.size();
      if (n < 5 or n > 63) return false;
      var hasDash = false;
      for (c in t.chars()) {
        let ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (not ok) return false;
        if (c == '-') hasDash := true;
      };
      hasDash;
    };

    // C-5 (v2): buyer is Text. Only ICP-principal buyers can receive an ICRC
    // refund; EVM (0x…) buyers and any malformed string return null (no refund,
    // no trap).
    func buyerIcpAccount(buyer : Text) : ?Types.Account {
      if (Text.startsWith(buyer, #text "0x")) { return null };
      if (not looksLikePrincipal(buyer)) { return null };
      ?{ owner = Principal.fromText(buyer); subaccount = null };
    };

    /// Pre-settle validation for a service request. Runs every guard submitRequest can reject on
    /// (invalid buyer, unknown/disabled service, underpayment) against `expectedAmount` — the amount
    /// that WILL settle — so a caller can validate BEFORE moving funds. A caller that then settles and
    /// calls createJobFromReceipt gets the money-moved ⇒ job-exists invariant, closing the
    /// settled-then-no-job strand (docs/decisions/settled-then-job-failed.md, Option A / S1). Uses
    /// config.ledgerFee (the fee the settle economics assume), so validating `price + <caller fee>`
    /// here also catches a caller-vs-registry fee skew before any funds move.
    public func validateSubmittable(buyer : Text, serviceId : Text, expectedAmount : Nat) : { #ok; #err : Text } {
      // Reject a malformed buyer up front (returnable error) rather than storing
      // a string that would later TRAP Principal.fromText in the refund timer.
      if (not Text.startsWith(buyer, #text "0x") and not looksLikePrincipal(buyer)) {
        return #err("Invalid buyer: must be an ICP principal or a 0x EVM address");
      };
      let svc = switch (services.get(serviceId)) {
        case (null) { return #err("Service not found: " # serviceId) };
        case (?s) { s };
      };
      if (not svc.enabled) return #err("Service is disabled");

      // Validate amount against pricing. A1: the buyer must pay `price + ledgerFee` so the pool
      // can cover the outbound settle transfer; otherwise every settle is short by one fee.
      switch (svc.pricing) {
        case (#Exact(price)) {
          let total = price + config.ledgerFee;
          if (expectedAmount < total) return #err("Insufficient payment: need " # Nat.toText(total) # " (price " # Nat.toText(price) # " + fee " # Nat.toText(config.ledgerFee) # "), got " # Nat.toText(expectedAmount));
        };
        case (#Upto(_maxPrice)) {
          // A positive payment that covers at least the ledger fee is required, so the job has
          // something to settle and the pool can afford the outbound transfer.
          if (expectedAmount < config.ledgerFee + 1) return #err("Payment required: must be at least " # Nat.toText(config.ledgerFee + 1) # " (ledger fee " # Nat.toText(config.ledgerFee) # " + 1) for Upto pricing, got " # Nat.toText(expectedAmount));
          // Upto: buyer authorizes up to maxPrice + fee; we accept any amount over the fee.
        };
        case (#Session) {}; // Session-based billing handled separately
      };
      #ok;
    };

    /// Create the job for an ALREADY-SETTLED payment. INFALLIBLE by contract — no #err, no trap — so a
    /// caller that ran validateSubmittable before settling is guaranteed money-moved ⇒ job-exists. Do
    /// NOT add a fallible check or Principal.fromText here (buyer stays Text); that would reintroduce
    /// the settled-then-no-job strand (docs/decisions/settled-then-job-failed.md, Option A invariant).
    /// The svc lookup is total: a service can be disabled but never deleted, so a validated caller
    /// always finds it; the null branch falls back to a 0 timeout rather than trapping.
    public func createJobFromReceipt(buyer : Text, serviceId : Text, params : Blob, receipt : Types.PaymentReceipt, callback : ?Text) : Text {
      let timeout = switch (services.get(serviceId)) { case (?s) { s.timeout }; case (null) { 0 } };
      jobCounter += 1;
      let jobId = "job-" # Nat.toText(jobCounter);
      let now = Time.now();

      let job : Types.Job = {
        id = jobId;
        serviceId;
        buyer;
        operator = null;
        params;
        paymentReceiptId = receipt.id;
        amount = receipt.amount;
        actualCost = null;
        status = #Pending;
        result = null;
        proof = null;
        createdAt = now;
        expiresAt = now + timeout * 1_000_000_000; // seconds → nanos
        completedAt = null;
        deliveryCallback = callback;
        parkedTx = null;
      };
      jobs.put(jobId, job);
      // 1a: record the EVM payment rail (network + token) for an EVM-paid job, so it can be
      // settled/refunded on-chain on that rail rather than from the ICP pool (C3). 2.22.0: keyed
      // on the receipt's network, not on the buyer's spelling — a payer written `0X…` or as bare
      // hex was put on the ICP rail, where its refund could never be paid.
      if (Text.startsWith(receipt.network, #text "eip155:")) {
        evmJobRail.put(jobId, { network = receipt.network; token = receipt.token });
      };
      jobId;
    };

    /// Submit a service request. The buyer has already paid (receipt from Gateway).
    /// The payment is custodied at the platform recipient account until the job is
    /// verified and settled (see settleJob / expireJobs for the custody model).
    /// C-5 (v2): `buyer` is Text — a principal for ICP payers, or a 0x EVM address
    /// for EVM payers (receipt.sender). It is NOT coerced to a Principal, which
    /// trapped for EVM addresses after the on-chain transfer had already executed.
    /// Settle-first callers should instead validateSubmittable BEFORE settling + createJobFromReceipt
    /// after, so a post-settle rejection can never strand funds (Option A). This wrapper keeps one
    /// code path for callers that already hold a receipt (validate with receipt.amount, then create).
    public func submitRequest(
      buyer : Text,
      serviceId : Text,
      params : Blob,
      receipt : Types.PaymentReceipt,
      callback : ?Text,
    ) : { #ok : Text; #err : Text } {
      switch (validateSubmittable(buyer, serviceId, receipt.amount)) {
        case (#err(e)) { #err(e) };
        case (#ok) { #ok(createJobFromReceipt(buyer, serviceId, params, receipt, callback)) };
      };
    };

    /// 1a: the EVM payment rail recorded for a job, if it was paid on-chain (null for ICP
    /// jobs). Used by the per-rail settlement path; exposed for tests/observability.
    public func getEvmRail(jobId : Text) : ?Types.EvmRail {
      evmJobRail.get(jobId);
    };

    /// Operator claims a pending job.
    public func claimJob(caller : Principal, jobId : Text) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found: " # jobId) };
        case (?j) { j };
      };
      if (job.status != #Pending) return #err("Job is not pending (status: " # debug_show(job.status) # ")");

      // Verify caller is the service's operator
      let svc = switch (services.get(job.serviceId)) {
        case (null) { return #err("Service not found") };
        case (?s) { s };
      };
      if (svc.operatorId != caller) return #err("Not the operator for this service");

      jobs.put(jobId, { job with operator = ?caller; status = #Assigned });
      #ok;
    };

    /// Operator submits the result (and optional proof). Triggers verification.
    public func submitResult(
      caller : Principal,
      jobId : Text,
      result : Blob,
      proof : ?Blob,
      actualCost : ?Nat,
    ) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found: " # jobId) };
        case (?j) { j };
      };
      // 2.22.0: not #Computing, which means a ZK verifier call is in flight. Accepting it let the
      // operator swap result/actualCost under that call and be paid for a record the proof did
      // not bind. A verifier call that throws puts the job back to #Assigned (verifyAndSettle).
      switch (job.status) {
        case (#Assigned) {};
        case (other) { return #err("Cannot submit result in status: " # debug_show(other)) };
      };
      switch (job.operator) {
        case (?op) { if (op != caller) return #err("Not the assigned operator") };
        case (null) { return #err("Job not assigned") };
      };

      // Validate actualCost for Upto pricing. A1: the buyer paid `price + ledgerFee`, but the
      // operator may only ever be paid the service amount (the fee covers the outbound transfer).
      // So the operator's billable ceiling — and the Exact-pricing default — is the amount NET of
      // the fee, not the full escrowed `job.amount` (which would let the operator claim the fee
      // and leave the pool short).
      let serviceAmount = Utils.satSub(job.amount, config.ledgerFee);
      let cost = switch (actualCost) {
        case (?c) {
          if (c > serviceAmount) return #err("Actual cost exceeds escrowed amount (net of ledger fee)");
          c;
        };
        case (null) { serviceAmount }; // Exact pricing: full service amount (net of fee)
      };

      let updated : Types.Job = {
        job with
        result = ?result;
        proof = proof;
        actualCost = ?cost;
        status = #Submitted;
        completedAt = ?Time.now();
      };
      jobs.put(jobId, updated);

      // Verify and settle based on the service's verification method
      await verifyAndSettle(jobId);
    };

    /// Internal: verify result and settle payment.
    func verifyAndSettle(jobId : Text) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      let svc = switch (services.get(job.serviceId)) {
        case (null) { return #err("Service not found") };
        case (?s) { s };
      };

      // H4: verifyAndSettle runs as a fresh message AFTER submitResult's `await` commit
      // point, so a concurrent expireJobs/disputeJob/confirmJob may have already moved this
      // job out of #Submitted (e.g. #Submitted → #Expired → refunded) before we got here.
      // The #AutoSettle and #HashMatch branches below write #Verified + settleJob from the
      // stale `job` snapshot with NO re-check; without this guard that clobbers a terminal
      // status and pays the operator ON TOP OF the buyer's refund — a refund-and-settle
      // double spend. Only proceed if the job is still awaiting verification. (The #ZkGroth16
      // branch has its own equivalent #Computing reservation + post-await re-check.)
      if (job.status != #Submitted) {
        return #err("Job no longer awaiting verification (status: " # debug_show (job.status) # ")");
      };

      switch (svc.verification) {
        case (#AutoSettle) {
          jobs.put(jobId, { job with status = #Verified });
          asResult(await settleJob(jobId));
        };
        case (#HashMatch) {
          // The buyer's params should contain the expected hash as the first 32 bytes
          let result = switch (job.result) {
            case (null) { return #err("No result to verify") };
            case (?r) { r };
          };
          let resultHash = SHA256.fromBlob(#sha256, result);
          if (Blob.toArray(job.params).size() < 32) return #err("Params must contain 32-byte expected hash");
          let expectedHash = Blob.fromArray(Array.subArray(Blob.toArray(job.params), 0, 32));
          if (resultHash == expectedHash) {
            jobs.put(jobId, { job with status = #Verified });
            asResult(await settleJob(jobId));
          } else {
            jobs.put(jobId, { job with status = #Disputed });
            #err("Hash mismatch: result does not match expected hash");
          };
        };
        case (#BuyerConfirm(_)) {
          // Stay in #Submitted — buyer must call confirmJob or disputeJob
          #ok;
        };
        case (#ZkGroth16({ verificationKey; verifierCanister; bindResult })) {
          let proof = switch (job.proof) {
            case (null) { return #err("ZK proof required but not provided") };
            case (?p) { p };
          };
          let result = switch (job.result) {
            case (null) { return #err("No result to verify") };
            case (?r) { r };
          };

          // Lost-update fix: reserve a non-resolvable interim status SYNCHRONOUSLY before the
          // cross-canister verifier await. disputeJob / confirmJob act only on #Submitted and
          // submitResult only on #Assigned, so #Computing takes this job out of their reach. The
          // expiry sweep does act on a #Computing job past expiresAt; both arms below re-check the
          // status after the await, so a refund landing DURING it is not clobbered by a stale
          // write-back (a refund-and-settle double spend).
          jobs.put(jobId, { job with status = #Computing });

          // Proof-not-bound fix (OPT-IN, bindResult): bind the DELIVERED result into the public
          // inputs so the proof attests to (resultHash, params) — not just params. Otherwise an
          // operator submits a valid proof for the params alongside an ARBITRARY result and is paid
          // for garbage. This requires a circuit whose public input 0 commits to the result, so it
          // is opt-in; the default (false) passes the buyer's params only, matching circuits that
          // prove the computation but not the result string (e.g. the √25 demo).
          // The hash is reduced to a valid BN254 scalar. M12: arkworks Fr::deserialize_compressed
          // (in the verifier canister) reads the 32 bytes LITTLE-endian, so byte 31 is the MOST-
          // significant — zero byte 31 to force the value below the field modulus (top byte 0x30).
          // Zeroing byte 0 (the LE LEAST-significant byte) leaves a random MSB that exceeds the
          // modulus ~81% of the time and fails deserialization, marking honest jobs #Disputed.
          // The circuit must commit to this same little-endian reduced value.
          let publicInputs : [Blob] = if (bindResult) {
            let h = Blob.toArray(SHA256.fromBlob(#sha256, result));
            let reduced = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { if (i == 31) { 0 } else { h[i] } }));
            if (Blob.toArray(job.params).size() > 0) { [reduced, job.params] } else { [reduced] };
          } else if (Blob.toArray(job.params).size() > 0) {
            [job.params];
          } else { [] };

          let verifier : Types.ZkVerifierActor = actor (Principal.toText(verifierCanister));
          // 2.22.0: a verifier call that throws decides nothing and moved no funds, so the job goes
          // back to #Assigned (if still ours) for the operator to resubmit. Before, it stayed
          // #Computing until the expiry sweep refunded it.
          let verdict = try { await verifier.verify_groth16(proof, publicInputs, verificationKey) } catch (e) {
            switch (jobs.get(jobId)) {
              case (?j2) {
                if (j2.status == #Computing) {
                  jobs.put(jobId, { j2 with status = #Assigned });
                  return #err("ZK verifier call failed (job back to #Assigned; resubmit to retry): " # Error.message(e));
                };
              };
              case (null) {};
            };
            return #err("ZK verifier call failed: " # Error.message(e));
          };
          switch (verdict) {
            case (#ok) {
              // Re-fetch after the await: settle only if no concurrent transition fired (the job
              // is still our reserved #Computing). Otherwise abort without paying.
              switch (jobs.get(jobId)) {
                case (?j2) {
                  if (j2.status != #Computing) {
                    return #err("Job changed during verification (status: " # debug_show(j2.status) # ")");
                  };
                  jobs.put(jobId, { j2 with status = #Verified });
                  asResult(await settleJob(jobId));
                };
                case (null) { #err("Job vanished during verification") };
              };
            };
            case (#err(msg)) {
              // SEC-0: mirror the #ok guard. Only transition if the job is STILL our reserved
              // #Computing. A concurrent transition that fired during the verifier await (e.g.
              // expireJobs → #Expired → #Refunded) must NOT be clobbered back to #Disputed —
              // otherwise the next expireJobs tick re-refunds an already-terminal job, draining
              // the shared pool a second time (the "stale write-back double spend" the comment
              // at the #Computing reservation above warns about).
              switch (jobs.get(jobId)) {
                case (?j2) {
                  if (j2.status == #Computing) {
                    jobs.put(jobId, { j2 with status = #Disputed });
                  };
                };
                case (null) {};
              };
              #err("ZK verification failed: " # msg);
            };
          };
        };
      };
    };

    // 2.22.0: the buyer's confirm/dispute (and their EVM-signed variants) apply to #BuyerConfirm
    // services only. On an AutoSettle/HashMatch/ZK job the result sits in #Submitted between
    // submitResult and the verifyAndSettle self-call, and a buyer could dispute it out of the
    // verification it was sold under (or confirm a result the hash check would have refused).
    func notBuyerConfirm(job : Types.Job) : Bool {
      switch (services.get(job.serviceId)) {
        case (?svc) { switch (svc.verification) { case (#BuyerConfirm(_)) { false }; case (_) { true } } };
        case (null) { true };
      };
    };
    let NOT_BUYER_CONFIRM = "Job's service does not use BuyerConfirm verification";

    /// Buyer confirms a result (for BuyerConfirm verification).
    public func confirmJob(buyer : Principal, jobId : Text) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.buyer != Principal.toText(buyer)) return #err("Not the buyer");
      if (job.status != #Submitted) return #err("Job not in submitted status");
      if (notBuyerConfirm(job)) return #err(NOT_BUYER_CONFIRM);
      jobs.put(jobId, { job with status = #Verified });
      asResult(await settleJob(jobId));
    };

    /// Buyer disputes a result (for BuyerConfirm verification).
    public func disputeJob(buyer : Principal, jobId : Text, _reason : Text) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.buyer != Principal.toText(buyer)) return #err("Not the buyer");
      if (job.status != #Submitted) return #err("Job not in submitted status");
      if (notBuyerConfirm(job)) return #err(NOT_BUYER_CONFIRM);
      jobs.put(jobId, { job with status = #Disputed });
      // M-6: Disputed jobs are resolved via resolveDispute() or auto-refunded by
      // expireJobs() once past the timeout — escrow is never locked permanently.
      #ok;
    };

    // ── EVM buyer authorization (S14, option B) ──
    // EVM-paid buyers have no ICP principal, so the principal-based confirmJob/disputeJob
    // can NEVER authorize them (job.buyer is a 0x address that Principal.toText can't equal).
    // These accept a secp256k1 signature over a canister/action/job-bound message, recover the
    // signer, and authorize it against the stored EVM buyer address. The buyer signs the
    // keccak256 of buyerActionMessage(action, jobId) with the key that owns job.buyer.

    /// The message an EVM buyer signs to confirm/dispute a job. Binds the action
    /// ("confirm"/"dispute"), the specific job, and THIS canister — so a signature cannot be
    /// replayed across actions, jobs, or canisters. Single-use is enforced by the job status
    /// (each transition requires #Submitted, which the action leaves).
    public func buyerActionMessage(action : Text, jobId : Text) : Text {
      "ic402-buyer-action:v1:" # action # ":" # jobId # ":" # Principal.toText(_canisterPrincipal);
    };

    /// Recover the EVM address that signed buyerActionMessage(action, jobId). `signature` is
    /// 65 bytes: r[0:32] || s[32:64] || v[64]. Returns the lowercase 0x address, or null.
    public func recoverBuyerActionSigner(action : Text, jobId : Text, signature : [Nat8]) : ?Text {
      if (signature.size() != 65) return null;
      let digest = EvmAddress.keccak256Text(buyerActionMessage(action, jobId));
      let r = Array.subArray<Nat8>(signature, 0, 32);
      let s = Array.subArray<Nat8>(signature, 32, 32);
      var v = signature[64];
      if (v >= 27) { v -= 27 };
      switch (EvmAddress.ecRecover(digest, r, s, v)) {
        case (?pubKey) {
          switch (EvmAddress.fromCompressedPublicKey(pubKey)) {
            case (#ok(addr)) { ?addr };
            case (#err(_)) { null };
          };
        };
        case (null) { null };
      };
    };

    /// Authorize an EVM buyer action: the recovered signer must equal job.buyer.
    func authorizeEvmBuyer(job : Types.Job, action : Text, jobId : Text, signature : [Nat8]) : Bool {
      switch (recoverBuyerActionSigner(action, jobId, signature)) {
        case (?signer) { EvmUtils.addressesEqual(signer, job.buyer) };
        case (null) { false };
      };
    };

    /// EVM-buyer counterpart of confirmJob: on a valid signature from the job's EVM buyer,
    /// settle the job to the operator. (Settlement currently draws the ICP pool — the EVM-rail
    /// payout for EVM-paid jobs is the cross-rail follow-up, audit C3.)
    public func confirmJobEvm(jobId : Text, signature : [Nat8]) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.status != #Submitted) return #err("Job not in submitted status");
      if (notBuyerConfirm(job)) return #err(NOT_BUYER_CONFIRM);
      if (not authorizeEvmBuyer(job, "confirm", jobId, signature)) {
        return #err("Signature does not authorize this job's EVM buyer");
      };
      jobs.put(jobId, { job with status = #Verified });
      asResult(await settleJob(jobId));
    };

    /// EVM-buyer counterpart of disputeJob: on a valid signature from the job's EVM buyer,
    /// mark the job disputed (resolved via resolveDispute / timeout). Synchronous.
    public func disputeJobEvm(jobId : Text, signature : [Nat8], _reason : Text) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.status != #Submitted) return #err("Job not in submitted status");
      if (notBuyerConfirm(job)) return #err(NOT_BUYER_CONFIRM);
      if (not authorizeEvmBuyer(job, "dispute", jobId, signature)) {
        return #err("Signature does not authorize this job's EVM buyer");
      };
      jobs.put(jobId, { job with status = #Disputed });
      #ok;
    };

    /// M-6 (v2): Resolve a submitted/disputed job. The consuming canister MUST
    /// gate access (e.g. controller-only). `refundBuyer = true` refunds the buyer;
    /// false settles to the operator. Without this, BuyerConfirm jobs the buyer
    /// neither confirms nor disputes (and disputed jobs) had no resolution path.
    /// 2.17.6: also a #Verified job — where a failed operator payment leaves it ("Settlement
    /// failed: …"), with nothing else able to move it. No funds have moved for a #Verified job
    /// (settleJob reserves #Settling before any await), so retrying the settle or refunding is safe.
    /// 2.22.0: that includes a #Verified job whose operator payment reverted on-chain (it carries
    /// the reverted tx, and the expiry sweep does not retry it): this call is the controller's
    /// decision to send again, so the record of the reverted tx is dropped.
    public func resolveDispute(jobId : Text, refundBuyer : Bool) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      switch (job.status) {
        case (#Submitted or #Disputed or #Verified) {};
        case (_) { return #err("Job is not in a resolvable state (status: " # debug_show(job.status) # ")") };
      };
      // A resolvable job carries a parked tx only as the record of a reverted payment (nothing
      // moved). Forward writes drop it; a failed refund restores `job` as it was, record included.
      let fresh = { job with parkedTx = null };
      if (refundBuyer) {
        // H-5 (v2): reserve a non-resolvable interim status SYNCHRONOUSLY before the await so
        // the expireJobs timer (which only acts on #Submitted/#Disputed/#Pending) cannot also
        // refund this same job during the await — preventing a double refund. Revert on failure.
        jobs.put(jobId, { fresh with status = #Settling });
        // 1a/A1: refund on the rail the job paid on — ICP pool, or on-chain to an EVM (0x)
        // buyer (lets EVM buyers actually be refunded; S14 / C3 refund half), net of the
        // refund's ledger fee (buyer paid price+fee; the fee is consumed by the transfer).
        let fee = config.ledgerFee;
        let refundAmt = Utils.satSub(job.amount, fee);
        switch (await refundOnRail(jobId, job, refundAmt)) {
          case (#ok) {
            if (not stillSettling(jobId)) return resolvedMeanwhile(jobId, "The buyer WAS refunded");
            jobs.put(jobId, { fresh with status = #Refunded; completedAt = ?Time.now() });
            #ok;
          };
          case (#pending(p)) {
            // B2/recovery: broadcast but unconfirmed — do NOT revert (a re-drive would double-
            // refund). Persist the parked refund (leg #Refund); stay parked in #Settling.
            jobs.put(jobId, { job with status = #Settling; parkedTx = ?{ txHash = p.txHash; leg = #Refund; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
            #err("Refund pending (parked in #Settling — reconcileJob to finalize): tx " # p.txHash);
          };
          case (#err(e) or #unavailable(e) or #reverted(e, _)) {
            // Revert to its prior status (no funds moved) — but only if the job is still ours. A
            // controller's resolveJob during the await made it terminal; reverting from the
            // pre-await snapshot would bring it back as #Submitted/#Disputed/#Verified, to be
            // refunded or settled a second time (2.17.6).
            revertIfSettling(jobId, job);
            #err("Refund failed: " # e);
          };
        };
      } else {
        jobs.put(jobId, { fresh with status = #Verified });
        asResult(await settleJob(jobId));
      };
    };

    // Put `back` in place of a job this message reserved #Settling, unless a controller's
    // resolveJob made it terminal during the await (2.17.6).
    func revertIfSettling(jobId : Text, back : Types.Job) {
      switch (jobs.get(jobId)) { case (?j2) { if (j2.status == #Settling) jobs.put(jobId, back) }; case (null) {} };
    };

    // 2.19.1: whether `jobId` is still the #Settling job this message reserved. A controller's
    // resolveJob (which accepts any #Settling job) can make it terminal while a payout await is in
    // flight. When a DEFINITE outcome (paid, or failed) comes back after that, the controller's
    // status is kept and no further transfer is sent (2.17.6 covered only the rollback branches).
    // A PENDING broadcast is still recorded on the job (re-parked), as before: its tx hash is the
    // only handle reconcileJob has, so it must not be dropped.
    func stillSettling(jobId : Text) : Bool {
      switch (jobs.get(jobId)) { case (?j) { j.status == #Settling }; case (null) { false } };
    };

    // The error for a payout whose outcome came back after a controller resolved the job. Also
    // printed to the canister log: the #err goes to whoever triggered the settle (often the buyer
    // or operator, not the controller), and the job record keeps the controller's status.
    func resolvedMeanwhile(jobId : Text, what : Text) : { #err : Text } {
      let status = switch (jobs.get(jobId)) { case (?j) { debug_show (j.status) }; case (null) { "deleted" } };
      let msg = "ic402 job " # jobId # ": a controller resolved it (now " # status # ") while its payout was in flight, so it was left as resolved. " # what # " — reconcile the funds.";
      Debug.print(msg);
      #err(msg);
    };

    // settleJob's outcome. 2.22.0: #noRetry is a failure the expiry sweep must not retry on its
    // own — a structural one (Payout #unavailable), or an operator payment that reverted on-chain.
    type SettleResult = { #ok; #err : Text; #noRetry : Text };
    func asResult(r : SettleResult) : { #ok; #err : Text } {
      switch (r) { case (#ok) { #ok }; case (#err(e) or #noRetry(e)) { #err(e) } };
    };

    /// Settle a verified job: pay the operator (and refund the Upto remainder to
    /// the buyer) from the platform recipient account.
    func settleJob(jobId : Text) : async SettleResult {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.status != #Verified) return #err("Job not verified");

      // H-5 (v2): Reserve the terminal transition synchronously BEFORE any await.
      // A concurrent confirmJob/verifyAndSettle that also reaches settleJob will
      // now see #Settling (not #Verified) and abort, preventing double payout.
      jobs.put(jobId, { job with status = #Settling });

      // A1: the buyer paid `price + ledgerFee`, so strip the fee to get the service amount the
      // operator/remainder logic works with. The fee covers the outbound transfer (the ledger
      // deducts amount+fee), so the pool nets zero per job instead of going short every time.
      let fee = config.ledgerFee;
      let serviceAmount = Utils.satSub(job.amount, fee);
      let cost = switch (job.actualCost) {
        case (?c) { c };
        case (null) { serviceAmount };
      };

      // C-4 / 1a: pay the operator their cost on the job's rail — ICP from the pool, or on-chain
      // to the operator's registered EVM payout address for EVM jobs (fixes the C3 settle half).
      switch (await settleToOperator(jobId, job, cost)) {
        case (#err(e)) {
          // Roll back for retry (no funds moved) — unless a controller's resolveJob made the job
          // terminal during the await: back in #Verified it would wait for a controller's
          // resolveDispute to settle or refund it a second time (2.17.6).
          revertIfSettling(jobId, { job with status = #Verified });
          return #err("Settlement failed: " # e);
        };
        case (#unavailable(e)) {
          revertIfSettling(jobId, { job with status = #Verified });
          return #noRetry("Settlement failed: " # e);
        };
        case (#reverted(e, tx)) {
          // 2.22.0: nothing moved, so back to #Verified as on #err, but with the reverted tx
          // recorded on the job (leg #Settle): the expiry sweep does not retry a #Verified job
          // that carries one. A controller decides — resolveDispute sends again or refunds,
          // resolveJob closes it.
          revertIfSettling(jobId, { job with status = #Verified; parkedTx = ?{ txHash = tx.txHash; leg = #Settle; chainId = tx.chainId; token = tx.token; parkedAt = Time.now() } });
          return #noRetry("Settlement failed: " # e);
        };
        case (#pending(p)) {
          // B2/recovery: broadcast but unconfirmed — it MAY have landed, so do NOT roll back to
          // #Verified (re-broadcast would double-pay). Persist the parked tx (leg #Settle) so a
          // controller can confirm-only reconcile it; stay parked in #Settling (set above).
          jobs.put(jobId, { job with status = #Settling; parkedTx = ?{ txHash = p.txHash; leg = #Settle; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
          return #err("Settlement pending (parked in #Settling — reconcileJob to finalize): tx " # p.txHash);
        };
        case (#ok) {
          if (not stillSettling(jobId)) {
            let owed = Utils.satSub(serviceAmount, cost + fee);
            return resolvedMeanwhile(jobId, "The operator WAS paid (" # Nat.toText(cost) # ")" # (if (owed > 0) { "; the buyer's Upto remainder (" # Nat.toText(owed) # ") was NOT refunded" } else { "" }));
          };
        };
      };

      // C-4/C-5 / 1a: refund the Upto remainder to the buyer on its rail, net of the refund's own
      // ledger fee. The operator is already paid, so on failure mark #Settled and surface it.
      // 2.22.0: completedAt is the settlement time, not the submit time: GC reclaims a terminal
      // job 24h after completedAt, so a job confirmed a day after its result was GC'd at once.
      let refundAmount = Utils.satSub(serviceAmount, cost + fee);
      if (refundAmount > 0) {
        switch (await refundOnRail(jobId, job, refundAmount)) {
          case (#err(e) or #unavailable(e) or #reverted(e, _)) {
            if (not stillSettling(jobId)) return resolvedMeanwhile(jobId, "The operator was paid; the buyer's Upto remainder (" # Nat.toText(refundAmount) # ") was NOT refunded: " # e);
            jobs.put(jobId, { job with status = #Settled; completedAt = ?Time.now() });
            return #err("Operator paid but buyer remainder refund failed: " # e);
          };
          case (#pending(p)) {
            // B2/recovery: operator is paid (confirmed); the remainder refund is broadcast-but-
            // unconfirmed. The job IS settled — mark #Settled and record the parked remainder
            // (leg #UptoRemainder) so reconcileJob can confirm/clear it (no re-drive).
            let parked = ?{ txHash = p.txHash; leg = #UptoRemainder; chainId = p.chainId; token = p.token; parkedAt = Time.now() };
            // 2.22.0: a controller's resolveJob during this await keeps its status (as on the other
            // arms); the parked hash is still recorded on the job, for reconcileJob.
            if (not stillSettling(jobId)) {
              switch (jobs.get(jobId)) { case (?j2) { jobs.put(jobId, { j2 with parkedTx = parked }) }; case (null) {} };
              return resolvedMeanwhile(jobId, "The operator was paid; the buyer's Upto remainder refund is pending (tx " # p.txHash # ", recorded on the job for reconcileJob)");
            };
            jobs.put(jobId, { job with status = #Settled; completedAt = ?Time.now(); parkedTx = parked });
            return #err("Operator paid; buyer remainder refund pending (reconcileJob to confirm): tx " # p.txHash);
          };
          case (#ok) {};
        };
      };

      if (not stillSettling(jobId)) return resolvedMeanwhile(jobId, "The operator was paid and any buyer remainder refunded");
      jobs.put(jobId, { job with status = #Settled; completedAt = ?Time.now() });
      #ok;
    };

    /// Pure decision for reconcileJob (sync, unit-testable): given the on-chain confirm OUTCOME,
    /// the parked leg, and the job's CURRENT status, decide the transition. Keeping this pure lets
    /// the #confirmed/#pending/#reverted/#err × leg matrix be tested without async/RPC. The golden
    /// rules it encodes: finalize ONLY on #confirmed; #reverted/#err/#pending never move state
    /// (no double-pay, no false finalize); a #confirmed leg only finalizes from its parked status.
    public type ReconcileResult = {
      #finalize : { status : Types.JobStatus; msg : Text }; // set status + clear parkedTx + completedAt
      #clearParked : { msg : Text }; // clear parkedTx only (Upto remainder confirmed)
      #stay : { err : Text }; // no state change; surface the reason
    };
    /// Pure decision for reconciling a parked job leg: finalize a #confirmed leg from its parked
    /// status, clear the parked tx for a confirmed Upto remainder, otherwise stay parked. Never
    /// re-broadcasts.
    public func reconcileDecision(
      outcome : { #confirmed; #reverted; #pending; #err : Text },
      leg : Types.ParkedLeg,
      status : Types.JobStatus,
    ) : ReconcileResult {
      switch (outcome) {
        case (#pending) { #stay({ err = "Parked tx still pending — stay parked" }) };
        case (#reverted) { #stay({ err = "Parked tx reverted on-chain; no funds moved — use resolveJob" }) };
        case (#err(e)) { #stay({ err = "Confirm RPC failed — stay parked: " # e }) };
        case (#confirmed) {
          switch (leg) {
            case (#Settle) {
              if (status != #Settling) {
                #stay({ err = "Job no longer #Settling (status: " # debug_show (status) # ")" });
              } else { #finalize({ status = #Settled; msg = "Settle confirmed on-chain; job #Settled" }) };
            };
            case (#Refund) {
              switch (status) {
                case (#Settling or #Expired) { #finalize({ status = #Refunded; msg = "Refund confirmed on-chain; job #Refunded" }) };
                case (_) { #stay({ err = "Job not in a refund-parked state (status: " # debug_show (status) # ")" }) };
              };
            };
            // operator already settled+confirmed; a confirmed remainder just clears the parked tx.
            case (#UptoRemainder) { #clearParked({ msg = "Upto remainder refund confirmed; parked tx cleared" }) };
          };
        };
      };
    };

    /// v2.1.1 recovery (controller-only via the consumer): CONFIRM-ONLY finalize a job whose
    /// outbound settle/refund parked (#pending). Re-polls the STORED parked tx via the read-only
    /// confirm hook and applies reconcileDecision. NEVER re-broadcasts (that risks double-pay).
    public func reconcileJob(jobId : Text) : async { #ok : Text; #err : Text } {
      let job = switch (jobs.get(jobId)) { case (null) { return #err("Job not found") }; case (?j) { j } };
      let parked = switch (job.parkedTx) { case (null) { return #err("Job has no parked tx to reconcile") }; case (?p) { p } };
      let confirm = switch (evmConfirm) { case (null) { return #err("No confirm hook wired") }; case (?f) { f } };
      let outcome = await confirm(parked.chainId, parked.txHash);
      // Re-fetch after the await: a concurrent transition may have moved the job.
      let j2 = switch (jobs.get(jobId)) { case (null) { return #err("Job vanished during reconcile") }; case (?j) { j } };
      switch (reconcileDecision(outcome, parked.leg, j2.status)) {
        case (#finalize({ status; msg })) {
          jobs.put(jobId, { j2 with status; parkedTx = null; completedAt = ?Time.now() });
          #ok(msg # " (tx " # parked.txHash # ")");
        };
        case (#clearParked({ msg })) {
          jobs.put(jobId, { j2 with parkedTx = null });
          #ok(msg # " (tx " # parked.txHash # ")");
        };
        case (#stay({ err })) { #err(err # " (tx " # parked.txHash # ")") };
      };
    };

    // ── Query ──

    /// Get job status.
    public func getJobStatus(jobId : Text) : ?Types.JobStatus {
      switch (jobs.get(jobId)) {
        case (null) { null };
        case (?j) { ?j.status };
      };
    };

    /// Get full job record.
    public func getJob(jobId : Text) : ?Types.Job {
      jobs.get(jobId);
    };

    /// Get job result (only if submitted or later).
    public func getJobResult(jobId : Text) : ?Blob {
      switch (jobs.get(jobId)) {
        case (null) { null };
        case (?j) {
          switch (j.status) {
            case (#Submitted or #Verified or #Settled) { j.result };
            case (_) { null };
          };
        };
      };
    };

    /// List jobs for a service.
    public func listJobs(serviceId : Text, statusFilter : ?Types.JobStatus) : [Types.Job] {
      let result = Buffer.Buffer<Types.Job>(16);
      for ((_, job) in jobs.entries()) {
        if (job.serviceId == serviceId) {
          let matches = switch (statusFilter) {
            case (null) { true };
            case (?s) { job.status == s };
          };
          if (matches) { result.add(job) };
        };
      };
      Buffer.toArray(result);
    };

    // ── Expiry Timer ──

    /// Expire stale jobs and refund escrowed amounts.
    /// Call this from a recurring timer (e.g., every 60 seconds).
    /// 2.22.0: a #Submitted job of a #BuyerConfirm service whose dispute window has ended is
    /// settled to the operator instead (see disputeWindowEnd), and so is a #Verified job an earlier
    /// settle left behind. A refund or payment that fails definitively is retried by later calls,
    /// at most 5 times; one no retry can fix (no hook, no payout address, …) is not retried; one
    /// that reverted on-chain is never sent again (the job carries the reverted tx, for a
    /// controller). Returns the jobs this call refunded, or left #Expired with a pending refund
    /// parked on them.
    public func expireJobs() : async [Text] { await* expireJobsCore() };

    // 2.22.0 (owner decision D1): when the dispute window of a #Submitted #BuyerConfirm job ends —
    // `disputeWindowSeconds` after the result was submitted (completedAt). The sweep then settles
    // the job to the operator, and until then it does not refund it at expiresAt: the window
    // decides, wherever it ends relative to expiresAt (a window can outlast the job's timeout
    // whenever the result came in late). null = the pre-2.22.0 behaviour (refund at expiresAt,
    // unless the buyer confirms first): the service is not BuyerConfirm, its window is 0, or the
    // job has no submit time. A disputed job is #Disputed, never matched here.
    func disputeWindowEnd(job : Types.Job) : ?Int {
      let svc = switch (services.get(job.serviceId)) { case (?s) { s }; case (null) { return null } };
      switch (svc.verification, job.completedAt) {
        case (#BuyerConfirm({ disputeWindowSeconds }), ?submittedAt) {
          if (disputeWindowSeconds == 0) { null } else { ?(submittedAt + disputeWindowSeconds * 1_000_000_000) };
        };
        case (_, _) { null };
      };
    };

    // 2.22.0: definite payout failures per job, counted for the sweep's automatic retries. After
    // MAX_AUTO_ATTEMPTS (or at once, for a failure no retry can fix) the sweep leaves the job as
    // it is for a controller, and says so in the canister log. Kept out of stable state: an
    // upgrade clears it, which grants each job another MAX_AUTO_ATTEMPTS — bounded, and an upgrade
    // is when a missing hook or a fixed configuration takes effect. A payment that reverted
    // on-chain is never retried at all; that is recorded on the job itself (its parkedTx).
    let MAX_AUTO_ATTEMPTS : Nat = 5;
    let payoutFailures = HashMap.HashMap<Text, Nat>(8, Text.equal, Text.hash);

    func sweepGaveUp(id : Text) : Bool {
      switch (payoutFailures.get(id)) { case (?n) { n >= MAX_AUTO_ATTEMPTS }; case (null) { false } };
    };

    // Count one definite failure (`final`: one no retry can fix). Logs once, when the sweep stops.
    func notePayoutFailure(id : Text, what : Text, final : Bool, e : Text) {
      let n = if (final) { MAX_AUTO_ATTEMPTS } else { (switch (payoutFailures.get(id)) { case (?k) { k }; case (null) { 0 } }) + 1 };
      payoutFailures.put(id, n);
      if (n >= MAX_AUTO_ATTEMPTS) {
        Debug.print("ic402 job " # id # ": " # what # " failed (" # e # "); nothing moved. The sweep will not try again until the next upgrade; the job is left as it is for a controller.");
      };
    };

    func expireJobsCore() : async* [Text] {
      let now = Time.now();
      let expired = Buffer.Buffer<Text>(8);

      label sweep for ((id, _) in jobs.entries()) {
        // 2.17.6: judge the LIVE record, not the iterator's. entries() hands back a bucket as it was
        // when the iterator entered it, so after the refund await below, a job confirmed or
        // resolved meanwhile (now #Verified/#Settling or terminal) still showed its old #Submitted
        // here, and was expired and refunded on top of the operator payment.
        var job = switch (jobs.get(id)) { case (?j) { j }; case (null) { continue sweep } };
        if (job.status == #Submitted) {
          switch (disputeWindowEnd(job)) {
            case (?windowEnd) {
              if (now <= windowEnd) continue sweep; // the window decides, not expiresAt
              // The buyer neither confirmed nor disputed in time: settle it as confirmJob does
              // (#Verified, then settleJob with its #Settling reservation and race guards), below.
              job := { job with status = #Verified };
              jobs.put(id, job);
            };
            case (null) {};
          };
        };
        // 2.22.0: settle a #Verified job — one whose window just ended, or one an earlier settle
        // left #Verified (a failed operator payment; before, only a controller could move it).
        // Not one carrying a parked tx (its payment reverted on-chain), nor one the sweep gave up.
        if (job.status == #Verified) {
          if (job.parkedTx == null and not sweepGaveUp(id)) {
            try {
              switch (await settleJob(id)) {
                case (#ok) { payoutFailures.delete(id) };
                case (#err(e)) { notePayoutFailure(id, "settle to the operator", false, e) };
                case (#noRetry(e)) { notePayoutFailure(id, "settle to the operator", true, e) };
              };
            } catch (e) {
              // A ledger reject leaves the job #Settling (settleJob), for a controller to check
              // and resolveJob — as after confirmJob. The sweep goes on.
              Debug.print("ic402 job " # id # ": settle to the operator rejected (job left #Settling): " # Error.message(e));
            };
          };
          continue sweep;
        };
        // M-6 (v2): Also time out jobs stuck in #Submitted (buyer never confirmed)
        // or #Disputed, so escrow is never locked permanently with no resolution.
        let timedOut = switch (job.status) {
          case (#Pending or #Assigned or #Computing or #Submitted or #Disputed) { now > job.expiresAt };
          case (_) { false };
        };
        if (timedOut and not sweepGaveUp(id)) {
          jobs.put(id, { job with status = #Expired; completedAt = ?now });

          // 1a/A1: refund the buyer on the rail it paid on — ICP from the pool, or on-chain to a
          // 0x (EVM) buyer — net of the refund's ledger fee.
          let fee = config.ledgerFee;
          let refundAmt = Utils.satSub(job.amount, fee);
          // 2.22.0: a REJECT is an unknown outcome (the transfer may have landed; see
          // payFromMainAccount): park the job #Settling for a controller to check and resolveJob,
          // and go on with the sweep. Before, the reject ended the whole tick and left the job
          // #Expired, where nothing could refund it and GC dropped it after 24h.
          let outcome = try { await refundOnRail(id, job, refundAmt) } catch (e) {
            switch (jobs.get(id)) { case (?j2) { if (j2.status == #Expired) jobs.put(id, { j2 with status = #Settling }) }; case (null) {} };
            Debug.print("ic402 job " # id # ": expiry refund rejected, outcome unknown (job parked #Settling for resolveJob): " # Error.message(e));
            continue sweep;
          };
          switch (outcome) {
            case (#ok) { jobs.put(id, { job with status = #Refunded; completedAt = ?now }); expired.add(id); payoutFailures.delete(id) };
            case (#pending(p)) {
              // B2/recovery: broadcast but unconfirmed — keep #Expired but ATTACH the parked
              // refund (leg #Refund) so reconcileJob can confirm it; gcTerminalJobs will NOT
              // reclaim a job that still carries a parkedTx (so a possibly-landed refund isn't
              // dropped). Do NOT re-drive (re-broadcast would double-refund).
              jobs.put(id, { job with status = #Expired; completedAt = ?now; parkedTx = ?{ txHash = p.txHash; leg = #Refund; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
              expired.add(id);
              payoutFailures.delete(id);
            };
            case (#reverted(e, tx)) {
              // 2.22.0: mined and reverted — nothing moved, and it is not sent again. The job stays
              // #Expired carrying the reverted tx (leg #Refund), like a pending refund: never GC'd,
              // shown as parked, and closed by a controller with resolveJob once the buyer has been
              // paid another way (reconcileJob reports the revert).
              jobs.put(id, { job with status = #Expired; completedAt = ?now; parkedTx = ?{ txHash = tx.txHash; leg = #Refund; chainId = tx.chainId; token = tx.token; parkedAt = Time.now() } });
              payoutFailures.delete(id);
              Debug.print("ic402 job " # id # ": expiry refund " # e # "; not sent again — the job is parked #Expired for resolveJob.");
            };
            case (#err(e)) {
              // 2.22.0: definite — no funds moved. Put the job back as it was so a later tick
              // retries the refund, up to MAX_AUTO_ATTEMPTS. Before, it stayed #Expired with the
              // refund owed, and was GC'd.
              switch (jobs.get(id)) { case (?j2) { if (j2.status == #Expired) jobs.put(id, job) }; case (null) {} };
              notePayoutFailure(id, "expiry refund", false, e);
            };
            case (#unavailable(e)) {
              // Nothing moved, and no retry can succeed as things are: put it back, do not retry.
              switch (jobs.get(id)) { case (?j2) { if (j2.status == #Expired) jobs.put(id, job) }; case (null) {} };
              notePayoutFailure(id, "expiry refund", true, e);
            };
          };
        };
      };

      // M-5 / S-13: Remove terminal jobs (Settled / Refunded / Expired) older than 24h.
      ignore gcTerminalJobs();

      Buffer.toArray(expired);
    };

    /// S-13: Garbage-collect terminal jobs (Settled / Refunded / Expired) older than 24h,
    /// freeing their retained params/result/proof blobs. Previously #Expired jobs — every
    /// timed-out EVM-paid job, and every ICP job whose refund failed — were NEVER collected,
    /// so the jobs map (and the stable snapshot that preupgrade serializes) grew without
    /// bound: an attacker-cheap state-exhaustion / upgrade-brick vector. Synchronous so it is
    /// directly unit-testable and can also be driven from the maintenance timer. Returns the
    /// number of jobs removed.
    /// Operator escape hatch for a job STUCK in #Settling (an outbound EVM settle/refund that
    /// broadcast but never confirmed within the poll budget). The operator verifies the on-chain
    /// outcome THEMSELVES, then forces the job to a terminal state so it stops pinning memory and
    /// becomes GC-eligible. This is a STATE assertion only — it moves NO funds; if the parked
    /// transfer never landed, the operator must reconcile the funds out-of-band (or via an EVM
    /// sweep). The consumer MUST gate this on Principal.isController. (A future confirm-only
    /// reconcileJob would automate the on-chain check; this is the manual remedy.)
    /// 2.19.1: if a payout in flight when this ran then comes back paid or failed, the job keeps
    /// the status set here and no further transfer is sent; the in-flight call returns #err saying
    /// what was paid, also printed to the canister log. Before, a success overwrote this status
    /// (and an Upto settle went on to refund the buyer's remainder). If it comes back as a pending
    /// EVM broadcast, the job is re-parked in #Settling with the tx hash, for reconcileJob.
    /// 2.22.0: also a job in any other status that carries a parked tx — a refund parked on an
    /// #Expired job, or an Upto remainder parked on a #Settled one. reconcileJob sends a parked tx
    /// that reverted on-chain here, and before this only a #Settling job was accepted, so those
    /// had no exit (and, still carrying the tx, were never GC'd).
    public func resolveJob(jobId : Text, terminal : Types.JobStatus) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.status != #Settling and job.parkedTx == null) {
        return #err("Job is not stuck in #Settling (status: " # debug_show (job.status) # ")");
      };
      switch (terminal) {
        case (#Settled or #Refunded or #Expired) {
          // Clear parkedTx: this is the operator asserting the dead/handled tx is resolved, so the
          // job becomes GC-eligible again (gcTerminalJobs skips jobs that still carry a parkedTx).
          jobs.put(jobId, { job with status = terminal; completedAt = ?Time.now(); parkedTx = null });
          #ok;
        };
        case (_) { #err("resolveJob target must be a terminal status (#Settled / #Refunded / #Expired)") };
      };
    };

    /// Garbage-collect terminal (settled/refunded/expired) jobs older than 24h; returns the count
    /// removed. Skips any job still carrying a parked tx.
    public func gcTerminalJobs() : Nat {
      let gcCutoff = Time.now() - 24 * 60 * 60 * 1_000_000_000; // 24 hours in nanoseconds
      let staleJobs = Buffer.Buffer<Text>(8);
      for ((id, job) in jobs.entries()) {
        switch (job.status) {
          case (#Settled or #Refunded or #Expired) {
            let completedTime = switch (job.completedAt) {
              case (?t) { t };
              case (null) { job.createdAt }; // fallback if completedAt not set
            };
            // Recovery: do NOT reclaim a terminal job that still carries an unresolved parkedTx
            // (a broadcast-but-unconfirmed settle/refund) — reconcileJob must be able to confirm
            // a possibly-landed transfer first. It GCs normally once reconcile clears parkedTx.
            if (job.parkedTx == null and completedTime < gcCutoff) { staleJobs.add(id) };
          };
          case (_) {};
        };
      };
      for (id in staleJobs.vals()) { jobs.delete(id); evmJobRail.delete(id); payoutFailures.delete(id) };
      staleJobs.size();
    };

    /// Observability (NEW-4): counts of jobs by status for an operator health view.
    /// `settling` is the parked / in-flight-settlement count — a non-zero, non-decreasing
    /// `settling` means funds are parked mid-settlement (an EVM transfer that broadcast but
    /// hasn't confirmed); that's the metric to watch and reconcile.
    public func jobCounts() : {
      total : Nat; settling : Nat; settled : Nat; refunded : Nat; expired : Nat; active : Nat; parked : Nat;
    } {
      var total = 0; var settling = 0; var settled = 0; var refunded = 0; var expired = 0; var active = 0; var parked = 0;
      for ((_, job) in jobs.entries()) {
        total += 1;
        switch (job.status) {
          case (#Settling) { settling += 1 };
          case (#Settled) { settled += 1 };
          case (#Refunded) { refunded += 1 };
          case (#Expired) { expired += 1 };
          case (_) { active += 1 };
        };
        // `parked` is the true funds-parked count: it spans all three legs (settle #Settling,
        // refund #Settling/#Expired, Upto remainder on a #Settled job) — the metric to reconcile.
        switch (job.parkedTx) { case (?_) { parked += 1 }; case (null) {} };
      };
      { total; settling; settled; refunded; expired; active; parked };
    };

    // ── Expiry timer (self-adjusting cadence) ──
    //
    // A recurring timer is billed per TICK — the message-execution base fee — not per unit of
    // work, so an always-on 60s job-expiry sweep costs a canister ~1.4B cycles/hour whether or
    // not it has ever seen a job (measured: ~23.6M cycles/tick). This sweep therefore runs at its
    // working cadence only while unfinished jobs exist, and falls back to a slow idle poll when
    // none do.
    //
    // WHY A POLL RATHER THAN A CLEAN DISARM (as Sessions does): the only job-CREATING entry point
    // is createJobFromReceipt, which is SYNCHRONOUS — and a synchronous Motoko function cannot
    // hold the `system` capability, so it cannot arm a timer. Adding `<system>` to it would be a
    // hard compile error for every sync caller (M0197), and it is also the function that must
    // stay infallible for the money-moved ⇒ job-exists invariant (docs/decisions/
    // settled-then-job-failed.md), so it is the wrong place to grow. The idle poll is the safety
    // net: a job created behind the timer's back is picked up within expiryIdlePollSeconds, and
    // the sweep switches straight back to its working cadence. A caller that wants expiry to
    // start IMMEDIATELY calls armExpiryTimer<system>() right after creating the job (async
    // context required — see example/main.mo); then the poll never has to catch anything.
    var expiryTimer : ?Timer.TimerId = null;
    var expiryIntervalSeconds : Nat = 60;
    var expiryIdlePollSeconds : Nat = 3600;
    var expiryFastMode : Bool = false;
    // 2.17.5: set by armExpiryTimer, consumed by the next tick, which counts it as work. Callers
    // arm just BEFORE the settle that creates the job (example/main.mo), so a tick landing during
    // that settle would otherwise find no unfinished job and drop to the idle poll just before the
    // job appears. Costs at most one extra tick after an arm that creates no job.
    var armRequested : Bool = false;

    /// Whether the job-expiry sweep is armed at all (it is, at the idle cadence, unless
    /// setExpiryIdlePollSeconds(0) turned the poll off and there are no unfinished jobs).
    public func expiryTimerArmed() : Bool { expiryTimer != null };

    /// Whether the sweep is running at its working cadence (unfinished jobs exist) rather than
    /// idle-polling.
    public func expiryTimerActive() : Bool { expiryTimer != null and expiryFastMode };

    /// Whether the sweep has anything to act on: any job not yet terminal (`#Settled`,
    /// `#Refunded`, `#Expired`). 2.17.5: terminal jobs no longer keep the working cadence through
    /// their 24h retention; the idle poll still runs expireJobs, so gcTerminalJobs reclaims them
    /// within an hour of their 24h at the default poll, or on the next arm with the poll off (and a
    /// job carrying a parkedTx is still kept for reconcileJob). A #Submitted #BuyerConfirm job
    /// waiting out its dispute window is work too (2.22.0: the sweep settles it when the window ends).
    public func hasExpiryWork() : Bool {
      for ((_, j) in jobs.entries()) {
        switch (j.status) { case (#Settled or #Refunded or #Expired) {}; case (_) { return true } };
      };
      false;
    };

    func cancelExpiryTimer() {
      switch (expiryTimer) {
        case (?id) { Timer.cancelTimer(id); expiryTimer := null };
        case (null) {};
      };
    };

    func armExpiryAt<system>(seconds : Nat, fast : Bool) {
      cancelExpiryTimer();
      expiryFastMode := fast;
      expiryTimer := ?Timer.recurringTimer<system>(
        #seconds seconds,
        func() : async () {
          ignore await* expireJobsCore(); // inline: no self-call message per tick (2.17.5)
          // ── ATOMIC TAIL — do NOT introduce an `await` below this line. ──
          // State commits at each await, so a job created by another message DURING the sweep
          // above is already visible to hasExpiryWork() here, and one created after the cadence
          // switch below is picked up by the next tick. An await between the check and the
          // re-arm would reopen the window where a live job is left on the slow cadence.
          let work = hasExpiryWork() or armRequested;
          armRequested := false;
          switch (Utils.expiryCadence(work, expiryFastMode, expiryIdlePollSeconds)) {
            case (#stay) {};
            case (#switchToFast) { armExpiryAt<system>(expiryIntervalSeconds, true) };
            case (#switchToIdle) { armExpiryAt<system>(expiryIdlePollSeconds, false) };
            case (#disarm) { cancelExpiryTimer() };
          };
        },
      );
    };

    /// Start the job expiry timer. Call once at canister init.
    /// Armed unconditionally at the working cadence: on upgrade a `persistent actor` re-runs its
    /// init body (where this call lives) BEFORE postupgrade restores stable jobs, so gating the
    /// arm on "are there jobs?" would leave exactly the canisters that DO have live jobs unswept.
    /// The first tick drops to the idle poll if there is nothing to expire.
    public func startTimers<system>() {
      armExpiryAt<system>(expiryIntervalSeconds, true);
    };

    /// Arm the sweep at its working cadence if it is not already there (idempotent), and keep it
    /// there for at least the next tick even if no unfinished job exists yet. Call it on the
    /// job-creating path from an async context — example/main.mo calls it just BEFORE the settle
    /// that precedes createJobFromReceipt — so a new job's expiry starts within
    /// expiryIntervalSeconds instead of waiting for the idle poll to notice it. A settle that
    /// outlasts a whole interval can still miss; the idle poll (or, with it off, the next arm)
    /// then picks the job up.
    public func armExpiryTimer<system>() {
      armRequested := true;
      if (expiryTimer != null and expiryFastMode) return;
      armExpiryAt<system>(expiryIntervalSeconds, true);
    };

    /// Set the working cadence in seconds (default 60), applied immediately. Expiry latency is
    /// bounded by this interval: a timed-out job is refunded within `seconds` of passing
    /// expiresAt. Nothing about refund correctness depends on the cadence — the buyer's escrow is
    /// intact until the sweep runs — so this trades refund latency for cycles.
    public func setExpiryIntervalSeconds<system>(seconds : Nat) : { #ok; #err : Text } {
      if (seconds == 0) { return #err("expiry interval must be at least 1 second") };
      expiryIntervalSeconds := seconds;
      if (expiryTimer != null and expiryFastMode) { armExpiryAt<system>(seconds, true) };
      #ok;
    };

    /// Set the idle poll cadence in seconds (default 3600 = one tick per hour), applied
    /// immediately. This is the worst-case delay before a job created by a caller that did not
    /// call armExpiryTimer starts being swept. 0 disarms the timer entirely when there are no
    /// unfinished jobs — zero idle cost, but then expiry NEVER starts unless every job-creating call site
    /// arms it, so only use 0 if you control them all.
    /// 2.22.0: setting a non-zero poll after 0 restarts the poll if the sweep had disarmed (before,
    /// it stayed off until the next armExpiryTimer). Otherwise configuring the poll arms nothing:
    /// a registry whose sweep was never started keeps it unstarted.
    public func setExpiryIdlePollSeconds<system>(seconds : Nat) : { #ok; #err : Text } {
      let pollWasOff = expiryIdlePollSeconds == 0;
      expiryIdlePollSeconds := seconds;
      if (expiryTimer != null and not expiryFastMode) {
        if (seconds == 0) { cancelExpiryTimer() } else { armExpiryAt<system>(seconds, false) };
      } else if (expiryTimer == null and pollWasOff and seconds > 0) {
        armExpiryAt<system>(seconds, false);
      };
      #ok;
    };

    // ── Stable State ──

    /// Serialize for canister upgrades.
    public func toStable() : Types.StableServiceRegistryState {
      {
        services = Iter.toArray(services.entries());
        jobs = Iter.toArray(jobs.entries());
        serviceCounter;
        jobCounter;
        evmRails = ?Iter.toArray(evmJobRail.entries());
        operatorPayouts = ?Iter.toArray(operatorEvmPayout.entries());
      };
    };

    /// Restore from canister upgrades.
    public func loadStable(data : Types.StableServiceRegistryState) {
      services := HashMap.fromIter(data.services.values(), data.services.size(), Text.equal, Text.hash);
      jobs := HashMap.fromIter(data.jobs.values(), data.jobs.size(), Text.equal, Text.hash);
      serviceCounter := data.serviceCounter;
      jobCounter := data.jobCounter;
      // Optional for upgrade compatibility: pre-1a stable records have no evmRails.
      evmJobRail := switch (data.evmRails) {
        case (?rails) { HashMap.fromIter(rails.values(), rails.size(), Text.equal, Text.hash) };
        case (null) { HashMap.HashMap<Text, Types.EvmRail>(16, Text.equal, Text.hash) };
      };
      operatorEvmPayout := switch (data.operatorPayouts) {
        case (?p) { HashMap.fromIter(p.values(), p.size(), Principal.equal, Principal.hash) };
        case (null) { HashMap.HashMap<Principal, Text>(8, Principal.equal, Principal.hash) };
      };
    };
  };
};
