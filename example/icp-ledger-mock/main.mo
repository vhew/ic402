/// ============================================================================
/// icp-ledger-mock — a scriptable ICRC-1/ICRC-2 ledger TEST DOUBLE.
///
/// ⚠️  TEST FIXTURE ONLY. Never deploy this to mainnet. The scripting and minting hooks are
///     intentionally unauthenticated so CI can drive them; on a real network anyone could mint.
///
/// WHY IT EXISTS:
///   The replica suite runs against DFINITY's ICRC-1 ledger, which never rejects a call, and
///   `mops test` cannot make an inter-canister call that fails with a system reject code. So the
///   library's ICP-ledger failure branches (a transfer whose outcome is unknown, a close leg the
///   ledger rejects, a ledger that commits and then traps, a stopped ledger) ran in no test. This
///   canister is the ICP counterpart of example/evm-rpc-mock: scripts/setup-ledger-faults.sh points
///   the example's ckUSDC ledger at it, and test/ledger-faults.test.ts scripts each failure.
///
/// LEDGER SEMANTICS (every call that is not scripted otherwise):
///   - real balances, keyed by (owner, subaccount); a null subaccount is the all-zero one;
///   - icrc1_transfer and icrc2_transfer_from debit amount + fee (the fee is burned) and append a
///     block; icrc2_approve charges the fee and sets the allowance (expires_at honoured);
///   - icrc2_transfer_from checks and decrements the allowance by amount + fee, except when the
///     spender is the `from` account itself (as DFINITY's ledgers do);
///   - an explicit fee different from the current fee is #BadFee, checked BEFORE deduplication;
///   - deduplication as DFINITY's ledgers do it: only for a call with created_at_time set, keyed on
///     the caller and the full argument (so memo and created_at_time included). #TooOld past the
///     24 h window plus 2 min drift, #CreatedInFuture beyond the drift, #Duplicate { duplicate_of }
///     for a repeat. Both checks use the mock clock (the replica's, plus advanceClock);
///   - #InsufficientFunds and #InsufficientAllowance arise from state.
///   No minting account: mint() credits an account directly.
///
/// SCRIPTING: a FIFO of outcomes per method (icrc1_fee, icrc1_transfer, icrc2_transfer_from,
/// icrc1_balance_of). Each call takes the next outcome; an empty queue means #ok.
///   #ok                  the ledger semantics above
///   #err e               reply #Err(e), commit nothing (transfer methods only)
///   #reject t            `throw Error.reject t` before any effect: reject code 4, nothing committed
///   #commitThenTrap      apply the ledger semantics (commit), then await a self-call and trap, so
///                        the caller sees reject code 5 for a transfer that landed — what a DFINITY
///                        ledger trapping after its archive_blocks await would look like. (On
///                        icrc1_fee / icrc1_balance_of nothing is committed: a plain code-5 reject.)
///   #undecodable c       reply #Err(#MockUndecodable), committing the transfer first when c is true.
///                        No ICRC-1 client knows that arm, so the CALLER traps decoding the reply
///                        after its await (transfer methods only). This is why the mock's .did is not
///                        the official one: keep it out of scripts/check-candid-mirrors.sh.
///   #holdThenOk s        wait about s seconds (one raw_rand round per check), then #ok. While a call
///                        is held, held() counts it. The suite holds a fee query, stops this canister
///                        through the management canister, and the caller's NEXT call then meets a
///                        genuinely stopped ledger (the held call still replies: a stopping canister
///                        finishes its open calls).
///
/// Control: script, reset, mint, setFee, advanceClock. Queries: log, held, pendingScripts,
/// balanceOf, allowanceOf, currentFee. icrc1_fee and icrc1_balance_of are update methods here (the
/// official .did has them as queries) so they can be faulted and held; inter-canister calls are
/// updates anyway.
///
/// Regenerate icp_ledger_mock.did after changing the interface:
///   $(mops toolchain bin moc) $(mops sources) --idl example/icp-ledger-mock/main.mo \
///     -o example/icp-ledger-mock/icp_ledger_mock.did
/// ============================================================================

import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Error "mo:base/Error";
import HashMap "mo:base/HashMap";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

