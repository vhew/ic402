/// 2.22.0 — EVM rail fixes (findings E3, E4, E5, E7, E9, E10, F1).
///
/// Everything here runs before a broadcast: the interpreter has no tECDSA and traps on
/// Cycles.balance(), so a test that reaches EvmSender.sendTransaction dies there — which is how a
/// mutation that removes a pre-broadcast refusal turns these tests red. The paths that need a
/// broadcast (E5 in Gateway.settle, E7's revert check, the #maybeSent confirm poll, the dropped-tx
/// reconcile, the InsufficientFunds re-read, the 100k gas limit on the wire) are in
/// test/evm-outbound.test.ts, against the scriptable EVM-RPC mock (CI only).
///
/// The fake EVM-RPC canister is an in-file actor; it answers eth_call (authorizationState) and
/// receipt polls. Each test names the mutation that turns it red.
import Gateway "../src/ic402/Gateway";
import Sessions "../src/ic402/Sessions";
import Types "../src/ic402/Types";
import Policy "../src/ic402/Policy";
import Escrow "../src/ic402/Escrow";
import EvmEscrow "../src/ic402/EvmEscrow";
import EvmSender "../src/ic402/EvmSender";
import EvmSigner "../src/ic402/EvmSigner";
import EvmRpc "../src/ic402/EvmRpc";
import EvmUtils "../src/ic402/EvmUtils";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import SHA256 "mo:sha2/Sha256";
import { test; suite } "mo:test/async";

let canisterP = Principal.fromText("aaaaa-aa");
let payerP = Principal.fromText("2vxsx-fae");

// The canister's derived EVM address in these fixtures (also the real-signature fixture's `to`).
let canisterEvm = "0x1111111111111111111111111111111111111111";

// A real EIP-3009 signature (Hardhat test key #0, as in test/gateway.test.mo): from `signer`,
// to `canisterEvm`, value 5000, validAfter 0, validBefore 9_999_999_999, nonce 0x0101…01, over
// token A's domain ("Token A" / "1", chain 84532, verifyingContract 0xaaaa…).
let signer = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
let tokenA = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
let realR = Blob.fromArray(EvmUtils.hexToBytes("a5c642f694f8c9a6401f3f5a343eb3e108096cdc509a745a0e5afd8a90bc17da"));
let realS = Blob.fromArray(EvmUtils.hexToBytes("3d4668f36cee6112718e6d84883a841dd1bc4601d1007b00c35a05addcb65ef0"));
let b32 = Blob.fromArray(Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 { 1 }));

let chainA : Types.EvmChainConfig = {
  chainId = 84532;
  recipient = canisterEvm;
  tokens = [{ address = tokenA; symbol = "AAA"; decimals = 6; name = ?"Token A"; version = ?"1" }];
};

func config(ecdsaKeyName : ?Text, rpc : ?Text) : Types.Config = {
  recipient = { owner = canisterP; subaccount = null };
  tokens = [];
  evmChains = [chainA];
  evmRpcCanister = rpc;
  ecdsaKeyName;
  nonceExpirySeconds = null;
};

func authz(validBefore : Nat, nonce : Blob) : Types.PaymentSignature = {
  scheme = "exact";
  network = "eip155:84532";
  signature = Blob.fromArray([]);
  publicKey = ?b32;
  asset = null;
  sender = signer;
  nonce = Blob.fromArray([]);
  authorization = ?{
    from = signer;
    to = canisterEvm;
    value = 5000;
    validAfter = 0;
    validBefore;
    nonce;
    v = 27;
    r = realR;
    s = realS;
  };
};
let signed = authz(9_999_999_999, b32);

let intent : Types.SessionIntent = {
  network = "eip155:84532";
  token = tokenA;
  recipient = canisterEvm;
  suggestedDeposit = 5000;
  minDeposit = null;
  expiry = 9_999_999_999_000_000_000;
  costPerCall = null;
  description = null;
};
let clientCfg : Types.SessionConfig = { maxDeposit = 5000; autoClose = false; idleTimeout = null };

func mkSessions(sender : ?EvmSender.EvmSender) : Sessions.Sessions {
  Sessions.Sessions(
    canisterP, config(null, null), Policy.Engine(), Escrow.EscrowManager(canisterP), EvmEscrow.EvmEscrowManager(),
    sender, { get = func() : ?Text { ?canisterEvm } },
  );
};

