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
import Int "mo:base/Int";
import Utils "Utils";
import Text "mo:base/Text";
import Time "mo:base/Time";
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

    /// 1a: settle `cost` to the job's operator on the rail it was paid on. ICP jobs pay the
    /// operator principal from the pool; EVM jobs pay the operator's registered EVM payout
    /// address on-chain — fixing the settle half of the cross-rail flaw (C3). Returns true on
    /// success (false if no operator / no payout address / no transfer hook / transfer fails).
    func settleToOperator(jobId : Text, job : Types.Job, cost : Nat) : async { #ok; #pending : { txHash : Text; chainId : Nat; token : Text }; #err : Text } {
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
                case (#reverted(h)) { #err("EVM settle to operator reverted on-chain (tx " # h # ")") };
                case (#pending(h)) { #pending({ txHash = h; chainId; token = rail.token }) };
                case (#err(e)) { #err("EVM settle to operator: " # e) };
              };
            };
            case (?_, _, null) { #err("operator has no registered EVM payout address (call setEvmPayout)") };
            case (_, _, _) { #err("EVM settle unavailable (no transfer hook / unparseable chain)") };
          };
        };
        case (null) {
          switch (job.operator) {
            case (?op) {
              switch (await payFromMainAccount({ owner = op; subaccount = null }, cost)) {
                case (#ok(_)) { #ok };
                case (#err(e)) { #err(e) };
              };
            };
            case (null) { #err("job has no assigned operator") };
          };
        };
      };
    };

    /// 1a: refund `amount` to the job's buyer on the rail it paid on. ICP buyers via the
    /// ckUSDC pool; EVM buyers via an on-chain tECDSA transfer to their 0x address (the
    /// injected hook). Returns true on success. Fixes the EVM-buyer refund stranding (S14)
    /// and the refund half of the cross-rail flaw (C3).
    func refundOnRail(jobId : Text, job : Types.Job, amount : Nat) : async { #ok; #pending : { txHash : Text; chainId : Nat; token : Text }; #err : Text } {
      switch (evmJobRail.get(jobId)) {
        case (?rail) {
          switch (evmTransfer, parseChainId(rail.network)) {
            case (?transfer, ?chainId) {
              // B2: finalize only on #confirmed (see settleToOperator).
              switch (await transfer(chainId, rail.token, job.buyer, amount)) {
                case (#confirmed(_)) { #ok };
                case (#reverted(h)) { #err("EVM refund reverted on-chain (tx " # h # ")") };
                case (#pending(h)) { #pending({ txHash = h; chainId; token = rail.token }) };
                case (#err(e)) { #err("EVM refund: " # e) };
              };
            };
            case (_, _) { #err("EVM refund unavailable (no transfer hook / unparseable chain)") };
          };
        };
        case (null) {
          switch (buyerIcpAccount(job.buyer)) {
            case (?acct) {
              switch (await payFromMainAccount(acct, amount)) {
                case (#ok(_)) { #ok };
                case (#err(e)) { #err(e) };
              };
            };
            case (null) { #err("buyer is not ICP-refundable and has no EVM rail") };
          };
        };
      };
    };

    // ── Service Registration ──

    /// Register a new service. Starts disabled; call enableService to activate.
    public func registerService(caller : Principal, def : Types.ServiceDefinition) : { #ok : Text; #err : Text } {
      if (def.operatorId != caller) return #err("Caller must be the operator");
      if (def.name.size() == 0 or def.name.size() > 128) return #err("Name must be 1-128 chars");
      if (def.description.size() > 1024) return #err("Description too long (max 1024)");
      if (def.timeout == 0) return #err("Timeout must be > 0");

      serviceCounter += 1;
      let id = if (def.id == "") { "svc-" # Nat.toText(serviceCounter) } else { def.id };

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

    // ── Job Lifecycle ──

    // C-4 (v2): Funds are custodied at the platform recipient account (where
    // Gateway.settle deposits the buyer's payment), NOT in a per-job escrow
    // subaccount. The previous code transferred from an unfunded subaccount, so
    // every settle/refund failed with InsufficientFunds and funds were stranded.
    // All settlement/refund transfers therefore source from config.recipient.
    func payFromMainAccount(to : Types.Account, amount : Nat) : async { #ok : Nat; #err : Text } {
      if (amount == 0) return #ok(0);
      if (config.tokens.size() == 0) return #err("No token configured");
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
      // settled/refunded on-chain on that rail rather than from the ICP pool (C3).
      if (Text.startsWith(buyer, #text "0x")) {
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
      switch (job.status) {
        case (#Assigned or #Computing) {};
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
          await settleJob(jobId);
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
            await settleJob(jobId);
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
          // cross-canister verifier await. expireJobs / disputeJob / confirmJob all act only on
          // #Submitted, so #Computing takes this job out of their reach; without this, a refund
          // or dispute landing DURING the await would be silently clobbered by the stale
          // write-back below — a refund-and-settle double spend.
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
          switch (await verifier.verify_groth16(proof, publicInputs, verificationKey)) {
            case (#ok) {
              // Re-fetch after the await: settle only if no concurrent transition fired (the job
              // is still our reserved #Computing). Otherwise abort without paying.
              switch (jobs.get(jobId)) {
                case (?j2) {
                  if (j2.status != #Computing) {
                    return #err("Job changed during verification (status: " # debug_show(j2.status) # ")");
                  };
                  jobs.put(jobId, { j2 with status = #Verified });
                  await settleJob(jobId);
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

    /// Buyer confirms a result (for BuyerConfirm verification).
    public func confirmJob(buyer : Principal, jobId : Text) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.buyer != Principal.toText(buyer)) return #err("Not the buyer");
      if (job.status != #Submitted) return #err("Job not in submitted status");
      jobs.put(jobId, { job with status = #Verified });
      await settleJob(jobId);
    };

    /// Buyer disputes a result (for BuyerConfirm verification).
    public func disputeJob(buyer : Principal, jobId : Text, _reason : Text) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.buyer != Principal.toText(buyer)) return #err("Not the buyer");
      if (job.status != #Submitted) return #err("Job not in submitted status");
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
      if (not authorizeEvmBuyer(job, "confirm", jobId, signature)) {
        return #err("Signature does not authorize this job's EVM buyer");
      };
      jobs.put(jobId, { job with status = #Verified });
      await settleJob(jobId);
    };

    /// EVM-buyer counterpart of disputeJob: on a valid signature from the job's EVM buyer,
    /// mark the job disputed (resolved via resolveDispute / timeout). Synchronous.
    public func disputeJobEvm(jobId : Text, signature : [Nat8], _reason : Text) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.status != #Submitted) return #err("Job not in submitted status");
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
    public func resolveDispute(jobId : Text, refundBuyer : Bool) : async { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      switch (job.status) {
        case (#Submitted or #Disputed) {};
        case (_) { return #err("Job is not in a resolvable state (status: " # debug_show(job.status) # ")") };
      };
      if (refundBuyer) {
        // H-5 (v2): reserve a non-resolvable interim status SYNCHRONOUSLY before the await so
        // the expireJobs timer (which only acts on #Submitted/#Disputed/#Pending) cannot also
        // refund this same job during the await — preventing a double refund. Revert on failure.
        jobs.put(jobId, { job with status = #Settling });
        // 1a/A1: refund on the rail the job paid on — ICP pool, or on-chain to an EVM (0x)
        // buyer (lets EVM buyers actually be refunded; S14 / C3 refund half), net of the
        // refund's ledger fee (buyer paid price+fee; the fee is consumed by the transfer).
        let fee = config.ledgerFee;
        let refundAmt = Utils.satSub(job.amount, fee);
        switch (await refundOnRail(jobId, job, refundAmt)) {
          case (#ok) {
            jobs.put(jobId, { job with status = #Refunded; completedAt = ?Time.now() });
            #ok;
          };
          case (#pending(p)) {
            // B2/recovery: broadcast but unconfirmed — do NOT revert (a re-drive would double-
            // refund). Persist the parked refund (leg #Refund); stay parked in #Settling.
            jobs.put(jobId, { job with status = #Settling; parkedTx = ?{ txHash = p.txHash; leg = #Refund; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
            #err("Refund pending (parked in #Settling — reconcileJob to finalize): tx " # p.txHash);
          };
          case (#err(e)) {
            jobs.put(jobId, job); // revert to its prior status (no funds moved)
            #err("Refund failed: " # e);
          };
        };
      } else {
        jobs.put(jobId, { job with status = #Verified });
        await settleJob(jobId);
      };
    };

    /// Settle a verified job: pay the operator (and refund the Upto remainder to
    /// the buyer) from the platform recipient account.
    func settleJob(jobId : Text) : async { #ok; #err : Text } {
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
          jobs.put(jobId, { job with status = #Verified }); // roll back for retry (no funds moved)
          return #err("Settlement failed: " # e);
        };
        case (#pending(p)) {
          // B2/recovery: broadcast but unconfirmed — it MAY have landed, so do NOT roll back to
          // #Verified (re-broadcast would double-pay). Persist the parked tx (leg #Settle) so a
          // controller can confirm-only reconcile it; stay parked in #Settling (set above).
          jobs.put(jobId, { job with status = #Settling; parkedTx = ?{ txHash = p.txHash; leg = #Settle; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
          return #err("Settlement pending (parked in #Settling — reconcileJob to finalize): tx " # p.txHash);
        };
        case (#ok) {};
      };

      // C-4/C-5 / 1a: refund the Upto remainder to the buyer on its rail, net of the refund's own
      // ledger fee. The operator is already paid, so on failure mark #Settled and surface it.
      let refundAmount = Utils.satSub(serviceAmount, cost + fee);
      if (refundAmount > 0) {
        switch (await refundOnRail(jobId, job, refundAmount)) {
          case (#err(e)) {
            jobs.put(jobId, { job with status = #Settled });
            return #err("Operator paid but buyer remainder refund failed: " # e);
          };
          case (#pending(p)) {
            // B2/recovery: operator is paid (confirmed); the remainder refund is broadcast-but-
            // unconfirmed. The job IS settled — mark #Settled and record the parked remainder
            // (leg #UptoRemainder) so reconcileJob can confirm/clear it (no re-drive).
            jobs.put(jobId, { job with status = #Settled; parkedTx = ?{ txHash = p.txHash; leg = #UptoRemainder; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
            return #err("Operator paid; buyer remainder refund pending (reconcileJob to confirm): tx " # p.txHash);
          };
          case (#ok) {};
        };
      };

      jobs.put(jobId, { job with status = #Settled });
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
    public func expireJobs() : async [Text] {
      let now = Time.now();
      let expired = Buffer.Buffer<Text>(8);

      for ((id, job) in jobs.entries()) {
        // M-6 (v2): Also time out jobs stuck in #Submitted (buyer never confirmed)
        // or #Disputed, so escrow is never locked permanently with no resolution.
        let timedOut = switch (job.status) {
          case (#Pending or #Assigned or #Computing or #Submitted or #Disputed) { now > job.expiresAt };
          case (_) { false };
        };
        if (timedOut) {
          jobs.put(id, { job with status = #Expired; completedAt = ?now });
          expired.add(id);

          // 1a/A1: refund the buyer on the rail it paid on — ICP from the pool, or on-chain to a
          // 0x (EVM) buyer — net of the refund's ledger fee. On failure leave #Expired (reclaimed
          // by gcTerminalJobs after 24h).
          let fee = config.ledgerFee;
          let refundAmt = Utils.satSub(job.amount, fee);
          switch (await refundOnRail(id, job, refundAmt)) {
            case (#ok) { jobs.put(id, { job with status = #Refunded; completedAt = ?now }) };
            case (#pending(p)) {
              // B2/recovery: broadcast but unconfirmed — keep #Expired but ATTACH the parked
              // refund (leg #Refund) so reconcileJob can confirm it; gcTerminalJobs will NOT
              // reclaim a job that still carries a parkedTx (so a possibly-landed refund isn't
              // dropped). Do NOT re-drive (re-broadcast would double-refund).
              jobs.put(id, { job with status = #Expired; completedAt = ?now; parkedTx = ?{ txHash = p.txHash; leg = #Refund; chainId = p.chainId; token = p.token; parkedAt = Time.now() } });
            };
            case (#err(_)) {}; // no funds moved — leave #Expired (reclaimed after 24h)
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
    public func resolveJob(jobId : Text, terminal : Types.JobStatus) : { #ok; #err : Text } {
      let job = switch (jobs.get(jobId)) {
        case (null) { return #err("Job not found") };
        case (?j) { j };
      };
      if (job.status != #Settling) {
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
      for (id in staleJobs.vals()) { jobs.delete(id); evmJobRail.delete(id) };
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

    /// Start the job expiry timer. Call once at canister init.
    public func startTimers<system>() {
      ignore Timer.recurringTimer<system>(#seconds 60, func() : async () {
        ignore await expireJobs();
      });
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
      services := HashMap.fromIter(data.services.vals(), data.services.size(), Text.equal, Text.hash);
      jobs := HashMap.fromIter(data.jobs.vals(), data.jobs.size(), Text.equal, Text.hash);
      serviceCounter := data.serviceCounter;
      jobCounter := data.jobCounter;
      // Optional for upgrade compatibility: pre-1a stable records have no evmRails.
      evmJobRail := switch (data.evmRails) {
        case (?rails) { HashMap.fromIter(rails.vals(), rails.size(), Text.equal, Text.hash) };
        case (null) { HashMap.HashMap<Text, Types.EvmRail>(16, Text.equal, Text.hash) };
      };
      operatorEvmPayout := switch (data.operatorPayouts) {
        case (?p) { HashMap.fromIter(p.vals(), p.size(), Principal.equal, Principal.hash) };
        case (null) { HashMap.HashMap<Principal, Text>(8, Principal.equal, Principal.hash) };
      };
    };
  };
};
