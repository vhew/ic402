import { describe, it, expect, beforeAll, beforeEach, afterEach } from 'vitest';
import { createHash } from 'node:crypto';
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { Ed25519KeyIdentity } from '@icp-sdk/core/identity';
import { IDL } from '@icp-sdk/core/candid';
import { Principal } from '@icp-sdk/core/principal';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import type { PaymentSignatureArg } from '../packages/client/src/idl.js';

/**
 * ICP-ledger FAILURE paths, against a scriptable mock ledger (example/icp-ledger-mock).
 *
 * DFINITY's ICRC-1 ledger never rejects a call, and `mops test` cannot make an inter-canister
 * call that fails with a system reject code, so these branches ran in no test: a ledger call
 * rejected with an unknown outcome (the library cannot tell "never ran" from "committed, then
 * failed"), a close leg the ledger refuses or rejects, a transfer that commits and then traps, a
 * stopped ledger, and the library itself trapping after a transfer landed. Each test names the
 * library branch it covers.
 *
 * Every ICP payment here goes through the example's Candid methods (settleFrom via search and
 * submitServiceRequest; openSession / endSession), each payer a fresh identity.
 *
 * "Stopped" is real: the suite (test-payer, a controller of the mock) stops the mock through the
 * management canister. To stop it BETWEEN the library's fee query and its transfer, the fee query
 * is held a few seconds and the mock is stopped meanwhile: a stopping canister finishes the calls
 * it has open, so the fee query answers and the transfer that follows meets a stopped ledger.
 *
 * Fixture setup (the example must point its ckUSDC ledger at the mock):
 *   pnpm setup:local
 *   bash scripts/predemo.sh
 *   bash scripts/setup-ledger-faults.sh
 *
 * Run:
 *   IC402_REQUIRE_LEDGER_FAULTS=1 pnpm exec vitest run test/ledger-faults.test.ts
 */

const HOST = 'http://localhost:4944';
const FEE = 10_000n; // the mock's default fee, = the example's CKUSDC_FEE
const DEPOSIT = 50_000n; // the example's suggestedDeposit
const SEARCH_PRICE = 1_000n;
const MINT = 1_000_000n;

// ── the mock's interface (example/icp-ledger-mock/icp_ledger_mock.did) ──
const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });
const TransferError = IDL.Variant({
  BadFee: IDL.Record({ expected_fee: IDL.Nat }),
  BadBurn: IDL.Record({ min_burn_amount: IDL.Nat }),
  InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
  InsufficientAllowance: IDL.Record({ allowance: IDL.Nat }),
  TooOld: IDL.Null,
  CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
  Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
  TemporarilyUnavailable: IDL.Null,
  GenericError: IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
  MockUndecodable: IDL.Null,
});
const Outcome = IDL.Variant({
  ok: IDL.Null,
  err: TransferError,
  reject: IDL.Text,
  commitThenTrap: IDL.Null,
  undecodable: IDL.Bool,
  holdThenOk: IDL.Nat,
});
const Method = IDL.Variant({
  icrc1_fee: IDL.Null,
  icrc1_transfer: IDL.Null,
  icrc2_transfer_from: IDL.Null,
  icrc1_balance_of: IDL.Null,
});
const LogEntry = IDL.Record({
  seq: IDL.Nat,
  method: Method,
  outcome: IDL.Text,
  block: IDL.Opt(IDL.Nat),
  from: IDL.Opt(Account),
  to: IDL.Opt(Account),
  amount: IDL.Nat,
});
const ApproveResult = IDL.Variant({
  Ok: IDL.Nat,
  Err: IDL.Variant({
    BadFee: IDL.Record({ expected_fee: IDL.Nat }),
    InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    AllowanceChanged: IDL.Record({ current_allowance: IDL.Nat }),
    Expired: IDL.Record({ ledger_time: IDL.Nat64 }),
    TooOld: IDL.Null,
    CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    GenericError: IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
  }),
});
const mockIdl = () =>
  IDL.Service({
    icrc2_approve: IDL.Func(
      [
        IDL.Record({
          from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
          spender: Account,
          amount: IDL.Nat,
          expected_allowance: IDL.Opt(IDL.Nat),
          expires_at: IDL.Opt(IDL.Nat64),
          fee: IDL.Opt(IDL.Nat),
          memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
          created_at_time: IDL.Opt(IDL.Nat64),
        }),
      ],
      [ApproveResult],
      [],
    ),
    script: IDL.Func([Method, IDL.Vec(Outcome)], [], []),
    reset: IDL.Func([], [], []),
    mint: IDL.Func([Account, IDL.Nat], [IDL.Nat], []),
    setFee: IDL.Func([IDL.Nat], [], []),
    advanceClock: IDL.Func([IDL.Nat], [], []),
    log: IDL.Func([], [IDL.Vec(LogEntry)], ['query']),
    held: IDL.Func([], [IDL.Nat], ['query']),
    balanceOf: IDL.Func([Account], [IDL.Nat], ['query']),
  });

