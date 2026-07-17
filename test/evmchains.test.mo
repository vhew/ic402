/// setEvmChains CAPTURE REGRESSION — the test a Gateway-only implementation fails.
///
/// Sessions receives `config` BY VALUE at construction (Gateway.mo wires it in) and performs
/// its OWN `evmChains` lookup at session-open (Sessions.mo, openEvmSession's M-5 chain
/// resolution). Motoko records are immutable value bindings, so an implementation of
/// setEvmChains that only swapped the Gateway's binding would pass every synchronous test in
/// test/gateway.test.mo while silently leaving the SESSION rail on the construction-time
/// chains. These tests drive the real open path and assert the chain-lookup outcome flips
/// after setEvmChains:
///   - the swapped-IN chain proceeds PAST the chain lookup and dies at the deliberately bogus
///     EIP-3009 signature → #invalidSignature (verified locally — no inter-canister call),
///   - the swapped-OUT chain is rejected at the lookup → #networkNotSupported.
/// Everything on these paths (locks, policy, C-1 recipient check, value checks, chain lookup,
/// local EIP-712 recovery) runs before any actor call, so the whole flow executes in the
/// unit-test interpreter. mo:test/async because openSession is async.
import Gateway "../src/ic402/Gateway";
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
// The canister's "derived" EVM address (C-1: the EIP-3009 `to` must equal it, and the open
// path refuses to proceed while it is underived — so the fixtures inject it).
let canisterEvmAddr = "0x9999999999999999999999999999999999999999";

let tokA : Types.EvmTokenConfig = {
  address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  symbol = "USDC"; decimals = 6; name = ?"USDC"; version = ?"2";
};
let tokB : Types.EvmTokenConfig = {
  address = "0xdddddddddddddddddddddddddddddddddddddddd";
  symbol = "USDC"; decimals = 6; name = ?"USD Coin"; version = ?"2";
};
let chainA : Types.EvmChainConfig = { chainId = 84532; recipient = canisterEvmAddr; tokens = [tokA] };
let chainB : Types.EvmChainConfig = { chainId = 8453; recipient = canisterEvmAddr; tokens = [tokB] };
let cfg : Types.Config = {
  recipient = { owner = canisterP; subaccount = null };
  tokens = [];
  evmChains = [chainA]; // constructed with chain A ONLY
  evmRpcCanister = null;
  ecdsaKeyName = null;
  nonceExpirySeconds = null;
};

let DEPOSIT : Nat = 1_000_000; // 1 USDC
let b32 = Blob.fromArray(Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 { 1 }));

func intentFor(network : Text, token : Text) : Types.SessionIntent = {
  network;
  token;
  recipient = canisterEvmAddr;
  suggestedDeposit = DEPOSIT;
  minDeposit = null;
  expiry = 9_999_999_999_000_000_000; // far future (fake clock is ~0)
  costPerCall = null;
  description = null;
};

let clientCfg : Types.SessionConfig = {
  maxDeposit = DEPOSIT;
  autoClose = false;
  idleTimeout = null;
};

// Well-formed but cryptographically bogus EIP-3009 deposit authorization: passes the lock,
// policy, C-1 `to == canisterEvmAddr`, and value == deposit checks, so the next gate is the
// CHAIN LOOKUP — after which the local EIP-712 recovery rejects the dummy r/s.
func sigFor(network : Text) : Types.PaymentSignature = {
  scheme = "exact";
  network;
  signature = Blob.fromArray([]);
  publicKey = ?b32; // session voucher key (32-byte length-checked)
  asset = null;
  sender = "0x2222222222222222222222222222222222222222";
  nonce = Blob.fromArray([]);
  authorization = ?{
    from = "0x2222222222222222222222222222222222222222";
    to = canisterEvmAddr;
    value = DEPOSIT;
    validAfter = 0;
    validBefore = 9_999_999_999;
    nonce = b32;
    v = 27;
    r = b32;
    s = b32;
  };
};

