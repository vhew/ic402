/// 2.17.3 session-close fixes — the decisions reached BEFORE any ledger call, so they run
/// without a ledger at all (sessions are injected with loadStable, which arms no timer).
///
///   - B1: recoverEscrow accepts #closed only; #closing / #expired are refused up front.
///   - Exit for B1: forceResolveSession takes any #closing (an ICP one interrupted by a trap, or
///     left by an earlier version, or an EVM one) to #closed and refreshes
///     lastActivityAt (G1) so recoverEscrow has a full GC window afterwards.
///
/// `dummyLedger` is never reached on a correct guard; a mutation that drops one makes the call
/// hit it and throw, so the expected #err still goes red. The ledger legs themselves (a refund
/// failure, a force landing mid-close, the sweep past ledger rejects) are in
/// test/closeledger.test.mo. The sweep's catch arm (a rejected self-call, or a trap mid-close)
/// cannot be induced in-process and is covered by review only.
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");
let strangerP = Principal.fromText("w7x7r-cok77-xa");
let dummyLedger : Types.LedgerActor = actor (Principal.toText(canisterP));
let STALE : Int = 7; // fixture lastActivityAt — any refresh (even to 0 in the interpreter) differs

func mkSessions() : Sessions.Sessions {
  Sessions.Sessions(
    canisterP,
    {
      recipient = { owner = canisterP; subaccount = null };
      tokens = [{ ledger = canisterP; symbol = "TKN"; decimals = 8 }];
      evmChains = [];
      evmRpcCanister = null;
      ecdsaKeyName = null;
      nonceExpirySeconds = null;
    },
    Policy.Engine(),
    Escrow.EscrowManager(canisterP),
    EvmEscrow.EvmEscrowManager(),
    null,
    { get = func() : ?Text { null } },
  );
};

func load(network : Text, status : Types.SessionStatus) : Sessions.Sessions {
  let mgr = mkSessions();
  mgr.loadStable([{
    id = "sess-1"; payer = payerP; payerPublicKey = Blob.fromArray([]); deposited = 50_000; consumed = 1_000;
    remaining = 49_000; voucherCount = 0; status; openedAt = 0; lastActivityAt = STALE; lastSequence = 0;
    lastCumulativeAmount = 1_000; subaccount = Blob.fromArray([]); network; token = "TKN";
    recipient = Principal.toText(canisterP); autoClose = false; maxDuration = null; idleTimeout = null; evmDeposit = null;
  }]);
  mgr;
};

func session(mgr : Sessions.Sessions) : { status : Types.SessionStatus; lastActivityAt : Int } {
  switch (mgr.getSession("sess-1")) { case (?s) { s }; case (null) { assert false; loop {} } };
};

func refused(r : { #ok : Nat; #err : Text }, prefix : Text) {
  switch (r) {
    case (#err(msg)) { assert Text.startsWith(msg, #text prefix) };
    case (#ok(_)) { assert false };
  };
};

await suite("recoverEscrow accepts #closed only (B1)", func() : async () {
  let inProgress = "Cannot recover escrow while a close is in progress";

  await test("refuses #closing — a close is in flight", func() : async () {
    // Mutation: re-admit #closing (`case (#closed or #closing)`) — the call reaches dummyLedger.
    refused(await load("icp:1", #closing).recoverEscrow(payerP, dummyLedger, "sess-1", 1_000), inProgress);
  });

  await test("refuses #expired — the sweep marked it and its close has not finished", func() : async () {
    // Mutation: re-admit #expired (`case (#closed or #expired)`).
    refused(await load("icp:1", #expired).recoverEscrow(payerP, dummyLedger, "sess-1", 1_000), inProgress);
  });

  await test("refuses a non-payer caller before any status check (unchanged)", func() : async () {
    refused(await load("icp:1", #closed).recoverEscrow(strangerP, dummyLedger, "sess-1", 1_000), "Not authorized");
  });
});

await suite("forceResolveSession is the exit for a session resting in #closing (B3)", func() : async () {

  await test("takes an ICP #closing to #closed and refreshes lastActivityAt", func() : async () {
    // Mutations: refuse ICP here (no exit for a parked ICP close, since recoverEscrow now refuses
    // #closing); drop the lastActivityAt refresh in finalizeClosedSession (a long-idle session
    // would be GC'd on the next tick, before recoverEscrow can run).
    let mgr = load("icp:1", #closing);
    switch (mgr.forceResolveSession("sess-1")) { case (#ok) {}; case (#err(_)) { assert false } };
    assert session(mgr).status == #closed;
    assert session(mgr).lastActivityAt != STALE;
  });

  await test("takes an EVM #closing to #closed (its original purpose)", func() : async () {
    let mgr = load("eip155:8453", #closing);
    switch (mgr.forceResolveSession("sess-1")) { case (#ok) {}; case (#err(_)) { assert false } };
    assert session(mgr).status == #closed;
  });

  await test("refuses a session that is not #closing", func() : async () {
    let mgr = load("icp:1", #closed);
    switch (mgr.forceResolveSession("sess-1")) { case (#err(_)) {}; case (#ok) { assert false } };
  });
});