// Controller-only and payer recovery methods of the example, absent from the public client IDL.
const JobStatus = IDL.Variant({
  Assigned: IDL.Null,
  Computing: IDL.Null,
  Disputed: IDL.Null,
  Expired: IDL.Null,
  Pending: IDL.Null,
  Refunded: IDL.Null,
  Settled: IDL.Null,
  Settling: IDL.Null,
  Submitted: IDL.Null,
  Verified: IDL.Null,
});
const TextResult = IDL.Variant({ ok: IDL.Text, err: IDL.Text });
const UnitResult = IDL.Variant({ ok: IDL.Null, err: IDL.Text });
const adminIdl = () =>
  IDL.Service({
    reconcileSession: IDL.Func([IDL.Text], [TextResult], []),
    recoverEscrow: IDL.Func([IDL.Text, IDL.Nat], [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })], []),
    clearRefundOwed: IDL.Func([IDL.Text], [UnitResult], []),
    resolveJob: IDL.Func([IDL.Text, JobStatus], [UnitResult], []),
  });

const managementIdl = () => {
  const Target = IDL.Record({ canister_id: IDL.Principal });
  return IDL.Service({
    stop_canister: IDL.Func([Target], [], []),
    start_canister: IDL.Func([Target], [], []),
  });
};

type Outcome =
  | { ok: null }
  | { err: Record<string, unknown> }
  | { reject: string }
  | { commitThenTrap: null }
  | { undecodable: boolean }
  | { holdThenOk: bigint };