func isNetworkNotSupported(r : { #ok : Types.SessionState; #err : Types.PaymentResult }) : Bool {
  switch (r) { case (#err(#networkNotSupported(_))) { true }; case (_) { false } };
};
// "Got past the chain lookup": the bogus signature is the NEXT local failure after chain/domain
// resolution succeeds. Excludes the strict token-membership rejection (distinct message), so
// a configured-token open and an unconfigured-token open cannot be confused.
func failedAtSignature(r : { #ok : Types.SessionState; #err : Types.PaymentResult }) : Bool {
  switch (r) {
    case (#err(#invalidSignature(m))) { not Text.contains(m, #text "Unsupported asset") };
    case (_) { false };
  };
};
// The strict token-membership rejection: chain resolves, but the token is not (any longer) in
// its configured list.
func failedAtUnconfiguredToken(r : { #ok : Types.SessionState; #err : Types.PaymentResult }) : Bool {
  switch (r) {
    case (#err(#invalidSignature(m))) { Text.contains(m, #text "Unsupported asset") };
    case (_) { false };
  };
};

// Distinct callers per open (defensive vs the per-caller open lock).
let c1 = Principal.fromText("2vxsx-fae");
let c2 = Principal.fromText("aaaaa-aa");

await suite("Sessions.setEvmChains reaches the session-open chain lookup", func() : async () {

  await test("constructed chain resolves; after setEvmChains the NEW chain resolves and the OLD one is rejected", func() : async () {
    let mgr = Sessions.Sessions(
      canisterP, cfg, Policy.Engine(), Escrow.EscrowManager(canisterP),
      EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { ?canisterEvmAddr } },
    );
    // Sanity: chain A (constructor config) passes the lookup, bogus sig fails after it.
    let r0 = await mgr.openSession(c1, intentFor("eip155:84532", tokA.address), clientCfg, sigFor("eip155:84532"));
    assert failedAtSignature(r0);

    mgr.setEvmChains([chainB]);

    // Swapped-in chain B passes the lookup (fails at the signature — i.e. AFTER it)…
    let rB = await mgr.openSession(c1, intentFor("eip155:8453", tokB.address), clientCfg, sigFor("eip155:8453"));
    assert failedAtSignature(rB);
    // …swapped-out chain A no longer resolves.
    let rA = await mgr.openSession(c2, intentFor("eip155:84532", tokA.address), clientCfg, sigFor("eip155:84532"));
    assert isNetworkNotSupported(rA);
  });

  await test("TOKEN granularity: a token absent from the live chain's list is rejected, not defaulted", func() : async () {
    // Chain B stays configured but its token list is [tokB] — an intent naming tokA (e.g. a
    // token the operator just swapped out) must be REJECTED at membership, never fall through
    // to the "USD Coin"/"2" default EIP-712 domain (which, for canonical USDC, would verify a
    // genuine signature and open a session on a de-configured token).
    let mgr = Sessions.Sessions(
      canisterP, cfg, Policy.Engine(), Escrow.EscrowManager(canisterP),
      EvmEscrow.EvmEscrowManager(), null, { get = func() : ?Text { ?canisterEvmAddr } },
    );
    mgr.setEvmChains([chainB]);
    let r = await mgr.openSession(c1, intentFor("eip155:8453", tokA.address), clientCfg, sigFor("eip155:8453"));
    assert failedAtUnconfiguredToken(r);
  });
});

await suite("Gateway.setEvmChains forwards to the session rail (the Gateway-only-swap regression)", func() : async () {

  await test("after gate.setEvmChains, gate.openSession resolves the NEW chain and rejects the OLD", func() : async () {
    let gate = Gateway.Gateway(cfg, canisterP);
    // Seed the derived EVM recipient through the stable-state round-trip: C-1 requires it
    // before the chain lookup is reachable, and tECDSA derivation is impossible here.
    let snap = gate.toStable();
    gate.loadStable({ snap with evmRecipient = ?canisterEvmAddr });

    // Sanity pre-swap: chain A resolves through the full Gateway → Sessions path.
    let r0 = await gate.openSession(c1, intentFor("eip155:84532", tokA.address), clientCfg, sigFor("eip155:84532"));
    assert failedAtSignature(r0);

    switch (gate.setEvmChains([chainB])) { case (#ok) {}; case (#err(_)) { assert false } };

    // THE regression assertion: a Gateway-only swap leaves Sessions on [chainA], making this
    // #networkNotSupported instead of #invalidSignature.
    let rB = await gate.openSession(c1, intentFor("eip155:8453", tokB.address), clientCfg, sigFor("eip155:8453"));
    assert failedAtSignature(rB);
    let rA = await gate.openSession(c2, intentFor("eip155:84532", tokA.address), clientCfg, sigFor("eip155:84532"));
    assert isNetworkNotSupported(rA);
  });
});