func evmSession(id : Text, recipient : Text, deposited : Nat, consumed : Nat) : Types.StableSession = {
  id; payer = payerP; payerPublicKey = b32; deposited; consumed; remaining = deposited - consumed;
  voucherCount = 0; status = #open; openedAt = 0; lastActivityAt = 0; lastSequence = 0;
  lastCumulativeAmount = consumed; subaccount = Blob.fromArray([]); network = "eip155:84532"; token = tokenA;
  recipient; autoClose = false; maxDuration = null; idleTimeout = null;
  evmDeposit = ?{ txHash = "0x01"; chainId = 84532; payerEvmAddress = signer; tokenAddress = tokenA };
};

// ── A fake EVM-RPC canister: eth_call answers authorizationState; receipts are never mined. ──
let rpc = persistent actor {
  var answer : Text = "";
  var lastTo : ?Text = null;
  var lastInput : ?Text = null;
  public func script(a : Text) : async () { answer := a };
  public func seen() : async (?Text, ?Text) { (lastTo, lastInput) };
  public func eth_call(_s : EvmRpc.RpcServices, _c : ?EvmRpc.RpcConfig, args : EvmRpc.CallArgs) : async EvmRpc.MultiCallResult {
    lastTo := args.transaction.to;
    lastInput := args.transaction.input;
    if (answer == "") { #Consistent(#Err(#ProviderError(#NoPermission))) } else { #Consistent(#Ok(answer)) };
  };
  public func eth_getTransactionReceipt(_s : EvmRpc.RpcServices, _c : ?EvmRpc.RpcConfig, _h : Text) : async EvmRpc.MultiGetTransactionReceiptResult {
    #Consistent(#Ok(null));
  };
};
let rpcText = Principal.toText(Principal.fromActor(rpc));
let WORD_FALSE = "0x0000000000000000000000000000000000000000000000000000000000000000";
let WORD_TRUE = "0x0000000000000000000000000000000000000000000000000000000000000001";

await suite("E5: AuthorizationGuard — one broadcast per authorization", func() : async () {

  await test("a claimed authorization is seen until released; the tx hash is reported once noted", func() : async () {
    // Mutation: claim ignores an existing entry (always #ok), or release does not delete, or
    // noteTx does not store the hash.
    let g = EvmSender.AuthorizationGuard();
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer), Blob.toArray(b32));
    assert g.claim(k, 1_000, 0) == #ok;
    assert g.claim(k, 1_000, 0) == #seen(null);
    g.noteTx(k, "0xabc");
    assert g.claim(k, 1_000, 0) == #seen(?"0xabc");
    g.release(k);
    assert g.claim(k, 1_000, 0) == #ok;
  });

  await test("the key is the decoded authorization: hex case and 0x do not make a second one", func() : async () {
    // Mutation: key the token by its text instead of its decoded bytes.
    let g = EvmSender.AuthorizationGuard();
    let lower = g.key(84532, tokenA, EvmUtils.hexToBytes(Text.toLowercase(signer)), Blob.toArray(b32));
    let upper = g.key(84532, "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", EvmUtils.hexToBytes(signer), Blob.toArray(b32));
    assert lower == upper;
    assert g.key(8453, tokenA, EvmUtils.hexToBytes(signer), Blob.toArray(b32)) != lower; // other chain: other authorization
  });

  await test("an entry lives until validBefore, and at most 24 hours", func() : async () {
    // Mutation: drop the 24-hour cap (expiresAt = validBefore).
    let g = EvmSender.AuthorizationGuard();
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer), Blob.toArray(b32));
    assert g.claim(k, 100, 0) == #ok;
    assert g.claim(k, 100, 99) == #seen(null);
    assert g.claim(k, 100, 100) == #ok; // expired at validBefore — the chain refuses it from then on
    let k2 = g.key(84532, tokenA, EvmUtils.hexToBytes(signer), Blob.toArray(Blob.fromArray(Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 { 2 }))));
    assert g.claim(k2, 9_999_999_999, 0) == #ok;
    assert g.claim(k2, 9_999_999_999, 86_399) == #seen(null);
    assert g.claim(k2, 9_999_999_999, 86_400) == #ok;
  });

  await test("Sessions: a deposit authorization already broadcast is refused as pending, before any send", func() : async () {
    // Mutation: drop the claim in openEvmSession — the open then reaches the send (the
    // interpreter traps on Cycles.balance()).
    let snd = EvmSender.EvmSender("k", null);
    let m = mkSessions(?snd);
    let k = snd.broadcastAuthorizations.key(84532, tokenA, EvmUtils.hexToBytes(signer), Blob.toArray(b32));
    assert snd.broadcastAuthorizations.claim(k, 9_999_999_999, 0) == #ok;
    snd.broadcastAuthorizations.noteTx(k, "0xfeed");
    switch (await m.openSession(payerP, intent, clientCfg, signed)) {
      case (#err(#settlementPending(msg))) { assert Text.contains(msg, #text "0xfeed") };
      case (_) { assert false };
    };
  });
});