persistent actor IcpLedgerMock {

  public type Account = { owner : Principal; subaccount : ?Blob };

  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
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

  /// ICRC-2's TransferFromError, plus the test-only #MockUndecodable. icrc1_transfer replies the
  /// same type: the ledger itself never gives it #InsufficientAllowance or #MockUndecodable, so a
  /// conformant reply decodes at ICRC-1's TransferError.
  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
    #MockUndecodable;
  };

  public type TransferResult = { #Ok : Nat; #Err : TransferError };

  public type ApproveArg = {
    from_subaccount : ?Blob;
    spender : Account;
    amount : Nat;
    expected_allowance : ?Nat;
    expires_at : ?Nat64;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type ApproveError = {
    #BadFee : { expected_fee : Nat };
    #InsufficientFunds : { balance : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type Method = { #icrc1_fee; #icrc1_transfer; #icrc2_transfer_from; #icrc1_balance_of };

  public type Outcome = {
    #ok;
    #err : TransferError;
    #reject : Text;
    #commitThenTrap;
    #undecodable : Bool;
    #holdThenOk : Nat;
  };

  /// One scriptable call, as it happened. `block` is set when the call committed a transfer.
  public type LogEntry = {
    seq : Nat;
    method : Method;
    outcome : Text;
    block : ?Nat;
    from : ?Account;
    to : ?Account;
    amount : Nat;
  };

  let TX_WINDOW : Nat = 24 * 60 * 60 * 1_000_000_000; // 24 h, in nanoseconds
  let PERMITTED_DRIFT : Nat = 2 * 60 * 1_000_000_000; // 2 min
  let DEFAULT_FEE : Nat = 10_000; // the example's CKUSDC_FEE

  // ── state (transient: a fixture, reinstalled by the setup script, reset() by the suite) ──
  transient var fee : Nat = DEFAULT_FEE;
  transient var clockOffset : Nat = 0;
  transient var nextBlock : Nat = 0;
  transient var nextSeq : Nat = 0;
  transient var holding : Nat = 0;
  transient var balances = HashMap.HashMap<Text, Nat>(16, Text.equal, Text.hash);
  transient var allowances = HashMap.HashMap<Text, { allowance : Nat; expires_at : ?Nat64 }>(16, Text.equal, Text.hash);
  transient var dedup = HashMap.HashMap<Blob, Nat>(16, Blob.equal, Blob.hash);
  transient let queues = Array.tabulate<Buffer.Buffer<Outcome>>(4, func(_) { Buffer.Buffer<Outcome>(4) });
  transient let calls = Buffer.Buffer<LogEntry>(32);

  transient let management : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";

  func methodIndex(m : Method) : Nat {
    switch (m) {
      case (#icrc1_fee) { 0 };
      case (#icrc1_transfer) { 1 };
      case (#icrc2_transfer_from) { 2 };
      case (#icrc1_balance_of) { 3 };
    };
  };

  func now() : Nat { Int.abs(Time.now()) + clockOffset };

  func hex(b : Blob) : Text {
    let digits = "0123456789abcdef";
    let chars = Text.toArray(digits);
    var out = "";
    for (x in b.values()) {
      let n = Nat8.toNat(x);
      out #= Text.fromChar(chars[n / 16]) # Text.fromChar(chars[n % 16]);
    };
    out;
  };

  let ZERO_SUBACCOUNT : Blob = Blob.fromArray(Array.freeze(Array.init<Nat8>(32, 0)));

  func key(a : Account) : Text {
    Principal.toText(a.owner) # "." # hex(switch (a.subaccount) { case (?s) { s }; case (null) { ZERO_SUBACCOUNT } });
  };

  func balance(a : Account) : Nat { switch (balances.get(key(a))) { case (?b) { b }; case (null) { 0 } } };

  func allowance(owner : Account, spender : Account) : Nat {
    switch (allowances.get(key(owner) # "|" # key(spender))) {
      case (?a) {
        switch (a.expires_at) {
          case (?e) { if (Nat64.toNat(e) <= now()) { 0 } else { a.allowance } };
          case (null) { a.allowance };
        };
      };
      case (null) { 0 };
    };
  };

  func block() : Nat {
    let b = nextBlock;
    nextBlock += 1;
    b;
  };

  // The fee, deduplication, allowance and balance checks of DFINITY's ledgers, in their order, and
  // the commit. `spender` is null for icrc1_transfer.
  func applyTransfer(
    dedupKey : Blob,
    from : Account,
    to : Account,
    spender : ?Account,
    amount : Nat,
    argFee : ?Nat,
    createdAt : ?Nat64,
  ) : TransferResult {
    switch (argFee) {
      case (?f) { if (f != fee) { return #Err(#BadFee({ expected_fee = fee })) } };
      case (null) {};
    };
    switch (createdAt) {
      case (?t) {
        let n = now();
        let created = Nat64.toNat(t);
        if (created + TX_WINDOW + PERMITTED_DRIFT < n) { return #Err(#TooOld) };
        if (created > n + PERMITTED_DRIFT) { return #Err(#CreatedInFuture({ ledger_time = Nat64.fromNat(n) })) };
        switch (dedup.get(dedupKey)) { case (?b) { return #Err(#Duplicate({ duplicate_of = b })) }; case (null) {} };
      };
      case (null) {};
    };
    let debit = amount + fee;
    let checkAllowance = switch (spender) { case (?s) { key(s) != key(from) }; case (null) { false } };
    if (checkAllowance) {
      let s = switch (spender) { case (?s) { s }; case (null) { Debug.trap("unreachable") } };
      let a = allowance(from, s);
      if (a < debit) { return #Err(#InsufficientAllowance({ allowance = a })) };
    };
    let bal = balance(from);
    if (bal < debit) { return #Err(#InsufficientFunds({ balance = bal })) };
    if (checkAllowance) {
      let s = switch (spender) { case (?s) { s }; case (null) { Debug.trap("unreachable") } };
      let k = key(from) # "|" # key(s);
      switch (allowances.get(k)) {
        case (?a) { allowances.put(k, { a with allowance = a.allowance - debit }) };
        case (null) {};
      };
    };
    balances.put(key(from), bal - debit);
    balances.put(key(to), balance(to) + amount);
    let b = block();
    if (createdAt != null) { dedup.put(dedupKey, b) };
    #Ok(b);
  };

  func take(m : Method) : Outcome {
    let q = queues[methodIndex(m)];
    if (q.size() == 0) { #ok } else { q.remove(0) };
  };

  func outcomeName(o : Outcome) : Text {
    switch (o) {
      case (#ok) { "ok" };
      case (#err(e)) { "err " # debug_show (e) };
      case (#reject(_)) { "reject" };
      case (#commitThenTrap) { "commitThenTrap" };
      case (#undecodable(c)) { "undecodable" # (if (c) { " (committed)" } else { "" }) };
      case (#holdThenOk(s)) { "holdThenOk " # Nat.toText(s) };
    };
  };

  func record(m : Method, o : Outcome, r : ?TransferResult, from : ?Account, to : ?Account, amount : Nat) {
    let committed = switch (r) { case (?#Ok(b)) { ?b }; case (_) { null } };
    let suffix = switch (r) { case (?#Err(e)) { " -> " # debug_show (e) }; case (_) { "" } };
    calls.add({ seq = nextSeq; method = m; outcome = outcomeName(o) # suffix; block = committed; from; to; amount });
    nextSeq += 1;
  };

  // A self-call: state written before it commits, as a DFINITY ledger's does at its archive_blocks
  // await, so a trap after it rejects a call whose transfer landed.
  func commitPoint() : async () {};

  func hold(seconds : Nat) : async* () {
    holding += 1;
    let deadline = Time.now() + seconds * 1_000_000_000;
    label wait while (Time.now() < deadline) {
      try { ignore await management.raw_rand() } catch (_) { break wait };
    };
    holding -= 1;
  };

  // The outcome machinery shared by the two transfer methods.
  func runTransfer(m : Method, apply : () -> TransferResult, from : Account, to : Account, amount : Nat) : async* TransferResult {
    let o = take(m);
    switch (o) {
      case (#ok) {
        let r = apply();
        record(m, o, ?r, ?from, ?to, amount);
        r;
      };
      case (#holdThenOk(s)) {
        await* hold(s);
        let r = apply();
        record(m, o, ?r, ?from, ?to, amount);
        r;
      };
      case (#err(e)) {
        record(m, o, null, ?from, ?to, amount);
        #Err(e);
      };
      case (#reject(t)) {
        record(m, o, null, ?from, ?to, amount);
        throw Error.reject(t);
      };
      case (#commitThenTrap) {
        let r = apply();
        record(m, o, ?r, ?from, ?to, amount);
        await commitPoint();
        Debug.trap("icp-ledger-mock: trapped after the transfer (" # debug_show (r) # ")");
      };
      case (#undecodable(commit)) {
        let r = if (commit) { ?apply() } else { null };
        record(m, o, r, ?from, ?to, amount);
        #Err(#MockUndecodable);
      };
    };
  };

  // The outcome machinery for icrc1_fee and icrc1_balance_of (no transfer to commit).
  func runRead(m : Method, value : () -> Nat) : async* Nat {
    let o = take(m);
    switch (o) {
      case (#ok) { record(m, o, null, null, null, 0); value() };
      case (#holdThenOk(s)) {
        await* hold(s);
        record(m, o, null, null, null, 0);
        value();
      };
      case (#reject(t)) { record(m, o, null, null, null, 0); throw Error.reject(t) };
      case (#commitThenTrap) {
        record(m, o, null, null, null, 0);
        await commitPoint();
        Debug.trap("icp-ledger-mock: trapped in " # debug_show (m));
      };
      case (#err(_) or #undecodable(_)) { Debug.trap("icp-ledger-mock: unreachable (script refuses it)") };
    };
  };

  // ── ICRC-1 / ICRC-2 ──

  public shared func icrc1_fee() : async Nat { await* runRead(#icrc1_fee, func() { fee }) };

  public shared func icrc1_balance_of(a : Account) : async Nat {
    await* runRead(#icrc1_balance_of, func() { balance(a) });
  };

  public shared (msg) func icrc1_transfer(arg : TransferArg) : async TransferResult {
    let from = { owner = msg.caller; subaccount = arg.from_subaccount };
    let dedupKey = to_candid (#transfer(msg.caller, arg));
    await* runTransfer(
      #icrc1_transfer,
      func() { applyTransfer(dedupKey, from, arg.to, null, arg.amount, arg.fee, arg.created_at_time) },
      from,
      arg.to,
      arg.amount,
    );
  };

  public shared (msg) func icrc2_transfer_from(arg : TransferFromArg) : async TransferResult {
    let spender = { owner = msg.caller; subaccount = arg.spender_subaccount };
    let dedupKey = to_candid (#transferFrom(msg.caller, arg));
    await* runTransfer(
      #icrc2_transfer_from,
      func() { applyTransfer(dedupKey, arg.from, arg.to, ?spender, arg.amount, arg.fee, arg.created_at_time) },
      arg.from,
      arg.to,
      arg.amount,
    );
  };

  public shared (msg) func icrc2_approve(arg : ApproveArg) : async { #Ok : Nat; #Err : ApproveError } {
    let owner = { owner = msg.caller; subaccount = arg.from_subaccount };
    switch (arg.fee) { case (?f) { if (f != fee) { return #Err(#BadFee({ expected_fee = fee })) } }; case (null) {} };
    switch (arg.expires_at) {
      case (?e) { if (Nat64.toNat(e) <= now()) { return #Err(#Expired({ ledger_time = Nat64.fromNat(now()) })) } };
      case (null) {};
    };
    switch (arg.expected_allowance) {
      case (?x) {
        let current = allowance(owner, arg.spender);
        if (x != current) { return #Err(#AllowanceChanged({ current_allowance = current })) };
      };
      case (null) {};
    };
    let bal = balance(owner);
    if (bal < fee) { return #Err(#InsufficientFunds({ balance = bal })) };
    balances.put(key(owner), bal - fee);
    allowances.put(key(owner) # "|" # key(arg.spender), { allowance = arg.amount; expires_at = arg.expires_at });
    #Ok(block());
  };

  // ── control (open by design — see the header) ──

  /// Append outcomes to `m`'s queue. #err and #undecodable apply to the transfer methods only.
  public func script(m : Method, outcomes : [Outcome]) : async () {
    for (o in outcomes.values()) {
      switch (m, o) {
        case (#icrc1_fee or #icrc1_balance_of, #err(_) or #undecodable(_)) {
          Debug.trap("icp-ledger-mock: " # debug_show (m) # " replies a Nat; script #ok, #reject, #commitThenTrap or #holdThenOk");
        };
        case (_) {};
      };
      queues[methodIndex(m)].add(o);
    };
  };

  /// Back to a pristine ledger: no queued outcomes, no balances, allowances, blocks, deduplication
  /// entries or log, the fee at 10_000 and the clock at the replica's.
  public func reset() : async () {
    for (q in queues.values()) { q.clear() };
    balances := HashMap.HashMap<Text, Nat>(16, Text.equal, Text.hash);
    allowances := HashMap.HashMap<Text, { allowance : Nat; expires_at : ?Nat64 }>(16, Text.equal, Text.hash);
    dedup := HashMap.HashMap<Blob, Nat>(16, Blob.equal, Blob.hash);
    calls.clear();
    fee := DEFAULT_FEE;
    clockOffset := 0;
    nextBlock := 0;
    nextSeq := 0;
  };

  public func mint(to : Account, amount : Nat) : async Nat {
    balances.put(key(to), balance(to) + amount);
    block();
  };

  public func setFee(f : Nat) : async () { fee := f };

  /// Move the mock clock forward (deduplication windows), in seconds.
  public func advanceClock(seconds : Nat) : async () { clockOffset += seconds * 1_000_000_000 };

  // ── queries for the suite (they consume no script and are not logged) ──

  public query func log() : async [LogEntry] { Buffer.toArray(calls) };
  public query func held() : async Nat { holding };
  public query func pendingScripts(m : Method) : async Nat { queues[methodIndex(m)].size() };
  public query func balanceOf(a : Account) : async Nat { balance(a) };
  public query func allowanceOf(owner : Account, spender : Account) : async Nat { allowance(owner, spender) };
  public query func currentFee() : async Nat { fee };
};
