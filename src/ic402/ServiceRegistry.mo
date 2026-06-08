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
import Text "mo:base/Text";
import Time "mo:base/Time";
import Timer "mo:base/Timer";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import SHA256 "mo:sha2/Sha256";
import Principal "mo:base/Principal";

module {

  /// Service marketplace: register services, manage jobs, verify and settle.
  /// Minimal config for ServiceRegistry — only the fields it uses.
  public type ServiceConfig = {
    recipient : Types.Account;
    tokens : [Types.TokenConfig];
  };

  public class ServiceRegistry(
    _canisterPrincipal : Principal,
    config : ServiceConfig,
  ) {
    var services = HashMap.HashMap<Text, Types.ServiceDefinition>(16, Text.equal, Text.hash);
    var jobs = HashMap.HashMap<Text, Types.Job>(64, Text.equal, Text.hash);
    var serviceCounter : Nat = 0;
    var jobCounter : Nat = 0;

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

    // C-5 (v2): buyer is Text. Only ICP-principal buyers can receive an ICRC
    // refund; EVM (0x…) buyers cannot be auto-refunded via the ICP ledger.
    func buyerIcpAccount(buyer : Text) : ?Types.Account {
      if (Text.startsWith(buyer, #text "0x")) { return null };
      ?{ owner = Principal.fromText(buyer); subaccount = null };
    };

    /// Submit a service request. The buyer has already paid (receipt from Gateway).
    /// The payment is custodied at the platform recipient account until the job is
    /// verified and settled (see settleJob / expireJobs for the custody model).
    /// C-5 (v2): `buyer` is Text — a principal for ICP payers, or a 0x EVM address
    /// for EVM payers (receipt.sender). It is NOT coerced to a Principal, which
    /// trapped for EVM addresses after the on-chain transfer had already executed.
    public func submitRequest(
      buyer : Text,
      serviceId : Text,
      params : Blob,
      receipt : Types.PaymentReceipt,
      callback : ?Text,
    ) : { #ok : Text; #err : Text } {
      let svc = switch (services.get(serviceId)) {
        case (null) { return #err("Service not found: " # serviceId) };
        case (?s) { s };
      };
      if (not svc.enabled) return #err("Service is disabled");

      // Validate amount against pricing
      switch (svc.pricing) {
        case (#Exact(price)) {
          if (receipt.amount < price) return #err("Insufficient payment: need " # Nat.toText(price) # ", got " # Nat.toText(receipt.amount));
        };
        case (#Upto(maxPrice)) {
          if (receipt.amount < 1) return #err("Payment required");
          // Upto: buyer authorizes up to maxPrice, we accept any amount <= max
        };
        case (#Session) {}; // Session-based billing handled separately
      };

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
        expiresAt = now + svc.timeout * 1_000_000_000; // seconds → nanos
        completedAt = null;
        deliveryCallback = callback;
      };
      jobs.put(jobId, job);
      #ok(jobId);
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

      // Validate actualCost for Upto pricing
      let cost = switch (actualCost) {
        case (?c) {
          if (c > job.amount) return #err("Actual cost exceeds escrowed amount");
          c;
        };
        case (null) { job.amount }; // Exact pricing: full amount
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
        case (#ZkGroth16({ verificationKey; verifierCanister })) {
          let proof = switch (job.proof) {
            case (null) { return #err("ZK proof required but not provided") };
            case (?p) { p };
          };
          // Params are the public inputs — each 32-byte chunk is one serialized field element
          let publicInputs : [Blob] = if (Blob.toArray(job.params).size() > 0) {
            [job.params];
          } else { [] };

          let verifier : Types.ZkVerifierActor = actor (Principal.toText(verifierCanister));
          switch (await verifier.verify_groth16(proof, publicInputs, verificationKey)) {
            case (#ok) {
              jobs.put(jobId, { job with status = #Verified });
              await settleJob(jobId);
            };
            case (#err(msg)) {
              jobs.put(jobId, { job with status = #Disputed });
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
    public func disputeJob(buyer : Principal, jobId : Text, reason : Text) : { #ok; #err : Text } {
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
        switch (buyerIcpAccount(job.buyer)) {
          case (?acct) {
            switch (await payFromMainAccount(acct, job.amount)) {
              case (#ok(_)) { jobs.put(jobId, { job with status = #Refunded }); #ok };
              case (#err(e)) { #err("Refund failed: " # e) };
            };
          };
          case (null) { #err("EVM buyer cannot be refunded via ICRC; refund out-of-band") };
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

      let cost = switch (job.actualCost) {
        case (?c) { c };
        case (null) { job.amount };
      };

      // C-4: Pay the operator their cost from the platform recipient account.
      switch (job.operator) {
        case (?op) {
          switch (await payFromMainAccount({ owner = op; subaccount = null }, cost)) {
            case (#err(e)) {
              jobs.put(jobId, { job with status = #Verified }); // roll back for retry
              return #err("Settlement failed: " # e);
            };
            case (#ok(_)) {};
          };
        };
        case (null) {
          jobs.put(jobId, { job with status = #Verified });
          return #err("Job has no assigned operator to settle to");
        };
      };

      // C-4/C-5: Refund the Upto remainder to the buyer (ICP buyers only).
      let refundAmount = if (job.amount > cost) { job.amount - cost } else { 0 };
      if (refundAmount > 0) {
        switch (buyerIcpAccount(job.buyer)) {
          case (?buyerAccount) {
            switch (await payFromMainAccount(buyerAccount, refundAmount)) {
              case (#err(e)) {
                // Operator was already paid — the job IS settled; surface the
                // refund problem without rolling back the operator payment.
                jobs.put(jobId, { job with status = #Settled });
                return #err("Operator paid but buyer refund failed: " # e);
              };
              case (#ok(_)) {};
            };
          };
          case (null) {}; // EVM buyer: Upto remainder is not ICRC-refundable here
        };
      };

      jobs.put(jobId, { job with status = #Settled });
      #ok;
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
          jobs.put(id, { job with status = #Expired });
          expired.add(id);

          // C-4/C-5: Refund the buyer from the platform recipient account
          // (ICP buyers only — EVM buyers are refunded out-of-band).
          switch (buyerIcpAccount(job.buyer)) {
            case (?buyerAccount) {
              switch (await payFromMainAccount(buyerAccount, job.amount)) {
                case (#ok(_)) { jobs.put(id, { job with status = #Refunded }) };
                case (#err(_)) {}; // leave #Expired; don't block other jobs
              };
            };
            case (null) {};
          };
        };
      };

      // M-5: Remove terminal jobs (Settled/Refunded) older than 24 hours
      let gcCutoff = now - 24 * 60 * 60 * 1_000_000_000; // 24 hours in nanoseconds
      let staleJobs = Buffer.Buffer<Text>(8);
      for ((id, job) in jobs.entries()) {
        switch (job.status) {
          case (#Settled or #Refunded) {
            let completedTime = switch (job.completedAt) {
              case (?t) { t };
              case (null) { job.createdAt }; // fallback if completedAt not set
            };
            if (completedTime < gcCutoff) {
              staleJobs.add(id);
            };
          };
          case (_) {};
        };
      };
      for (id in staleJobs.vals()) {
        jobs.delete(id);
      };

      Buffer.toArray(expired);
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
      };
    };

    /// Restore from canister upgrades.
    public func loadStable(data : Types.StableServiceRegistryState) {
      services := HashMap.fromIter(data.services.vals(), data.services.size(), Text.equal, Text.hash);
      jobs := HashMap.fromIter(data.jobs.vals(), data.jobs.size(), Text.equal, Text.hash);
      serviceCounter := data.serviceCounter;
      jobCounter := data.jobCounter;
    };
  };
};
