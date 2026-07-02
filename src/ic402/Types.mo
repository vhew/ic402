/// ic402 — Core types for payment, sessions, and policy.
module {

  // ── Token & Pricing ──

  /// Token ledger configuration (principal, symbol, decimals).
  public type TokenConfig = {
    ledger : Principal;
    symbol : Text;
    decimals : Nat8;
  };

  /// Payment price: token, amount, and CAIP-2 network.
  public type Price = {
    token : Principal;
    amount : Nat;
    network : Text; // CAIP-2: "icp:1" or "eip155:43114"
  };

  // ── EIP-3009 Authorization (standard x402 EVM payments) ──

  /// EIP-3009 TransferWithAuthorization parameters for EVM USDC payments.
  public type Eip3009Authorization = {
    /// payer EVM address (0x-prefixed)
    from : Text;
    /// recipient EVM address (0x-prefixed)
    to : Text;
    /// USDC amount
    value : Nat;
    /// unix timestamp (seconds)
    validAfter : Nat;
    /// unix timestamp (seconds)
    validBefore : Nat;
    /// random bytes32
    nonce : Blob;
    /// ECDSA recovery id
    v : Nat8;
    /// 32 bytes
    r : Blob;
    /// 32 bytes
    s : Blob;
  };

  // ── Charge (x402 "exact") ──

  /// 402 payment requirement returned to clients (scheme, amount, nonce, expiry).
  public type PaymentRequirement = {
    scheme : Text;
    network : Text;
    token : Text;
    amount : Nat;
    recipient : Text;
    nonce : Blob;
    /// Absolute deadline in NANOSECONDS since epoch (Time.now() scale).
    expiry : Int;
    /// EIP-712 domain name for 402 extra field. Null = "USD Coin".
    tokenName : ?Text;
    /// EIP-712 domain version for 402 extra field. Null = "2".
    tokenVersion : ?Text;
  };

  /// Payment signature for x402 settlement.
  /// For charges: `signature` contains the cryptographic signature (ICP) or tx hash (EVM).
  ///              `publicKey` should be null.
  /// For sessions: `publicKey` contains the payer's 32-byte Ed25519 public key
  ///               (used to verify voucher signatures during the session).
  ///               `signature` is unused (set to empty blob).
  public type PaymentSignature = {
    scheme : Text;
    network : Text;
    signature : Blob;
    publicKey : ?Blob; // Ed25519 public key for sessions. Null for charges.
    sender : Text;
    nonce : Blob;
    authorization : ?Eip3009Authorization; // EIP-3009 for standard x402 EVM payments. Null for ICP.
    /// EVM token contract (EIP-712 verifyingContract) the payer signed for. `null` for ICP / legacy
    /// clients → the chain's FIRST configured token is used. Enables multi-token-per-chain settlement:
    /// the verifyingContract, EIP-712 domain, and on-chain execution token all key off THIS asset, so
    /// a valid signature for a non-first token is no longer verified against the wrong token's domain.
    /// (Candid `opt` → backward-compatible: an old client that omits it decodes to null.)
    asset : ?Text;
  };

  /// Receipt issued after successful payment settlement.
  /// `txHash` is the on-chain proof: ICP block index (charges), EVM tx hash (EVM charges),
  /// or null (session close receipts where settlement is internal).
  public type PaymentReceipt = {
    id : Text;
    amount : Nat;
    token : Text;
    sender : Text;
    recipient : Text;
    network : Text;
    timestamp : Int;
    txHash : ?Text;
    sessionId : ?Text;
    refunded : ?Nat;
  };

  /// Result of a charge or session close settlement.
  public type PaymentResult = {
    #ok : PaymentReceipt;
    #insufficientFunds : Text;
    #invalidSignature : Text;
    #expired : Text;
    #policyDenied : Text;
    #tokenNotAccepted : Text;
    #networkNotSupported : Text;
    #settlementFailed : Text;
    // H-1 (v2): EVM transfer was broadcast but not yet confirmed on-chain.
    // The payment is NOT final — do not deliver value. The bound nonce is kept
    // locked (and GC'd at expiry) so the same challenge is not re-broadcast.
    #settlementPending : Text;
    #reputationTooLow : Nat;
    #depositBelowMinimum : Nat;
  };

  // ── Session (escrow + cumulative vouchers) ──

  /// Session offer describing deposit, cost, and expiry for the client.
  /// The credited deposit at open is min(suggestedDeposit, the client's SessionConfig.maxDeposit),
  /// and must be ≥ minDeposit (else #depositBelowMinimum). Setting minDeposit > suggestedDeposit
  /// makes the intent unsatisfiable. `costPerCall` is advisory pricing information for the
  /// client; the library does not enforce it per voucher. `expiry` is NANOSECONDS since epoch.
  public type SessionIntent = {
    network : Text;
    token : Text;
    recipient : Text;
    suggestedDeposit : Nat;
    minDeposit : ?Nat;
    /// Absolute deadline in NANOSECONDS since epoch (Time.now() scale).
    expiry : Int;
    costPerCall : ?Nat;
    description : ?Text;
  };

  /// Client-side session preferences (max deposit, auto-close, idle timeout).
  public type SessionConfig = {
    maxDeposit : Nat;
    autoClose : Bool;
    /// NANOSECONDS; null = inherit the effective policy's sessionIdleTimeout.
    idleTimeout : ?Int;
  };

  /// Lifecycle state of a streaming session.
  public type SessionStatus = {
    #open;
    #closing;
    #closed;
    #expired;
  };

  /// Public view of a session's state (read-only snapshot).
  public type SessionState = {
    id : Text;
    payer : Principal;
    deposited : Nat;
    consumed : Nat;
    remaining : Nat;
    voucherCount : Nat;
    status : SessionStatus;
    openedAt : Int;
    lastActivityAt : Int;
  };

  /// Cumulative payment voucher signed by the session payer.
  /// `signature` is a 64-byte Ed25519 signature (by the publicKey registered at openSession)
  /// over the CBOR array [text(verifyingCanisterId), text(sessionId), uint(cumulativeAmount),
  /// uint(sequence)] — see Sessions.encodeVoucherPayload; the canister principal is bound in,
  /// so a voucher cannot be replayed against another canister. `cumulativeAmount` is the
  /// running TOTAL (not a delta), strictly increasing and ≤ the session deposit; values above
  /// Nat64 max are rejected (#payloadOverflow).
  public type Voucher = {
    sessionId : Text;
    cumulativeAmount : Nat;
    sequence : Nat;
    signature : Blob;
  };

  /// Result of voucher consumption.
  /// `#ok(delta)` returns the incremental amount consumed by this voucher
  /// (cumulativeAmount - previousCumulativeAmount).
  public type VoucherResult = {
    #ok : Nat;
    #insufficientDeposit;
    #invalidSignature;
    #invalidSequence;
    #sessionNotOpen;
    #policyDenied : Text;
    #payloadOverflow; // Cumulative amount or sequence exceeds Nat64 maximum
  };

  // ── Policy ──

  /// Spending limits and access control.
  /// Set a field to `null` to disable that limit (no restriction).
  /// Set a field to `?value` to enforce it.
  public type SpendingPolicy = {
    maxPerTransaction : ?Nat;
    maxPerDay : ?Nat;
    rateLimitPerMinute : ?Nat;
    maxSessionDeposit : ?Nat;
    maxConcurrentSessions : ?Nat;
    /// Max session lifetime in NANOSECONDS (compared to Time.now() − openedAt).
    maxSessionDuration : ?Int;
    /// Idle cutoff in NANOSECONDS since last voucher/activity.
    sessionIdleTimeout : ?Int;
    allowedCallers : ?[Principal];
    blockedCallers : ?[Principal];
  };

  /// Minimum reputation and required tags for access control.
  public type TrustRequirements = {
    minReputation : Nat;
    requiredTags : [Text];
  };

  // ── ICRC-1/2 ──

  /// ICRC-1 account (owner principal + optional subaccount).
  public type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  /// ICRC-1 transfer arguments.
  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  /// ICRC-1 transfer error variants.
  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  /// ICRC-1 transfer result.
  public type TransferResult = {
    #Ok : Nat;
    #Err : TransferError;
  };

  /// ICRC-2 transferFrom arguments.
  public type TransferFromArg = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  /// ICRC-2 transferFrom error variants.
  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  /// ICRC-2 transferFrom result.
  public type TransferFromResult = {
    #Ok : Nat;
    #Err : TransferFromError;
  };

  // ── Internal session state (extends public SessionState) ──

  /// Internal mutable session state (not exposed to clients).
  public type InternalSessionState = {
    id : Text;
    payer : Principal;
    payerPublicKey : Blob;
    deposited : Nat;
    // v2: the daily-limit bucket day the deposit was reserved against (from
    // Policy.currentDay()), so the credit-back on close targets the same bucket
    // even when close happens on a later UTC day. Transient (not in StableSession).
    spendDay : Int;
    var consumed : Nat;
    var remaining : Nat;
    var voucherCount : Nat;
    var status : SessionStatus;
    openedAt : Int;
    var lastActivityAt : Int;
    var lastSequence : Nat;
    var lastCumulativeAmount : Nat;
    subaccount : Blob;
    network : Text;
    token : Text;
    recipient : Text;
    autoClose : Bool;
    maxDuration : ?Int;
    idleTimeout : ?Int;
    evmDeposit : ?EvmSessionDeposit;
  };

  // ── Stable state types ──

  /// Stable storage format for sessions (canister upgrades).
  public type StableSession = {
    id : Text;
    payer : Principal;
    payerPublicKey : Blob;
    deposited : Nat;
    consumed : Nat;
    remaining : Nat;
    voucherCount : Nat;
    status : SessionStatus;
    openedAt : Int;
    lastActivityAt : Int;
    lastSequence : Nat;
    lastCumulativeAmount : Nat;
    subaccount : Blob;
    network : Text;
    token : Text;
    recipient : Text;
    autoClose : Bool;
    maxDuration : ?Int;
    idleTimeout : ?Int;
    evmDeposit : ?EvmSessionDeposit;
  };

  /// Stable storage format for nonce manager state.
  public type StableNonceState = {
    nonces : [(Blob, (Int, Nat, Text, Text))]; // (expiry, amount, network, token)
    counter : Nat;
    lockedNonces : ?[Blob]; // C-1: Persist locked nonces across upgrades
  };

  /// Stable storage format for policy engine state.
  public type StablePolicyState = {
    globalPolicy : SpendingPolicy;
    callerPolicies : [(Principal, SpendingPolicy)];
    dailySpendEntries : [(Text, Nat)];
    rateLimitEntries : [(Text, [Int])];
  };

  /// Stable storage format for the entire gateway (top-level persist).
  public type StableGatewayState = {
    sessions : [StableSession];
    nonces : StableNonceState;
    policy : StablePolicyState;
    receiptCounter : Nat;
    accessGrants : ?StableAccessGrantState;
    consumedTxHashes : ?[Text];  // C-1: EVM tx replay prevention
    sessionCounter : ?Nat;        // M-3: session counter persistence
    evmRecipient : ?Text;         // Self-derived EVM address from tECDSA key
    evmAllocations : ?[StableEvmAllocation]; // EVM session deposit allocations
  };

  // ── Ledger actor type ──

  /// Actor interface for ICRC-1/2 ledger canisters.
  public type LedgerActor = actor {
    icrc1_transfer : (TransferArg) -> async TransferResult;
    icrc1_fee : () -> async Nat;
    icrc2_transfer_from : (TransferFromArg) -> async TransferFromResult;
  };

  // ── Configuration ──

  /// EVM ERC-20 token configuration (address, symbol, EIP-712 domain).
  public type EvmTokenConfig = {
    address : Text;
    symbol : Text;
    decimals : Nat8;
    name : ?Text;    // EIP-712 domain name (e.g. "USD Coin" mainnet, "USDC" Base Sepolia). Null = "USD Coin".
    version : ?Text; // EIP-712 domain version. Null = "2".
  };

  /// EVM chain configuration (chain ID, recipient, tokens).
  public type EvmChainConfig = {
    chainId : Nat;
    recipient : Text;
    tokens : [EvmTokenConfig];
  };

  /// Gas fee overrides for EVM transactions.
  public type GasConfig = {
    maxFeePerGas : ?Nat;
    maxPriorityFeePerGas : ?Nat;
    gasLimit : ?Nat;
  };

  /// Configuration for ERC-8004 agent identity registration.
  public type ERC8004Config = {
    chain : { #base; #ethereum; #avalanche; #optimism; #arbitrum };
    card : AgentCard;
    ecdsaKeyName : Text;
    evmRpcCanister : ?Text;
    registryAddress : Text;
    chainId : Nat;
    gasConfig : ?GasConfig;
  };

  /// Result of ERC-8004 agent registration.
  public type RegisterAgentResult = {
    #ok : { tokenId : Nat; txHash : Text };
    #err : Text;
  };

  /// ERC-8004 agent metadata (name, description, services).
  public type AgentCard = {
    name : Text;
    description : Text;
    services : [ServiceEntry];
    x402Support : Bool;
  };

  /// Service endpoint in an ERC-8004 agent card.
  public type ServiceEntry = {
    name : Text;
    endpoint : Text;
    version : Text;
    skills : [Text];
    domains : [Text];
  };

  /// Top-level gateway configuration (tokens, EVM chains, ECDSA key).
  public type Config = {
    recipient : { owner : Principal; subaccount : ?Blob };
    tokens : [TokenConfig];
    evmChains : [EvmChainConfig];
    evmRpcCanister : ?Text; // Override EVM RPC canister principal. Null = use default (mainnet 7hfb6-...).
    ecdsaKeyName : ?Text; // "dfx_test_key" (local) or "key_1" (mainnet). Null = disable auto EVM address derivation.
    nonceExpirySeconds : ?Nat; // Nonce validity window. Null = use default (300 seconds / 5 minutes).
  };

  // ── Content Delivery ──

  /// Reference to stored content (id, mime type, size, metadata).
  public type ContentRef = {
    id : Text;
    mimeType : ?Text;
    sizeBytes : ?Nat;
    metadata : ?[(Text, Text)];
  };

  /// HMAC-signed access grant for content delivery.
  public type AccessGrant = {
    grantId : Text;
    contentRef : ContentRef;
    grantee : Principal;
    receiptId : Text;
    issuedAt : Int;
    expiresAt : Int;
    hmac : Blob;
  };

  /// Result of access grant verification.
  public type AccessGrantResult = {
    #ok;
    #expired : Text;
    #invalidGrant : Text;
    #revoked : Text;
  };

  /// How content is delivered (inline, HTTP, asset canister, query).
  public type DeliveryMethod = {
    #inline : Blob;
    #canisterQuery : { method : Text; chunkCount : Nat };
    #httpUrl : Text;
    #assetCanister : { canisterId : Principal; path : Text };
  };

  /// Access grant paired with its delivery method.
  /// `settlementTxHash` is the on-chain proof of the inbound payment that unlocked this
  /// content: the EVM tx hash (EIP-3009 / EVM charges) or the ICP ledger block index
  /// (ICP charges), or null if the underlying receipt carried no hash. Lets a caller
  /// verify the settlement (e.g. on a block explorer) without a second round-trip.
  public type ContentDelivery = {
    grant : AccessGrant;
    delivery : DeliveryMethod;
    settlementTxHash : ?Text;
  };

  /// Stable storage format for grant subsystem state.
  public type StableAccessGrantState = {
    revokedGrantIds : [Text];
    revokedGrantTimestamps : ?[(Text, Int)]; // M-1: grant ID → revocation timestamp
    grantCounter : Nat;
    hmacSeed : Nat;
  };

  // ── Content Store ──

  /// Metadata for a stored content item.
  public type ContentEntry = {
    id : Text;
    mimeType : Text;
    totalSize : Nat;
    chunkCount : Nat;
    createdAt : Int;
  };

  /// Result of content store operations.
  public type ContentStoreResult = {
    #ok;
    #contentNotFound;
    #chunkNotFound : Nat;
    #contentAlreadyExists;
    #chunkTooLarge : Nat;
  };

  /// Stable storage format for a content entry with chunks.
  /// M-2 (v2): `salt` is a per-entry value mixed into key/nonce derivation so a
  /// re-created content id (delete + re-put) never reuses the same (key, nonce).
  /// Optional for backward decode of pre-v2 state (defaults to 0).
  public type StableContentEntry = {
    id : Text;
    mimeType : Text;
    chunks : [Blob];
    totalSize : Nat;
    createdAt : Int;
    salt : ?Nat;
  };

  /// Stable storage format for the content store.
  /// H-6/H-7 (v2): the externally-seeded master key and the seed flag are now
  /// persisted so encrypted content survives upgrades. Optional for backward
  /// decode of pre-v2 state. `saltCounter` backs the monotonic per-entry salt.
  public type StableContentStoreState = {
    entries : [StableContentEntry];
    masterKey : ?Blob;
    seedInitialized : ?Bool;
    saltCounter : ?Nat;
  };

  // ── EVM Session Deposits ──

  /// EVM deposit metadata for a session (tx hash, chain, payer, token).
  public type EvmSessionDeposit = {
    txHash : Text;
    chainId : Nat;
    payerEvmAddress : Text;
    tokenAddress : Text;
  };

  /// Stable storage format for EVM escrow allocations.
  public type StableEvmAllocation = {
    sessionId : Text;
    chainId : Nat;
    token : Text;
    amount : Nat;
  };

  // ── Identity ──

  /// Stable storage format for identity module state.
  public type StableIdentityState = {
    agentId : ?Nat;
    evmAddress : ?Text;
  };

  // ── HTTP (canister HTTP serving) ──

  /// IC HTTP gateway request (method, url, headers, body).
  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [(Text, Text)];
    body : Blob;
  };

  /// IC HTTP gateway response (status, headers, body).
  public type HttpResponse = {
    status_code : Nat16;
    headers : [(Text, Text)];
    body : Blob;
    upgrade : ?Bool;
  };

  // ── Service Marketplace ──

  /// Whether the service completes within one HTTP request or requires async delivery.
  public type ServiceType = { #Sync; #Async };

  /// How the buyer is charged.
  public type PricingScheme = {
    #Exact : Nat;   // fixed price per request (USDC e6)
    #Upto : Nat;    // max authorization; settle at actual cost
    #Session;       // use existing session deposit
  };

  /// How the canister verifies the operator's result before settling.
  public type VerificationMethod = {
    // bindResult: when true, the canister prepends a field element derived from SHA-256(result)
    // as public input 0, so the proof attests to the DELIVERED result (not just the params). This
    // requires a circuit built to commit to that input — so it is OPT-IN. When false (default),
    // the public inputs are the buyer's params only (a circuit that proves the computation but not
    // the result string — e.g. the √25 demo).
    #ZkGroth16 : { verificationKey : Blob; verifierCanister : Principal; bindResult : Bool };
    #HashMatch;                              // sha256(result) must match buyer-provided hash
    #BuyerConfirm : { disputeWindowSeconds : Nat }; // buyer approves or disputes
    #AutoSettle;                             // trust the operator (reputation-gated)
  };

  /// How the buyer receives the result.
  public type ServiceDeliveryMethod = { #Poll; #Callback; #Both };

  /// A registered service definition.
  public type ServiceDefinition = {
    id : Text;
    name : Text;
    description : Text;
    serviceType : ServiceType;
    pricing : PricingScheme;
    verification : VerificationMethod;
    delivery : ServiceDeliveryMethod;
    timeout : Nat;           // seconds until auto-refund if not completed
    operatorId : Principal;  // who does the work
    enabled : Bool;
    createdAt : Int;
  };

  /// Job lifecycle status.
  public type JobStatus = {
    #Pending;    // paid, waiting for operator
    #Assigned;   // operator claimed
    #Computing;  // operator working (optional status)
    #Submitted;  // operator submitted result
    #Verified;   // result verified (ZK, hash, or buyer confirm)
    #Settling;   // H-5 (v2): terminal settlement in progress — re-entry guard
    #Settled;    // payment transferred to operator
    #Disputed;   // buyer disputes the result
    #Expired;    // timed out, refund pending
    #Refunded;   // funds returned to buyer
  };

  /// A parked OUTBOUND EVM transfer whose settle/refund broadcast but did not confirm within the
  /// poll budget (#pending). Persisted so a controller can re-poll it CONFIRM-ONLY (never
  /// re-broadcast — that risks double-pay) and finalize. `leg` says which terminal state a mined
  /// status==1 implies; `chainId`/`token` let the reconcile re-poll the exact tx.
  public type ParkedLeg = {
    #Settle; // settle-to-operator → on confirm ⇒ #Settled
    #Refund; // dispute/expire refund-to-buyer → on confirm ⇒ #Refunded
    #UptoRemainder; // Upto buyer remainder; operator already paid+confirmed → confirm clears parkedTx
  };
  /// A settle/refund transfer that broadcast but isn't yet confirmed — recorded so a recovery
  /// path can re-poll it confirm-only (and never re-broadcast it).
  public type ParkedTx = {
    txHash : Text;
    leg : ParkedLeg;
    chainId : Nat;
    token : Text;
    parkedAt : Int;
  };

  /// Public view of a job.
  public type Job = {
    id : Text;
    serviceId : Text;
    buyer : Text;              // principal or EVM address
    operator : ?Principal;
    params : Blob;             // job parameters (opaque to canister)
    paymentReceiptId : Text;   // links to Gateway receipt
    amount : Nat;              // escrowed amount
    actualCost : ?Nat;         // for Upto pricing: real cost after completion
    status : JobStatus;
    result : ?Blob;            // operator's submission
    proof : ?Blob;             // ZK proof (if applicable)
    createdAt : Int;
    expiresAt : Int;
    completedAt : ?Int;
    deliveryCallback : ?Text;  // optional callback URL
    // v2.1.1: an in-flight EVM settle/refund that broadcast but did not confirm. null for ICP
    // jobs and jobs with no outstanding parked tx. Re-polled by reconcileJob (confirm-only).
    parkedTx : ?ParkedTx;
  };

  /// 1a: the on-chain payment rail of an EVM-paid job — the CAIP-2 network
  /// (e.g. "eip155:8453") and the ERC-20 token address it was paid in. Recorded at
  /// submitRequest so the job can be settled/refunded on the SAME rail it was paid on,
  /// instead of from the ICP ckUSDC pool (audit C3).
  public type EvmRail = {
    network : Text;
    token : Text;
  };

  /// Serializable service registry state for canister upgrades.
  public type StableServiceRegistryState = {
    services : [(Text, ServiceDefinition)];
    jobs : [(Text, Job)];
    serviceCounter : Nat;
    jobCounter : Nat;
    // Optional for upgrade compatibility: pre-1a stable records have no EVM rails / payouts.
    evmRails : ?[(Text, EvmRail)];
    operatorPayouts : ?[(Principal, Text)];
  };

  /// Interface for a ZK Groth16 verification canister.
  public type ZkVerifierActor = actor {
    verify_groth16 : shared (proof : Blob, public_inputs : [Blob], verification_key : Blob) -> async { #ok; #err : Text };
  };
};