type MethodName = 'icrc1_fee' | 'icrc1_transfer' | 'icrc2_transfer_from' | 'icrc1_balance_of';
type LogRow = { method: Record<string, null>; outcome: string; block: [] | [bigint] };
type AccountArg = { owner: Principal; subaccount: [] | [Uint8Array] };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe('ic402 ICP-ledger faults (mock ledger)', () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let example: any; // test-payer (a controller), public client IDL
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let admin: any; // test-payer, controller-only slice
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let mock: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let management: any;
  let exampleId = '';
  let mockId = '';
  let operator: Principal; // test-payer: registers the services, so it is their operator
  let skip = false;

  beforeAll(async () => {
    try {
      const agent = await createLocalAgent();
      operator = await agent.getPrincipal();
      exampleId = getCanisterId('example');
      mockId = getCanisterId('icp_ledger_mock'); // throws if the fixture isn't deployed
      example = createExampleActor(agent, exampleId);
      admin = Actor.createActor(adminIdl, { agent, canisterId: exampleId });
      mock = Actor.createActor(mockIdl, { agent, canisterId: mockId });
      management = Actor.createActor(managementIdl, {
        agent,
        canisterId: 'aaaaa-aa',
        effectiveTarget: { canisterId: Principal.fromText(mockId) },
      });
      // The overlay is in place only if the example's ICP token IS the mock.
      if ((await example.requestSession()).token !== mockId) skip = true;
    } catch {
      skip = true;
    }
  });

  // Skip-enforcement, as in evm-outbound.test.ts: the example must be RE-POINTED at the mock (a
  // plain `pnpm setup:local` wires DFINITY's ledger), so this keys off its OWN flag.
  it('mock ledger fixture is deployed (enforced when IC402_REQUIRE_LEDGER_FAULTS=1)', () => {
    if (process.env.IC402_REQUIRE_LEDGER_FAULTS === '1') {
      expect(skip).toBe(false);
    } else if (skip) {
      console.warn(
        '[ledger-faults] mock ledger fixture not deployed — suite SKIPPED. Run `pnpm setup:local`, `bash scripts/predemo.sh`, then `bash scripts/setup-ledger-faults.sh`.',
      );
    }
  });

  beforeEach(async () => {
    if (skip) return;
    await mock.reset();
  });

  // Sessions each test opened. A test that fails can leave one open, and the expiry sweep would
  // then close it during a later test, taking that test's scripted ledger outcomes. So close them
  // here (refused, moving nothing, for a session already closed or parked).
  const opened: { p: Payer; id: string }[] = [];
  afterEach(async () => {
    for (const { p, id } of opened.splice(0)) await p.example.endSession(id).catch(() => undefined);
  });

  // ── helpers ──

  const script = (m: MethodName, outcomes: Outcome[]) => mock.script({ [m]: null }, outcomes);
  const log = async (m: MethodName): Promise<LogRow[]> =>
    ((await mock.log()) as LogRow[]).filter((e) => m in e.method);
  const committed = async (m: MethodName) => (await log(m)).filter((e) => e.block.length === 1);
  const counts = async () => (await example.health()).sessions;
  const escrow = (sessionId: string): AccountArg => ({
    owner: Principal.fromText(exampleId),
    subaccount: [new Uint8Array(createHash('sha256').update(`ic402-escrow${sessionId}`).digest())],
  });

  /* eslint-disable @typescript-eslint/no-explicit-any */
  interface Payer {
    identity: Ed25519KeyIdentity;
    principal: Principal;
    account: AccountArg;
    example: any; // as this payer, public client IDL
    admin: any; // as this payer: recoverEscrow
    ledger: any; // the mock, as this payer: icrc2_approve
    balance: () => Promise<bigint>;
  }
  /* eslint-enable @typescript-eslint/no-explicit-any */

  // A fresh payer: its own identity (and session key), minted MINT on the mock.
  async function newPayer(): Promise<Payer> {
    const identity = Ed25519KeyIdentity.generate();
    const agent = await HttpAgent.create({ host: HOST, shouldFetchRootKey: true, identity });
    const principal = identity.getPrincipal();
    const account: AccountArg = { owner: principal, subaccount: [] };
    await mock.mint(account, MINT);
    return {
      identity,
      principal,
      account,
      example: createExampleActor(agent, exampleId),
      admin: Actor.createActor(adminIdl, { agent, canisterId: exampleId }),
      ledger: Actor.createActor(mockIdl, { agent, canisterId: mockId }),
      balance: (): Promise<bigint> => mock.balanceOf(account),
    };
  }

  // ICRC-2 approval of the example (the mock charges the approve fee: the payer then holds MINT - FEE).
  async function approve(p: Payer, amount: bigint) {
    const r = await p.ledger.icrc2_approve({
      from_subaccount: [],
      spender: { owner: Principal.fromText(exampleId), subaccount: [] },
      amount,
      expected_allowance: [],
      expires_at: [],
      fee: [],
      memo: [],
      created_at_time: [],
    });
    expect(r).toHaveProperty('Ok');
  }

  const openSession = (p: Payer, idleTimeout: [] | [bigint] = []) =>
    p.example.openSession(
      { maxDeposit: DEPOSIT, autoClose: true, idleTimeout },
      {
        scheme: 'exact',
        network: 'icp:1',
        signature: new Uint8Array(0),
        publicKey: [new Uint8Array(p.identity.getPublicKey().toRaw())],
        asset: [],
        sender: '',
        nonce: new Uint8Array(32),
        authorization: [],
      },
    );
  const voucher = (sessionId: string, cumulativeAmount: bigint, sequence: bigint) => ({
    sessionId,
    cumulativeAmount,
    sequence,
    signature: new Uint8Array(64), // the session key is the caller: no signature is checked
  });
  async function openAndSpend(p: Payer, spent: bigint, idleTimeout: [] | [bigint] = []) {
    await approve(p, DEPOSIT + FEE);
    const ok = await openSession(p, idleTimeout);
    expect(ok).toHaveProperty('ok');
    const id: string = ok.ok.id;
    opened.push({ p, id });
    expect(await p.example.sessionQuery(voucher(id, spent, 1n), 'q')).toHaveProperty('ok');
    return id;
  }
  const parkedId = (p: Payer, err: string) => {
    const m = /Session (\S+) is parked #closing/.exec(err);
    expect(m).not.toBeNull();
    opened.push({ p, id: m![1] }); // reconcileSession may open it
    return m![1];
  };

  // An ICP payment for `search` (1,000), as its payer.
  async function searchPayment(p: Payer, query: string): Promise<PaymentSignatureArg> {
    await approve(p, SEARCH_PRICE + FEE);
    const reqs = (await p.example.search(query, [])).paymentRequired;
    const req = reqs.find((r: { network: string }) => r.network === 'icp:1');
    return {
      scheme: 'exact',
      network: 'icp:1',
      signature: new Uint8Array(0),
      publicKey: [],
      asset: [],
      sender: p.principal.toText(),
      nonce: req.nonce,
      authorization: [],
    };
  }

  // The mock stopped for the duration of `fn`.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async function whileStopped(fn: () => Promise<any>): Promise<any> {
    await management.stop_canister({ canister_id: Principal.fromText(mockId) });
    try {
      return await fn();
    } finally {
      await management.start_canister({ canister_id: Principal.fromText(mockId) });
    }
  }

  // The mock answers the library's fee query and is stopped before the call that follows it.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async function stoppedAfterFee(op: () => Promise<any>): Promise<any> {
    await script('icrc1_fee', [{ holdThenOk: 4n }]);
    const pending = op();
    pending.catch(() => {}); // awaited below; keep an early failure from going unhandled meanwhile
    for (let i = 0; i < 50 && (await mock.held()) === 0n; i++) await sleep(100);
    expect(await mock.held()).toBe(1n);
    // Returns once the mock is stopped: after the held fee query has answered.
    await management.stop_canister({ canister_id: Principal.fromText(mockId) });
    try {
      return await pending;
    } finally {
      await management.start_canister({ canister_id: Principal.fromText(mockId) });
    }
  }

  // ── session open ──

  // Sessions.openSession, the deposit catch's unknown-outcome arm (Sessions.mo:515-527: park the
  // session #closing, arm the expiry sweep, keep the daily reservation, #settlementPending), and
  // reconcileIcpClose's "escrow holds the full deposit, nothing consumed" arm (Sessions.mo:1656-1662).
  // Fails on: that catch treating the reject as "never ran" (no session record, the landed deposit
  // unrecoverable); reconcile not opening a session whose escrow holds the deposit.
  it('open: a deposit that lands and then rejects (code 5) parks the session; reconcileSession opens it and it closes once', async () => {
    if (skip) return;
    const p = await newPayer();
    await approve(p, DEPOSIT + FEE);
    const before = await counts();
    await script('icrc2_transfer_from', [{ commitThenTrap: null }]);
    const err = String((await openSession(p)).err);
    expect(err).toMatch(/^Settlement pending/);
    expect(err).toMatch(/Deposit rejected \(#canister_error\)/);
    const id = parkedId(p, err);
    const h = await example.health();
    expect(h.sessions.closing).toBe(before.closing + 1n);
    expect(h.timers.sessionExpiryArmed).toBe(true);
    expect(await mock.balanceOf(escrow(id))).toBe(DEPOSIT); // the deposit did land
    expect(String((await p.example.sessionQuery(voucher(id, 1_000n, 1n), 'q')).error)).toMatch(
      /session not open/,
    );

    const reconciled = await admin.reconcileSession(id);
    expect(String(reconciled.ok)).toMatch(/the deposit landed\. Session opened/);
    expect(await p.example.sessionQuery(voucher(id, 1_000n, 1n), 'q')).toHaveProperty('ok');
    const closed = await p.example.endSession(id);
    expect(closed).toHaveProperty('ok');
    expect(closed.ok.amount).toBe(1_000n);
    expect(closed.ok.refunded).toEqual([DEPOSIT - 1_000n - 2n * FEE]);
    expect((await committed('icrc1_transfer')).length).toBe(2); // one settle, one refund
    expect(await mock.balanceOf(escrow(id))).toBe(0n);
    expect(await p.balance()).toBe(MINT - FEE - (DEPOSIT + FEE) + (DEPOSIT - 1_000n - 2n * FEE));
    expect((await counts()).closing).toBe(before.closing);
  });

  // The same catch with a REAL stopped ledger after a good fee query (code 5, nothing moved), and
  // reconcileIcpClose's "escrow short, nothing consumed" arm (Sessions.mo:1664-1672: #closed,
  // nothing owed). Fails on: that arm recording the escrow as owed (recoverEscrow pointed at funds
  // that never arrived); the parked session not counting against maxConcurrentSessions.
  it('open: a deposit refused by a ledger stopped after the fee query parks the session; reconcileSession closes it with nothing owed', async () => {
    if (skip) return;
    const p = await newPayer();
    await approve(p, DEPOSIT + FEE);
    const before = await counts();
    const err = String((await stoppedAfterFee(() => openSession(p))).err);
    expect(err).toMatch(/Deposit rejected \(#canister_error\)/);
    const id = parkedId(p, err);
    expect(await mock.balanceOf(escrow(id))).toBe(0n);
    expect(await p.balance()).toBe(MINT - FEE); // nothing moved
    expect((await committed('icrc2_transfer_from')).length).toBe(0);
    // Parked, it holds the payer's one session slot (the deposit may yet be found in escrow).
    expect(String((await openSession(p)).err)).toMatch(/^Policy/);

    const reconciled = await admin.reconcileSession(id);
    expect(String(reconciled.ok)).toMatch(/nothing was consumed: the deposit did not land/);
    const after = await counts();
    expect(after.closing).toBe(before.closing);
    expect(after.refundOwed).toBe(before.refundOwed);
    const again = await openSession(p); // the slot is free and the allowance untouched
    expect(again).toHaveProperty('ok');
    opened.push({ p, id: again.ok.id });
    expect(await p.example.endSession(again.ok.id)).toHaveProperty('ok');
  });

  // ── session close ──

  // closeIcpSession, the settle leg's #Err arm (Sessions.mo:1188-1191: reopen, #settlementFailed
  // "Settle: …"). Fails on: the session left #closing after a definite refusal (nothing re-closes
  // it; the next endSession is refused) or closed without settling.
  it.each([
    ['TemporarilyUnavailable', { TemporarilyUnavailable: null }],
    ['BadFee', { BadFee: { expected_fee: FEE } }],
    ['GenericError', { GenericError: { error_code: 1n, message: 'mock refusal' } }],
  ])(
    'close: a settle leg the ledger refuses (%s) reopens the session, and the next close settles once',
    async (_name, refusal) => {
      if (skip) return;
      const p = await newPayer();
      const id = await openAndSpend(p, 1_000n);
      await script('icrc1_transfer', [{ err: refusal }]);
      const refused = await p.example.endSession(id);
      expect(String(refused.settlementFailed)).toMatch(/^Settle: Settlement failed: /);
      expect((await committed('icrc1_transfer')).length).toBe(0);
      // #open again: a voucher is accepted.
      expect(await p.example.sessionQuery(voucher(id, 2_000n, 2n), 'q')).toHaveProperty('ok');
      const closed = await p.example.endSession(id);
      expect(closed).toHaveProperty('ok');
      expect(closed.ok.amount).toBe(2_000n);
      expect((await committed('icrc1_transfer')).length).toBe(2);
      expect(await mock.balanceOf(escrow(id))).toBe(0n);
    },
  );

  // closeIcpSession, the fee query's catch (Sessions.mo:1163-1166: reopen, #settlementFailed "Fee
  // query failed"), against a REAL stopped ledger. Fails on: the session left #closing (nothing
  // re-closes it).
  it('close: a stopped ledger refuses the fee query; nothing moves, the session stays open, and the close succeeds once the ledger is back', async () => {
    if (skip) return;
    const p = await newPayer();
    const id = await openAndSpend(p, 1_000n);
    const refused = await whileStopped(() => p.example.endSession(id));
    expect(String(refused.settlementFailed)).toMatch(/^Fee query failed \(icrc1_fee\)/);
    expect(await mock.balanceOf(escrow(id))).toBe(DEPOSIT);
    expect(await p.example.sessionQuery(voucher(id, 2_000n, 2n), 'q')).toHaveProperty('ok');
    const closed = await p.example.endSession(id);
    expect(closed).toHaveProperty('ok');
    expect((await committed('icrc1_transfer')).length).toBe(2);
  });

  // closeIcpSession, the settle leg's catch, unknown-outcome arm (Sessions.mo:1180-1185: stay
  // #closing, #settlementPending), with code 5 after the settle committed; then reconcileIcpClose's
  // "settle landed" arm (Sessions.mo:1673-1680: #closed, remainder owed) and recoverEscrow.
  // Fails on: the catch reopening the session (the next close, or the sweep, settles a second time
  // out of the payer's escrow); reconcile not recording the remainder (the payer cannot recover it).
  it('close: a settle that lands and then rejects (code 5) parks the close; reconcileSession closes it as settled and the payer recovers the rest', async () => {
    if (skip) return;
    const p = await newPayer();
    const id = await openAndSpend(p, 1_000n);
    const before = await counts();
    await script('icrc1_transfer', [{ commitThenTrap: null }]);
    const parked = await p.example.endSession(id);
    expect(String(parked.settlementPending)).toMatch(/^Settle leg rejected \(#canister_error\)/);
    expect((await counts()).closing).toBe(before.closing + 1n);
    expect(await mock.balanceOf(escrow(id))).toBe(DEPOSIT - 1_000n - FEE); // the settle landed
    // #closing: neither a re-close nor a recovery may move the escrow now.
    expect(String((await p.example.endSession(id)).settlementFailed)).toMatch(/already closed/);

    const reconciled = await admin.reconcileSession(id);
    expect(String(reconciled.ok)).toMatch(/^The settle landed/);
    const after = await counts();
    expect(after.closing).toBe(before.closing);
    expect(after.refundOwed).toBe(before.refundOwed + 1n);
    const balance = await p.balance();
    const recovered = await p.admin.recoverEscrow(id, MINT);
    expect(recovered).toHaveProperty('ok');
    expect(await p.balance()).toBe(balance + DEPOSIT - 1_000n - 2n * FEE);
    expect(await mock.balanceOf(escrow(id))).toBe(0n);
    expect((await counts()).refundOwed).toBe(before.refundOwed);
    expect((await committed('icrc1_transfer')).length).toBe(2); // the settle and the recovery
  });

  // The expiry sweep's catch around closeSessionInternal, mid-close arm (Sessions.mo:1463-1471),
  // reached by the LIBRARY trapping after its settle landed (an undecodable ledger reply), and the
  // `finally` of closeSessionInternal (Sessions.mo:1137) running on that trap, so reconcileSession
  // is not refused as "still in flight". Fails on: the sweep reopening a session whose close may
  // have paid (a second settle at the next tick); icpClosesInFlight left set by the trap (the
  // session can never be reconciled).
  it('sweep: a close whose settle lands but whose reply the library cannot decode stays #closing, and reconcileSession can still resolve it', async () => {
    if (skip) return;
    const p = await newPayer();
    const id = await openAndSpend(p, 1_000n, [5_000_000_000n]); // idle after 5 s
    const before = await counts();
    await script('icrc1_transfer', [{ undecodable: true }]);
    // The example's 60 s sweep closes it.
    let swept = false;
    for (let i = 0; i < 90 && !swept; i++) {
      await sleep(1_000);
      swept = (await log('icrc1_transfer')).length > 0;
    }
    expect(swept).toBe(true);
    expect(await mock.balanceOf(escrow(id))).toBe(DEPOSIT - 1_000n - FEE); // the settle landed
    let reconciled = await admin.reconcileSession(id);
    // The trap is processed a round after the mock replied: allow a few seconds, no more.
    for (let i = 0; i < 15 && /still in flight/.test(String(reconciled.err)); i++) {
      await sleep(1_000);
      reconciled = await admin.reconcileSession(id);
    }
    expect(String(reconciled.ok)).toMatch(/^The settle landed/);
    expect((await counts()).refundOwed).toBe(before.refundOwed + 1n);
    const balance = await p.balance();
    expect(await p.admin.recoverEscrow(id, MINT)).toHaveProperty('ok');
    expect(await p.balance()).toBe(balance + DEPOSIT - 1_000n - 2n * FEE);
  }, 200_000);

  // closeIcpSession, the refund leg's catch (Sessions.mo:1218-1245: #closed, the remainder owed),
  // with a reject (code 4, nothing moved); then recoverOwed's transfer, whose reject is uncaught
  // (Sessions.mo:2119), committing and then trapping, and recoverEscrowCore's `finally`
  // (Sessions.mo:2083) clearing the in-flight mark on that reject. Fails on: the refund reject not
  // recording the remainder; the in-flight mark left set (every later recovery refused).
  it('close and recovery: a rejected refund leaves the remainder owed; a recovery that lands and then rejects pays once, and the owed entry stays for clearRefundOwed', async () => {
    if (skip) return;
    const p = await newPayer();
    const id = await openAndSpend(p, 1_000n);
    const before = await counts();
    await script('icrc1_transfer', [{ ok: null }, { reject: 'mock: refund leg rejected' }]);
    const closed = await p.example.endSession(id);
    expect(String(closed.settlementFailed)).toMatch(
      /^Refund leg rejected \(session marked #closed\)/,
    );
    expect((await counts()).refundOwed).toBe(before.refundOwed + 1n);
    const left = DEPOSIT - 1_000n - FEE;
    expect(await mock.balanceOf(escrow(id))).toBe(left);

    const balance = await p.balance();
    await script('icrc1_transfer', [{ commitThenTrap: null }]);
    await expect(p.admin.recoverEscrow(id, MINT)).rejects.toThrow();
    expect(await p.balance()).toBe(balance + left - FEE); // the recovery landed
    expect(await mock.balanceOf(escrow(id))).toBe(0n);
    // Not refused as in flight; the escrow is empty, so it pays nothing.
    const again = await p.admin.recoverEscrow(id, MINT);
    expect(String(again.err)).toMatch(/InsufficientFunds/);
    expect(await p.balance()).toBe(balance + left - FEE);
    // The entry was not reduced (the reject's outcome is unknown to the library): it is the
    // controller's to clear once the escrow is seen empty.
    expect((await counts()).refundOwed).toBe(before.refundOwed + 1n);
    expect(await admin.clearRefundOwed(id)).toHaveProperty('ok');
    expect((await counts()).refundOwed).toBe(before.refundOwed);
  });

  // ── charges (settleFrom, with ledger deduplication on) ──

  // Gateway.settleCore, the transfer catch's unknown-outcome arm for settleFrom with dedup
  // (Gateway.mo:1433-1457: nonce kept locked, the transfer stored, #settlementPending), with code 5
  // after the transfer committed; the payer's re-submit goes to resolvePendingCharge, whose #Duplicate
  // arm issues the receipt (Gateway.mo:1507). Fails on: that catch treating the reject as "never
  // ran" (a fresh 402 invites a second payment); #Duplicate not issuing the receipt.
  it('charge: a transfer that lands and then rejects (code 5) is pending; the same payment re-submitted is #Duplicate — one receipt, one debit', async () => {
    if (skip) return;
    const p = await newPayer();
    const sig = await searchPayment(p, 'dup');
    await script('icrc2_transfer_from', [{ commitThenTrap: null }]);
    const first = await p.example.search('dup', [sig]);
    expect(String(first.error)).toMatch(/^Settlement pending/);
    expect(String(first.error)).toMatch(/Ledger call rejected \(#canister_error\)/);
    const debited = MINT - FEE - SEARCH_PRICE - FEE;
    expect(await p.balance()).toBe(debited);

    expect(await p.example.search('dup', [sig])).toHaveProperty('ok');
    expect(await p.balance()).toBe(debited);
    const sends = await log('icrc2_transfer_from');
    expect(sends.length).toBe(2);
    expect(sends[1].outcome).toMatch(/Duplicate/);
    expect(sends[1].block).toEqual([]);
    // The nonce is consumed: a third submit sends nothing.
    expect(await p.example.search('dup', [sig])).toHaveProperty('paymentRequired');
    expect((await log('icrc2_transfer_from')).length).toBe(2);
  });

  // The same catch with a REAL stopped ledger after a good fee query (code 5, nothing moved); the
  // re-submit's re-send lands, resolvePendingCharge's #Ok arm (Gateway.mo:1506).
  // Fails on: the catch treating the reject as "never ran"; #Ok not issuing the receipt.
  it('charge: a transfer refused by a ledger stopped after the fee query is pending; the same payment re-submitted settles once', async () => {
    if (skip) return;
    const p = await newPayer();
    const sig = await searchPayment(p, 'stopped');
    const first = await stoppedAfterFee(() => p.example.search('stopped', [sig]));
    expect(String(first.error)).toMatch(/^Settlement pending/);
    expect(String(first.error)).toMatch(/Ledger call rejected \(#canister_error\)/);
    expect(await p.balance()).toBe(MINT - FEE); // nothing moved

    expect(await p.example.search('stopped', [sig])).toHaveProperty('ok');
    expect(await p.balance()).toBe(MINT - FEE - SEARCH_PRICE - FEE);
    expect((await committed('icrc2_transfer_from')).length).toBe(1);
    expect(await p.example.search('stopped', [sig])).toHaveProperty('paymentRequired');
    expect((await log('icrc2_transfer_from')).length).toBe(1);
  });

  // resolvePendingCharge's #TooOld arm (Gateway.mo:1508-1511: the stored transfer dropped, still
  // pending) — the ledger's 24 h window has passed. Fails on: the transfer kept (every later
  // re-submit sends it again for nothing).
  it('charge: a pending charge re-submitted after the 24 h window is #TooOld; it stays pending and a further re-submit sends nothing', async () => {
    if (skip) return;
    const p = await newPayer();
    const sig = await searchPayment(p, 'too-old');
    await script('icrc2_transfer_from', [{ reject: 'mock: ledger busy' }]);
    expect(String((await p.example.search('too-old', [sig])).error)).toMatch(
      /Ledger call rejected \(#canister_reject\)/,
    );
    await mock.advanceClock(24n * 3600n + 180n);
    expect(String((await p.example.search('too-old', [sig])).error)).toMatch(
      /past the ledger's 24-hour deduplication window/,
    );
    expect(String((await p.example.search('too-old', [sig])).error)).toMatch(/^Settlement pending/);
    const sends = await log('icrc2_transfer_from');
    expect(sends.length).toBe(2);
    expect(sends[1].outcome).toMatch(/TooOld/);
    expect(await p.balance()).toBe(MINT - FEE);
  });

  // resolvePendingCharge's #BadFee arm (Gateway.mo:1512-1515: the stored transfer dropped, still
  // pending) — the ledger's fee changed. Fails on: the transfer kept.
  it('charge: a pending charge re-submitted after a fee change is #BadFee; it stays pending and a further re-submit sends nothing', async () => {
    if (skip) return;
    const p = await newPayer();
    const sig = await searchPayment(p, 'bad-fee');
    await script('icrc2_transfer_from', [{ reject: 'mock: ledger busy' }]);
    expect(String((await p.example.search('bad-fee', [sig])).error)).toMatch(/^Settlement pending/);
    await mock.setFee(20_000n);
    expect(String((await p.example.search('bad-fee', [sig])).error)).toMatch(/fee changed/);
    expect(String((await p.example.search('bad-fee', [sig])).error)).toMatch(/^Settlement pending/);
    const sends = await log('icrc2_transfer_from');
    expect(sends.length).toBe(2);
    expect(sends[1].outcome).toMatch(/BadFee/);
    expect(await p.balance()).toBe(MINT - FEE);
  });

  // The LIBRARY trapping after its transfer landed (an undecodable ledger reply): the charge's
  // transfer was stored in flight before the await (Gateway.mo:1414), and the trap leaves it so;
  // Nonce.takePending refuses an in-flight charge (Nonce.mo:134), so the re-submit is the
  // in-flight #settlementPending (Gateway.mo:1021) and sends nothing. No receipt can be obtained
  // in-band afterwards. Fails on: takePending handing out an in-flight charge (a second send).
  it('charge: a transfer that lands but whose reply the library cannot decode leaves the nonce in flight; a re-submit sends nothing', async () => {
    if (skip) return;
    const p = await newPayer();
    const sig = await searchPayment(p, 'undecodable');
    await script('icrc2_transfer_from', [{ undecodable: true }]);
    await expect(p.example.search('undecodable', [sig])).rejects.toThrow();
    const debited = MINT - FEE - SEARCH_PRICE - FEE;
    expect(await p.balance()).toBe(debited);
    const again = await p.example.search('undecodable', [sig]);
    expect(String(again.error)).toMatch(/in flight, or its outcome is unknown/);
    expect((await log('icrc2_transfer_from')).length).toBe(1);
    expect(await p.balance()).toBe(debited);
  });

  // ── jobs ──

  async function registerEnabled(pricing: object, verification: string, timeout: bigint) {
    const r = await example.registerService(
      `ledger-faults ${verification} ${Date.now()}`,
      'ledger-faults suite',
      { Async: null },
      pricing,
      verification,
      [],
      [],
      { Poll: null },
      timeout,
    );
    expect(r).toHaveProperty('ok');
    expect(await example.enableService(r.ok)).toHaveProperty('ok');
    return r.ok as string;
  }
  async function buyJob(p: Payer, serviceId: string, total: bigint) {
    await approve(p, total + FEE);
    const params = new TextEncoder().encode('params');
    const reqs = (await p.example.submitServiceRequest(serviceId, params, [])).paymentRequired;
    const req = reqs.find((r: { network: string }) => r.network === 'icp:1');
    expect(BigInt(req.amount)).toBe(total);
    const sig: PaymentSignatureArg = {
      scheme: 'exact',
      network: 'icp:1',
      signature: new Uint8Array(0),
      publicKey: [],
      asset: [],
      sender: p.principal.toText(),
      nonce: req.nonce,
      authorization: [],
    };
    const submitted = await p.example.submitServiceRequest(serviceId, params, [sig]);
    expect(submitted).toHaveProperty('ok');
    return submitted.ok.jobId as string;
  }
  const jobStatus = async (jobId: string) => Object.keys((await example.getJobStatus(jobId))[0])[0];

  // ServiceRegistry.expireJobsCore, the catch around the expiry refund (ServiceRegistry.mo:1390-1393:
  // park the job #Settling), reached by a refund that commits and then rejects. Fails on: the job
  // left #Expired (nothing refunds it, and the GC drops it after 24 h).
  it('jobs: an expiry refund that lands and then rejects parks the job #Settling, and resolveJob closes it', async () => {
    if (skip) return;
    const serviceId = await registerEnabled({ Exact: 5_000n }, 'AutoSettle', 2n); // 2 s timeout
    const p = await newPayer();
    await script('icrc1_transfer', [{ commitThenTrap: null }]);
    const jobId = await buyJob(p, serviceId, 5_000n + FEE);
    const paid = await p.balance();
    // The example's 60 s job sweep expires and refunds it.
    let status = await jobStatus(jobId);
    for (let i = 0; i < 100 && status !== 'Settling'; i++) {
      await sleep(1_000);
      status = await jobStatus(jobId);
    }
    expect(status).toBe('Settling');
    expect(await p.balance()).toBe(paid + 5_000n); // although the buyer WAS refunded
    expect((await committed('icrc1_transfer')).length).toBe(1);
    expect(await admin.resolveJob(jobId, { Refunded: null })).toHaveProperty('ok');
    expect(await jobStatus(jobId)).toBe('Refunded');
  }, 200_000);

  // ServiceRegistry.settleJob, the Upto remainder leg, whose reject is deliberately uncaught
  // (ServiceRegistry.mo:1110): after the operator was paid, the remainder refund commits and then
  // rejects, so confirmJob rejects and the job stays #Settling with both transfers landed.
  // Fails on: that reject read as a definite failure (the job marked #Settled with the remainder
  // reported unpaid, or rolled back for a second payment).
  it('jobs: an Upto remainder refund that lands and then rejects fails confirmJob and leaves the job #Settling', async () => {
    if (skip) return;
    const serviceId = await registerEnabled({ Upto: 20_000n }, 'BuyerConfirm:3600', 600n);
    const p = await newPayer();
    const jobId = await buyJob(p, serviceId, 20_000n + FEE);
    expect(await example.claimJob(jobId)).toHaveProperty('ok');
    const result = new TextEncoder().encode('result');
    expect(await example.submitJobResult(jobId, result, [], [5_000n])).toHaveProperty('ok');
    const operatorAccount = { owner: operator, subaccount: [] };
    const operatorBefore: bigint = await mock.balanceOf(operatorAccount);
    const buyerBefore = await p.balance();
    await script('icrc1_transfer', [{ ok: null }, { commitThenTrap: null }]);
    await expect(p.example.confirmJob(jobId)).rejects.toThrow();
    expect(await jobStatus(jobId)).toBe('Settling');
    expect(await mock.balanceOf(operatorAccount)).toBe(operatorBefore + 5_000n);
    expect(await p.balance()).toBe(buyerBefore + 20_000n - 5_000n - FEE); // the remainder landed
    expect((await committed('icrc1_transfer')).length).toBe(2);
    expect(await admin.resolveJob(jobId, { Settled: null })).toHaveProperty('ok');
    expect(await jobStatus(jobId)).toBe('Settled');
  });
});
