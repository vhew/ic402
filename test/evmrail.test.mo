/// 2.22.0 — EVM rail fixes (findings E3, E4, E5, E7, E9, E10, F1).
/// 2.23.1 — simulate an inbound transfer before signing it; one inbound transfer in flight per payer.
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
import EvmSplits "../src/ic402/EvmSplits";
import EvmSigner "../src/ic402/EvmSigner";
import EvmRpc "../src/ic402/EvmRpc";
import EvmUtils "../src/ic402/EvmUtils";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
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
    // 2.23.2: a gas stop's refusal (nothing signed) waits too, so an expired session is retried
    // instead of parked with no tx. The failure that SET the stop was signed and may have been
    // accepted by a provider, so it parks, as before, for the operator to check.
    // Mutation: reopenAfterUnsentLeg or sendCanWait drops the stop, or adds the signed failure; a
    // moved leg still parks; sendCanWait matches a marker inside caller-controlled text.
    assert Sessions.reopenAfterUnsentLeg(true, true, EvmSender.gasStopText(8453, 600));
    assert not Sessions.reopenAfterUnsentLeg(true, true, EvmSender.INSUFFICIENT_GAS # " — the canister's derived EVM address pays gas");
    assert not Sessions.reopenAfterUnsentLeg(true, false, EvmSender.gasStopText(8453, 600));
    assert EvmSender.sendCanWait(EvmSender.SEND_BUSY) and EvmSender.sendCanWait(EvmSender.gasStopText(1, 2));
    assert not EvmSender.sendCanWait(EvmSender.FEE_DATA_UNAVAILABLE # " — not broadcasting (retry later)");
    assert not EvmSender.sendCanWait("Invalid recipient address (expected a 20-byte / 40-hex-char address): 0x" # EvmSender.GAS_STOP_PREFIX);
    assert not EvmSender.sendCanWait("Invalid recipient address: 0x" # EvmSender.INSUFFICIENT_GAS);
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

await suite("F1: a parked tx that appears not to have landed", func() : async () {

  await test("txNonceConsumed: only a mined count past the tx's nonce", func() : async () {
    // Mutation: `latestNonce >= txNonce` (a count equal to the nonce means it is still unused).
    assert EvmSender.txNonceConsumed(5, 6);
    assert not EvmSender.txNonceConsumed(5, 5);
  });

  await test("reconcile decision: a dropped leg is reported and stays parked, naming what is owed", func() : async () {
    // Mutation: finalize (or settleDoneRefundOwed) on #dropped.
    switch (Sessions.sessionReconcileDecision(#dropped("nonce 3 was used"), #Refund, 10)) {
      case (#stay(m)) {
        assert Text.contains(m, #text "appears not to have landed") and Text.contains(m, #text "verify on chain before forcing");
        assert Text.contains(m, #text "remainder to the payer");
      };
      case (_) { assert false };
    };
  });

  await test("round 2: only an agreed 'no receipt' is dropped — disagreement, an RPC error or a status-less receipt is no answer", func() : async () {
    // Mutation: finalReceiptVerdict maps anything but a mined receipt to #dropped (what
    // confirmTransaction's #pending fold did before round 2).
    let mined : EvmRpc.TransactionReceipt = {
      to = null; status = ?1; root = null; transactionHash = "0x01"; blockNumber = 1; from = signer; logs = [];
      blockHash = "0x02"; transactionIndex = 0; effectiveGasPrice = 1; logsBloom = "0x"; contractAddress = null;
      gasUsed = 1; cumulativeGasUsed = 1;
    };
    assert EvmSender.finalReceiptVerdict(#Consistent(#Ok(null))) == #dropped;
    assert EvmSender.finalReceiptVerdict(#Consistent(#Ok(?mined))) == #confirmed;
    assert EvmSender.finalReceiptVerdict(#Consistent(#Ok(?{ mined with status = ?0 }))) == #reverted;
    assert EvmSender.finalReceiptVerdict(#Consistent(#Ok(?{ mined with status = null }))) == #pending;
    assert EvmSender.finalReceiptVerdict(#Consistent(#Err(#ProviderError(#NoPermission)))) == #pending;
    assert EvmSender.finalReceiptVerdict(#Inconsistent([(#EthSepolia(#Ankr), #Ok(null)), (#EthSepolia(#Sepolia), #Ok(?mined))])) == #pending;
  });

  await test("reconcileTransaction without a remembered nonce stays pending (no receipt)", func() : async () {
    // Mutation: report #dropped without a remembered nonce.
    let snd = EvmSender.EvmSender("k", ?rpcText);
    assert (await snd.reconcileTransaction(84532, "0x01", 1)) == #pending;
  });
});

// ── 2.23.1: simulate before signing; one inbound transfer in flight per payer ──
//
// The simulation runs inside executeTransferWithAuthorization after the cycle floor, which the
// interpreter cannot read, so its wiring (refused → nothing signed, the claims freed) is pinned in
// test/evm-outbound.test.ts against the mock. Here: the verdict, the texts, the guard, and the
// session-open busy refusal, which comes before the send.

await suite("2.23.1: simulate before signing", func() : async () {
  // Code 3 is geth's revert code; this message does not say "revert", so only the code marks it.
  let revertByCode : EvmRpc.RpcError = #JsonRpcError({ code = 3; message = "FiatTokenV2: transfer amount exceeds balance" });
  let revertByText : EvmRpc.RpcError = #JsonRpcError({ code = -32000; message = "Execution Reverted" });
  let rateLimited : EvmRpc.RpcError = #JsonRpcError({ code = -32005; message = "rate limit exceeded" });
  let down : EvmRpc.RpcError = #ProviderError(#NoPermission);

  await test("only an agreed success lets the send go ahead", func() : async () {
    // Mutation: classifySimulation fails open — #ok for a provider error, for disagreement, or for
    // an #Inconsistent of successes or of nothing.
    assert EvmSender.classifySimulation(#Consistent(#Ok("0x"))) == #ok;
    switch (EvmSender.classifySimulation(#Consistent(#Err(down)))) { case (#unknown(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Consistent(#Err(rateLimited)))) { case (#unknown(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Inconsistent([(#EthSepolia(#Ankr), #Ok("0x")), (#EthSepolia(#Sepolia), #Ok("0x01"))]))) { case (#unknown(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Inconsistent([(#EthSepolia(#Ankr), #Ok("0x")), (#EthSepolia(#Sepolia), #Err(revertByCode))]))) { case (#unknown(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Inconsistent([]))) { case (#unknown(_)) {}; case (_) { assert false } };
  });

  await test("a revert is a revert in any provider's words; a provider failure is not one", func() : async () {
    // Mutation: isRevertError drops the code-3 test, the message test, or the lower-casing; or an
    // #Inconsistent holding one non-revert error is read as reverted.
    switch (EvmSender.classifySimulation(#Consistent(#Err(revertByCode)))) { case (#reverted(m)) { assert Text.contains(m, #text "exceeds balance") }; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Consistent(#Err(revertByText)))) { case (#reverted(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Inconsistent([(#EthSepolia(#Ankr), #Err(revertByCode)), (#EthSepolia(#Sepolia), #Err(revertByText))]))) { case (#reverted(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Inconsistent([(#EthSepolia(#Ankr), #Err(revertByCode)), (#EthSepolia(#Sepolia), #Err(down))]))) { case (#unknown(_)) {}; case (_) { assert false } };
    // Two reverts and no success is the 2-of-N agreement on a revert, whatever the third said.
    switch (EvmSender.classifySimulation(#Inconsistent([(#EthSepolia(#Ankr), #Err(revertByCode)), (#EthSepolia(#Sepolia), #Err(revertByText)), (#EthSepolia(#PublicNode), #Err(rateLimited))]))) { case (#reverted(_)) {}; case (_) { assert false } };
    switch (EvmSender.classifySimulation(#Inconsistent([(#EthSepolia(#Ankr), #Err(revertByCode)), (#EthSepolia(#Sepolia), #Err(revertByText)), (#EthSepolia(#PublicNode), #Ok("0x"))]))) { case (#unknown(_)) {}; case (_) { assert false } };
    assert not EvmSender.isRevertError(rateLimited);
    assert not EvmSender.isRevertError(down);
  });

  await test("the refusals say nothing was signed or sent; only 'could not check' and 'busy' invite the same payment again", func() : async () {
    // Mutation: a text change that makes @ic402/client (marker "retry this same payment") read a
    // revert as transient, or "could not check" / busy as final.
    let rev = EvmSender.simulationRevertedText("x");
    let unk = EvmSender.simulationUnknownText("x");
    assert Text.contains(rev, #text "Nothing was signed or sent") and not Text.contains(rev, #text "retry this same payment");
    assert Text.contains(unk, #text "Nothing was signed or sent") and Text.contains(unk, #text "retry this same payment");
    assert Text.contains(EvmSender.PAYER_BUSY, #text "retry this same payment");
  });
});

await suite("2.23.1: one inbound transfer in flight per payer; cooldown after a revert", func() : async () {

  await test("a payer holds one slot until it is released", func() : async () {
    // Mutation: claim ignores an existing entry, or release does not delete.
    let g = EvmSender.PayerGuard(10_000);
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    assert g.claim(k, 0) == #ok;
    assert g.claim(k, 0) == #busy;
    assert g.size() == 1;
    g.release(k);
    assert g.claim(k, 0) == #ok;
  });

  await test("the key is (chain, token, payer) on decoded bytes", func() : async () {
    // Mutation: key the token or payer by its text, or leave the chain or the token out.
    let g = EvmSender.PayerGuard(10_000);
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    assert g.key(84532, "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", EvmUtils.hexToBytes(Text.toLowercase(signer))) == k;
    assert g.key(8453, tokenA, EvmUtils.hexToBytes(signer)) != k;
    assert g.key(84532, "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", EvmUtils.hexToBytes(signer)) != k;
    assert g.key(84532, tokenA, EvmUtils.hexToBytes(canisterEvm)) != k;
  });

  await test("a payer cooled down is refused for an hour, then claims again; others are not", func() : async () {
    // Mutation: claim ignores the cooldown, the cooldown never ends (or lasts another time), or it
    // cools every payer.
    let g = EvmSender.PayerGuard(10_000);
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    let other = g.key(84532, tokenA, EvmUtils.hexToBytes(canisterEvm));
    g.coolDown(k, 1_000, EvmSender.REVERT_COOLDOWN_SECONDS);
    assert g.claim(k, 1_000) == #coolingDown(4_600);
    assert g.claim(k, 4_599) == #coolingDown(4_600);
    assert g.claim(other, 1_000) == #ok;
    assert g.claim(k, 4_600) == #ok;
  });

  await test("a full cooldown list drops the expired entries first, then the one ending soonest", func() : async () {
    // Mutation: coolDown grows without bound, or evicts a live entry while expired ones remain.
    let g = EvmSender.PayerGuard(3);
    let key = func(i : Nat) : Text { g.key(i, tokenA, EvmUtils.hexToBytes(signer)) };
    g.coolDown(key(1), 10_000, EvmSender.REVERT_COOLDOWN_SECONDS); // live until 13_600
    g.coolDown(key(2), 0, EvmSender.REVERT_COOLDOWN_SECONDS); // expired at 3_600
    g.coolDown(key(3), 400, EvmSender.REVERT_COOLDOWN_SECONDS); // expired at 4_000
    g.coolDown(key(4), 10_000, EvmSender.REVERT_COOLDOWN_SECONDS); // full: BOTH expired ones go, not just the soonest
    assert g.coolingSize() == 2;
    g.coolDown(key(5), 9_000, EvmSender.REVERT_COOLDOWN_SECONDS); // live until 12_600, ends soonest of the live ones
    g.coolDown(key(6), 10_000, EvmSender.REVERT_COOLDOWN_SECONDS); // full, none expired: the one ending soonest goes
    assert g.coolingSize() == 3;
    assert g.claim(key(5), 10_000) == #ok;
    assert g.claim(key(1), 10_000) == #coolingDown(13_600);
    assert g.claim(key(4), 10_000) == #coolingDown(13_600);
    assert g.claim(key(6), 10_000) == #coolingDown(13_600);
  });

  await test("Sessions: a deposit from a payer with a transfer in flight is refused as busy, before any send, freeing what it took", func() : async () {
    // Mutation: drop the payer claim in openEvmSession (the open then reaches the send — the
    // interpreter traps on Cycles.balance()); skip freeing the authorization claim, the open lock
    // or the pool allocation on the busy refusal; or release a slot the refused open never held.
    let snd = EvmSender.EvmSender("k", null);
    let pool = EvmEscrow.EvmEscrowManager();
    let m = Sessions.Sessions(
      canisterP, config(null, null), Policy.Engine(), Escrow.EscrowManager(canisterP), pool,
      ?snd, { get = func() : ?Text { ?canisterEvm } },
    );
    let pk = snd.inFlightPayers.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    assert snd.inFlightPayers.claim(pk, 0) == #ok; // another transfer from this payer is in flight
    switch (await m.openSession(payerP, intent, clientCfg, signed)) {
      case (#err(#policyDenied(msg))) { assert msg == EvmSender.PAYER_BUSY };
      case (_) { assert false };
    };
    // Busy again, not "already broadcast" (the authorization claim was freed) and not "an open is
    // in progress" (the open lock was freed).
    switch (await m.openSession(payerP, intent, clientCfg, signed)) {
      case (#err(#policyDenied(msg))) { assert msg == EvmSender.PAYER_BUSY };
      case (_) { assert false };
    };
    let ak = snd.broadcastAuthorizations.key(84532, tokenA, EvmUtils.hexToBytes(signer), Blob.toArray(b32));
    assert snd.broadcastAuthorizations.claim(ak, 9_999_999_999, 0) == #ok;
    assert pool.totalAllocated(84532, tokenA) == 0; // the reservation was returned
    assert snd.inFlightPayers.claim(pk, 0) == #busy; // still the other transfer's
  });

  await test("Sessions: a deposit from a payer cooling down is refused, before any send", func() : async () {
    // Mutation: Sessions ignores #coolingDown (treats it as #ok, reaching the send), or answers it
    // with the busy text, which invites a retry.
    let snd = EvmSender.EvmSender("k", null);
    let m = mkSessions(?snd);
    snd.inFlightPayers.coolDown(snd.inFlightPayers.key(84532, tokenA, EvmUtils.hexToBytes(signer)), 0, EvmSender.REVERT_COOLDOWN_SECONDS);
    switch (await m.openSession(payerP, intent, clientCfg, signed)) {
      case (#err(#policyDenied(msg))) {
        assert msg == EvmSender.payerCoolingText(3_600);
        assert not Text.contains(msg, #text "retry this same payment");
      };
      case (_) { assert false };
    };
  });
});

await suite("2.23.1: what the simulation does not see", func() : async () {

  await test("an authorization must stay valid 120 more seconds", func() : async () {
    // Mutation: expiresTooSoon drops the margin (back to `validBefore <= now`) or uses another one.
    assert EvmSender.expiresTooSoon(100, 0);
    assert EvmSender.expiresTooSoon(119, 0);
    assert not EvmSender.expiresTooSoon(120, 0);
    assert EvmSender.expiresTooSoon(1_119, 1_000);
  });

  await test("settle, verifyPayment and session open refuse one that expires too soon (the interpreter's clock is 0)", func() : async () {
    // Mutation: drop the margin at any of the three (validBefore 100 then passes the window check
    // and fails on its signature, which is over another validBefore).
    let gate = Gateway.Gateway(config(null, null), canisterP);
    switch (await gate.settle(authz(100, b32), ?5000)) { case (#expired(m)) { assert m == EvmSender.EXPIRES_TOO_SOON }; case (_) { assert false } };
    assert gate.verifyPayment(authz(100, b32), 5000, canisterEvm, tokenA).invalidReason == ?"invalid_exact_evm_payload_authorization_valid_before";
    let m = mkSessions(?EvmSender.EvmSender("k", null));
    switch (await m.openSession(payerP, intent, clientCfg, authz(100, b32))) { case (#err(#expired(_))) {}; case (_) { assert false } };
    // 120 s left passes the window check (and then fails on the signature).
    assert gate.verifyPayment(authz(120, b32), 5000, canisterEvm, tokenA).invalidReason == ?"invalid_exact_evm_payload_authorization_signature";
  });

  await test("a revert just after validAfter is 'could not check', not a final refusal", func() : async () {
    // Mutation: simulationRefusal ignores validAfter (a revert is always final), or reads a recent
    // validAfter as a pass.
    assert EvmSender.simulationRefusal(#ok, 0, 1_000) == null;
    switch (EvmSender.simulationRefusal(#reverted("x"), 0, 1_000)) { case (?t) { assert t == EvmSender.simulationRevertedText("x") }; case (null) { assert false } };
    switch (EvmSender.simulationRefusal(#reverted("x"), 941, 1_000)) {
      case (?t) { assert Text.contains(t, #text "retry this same payment") and Text.contains(t, #text "only moments ago") };
      case (null) { assert false };
    };
    switch (EvmSender.simulationRefusal(#reverted("x"), 940, 1_000)) { case (?t) { assert t == EvmSender.simulationRevertedText("x") }; case (null) { assert false } };
    switch (EvmSender.simulationRefusal(#unknown("y"), 0, 1_000)) { case (?t) { assert t == EvmSender.simulationUnknownText("y") }; case (null) { assert false } };
  });

  await test("the simulation budget: 10 at once, one more every 6 seconds; a sent transfer gives its token back", func() : async () {
    // Mutation: take never refuses, never refills or refills faster; giveBack does nothing or
    // overfills past the capacity.
    let b = EvmSender.SimulationBudget(10, 6);
    for (_ in Iter.range(1, 10)) { assert b.take(1_000_000) };
    assert not b.take(1_000_000); // 10 in flight or refused: no more
    b.giveBack(); // one of them was sent
    assert b.take(1_000_000);
    assert not b.take(1_000_005);
    assert b.take(1_000_006); // refilled one
    assert not b.take(1_000_006);
    for (_ in Iter.range(1, 20)) { b.giveBack() };
    for (_ in Iter.range(1, 10)) { assert b.take(1_000_006) };
    assert not b.take(1_000_006); // capped at 10
  });

  await test("an operator can lift every cooldown", func() : async () {
    // Mutation: clearCooldowns clears nothing, or the Gateway's wrapper does not reach the guard.
    let g = EvmSender.PayerGuard(10_000);
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    g.coolDown(k, 0, EvmSender.REVERT_COOLDOWN_SECONDS);
    assert g.clearCooldowns() == 1;
    assert g.claim(k, 0) == #ok;
    assert g.clearCooldowns() == 0;
    assert Gateway.Gateway(config(null, null), canisterP).clearEvmPayerCooldowns() == 0; // no sender
    assert not Gateway.Gateway(config(null, null), canisterP).liftEvmPayerCooldown(84532, tokenA, signer);
  });

  await test("an operator can lift one payer's cooldown; the others stay", func() : async () {
    // Mutation: liftCooldown lifts nothing, lifts every payer, or reports an expired one as lifted.
    let g = EvmSender.PayerGuard(10_000);
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    let other = g.key(84532, tokenA, EvmUtils.hexToBytes(canisterEvm));
    g.coolDown(k, 0, EvmSender.REVERT_COOLDOWN_SECONDS);
    g.coolDown(other, 0, EvmSender.REVERT_COOLDOWN_SECONDS);
    assert g.liftCooldown(k, 10);
    assert g.claim(k, 10) == #ok;
    assert g.claim(other, 10) == #coolingDown(3_600);
    assert not g.liftCooldown(k, 10); // not cooling any more
    g.coolDown(k, 0, 5);
    assert not g.liftCooldown(k, 10); // expired at 5
  });

  await test("a cooldown is never shortened; a short hold then a revert extends it", func() : async () {
    // Mutation: coolDown always overwrites (a 5-minute hold after an hour's cooldown would cut it).
    let g = EvmSender.PayerGuard(10_000);
    let k = g.key(84532, tokenA, EvmUtils.hexToBytes(signer));
    g.coolDown(k, 0, EvmSender.REVERT_COOLDOWN_SECONDS);
    g.coolDown(k, 10, EvmSender.UNCONFIRMED_HOLD_SECONDS);
    assert g.claim(k, 400) == #coolingDown(3_600);
    let k2 = g.key(84532, tokenA, EvmUtils.hexToBytes(canisterEvm));
    g.coolDown(k2, 0, EvmSender.UNCONFIRMED_HOLD_SECONDS);
    g.coolDown(k2, 100, EvmSender.REVERT_COOLDOWN_SECONDS);
    assert g.claim(k2, 400) == #coolingDown(3_700);
  });

  await test("transient send failures invite the same payment again; others do not", func() : async () {
    // Mutation: transientSendError misses the send lock, the nonce read or the fee read, or
    // matches any error (an unfunded gas account is the operator's to fix, not the payer's).
    assert EvmSender.transientSendError(EvmSender.SEND_BUSY);
    assert EvmSender.transientSendError(EvmSender.INBOUND_SEND_BUSY);
    assert EvmSender.transientSendError(EvmSender.NONCE_READ_FAILED # ": eth_getTransactionCount did not reach multi-provider consensus.");
    assert EvmSender.transientSendError(EvmSender.FEE_DATA_UNAVAILABLE # " — not broadcasting (retry later)");
    assert EvmSender.transientSendError(EvmSender.FAILED_BEFORE_BROADCAST # ": the EVM-RPC canister is stopped");
    assert EvmSender.isSendBusy(EvmSender.INBOUND_SEND_BUSY); // a direct caller's 2.22.0 helper still sees busy
    assert not EvmSender.transientSendError("Insufficient ETH for gas — the canister's derived EVM address pays gas for broadcasts.");
    assert Text.contains(EvmSender.INBOUND_SEND_BUSY, #text "retry this same payment");
  });

  await test("the cooling and budget texts: cooling is final, the budget invites the same payment again", func() : async () {
    // Mutation: a text change that makes @ic402/client read cooling as transient, or the budget as final.
    assert not Text.contains(EvmSender.payerCoolingText(1), #text "retry this same payment");
    assert Text.contains(EvmSender.SIMULATION_BUSY, #text "retry this same payment");
  });
});

await suite("2.23.1: the EVM-RPC consensus config names a total for default providers", func() : async () {

  await test("default providers: 3 queried, 2 agree; custom services or an explicit list: all queried", func() : async () {
    // Mutation: back to `total = null` everywhere (refused by the EVM-RPC canister for default
    // providers), or a total on Custom services.
    let threshold = func(c : ?EvmRpc.RpcConfig) : ?{ total : ?Nat8; min : Nat8 } {
      switch (c) { case (?{ responseConsensus = ?#Threshold(t) }) { ?t }; case (_) { null } };
    };
    for (svc in [#EthMainnet(null), #EthSepolia(null), #ArbitrumOne(null), #BaseMainnet(null), #OptimismMainnet(null)].values()) {
      assert threshold(EvmRpc.consensusConfig(svc)) == ?{ total = ?3; min = 2 };
    };
    assert threshold(EvmRpc.consensusConfig(#Custom({ chainId = 43114; services = [] }))) == ?{ total = null; min = 2 };
    assert threshold(EvmRpc.consensusConfig(#BaseMainnet(?[#Ankr]))) == ?{ total = null; min = 2 };
    assert EvmRpc.rpcServices(8453) == ?#BaseMainnet(null); // what the sender passes for Base
  });
});

await suite("2.23.2: a chain the canister cannot pay gas on", func() : async () {

  await test("a stop refuses that chain for 10 minutes, then ends by itself; other chains are not stopped", func() : async () {
    // Mutation: stop does nothing, stops every chain, or never ends; the window is not 10 minutes.
    assert EvmSender.GAS_STOP_SECONDS == 600;
    let g = EvmSender.GasStops(EvmSender.GAS_STOP_SECONDS);
    assert g.stoppedUntil(8453, 1_000) == null;
    g.stop(8453, 1_000);
    assert g.stoppedUntil(8453, 1_000) == ?1_600;
    assert g.stoppedUntil(8453, 1_599) == ?1_600;
    assert g.stoppedUntil(8453, 1_600) == null;
    assert g.stoppedUntil(1, 1_000) == null;
  });

  await test("an operator lifts one chain's stop; the others stay; a stop is never shortened", func() : async () {
    // Mutation: lift lifts nothing, lifts every chain, or reports an ended stop as lifted; a later
    // stop overwrites a later end with an earlier one.
    let g = EvmSender.GasStops(600);
    g.stop(8453, 1_000);
    g.stop(1, 1_000);
    assert g.lift(8453, 1_100);
    assert g.stoppedUntil(8453, 1_100) == null;
    assert g.stoppedUntil(1, 1_100) == ?1_600;
    assert not g.lift(8453, 1_100); // not stopped any more
    assert not g.lift(1, 1_600); // ended at 1_600
    g.stop(10, 2_000);
    g.stop(10, 1_500); // an earlier end does not replace the later one
    assert g.stoppedUntil(10, 2_500) == ?2_600;
    g.stop(10, 2_100); // a later one extends it
    assert g.stoppedUntil(10, 2_650) == ?2_700;
    assert not Gateway.Gateway(config(null, null), canisterP).liftEvmGasStop(8453); // no sender
  });

  await test("a broadcast the canister cannot pay gas for is told apart; the stop's refusal is final", func() : async () {
    // Mutation: isInsufficientGas misses classifySend's text or matches other errors; the stop text
    // invites a retry (@ic402/client would read it as transient) or drops the chain or the end.
    switch (EvmSender.classifySend(#Consistent(#Ok(#InsufficientFunds)), "0xab")) {
      case (#err(e)) {
        assert EvmSender.isInsufficientGas(e);
        assert not EvmSender.transientSendError(e);
        assert Text.contains(e, #text "signed tx 0xab"); // named, to check before any hand re-send
      };
      case (_) { assert false };
    };
    // A refusal whose nonce then moved may have been accepted: never read as "failed before broadcast".
    assert not EvmSender.isInsufficientGas(EvmSender.GAS_REFUSAL_NONCE_MOVED);
    assert not EvmSender.isInsufficientGas(EvmSender.FEE_DATA_UNAVAILABLE # " — not broadcasting (retry later)");
    assert not EvmSender.isInsufficientGas(EvmSender.LOW_INBOUND_CYCLES);
    assert not EvmSender.isInsufficientGas("Insufficient cycles to safely broadcast and confirm; top up the canister");
    assert EvmSender.isInsufficientGas("EIP-3009 execution failed: " # EvmSender.INSUFFICIENT_GAS # " — x"); // a prefixed one too
    let t = EvmSender.gasStopText(8453, 1_600);
    assert Text.contains(t, #text "chain 8453") and Text.contains(t, #text "until 1600");
    assert Text.contains(t, #text "Nothing of this was signed or sent");
    assert not Text.contains(t, #text "retry this same payment");
    assert not EvmSender.isInsufficientGas(t);
    // The stable prefix, for integrators: the text starts with it, and a wrapped one still matches.
    assert Text.startsWith(t, #text(EvmSender.GAS_STOP_PREFIX));
    assert EvmSender.isGasStopped("EIP-3009 execution failed: " # t);
    assert not EvmSender.isGasStopped(EvmSender.SIMULATION_BUSY);
    assert not EvmSender.isGasStopped(EvmSender.INSUFFICIENT_GAS # " — the canister's derived EVM address pays gas");
  });

  await test("weaker evidence of a gas shortage stops the chain too: a provider error, or a disagreement where none accepted", func() : async () {
    // Mutation: gasShortageReported reads only the agreed status, ignores error text, or stops when
    // a provider accepted the tx (or answered a nonce too low or high, which may mean it is in).
    let funds = func(m : Text) : EvmRpc.SendRawTransactionResult { #Err(#JsonRpcError({ code = -32000; message = m })) };
    let other = funds("upstream request timed out");
    assert EvmSender.gasShortageReported(#Consistent(#Ok(#InsufficientFunds)));
    assert EvmSender.gasShortageReported(#Consistent(funds("Insufficient funds for gas * price + value")));
    assert not EvmSender.gasShortageReported(#Consistent(other));
    assert not EvmSender.gasShortageReported(#Consistent(#Ok(#NonceTooHigh)));
    assert EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), #Ok(#InsufficientFunds)), (#Provider(2), other)]));
    assert EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), other), (#Provider(2), funds("insufficient funds for transfer"))]));
    assert not EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), #Ok(#InsufficientFunds)), (#Provider(2), #Ok(#Ok(?"0xab")))]));
    assert not EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), #Ok(#InsufficientFunds)), (#Provider(2), #Ok(#NonceTooLow))]));
    assert not EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), #Ok(#NonceTooHigh)), (#Provider(2), #Ok(#InsufficientFunds))]));
    assert not EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), other), (#Provider(2), other)]));
    // Other clients' wording; an HTTP error body is not read.
    // Mutation: the Nethermind or Besu wording dropped, or every error's text read.
    assert EvmSender.gasShortageReported(#Consistent(funds("InsufficientFunds, Balance is zero, cannot pay gas")));
    assert EvmSender.gasShortageReported(#Consistent(funds("Upfront cost exceeds account balance")));
    assert not EvmSender.gasShortageReported(#Consistent(#Err(#HttpOutcallError(#InvalidHttpJsonRpcResponse({ status = 502; body = "insufficient funds"; parsingError = null })))));
    assert not EvmSender.gasShortageReported(#Consistent(funds("insufficient fee to replace the transaction")));
    assert not EvmSender.gasShortageReported(#Consistent(funds("exceeds block gas limit")));
    assert not EvmSender.gasShortageReported(#Inconsistent([(#Provider(1), #Ok(#InsufficientFunds)), (#Provider(2), #Ok(#Ok(null)))])); // accepted, no hash echoed
  });

  await test("the sender refuses every send on a stopped chain before signing, and an inbound transfer before its checks' outcalls", func() : async () {
    // Mutation: sendTransaction or executeTransferWithAuthorization skips the stop or checks it
    // after the cycle floor (the interpreter traps reading cycles), the sender's window is not 10
    // minutes, or a second stop adds an entry instead of replacing the chain's.
    let snd = EvmSender.EvmSender("k", null);
    snd.gasStops.stop(84532, 0); // the interpreter's clock is 0
    assert snd.gasStops.stoppedUntil(84532, 0) == ?600;
    switch (await snd.sendErc20Transfer(84532, tokenA, canisterEvm, 5)) {
      case (#err(e)) { assert e == EvmSender.gasStopText(84532, 600) };
      case (_) { assert false };
    };
    let nonce = Array.tabulate<Nat8>(32, func(_) = 1);
    switch (await snd.executeTransferWithAuthorization(84532, tokenA, EvmUtils.hexToBytes(signer), EvmUtils.hexToBytes(canisterEvm), 5000, 0, 9_999_999_999, nonce, 27, Blob.toArray(realR), Blob.toArray(realS))) {
      case (#err(e)) { assert e == EvmSender.gasStopText(84532, 600) };
      case (_) { assert false };
    };
    snd.gasStops.stop(84532, 0);
    assert snd.gasStops.size() == 1;
  });

  await test("an expired EVM session whose close a gas stop refuses reopens for the sweep, at either leg; nothing is signed", func() : async () {
    // Mutation: either close site (settle leg, refund leg) keeps the busy-lock-only rule inline, or
    // the stop is not checked first (the interpreter traps reading cycles).
    for ((consumed, leg) in [(1_000, "settle"), (0, "refund")].vals()) {
      let snd = EvmSender.EvmSender("k", null);
      snd.gasStops.stop(84532, 0);
      let m = mkSessions(?snd);
      // A recipient other than the canister's own address, so the settle leg is not skipped (E10a).
      m.loadStable([{ evmSession("sess-1", "0x4444444444444444444444444444444444444444", 5000, consumed) with status = #expired }]);
      switch (await m.closeSessionInternal("sess-1")) {
        case (#settlementFailed(t)) {
          assert Text.contains(t, #text ("EVM " # leg # " failed — nothing broadcast, session reopened"));
          assert EvmSender.isGasStopped(t);
        };
        case (_) { assert false };
      };
      switch (m.getSession("sess-1")) { case (?s) { assert s.status == #open }; case (null) { assert false } };
    };
  });
});

await suite("2.24.0: settleToSplit", func() : async () {

  let finder = "0x9f8e7d6c5b4a39281706fedcba9876543210fedc";
  func toAddr(to : Text) : Types.PaymentSignature {
    let a = authz(9_999_999_999, b32);
    switch (a.authorization) {
      case (?au) { { a with authorization = ?{ au with to } } };
      case (null) { a };
    };
  };
  func mkGate() : Gateway.Gateway {
    let gate = Gateway.Gateway(config(null, null), canisterP);
    gate.loadStable({ gate.toStable() with evmRecipient = ?canisterEvm });
    gate;
  };
  let split = switch (EvmSplits.splitPayTo(84532, finder, canisterEvm, 500, tokenA, ?1000)) { case (#ok(a)) { a }; case (#err(_)) { "" } };

  await test("the operator's ceiling: off by default, 1 to 9999 basis points", func() : async () {
    // Mutation: setEvmSplitCeiling accepts 0 or 10000+ (a split leaving the seller nothing), or does
    // not store the value; settleToSplit runs with split payees off.
    let gate = mkGate();
    assert gate.evmSplitCeiling() == null;
    switch (await gate.settleToSplit(toAddr(split), ?5000, { finder; finderShareBps = 500 })) {
      case (#policyDenied(e)) { assert e == EvmSplits.SPLITS_OFF };
      case (_) { assert false };
    };
    assert gate.setEvmSplitCeiling(?0) != #ok;
    assert gate.setEvmSplitCeiling(?10_000) != #ok;
    assert gate.setEvmSplitCeiling(?20_000) != #ok;
    assert gate.setEvmSplitCeiling(?9_999) == #ok;
    assert gate.setEvmSplitCeiling(?1000) == #ok;
    assert gate.evmSplitCeiling() == ?1000;
    assert gate.setEvmSplitCeiling(null) == #ok;
    assert gate.evmSplitCeiling() == null;
  });

  await test("the payment must be to the exact split allowed, recomputed; settle still requires this canister", func() : async () {
    // Mutation: settleToSplit skips the split check or compares against another split; a share
    // above the ceiling passes; settle's own recipient check is relaxed for every caller; ICP is let
    // through. The fixture's signature is for another `to`, so a payment that passes the split check
    // stops at the signature check — that is how the test tells "split accepted" apart.
    let gate = mkGate();
    assert gate.setEvmSplitCeiling(?1000) == #ok;
    switch (await gate.settleToSplit(toAddr(split), ?5000, { finder; finderShareBps = 500 })) {
      case (#invalidSignature(e)) { assert Text.contains(e, #text "signature verification failed") };
      case (_) { assert false };
    };
    switch (await gate.settleToSplit(toAddr(split), ?5000, { finder; finderShareBps = 600 })) {
      case (#invalidSignature(e)) { assert Text.contains(e, #text "must be the split") };
      case (_) { assert false };
    };
    switch (await gate.settleToSplit(toAddr(canisterEvm), ?5000, { finder; finderShareBps = 500 })) {
      case (#invalidSignature(e)) { assert Text.contains(e, #text "must be the split") }; // paid to the canister: not this call
      case (_) { assert false };
    };
    switch (await gate.settleToSplit(toAddr(split), ?5000, { finder; finderShareBps = 1001 })) {
      case (#policyDenied(e)) { assert Text.contains(e, #text "ceiling of 1000") };
      case (_) { assert false };
    };
    switch (await gate.settle(toAddr(split), ?5000)) {
      case (#invalidSignature(e)) { assert Text.contains(e, #text "must be the canister's EVM address") };
      case (_) { assert false };
    };
    switch (await gate.settleToSplit({ toAddr(split) with network = "icp:1" }, ?5000, { finder; finderShareBps = 500 })) {
      case (#networkNotSupported(_)) {};
      case (_) { assert false };
    };
    // The Gateway passes the paid token: the token as finder is refused.
    switch (await gate.settleToSplit(toAddr(split), ?5000, { finder = tokenA; finderShareBps = 500 })) {
      case (#policyDenied(e)) { assert Text.contains(e, #text "paid token") };
      case (_) { assert false };
    };
  });

  await test("the Gateway passes the payment's chain: a configured chain other than Base is refused", func() : async () {
    // Mutation: settleCore hands splitPayTo a fixed Base chain id instead of the payment's.
    let chainOne : Types.EvmChainConfig = { chainA with chainId = 1 };
    let gate = Gateway.Gateway({ config(null, null) with evmChains = [chainOne] }, canisterP);
    gate.loadStable({ gate.toStable() with evmRecipient = ?canisterEvm });
    assert gate.setEvmSplitCeiling(?1000) == #ok;
    switch (await gate.settleToSplit({ toAddr(split) with network = "eip155:1" }, ?5000, { finder; finderShareBps = 500 })) {
      case (#policyDenied(e)) { assert Text.contains(e, #text "Base (8453) and Base Sepolia (84532) only") };
      case (_) { assert false };
    };
  });

  await test("a refused split frees the server nonce: the same payment is answered the same way again", func() : async () {
    // Mutation: either split refusal returns without nonceManager.unlock — the nonce stays locked
    // and the second attempt is answered "in progress" instead.
    let gate = mkGate();
    let n = gate.requireEvm(5000)[0].nonce;
    let sig = { toAddr(split) with nonce = n };
    for (_ in [1, 2].vals()) {
      switch (await gate.settleToSplit(sig, ?5000, { finder; finderShareBps = 500 })) {
        case (#policyDenied(e)) { assert e == EvmSplits.SPLITS_OFF };
        case (_) { assert false };
      };
    };
    assert gate.setEvmSplitCeiling(?1000) == #ok;
    for (_ in [1, 2].vals()) {
      switch (await gate.settleToSplit(sig, ?5000, { finder; finderShareBps = 600 })) {
        case (#invalidSignature(e)) { assert Text.contains(e, #text "must be the split") };
        case (_) { assert false };
      };
    };
  });
});
