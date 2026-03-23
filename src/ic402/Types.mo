/// ic402 — Core types for payment, sessions, and policy.
module {

  // ── Token & Pricing ──

  public type TokenConfig = {
    ledger : Principal;
    symbol : Text;
    decimals : Nat8;
  };

  public type Price = {
    token : Principal;
    amount : Nat;
    network : Text; // CAIP-2: "icp:1" or "eip155:43114"
  };

  // ── Charge (x402 "exact") ──

  public type PaymentRequirement = {
    scheme : Text;
    network : Text;
    token : Text;
    amount : Nat;
    recipient : Text;
    nonce : Blob;
    expiry : Int;
  };

  public type PaymentSignature = {
    scheme : Text;
    network : Text;
    signature : Blob;
    sender : Text;
    nonce : Blob;
  };

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

  public type PaymentResult = {
    #ok : PaymentReceipt;
    #insufficientFunds;
    #invalidSignature;
    #expired;
    #policyDenied : Text;
    #tokenNotAccepted;
    #networkNotSupported;
    #settlementFailed : Text;
    #reputationTooLow : Nat;
    #depositBelowMinimum : Nat;
  };

  // ── Session (escrow + cumulative vouchers) ──

  public type SessionIntent = {
    network : Text;
    token : Text;
    recipient : Text;
    suggestedDeposit : Nat;
    minDeposit : ?Nat;
    expiry : Int;
    costPerCall : ?Nat;
    description : ?Text;
  };

  public type SessionConfig = {
    maxDeposit : Nat;
    autoClose : Bool;
    idleTimeout : ?Int;
  };

  public type SessionStatus = {
    #open;
    #closing;
    #closed;
    #expired;
  };

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

  public type Voucher = {
    sessionId : Text;
    cumulativeAmount : Nat;
    sequence : Nat;
    signature : Blob;
  };

  public type VoucherResult = {
    #ok : Nat; // delta
    #insufficientDeposit;
    #invalidSignature;
    #invalidSequence;
    #sessionNotOpen;
    #policyDenied : Text;
  };

  // ── Policy ──

  public type SpendingPolicy = {
    maxPerTransaction : ?Nat;
    maxPerDay : ?Nat;
    rateLimitPerMinute : ?Nat;
    maxSessionDeposit : ?Nat;
    maxConcurrentSessions : ?Nat;
    maxSessionDuration : ?Int;
    sessionIdleTimeout : ?Int;
    allowedCallers : ?[Principal];
    blockedCallers : ?[Principal];
  };

  public type TrustRequirements = {
    minReputation : Nat;
    requiredTags : [Text];
  };

  // ── ICRC-1/2 ──

  public type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

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

  public type TransferResult = {
    #Ok : Nat;
    #Err : TransferError;
  };

  public type TransferFromArg = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

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

  public type TransferFromResult = {
    #Ok : Nat;
    #Err : TransferFromError;
  };

  // ── Internal session state (extends public SessionState) ──

  public type InternalSessionState = {
    id : Text;
    payer : Principal;
    payerPublicKey : Blob;
    deposited : Nat;
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
  };

  // ── Stable state types ──

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
  };

  public type StableNonceState = {
    nonces : [(Blob, Int)];
    counter : Nat;
  };

  public type StablePolicyState = {
    globalPolicy : SpendingPolicy;
    callerPolicies : [(Principal, SpendingPolicy)];
    dailySpendEntries : [(Text, Nat)];
    rateLimitEntries : [(Text, [Int])];
  };

  public type StableGatewayState = {
    sessions : [StableSession];
    nonces : StableNonceState;
    policy : StablePolicyState;
    receiptCounter : Nat;
    accessGrants : ?StableAccessGrantState;
  };

  // ── Ledger actor type ──

  public type LedgerActor = actor {
    icrc1_transfer : (TransferArg) -> async TransferResult;
    icrc2_transfer_from : (TransferFromArg) -> async TransferFromResult;
  };

  // ── Configuration ──

  public type EvmTokenConfig = {
    address : Text;
    symbol : Text;
    decimals : Nat8;
  };

  public type EvmChainConfig = {
    chainId : Nat;
    recipient : Text;
    tokens : [EvmTokenConfig];
  };

  public type ERC8004Config = {
    chain : { #base; #ethereum; #avalanche; #optimism; #arbitrum };
    card : AgentCard;
  };

  public type AgentCard = {
    name : Text;
    description : Text;
    services : [ServiceEntry];
    x402Support : Bool;
  };

  public type ServiceEntry = {
    name : Text;
    endpoint : Text;
    version : Text;
    skills : [Text];
    domains : [Text];
  };

  public type Config = {
    recipient : { owner : Principal; subaccount : ?Blob };
    tokens : [TokenConfig];
    evmChains : [EvmChainConfig];
  };

  // ── Content Delivery ──

  public type ContentRef = {
    id : Text;
    mimeType : ?Text;
    sizeBytes : ?Nat;
    metadata : ?[(Text, Text)];
  };

  public type AccessGrant = {
    grantId : Text;
    contentRef : ContentRef;
    grantee : Principal;
    receiptId : Text;
    issuedAt : Int;
    expiresAt : Int;
    hmac : Blob;
  };

  public type AccessGrantResult = {
    #ok;
    #expired;
    #invalidGrant;
    #revoked;
  };

  public type DeliveryMethod = {
    #inline : Blob;
    #canisterQuery : { method : Text; chunkCount : Nat };
    #httpUrl : Text;
    #assetCanister : { canisterId : Principal; path : Text };
  };

  public type ContentDelivery = {
    grant : AccessGrant;
    delivery : DeliveryMethod;
  };

  public type StableAccessGrantState = {
    revokedGrantIds : [Text];
    grantCounter : Nat;
    hmacSeed : Nat;
  };

  // ── Content Store ──

  public type ContentEntry = {
    id : Text;
    mimeType : Text;
    totalSize : Nat;
    chunkCount : Nat;
    createdAt : Int;
  };

  public type ContentStoreResult = {
    #ok;
    #contentNotFound;
    #chunkNotFound : Nat;
    #contentAlreadyExists;
    #chunkTooLarge : Nat;
  };

  public type StableContentEntry = {
    id : Text;
    mimeType : Text;
    chunks : [Blob];
    totalSize : Nat;
    createdAt : Int;
  };

  public type StableContentStoreState = {
    entries : [StableContentEntry];
  };

  // ── Identity ──

  public type StableIdentityState = {
    agentId : ?Nat;
  };

  // ── HTTP (canister HTTP serving) ──

  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [(Text, Text)];
    body : Blob;
  };

  public type HttpResponse = {
    status_code : Nat16;
    headers : [(Text, Text)];
    body : Blob;
    upgrade : ?Bool;
  };
};