await suite("E3: Sessions reads the Gateway's CURRENT sender", func() : async () {

  await test("Gateway: an EVM session closes with the gateway's sender (Sessions is built without one)", func() : async () {
    // Mutation: drop `sessionsMgr.setEvmSenderSource(...)` in the Gateway — Sessions then has no
    // sender and the close answers "EVM sender not configured".
    let gate = Gateway.Gateway(config(?"k", null), canisterP);
    let st = gate.toStable();
    gate.loadStable({ st with sessions = [evmSession("sess-9", canisterEvm, 0, 0)]; evmRecipient = ?canisterEvm });
    switch (await gate.closeSession(payerP, "sess-9")) {
      case (#ok(_)) {};
      case (_) { assert false };
    };
  });
});

await suite("E10a: no settle leg to the canister's own address", func() : async () {

  await test("a fully consumed session settling to the canister itself closes without a send", func() : async () {
    // Mutation: drop `and not settlesToSelf` — the close sends the self-transfer (and the
    // interpreter traps on Cycles.balance()).
    let m = mkSessions(?EvmSender.EvmSender("k", null));
    m.loadStable([evmSession("sess-1", "0x1111111111111111111111111111111111111111", 5000, 5000)]);
    switch (await m.closeSessionInternal("sess-1")) {
      case (#ok(r)) { assert r.txHash == null; assert r.refunded == ?0 };
      case (_) { assert false };
    };
  });
});

await suite("E5: a timer close blocked only by the busy send lock is retried", func() : async () {

  await test("reopenAfterUnsentLeg: the busy lock reopens an expired close; other errors park it", func() : async () {
    // Mutation: reopenAfterUnsentLeg ignores the busy lock (`nothingMoved and not wasExpired`),
    // or EvmSender.isSendBusy matches nothing.
    assert Sessions.reopenAfterUnsentLeg(true, true, EvmSender.SEND_BUSY);
    assert not Sessions.reopenAfterUnsentLeg(true, true, "EVM fee data unavailable — not broadcasting (retry later)");
    assert Sessions.reopenAfterUnsentLeg(false, true, "anything");
    assert not Sessions.reopenAfterUnsentLeg(false, false, EvmSender.SEND_BUSY); // a leg already moved funds
  });
});

await suite("E4: tokens on one chain share decimals", func() : async () {

  await test("setEvmChains refuses mixed decimals and keeps the live set; equal decimals are accepted", func() : async () {
    // Mutation: checkEvmTokenDecimals always #ok, or setEvmChains skips it.
    let gate = Gateway.Gateway(config(null, null), canisterP);
    let six = { address = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; symbol = "BBB"; decimals = 6 : Nat8; name = null; version = null };
    let eighteen = { six with address = "0xcccccccccccccccccccccccccccccccccccccccc"; decimals = 18 : Nat8 };
    let mixed = { chainA with tokens = Array.append(chainA.tokens, [eighteen]) };
    switch (gate.setEvmChains([mixed])) { case (#err(e)) { assert Text.contains(e, #text "decimals") }; case (#ok) { assert false } };
    assert gate.getEvmChains()[0].tokens.size() == 1; // untouched
    assert gate.setEvmChains([{ chainA with tokens = Array.append(chainA.tokens, [six]) }]) == #ok;
  });
});

await suite("E9: one EVM payer, one policy principal", func() : async () {

  await test("every hex-case spelling of an address maps to the lower-case principal, which is unchanged", func() : async () {
    // Mutation: hash the raw `from` text in evmPolicyPrincipal or in settle (the pre-2.22.0
    // derivation) — the checksum spelling then escapes the lower-case blocklist entry.
    let lower = Text.toLowercase(signer);
    let legacy = Principal.fromBlob(Blob.fromArray(Array.subArray(Blob.toArray(SHA256.fromArray(#sha256, Blob.toArray(Text.encodeUtf8("evm:" # lower)))), 0, 29)));
    assert Gateway.evmPolicyPrincipal(lower) == legacy;
    assert Gateway.evmPolicyPrincipal(signer) == legacy;
    let gate = Gateway.Gateway(config(null, null), canisterP);
    gate.setPolicy(null, {
      maxPerTransaction = null; maxPerDay = null; rateLimitPerMinute = null; maxSessionDeposit = null;
      maxConcurrentSessions = null; maxSessionDuration = null; sessionIdleTimeout = null;
      allowedCallers = null; blockedCallers = ?[legacy];
    });
    switch (await gate.settle(signed, ?5000)) { case (#policyDenied(_)) {}; case (_) { assert false } };
  });
});

await suite("E10b: one pool per token, whatever its hex case", func() : async () {

  await test("allocations in two spellings of one token share the pool cap", func() : async () {
    // Mutation: compare allocation tokens as text in totalAllocated.
    let esc = EvmEscrow.EvmEscrowManager();
    esc.setPoolCap(?1000);
    assert esc.allocate("s1", 84532, tokenA, 600) == #ok;
    assert esc.totalAllocated(84532, "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == 600;
    switch (esc.allocate("s2", 84532, "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 500)) { case (#err(_)) {}; case (#ok) { assert false } };
  });
});

await suite("E10c/d/e: gas, nonces, ranges and windows", func() : async () {

  await test("the ERC-20 transfer gas limit covers a transfer to an address holding none", func() : async () {
    // Mutation: back to 65_000 (about 60_000 is needed, see EvmUtils.ERC20_TRANSFER_GAS).
    assert EvmUtils.ERC20_TRANSFER_GAS >= 90_000;
  });

  await test("two EIP-3009 nonces taken in one round differ", func() : async () {
    // Mutation: drop the per-call sequence (Time.now() alone — constant in the interpreter, as in one round).
    let s = EvmSigner.EvmSigner("k");
    let a = s.nextAuthorizationNonce();
    let b = s.nextAuthorizationNonce();
    assert a.size() == 32 and b.size() == 32;
    assert a != b;
  });

  await test("signers refuse an amount past uint256 before signing", func() : async () {
    // Mutation: drop the isUint256 check in EvmSigner.signErc20Transfer or signEip3009Authorization
    // (each then reaches tECDSA, which the interpreter cannot run).
    let s = EvmSigner.EvmSigner("k");
    switch (await s.signErc20Transfer(84532, tokenA, canisterEvm, 2 ** 256, 0, 1, 1)) { case (#err(_)) {}; case (#ok(_)) { assert false } };
    switch (await s.signEip3009Authorization(84532, tokenA, canisterEvm, 2 ** 256 + 1, "Token A", "1")) { case (#err(_)) {}; case (#ok(_)) { assert false } };
  });

  await test("the sender refuses an amount past uint256, and EIP-3009 fields that do not fit, before sending", func() : async () {
    // Mutation: drop the isUint256 check in sendErc20Transfer, or the fields check in
    // executeTransferWithAuthorization (each then reaches the send / the ABI encoder's assert).
    let snd = EvmSender.EvmSender("k", null);
    switch (await snd.sendErc20Transfer(84532, tokenA, canisterEvm, 2 ** 256)) { case (#err(_)) {}; case (_) { assert false } };
    let from = EvmUtils.hexToBytes(signer);
    let to = EvmUtils.hexToBytes(canisterEvm);
    switch (await snd.executeTransferWithAuthorization(84532, tokenA, from, to, 5000, 0, 9_999_999_999, [1, 2, 3], 27, Blob.toArray(realR), Blob.toArray(realS))) {
      case (#err(_)) {};
      case (_) { assert false };
    };
  });

  await test("verifyPayment: validBefore is strict, as on chain", func() : async () {
    // Mutation: `nowSeconds > authz.validBefore` (the pre-2.22.0 check). The interpreter's clock is 0 s.
    let gate = Gateway.Gateway(config(null, null), canisterP);
    let v = gate.verifyPayment(authz(0, b32), 5000, canisterEvm, tokenA);
    assert v.invalidReason == ?"invalid_exact_evm_payload_authorization_valid_before";
  });

  await test("verifyPayment: a validBefore past uint256 is refused, not read as far future", func() : async () {
    // Mutation: drop the eip3009FieldsFit check in verifyPayment.
    let gate = Gateway.Gateway(config(null, null), canisterP);
    let v = gate.verifyPayment(authz(2 ** 256 + 9_999_999_999, b32), 5000, canisterEvm, tokenA);
    assert v.invalidReason == ?"invalid_payload";
  });

  await test("settle: validBefore is strict, as on chain", func() : async () {
    // Mutation: `nowSeconds > authz.validBefore` in settle.
    let gate = Gateway.Gateway(config(null, null), canisterP);
    switch (await gate.settle(authz(0, b32), ?5000)) { case (#expired(_)) {}; case (_) { assert false } };
  });

  await test("settle: a nonce that is not 32 bytes is refused", func() : async () {
    // Mutation: drop the eip3009FieldsFit check in settle (the open-ended chain is then reached:
    // the canister's EVM address is not derived in this fixture → #settlementFailed).
    let gate = Gateway.Gateway(config(null, null), canisterP);
    switch (await gate.settle(authz(9_999_999_999, Blob.fromArray([1, 2, 3])), ?5000)) {
      case (#invalidSignature(m)) { assert Text.contains(m, #text "out of range") };
      case (_) { assert false };
    };
  });

  await test("session open: an expired deposit authorization is refused before any send", func() : async () {
    // Mutation: drop the window check in openEvmSession (it had none before 2.22.0) — the open
    // then reaches the signature check, which this expired authorization fails on.
    let m = mkSessions(?EvmSender.EvmSender("k", null));
    switch (await m.openSession(payerP, intent, clientCfg, authz(0, b32))) {
      case (#err(#expired(_))) {};
      case (_) { assert false };
    };
  });

  await test("session open: authorization fields that do not fit are refused", func() : async () {
    // Mutation: drop the eip3009FieldsFit check in openEvmSession (a validBefore past uint256 then
    // passes the window and fails later, at the signature).
    let m = mkSessions(?EvmSender.EvmSender("k", null));
    switch (await m.openSession(payerP, intent, clientCfg, authz(2 ** 256 + 9_999_999_999, b32))) {
      case (#err(#invalidSignature(msg))) { assert Text.contains(msg, #text "out of range") };
      case (_) { assert false };
    };
  });
});

await suite("E7: authorizationState", func() : async () {

  await test("the calldata is authorizationState(address,bytes32): selector 0xe94a0102", func() : async () {
    // Mutation: a wrong signature string or argument order in buildAuthorizationStateCalldata.
    let cd = EvmSender.buildAuthorizationStateCalldata(EvmUtils.hexToBytes(signer), Blob.toArray(b32));
    assert EvmUtils.bytesToHex(cd) == "0xe94a0102000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb922660101010101010101010101010101010101010101010101010101010101010101";
  });

  await test("the sender reads the token's answer: true is used, false unused, anything else unknown", func() : async () {
    // Mutation: swap #used/#unused in classifyAuthorizationState, read a non-bool word as a
    // bool, or send the call to another contract than the token.
    let snd = EvmSender.EvmSender("k", ?rpcText);
    let from = EvmUtils.hexToBytes(signer);
    await rpc.script(WORD_TRUE);
    assert (await snd.authorizationState(84532, tokenA, from, Blob.toArray(b32))) == #used;
    let (to, _) = await rpc.seen();
    assert to == ?tokenA;
    await rpc.script(WORD_FALSE);
    assert (await snd.authorizationState(84532, tokenA, from, Blob.toArray(b32))) == #unused;
    await rpc.script("0x0000000000000000000000000000000000000000000000000000000000000002");
    switch (await snd.authorizationState(84532, tokenA, from, Blob.toArray(b32))) { case (#unknown(_)) {}; case (_) { assert false } };
    await rpc.script(""); // provider error
    switch (await snd.authorizationState(84532, tokenA, from, Blob.toArray(b32))) { case (#unknown(_)) {}; case (_) { assert false } };
  });
});

await suite("F1: a parked tx that can never land", func() : async () {

  await test("txNonceConsumed: only a mined count past the tx's nonce", func() : async () {
    // Mutation: `latestNonce >= txNonce` (a count equal to the nonce means it is still unused).
    assert EvmSender.txNonceConsumed(5, 6);
    assert not EvmSender.txNonceConsumed(5, 5);
  });

  await test("reconcile decision: a dropped leg is reported and stays parked, naming what is owed", func() : async () {
    // Mutation: finalize (or settleDoneRefundOwed) on #dropped.
    switch (Sessions.sessionReconcileDecision(#dropped("nonce 3 was used"), #Refund, 10)) {
      case (#stay(m)) { assert Text.contains(m, #text "can never land") and Text.contains(m, #text "remainder to the payer") };
      case (_) { assert false };
    };
  });

  await test("reconcileTransaction without a remembered nonce stays pending (no receipt)", func() : async () {
    // Mutation: report #dropped without a remembered nonce.
    let snd = EvmSender.EvmSender("k", ?rpcText);
    assert (await snd.reconcileTransaction(84532, "0x01", 1)) == #pending;
  });
});
