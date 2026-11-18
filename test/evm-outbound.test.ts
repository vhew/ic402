import { describe, it, expect, beforeAll } from 'vitest';
import { randomBytes } from 'node:crypto';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import { Actor, type HttpAgent } from '@icp-sdk/core/agent';
import { IDL } from '@icp-sdk/core/candid';

/**
 * EVM-OUTBOUND hermetic integration tests (production-readiness item B3).
 *
 * Exercises the full outbound rail — real tECDSA signing + RLP encoding inside the
 * example canister, then broadcast → receipt-poll → confirm/park — against a
 * SCRIPTABLE mock of the DFINITY EVM RPC canister (example/evm-rpc-mock). No funded
 * testnet and no HTTPS outcall: every RPC round-trip is answered by the mock, so CI
 * can gate the state machine the demo could only show on a live chain (and can force
 * revert / pending / inconsistent-fee outcomes a real testnet won't produce on demand).
 *
 * Fixture setup (the example must point at the mock, not the real evm_rpc):
 *   pnpm setup:local
 *   bash scripts/setup-evm-outbound.sh
 *
 * Run:
 *   IC402_REQUIRE_EVM_OUTBOUND=1 pnpm exec vitest run test/evm-outbound.test.ts
 */

// sweepEvm is a controller-only operator escape hatch — deliberately NOT in the
// public @ic402/client IDL, so declare the minimal slice this suite drives.
const sweepResult = IDL.Variant({
  confirmed: IDL.Text,
  reverted: IDL.Text,
  pending: IDL.Text,
  err: IDL.Text,
});
const PendingDeposit = IDL.Record({
  txHash: IDL.Text,
  payer: IDL.Principal,
  payerEvmAddress: IDL.Text,
  chainId: IDL.Nat,
  token: IDL.Text,
  amount: IDL.Nat,
  createdAt: IDL.Int,
});
const exampleIdl = () =>
  IDL.Service({
    sweepEvm: IDL.Func([IDL.Nat, IDL.Text, IDL.Text, IDL.Nat], [sweepResult], []),
    // 2.22.0: controller-only recovery endpoints, also absent from the public client IDL.
    reconcileSession: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Text, err: IDL.Text })], []),
    setGatewayDerivationPath: IDL.Func(
      [IDL.Vec(IDL.Vec(IDL.Nat8))],
      [IDL.Variant({ ok: IDL.Null, err: IDL.Text })],
      [],
    ),
    listPendingEvmDeposits: IDL.Func([], [IDL.Vec(PendingDeposit)], ['query']),
    reconcileEvmDeposit: IDL.Func(
      [IDL.Text],
      [
        IDL.Variant({
          refunded: IDL.Text,
          reverted: IDL.Null,
          stillPending: IDL.Null,
          notFound: IDL.Null,
          err: IDL.Text,
        }),
      ],
      [],
    ),
  });

const ReceiptMode = IDL.Variant({
  confirmed: IDL.Null,
  reverted: IDL.Null,
  pendingThenConfirmed: IDL.Nat,
  inconsistent: IDL.Null,
  error: IDL.Null,
});
const FeeMode = IDL.Variant({
  consistent: IDL.Null,
  inconsistentOutlier: IDL.Null,
  unavailable: IDL.Null,
});
const SendMode = IDL.Variant({
  ok: IDL.Null,
  nonceTooHigh: IDL.Null,
  nonceTooLow: IDL.Null,
  insufficientFunds: IDL.Null,
});
const AuthStateMode = IDL.Variant({ unused: IDL.Null, used: IDL.Null, error: IDL.Null });
const mockIdl = () =>
  IDL.Service({
    setReceiptMode: IDL.Func([ReceiptMode], [], []),
    setFeeMode: IDL.Func([FeeMode], [], []),
    setSendMode: IDL.Func([SendMode], [], []),
    setPendingNonce: IDL.Func([IDL.Opt(IDL.Nat)], [], []),
    setLatestNonce: IDL.Func([IDL.Nat], [], []),
    setAuthStateMode: IDL.Func([AuthStateMode], [], []),
    reset: IDL.Func([], [], []),
    sentTxCount: IDL.Func([], [IDL.Nat], ['query']),
    getSentTxs: IDL.Func([], [IDL.Vec(IDL.Text)], ['query']),
    getReceiptPolls: IDL.Func([], [IDL.Nat], ['query']),
    getEthCalls: IDL.Func([], [IDL.Nat], ['query']),
  });

// The gasLimit field of a signed EIP-1559 tx (0x02 || rlp([chainId, nonce, maxPriorityFee,
// maxFee, gasLimit, ...])). Minimal RLP walk — enough for the five leading integers.
function gasLimitOf(rawTx: string): bigint {
  const b = Uint8Array.from(Buffer.from(rawTx.replace(/^0x/, ''), 'hex')).slice(1);
  const int = (at: number, n: number) => b.slice(at, at + n).reduce((a, x) => a * 256 + x, 0);
  let p = b[0] >= 0xf8 ? 1 + (b[0] - 0xf7) : 1;
  const items: Uint8Array[] = [];
  while (items.length < 5) {
    const c = b[p];
    if (c < 0x80) {
      items.push(b.slice(p, p + 1));
      p += 1;
    } else if (c <= 0xb7) {
      items.push(b.slice(p + 1, p + 1 + (c - 0x80)));
      p += 1 + (c - 0x80);
    } else {
      const ll = c - 0xb7;
      const l = int(p + 1, ll);
      items.push(b.slice(p + 1 + ll, p + 1 + ll + l));
      p += 1 + ll + l;
    }
  }
  return items[4].reduce((a, x) => a * 256n + BigInt(x), 0n);
}

const hexBytes = (h: string) => Uint8Array.from(Buffer.from(h.replace(/^0x/, ''), 'hex'));

// Base mainnet — EvmRpc.rpcServices supports it; the mock ignores service selection.
const CHAIN_ID = 8453n;
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const TO = '0x0000000000000000000000000000000000000001';
const AMOUNT = 1000n;

describe('ic402 EVM outbound (hermetic, mock EVM-RPC)', () => {
  let agent: HttpAgent;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let example: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let mock: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let full: any; // the example through the public client IDL (signX402Payment, openSession, …)
  let exampleId = '';
  let skip = false;

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      exampleId = getCanisterId('example');
      const mockId = getCanisterId('evm_rpc_mock'); // throws if the fixture isn't deployed
      example = Actor.createActor(exampleIdl, { agent, canisterId: exampleId });
      mock = Actor.createActor(mockIdl, { agent, canisterId: mockId });
      full = createExampleActor(agent, exampleId);
    } catch {
      skip = true;
    }
  });

  // Skip-enforcement: this suite needs the example RE-POINTED at the mock (a plain
  // `pnpm setup:local` wires the REAL evm_rpc), so it keys off its OWN flag — NOT
  // IC402_REQUIRE_REPLICA, which the test-integration job sets without this fixture.
  // Without the flag a missing fixture just warns, so `vitest run` stays green locally.
  it('mock EVM-RPC fixture is deployed (enforced when IC402_REQUIRE_EVM_OUTBOUND=1)', () => {
    if (process.env.IC402_REQUIRE_EVM_OUTBOUND === '1') {
      expect(skip).toBe(false);
    } else if (skip) {
      console.warn(
        '[evm-outbound] mock fixture not deployed — suite SKIPPED. Run `pnpm setup:local` then `bash scripts/setup-evm-outbound.sh`.',
      );
    }
  });

  const sweep = () => example.sweepEvm(CHAIN_ID, USDC, TO, AMOUNT);

  it('confirmed receipt (status=1) → #confirmed, and a real signed tx was broadcast exactly once', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ confirmed: null });
    const res = await sweep();
    expect(res).toHaveProperty('confirmed');
    // Broadcast genuinely happened (not a no-op) AND exactly once — and the bytes the canister
    // handed us are a real signed RLP tx (hex), proving the tECDSA-sign + RLP path actually ran.
    const sent: string[] = await mock.getSentTxs();
    expect(sent.length).toBe(1);
    expect(sent[0]).toMatch(/^0x[0-9a-fA-F]{2,}$/);
    expect(await mock.getReceiptPolls()).toBe(1n); // confirmed on the first poll
  });

  it('2.22.0: an ERC-20 transfer is signed with a 100_000 gas limit (65_000 left <10% for a first-time recipient)', async () => {
    if (skip) return;
    await mock.reset();
    const res = await sweep();
    expect(res).toHaveProperty('confirmed');
    const sent: string[] = await mock.getSentTxs();
    expect(gasLimitOf(sent[0])).toBe(100_000n);
  });

  it('reverted receipt (status=0) → #reverted, with the tx still broadcast once', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null });
    const res = await sweep();
    expect(res).toHaveProperty('reverted');
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('never-mined within the poll budget → #pending (caller must not deliver value)', async () => {
    if (skip) return;
    await mock.reset();
    // 99 ≫ the 4-poll confirm budget → every poll returns null (not yet mined).
    await mock.setReceiptMode({ pendingThenConfirmed: 99n });
    const res = await sweep();
    expect(res).toHaveProperty('pending');
    expect(await mock.sentTxCount()).toBe(1n);
    expect(await mock.getReceiptPolls()).toBe(4n); // exhausted the budget, then parked
  });

  it('pending then mined within the budget → #confirmed (multi-poll confirmation)', async () => {
    if (skip) return;
    await mock.reset();
    // null for 2 polls, then status=1 on poll 3 (inside the 4-poll budget).
    await mock.setReceiptMode({ pendingThenConfirmed: 2n });
    const res = await sweep();
    expect(res).toHaveProperty('confirmed');
    expect(await mock.getReceiptPolls()).toBe(3n);
  });

  it('inconsistent fee response (providers disagree, one outlier) → fee arm decodes + folds, no grief-park', async () => {
    if (skip) return;
    await mock.reset();
    // Providers return DIFFERENT fee histories (#Inconsistent), one a 9000-gwei outlier. This exercises
    // getFeeData's #Inconsistent arm end-to-end in the real canister: the Candid decode (the same arm
    // family that originally TRAPPED on RpcError), the per-provider base-fee fold, robustBaseFee, and
    // feeFromBase — all without trapping or parking the send. A clean #confirmed proves that path is
    // wired and survivable. NOTE: this end-to-end check can't distinguish robust-median from the
    // outlier (the mock's send always succeeds and feeFromBase clamps any base to 10_000 gwei), so the
    // SEC-2 property itself — robustBaseFee picks the LOWER MEDIAN, not the outlier — is asserted on
    // exact values in test/evmsender.test.mo.
    await mock.setFeeMode({ inconsistentOutlier: null });
    await mock.setReceiptMode({ confirmed: null });
    const res = await sweep();
    expect(res).toHaveProperty('confirmed');
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('ambiguous broadcast (#maybeSent via NonceTooHigh) → #pending with the tx recorded, not a hash-less failure (G5/G6)', async () => {
    if (skip) return;
    await mock.reset();
    // The send is ambiguous (NonceTooHigh) — the raw tx WAS dispatched and may have reached a
    // mempool. The library must surface it as pending WITH the tx hash, never as a clean
    // safe-to-retry failure. (Exercises the outbound #maybeSent path, which the G5/G6 inbound
    // change now mirrors: preserve the hash instead of collapsing to a hash-less #settlementFailed.)
    await mock.setSendMode({ nonceTooHigh: null });
    // 2.22.0: a #maybeSent is confirm-polled before it parks — keep the receipt unmined so it parks.
    await mock.setReceiptMode({ pendingThenConfirmed: 99n });
    const res = await sweep();
    expect(res).toHaveProperty('pending');
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('2.21.1: NonceTooLow after dispatch → #pending with the tx recorded, never a safe-to-retry failure', async () => {
    if (skip) return;
    await mock.reset();
    // A node whose copy of the tx arrives after another node's copy was included answers "nonce
    // too low" for that same tx. Treating it as "not broadcast" let callers send again.
    await mock.setSendMode({ nonceTooLow: null });
    await mock.setReceiptMode({ pendingThenConfirmed: 99n }); // 2.22.0: unmined, so it parks
    const res = await sweep();
    expect(res).toHaveProperty('pending');
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('2.22.0: a maybe-sent tx that DID land is confirmed by polling its hash, not parked', async () => {
    if (skip) return;
    await mock.reset();
    // NonceTooLow for this very tx (it was included) and its receipt is there: before 2.22.0 the
    // outbound #maybeSent parked as #pending with no poll, leaving a landed transfer to a manual
    // reconcile. Never re-sent either way.
    await mock.setSendMode({ nonceTooLow: null });
    await mock.setReceiptMode({ confirmed: null });
    const res = await sweep();
    expect(res).toHaveProperty('confirmed');
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('2.22.0: InsufficientFunds with the pending nonce unmoved → #err (nothing broadcast, safe to retry)', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSendMode({ insufficientFunds: null });
    await mock.setPendingNonce([7n]); // the re-read finds the same nonce: nobody holds the tx
    const res = await sweep();
    expect(res).toHaveProperty('err');
  });

  it('2.22.0: InsufficientFunds but the pending nonce moved past the tx → maybe sent (#pending), never a retry', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSendMode({ insufficientFunds: null }); // pending nonce advances per read
    await mock.setReceiptMode({ pendingThenConfirmed: 99n });
    const res = await sweep();
    expect(res).toHaveProperty('pending');
    expect(await mock.sentTxCount()).toBe(1n);
  });

  // ── Inbound EIP-3009 through the facilitator /settle route (2.22.0) ──
  //
  // The canister signs the authorization itself (signX402Payment, as test/integration.test.ts
  // does): its EvmSigner and the gateway recipient share key and path, so from == to == the
  // canister's address — the mock never moves funds, so that is fine. Base mainnet USDC with the
  // default domain ("USD Coin" / "2"), the chain config the fixture runs on.
  const raw = () => `http://${exampleId}.raw.localhost:4944`;
  async function settleBody(amount: bigint): Promise<string> {
    const payTo = (await full.gatewayRecipient())[0] as string;
    const signed = await full.signX402Payment(CHAIN_ID, USDC, payTo, amount, 'USD Coin', '2');
    const header = signed.ok.header as string;
    const paymentPayload = JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
    return JSON.stringify({
      x402Version: 2,
      paymentPayload,
      paymentRequirements: {
        scheme: 'exact',
        network: 'eip155:8453',
        amount: amount.toString(),
        asset: USDC,
        payTo,
        extra: { name: 'USD Coin', version: '2' },
      },
    });
  }
  async function postSettle(body: string): Promise<{ success: boolean; errorReason?: string }> {
    const res = await fetch(`${raw()}/settle`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
    });
    expect(res.status).toBe(200);
    return res.json();
  }

  it('2.22.0 (E5): the same authorization is broadcast once — a replay is refused as pending', async () => {
    if (skip) return;
    await mock.reset();
    const body = await settleBody(1000n);
    const first = await postSettle(body);
    expect(first.success).toBe(true);
    const replay = await postSettle(body);
    expect(replay.success).toBe(false);
    expect(replay.errorReason).toBe('settlement_pending');
    expect(await mock.sentTxCount()).toBe(1n); // not broadcast again
  });

  it('2.22.0 (E5): a send that failed BEFORE broadcasting frees the authorization for a retry', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setFeeMode({ unavailable: null }); // no fee data → refused before signing/sending
    const body = await settleBody(1000n);
    const first = await postSettle(body);
    expect(first.success).toBe(false);
    expect(first.errorReason).toBe('invalid_transaction_state');
    expect(await mock.sentTxCount()).toBe(0n);
    await mock.setFeeMode({ consistent: null });
    const retry = await postSettle(body);
    expect(retry.success).toBe(true);
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('2.22.0 (E7): a reverted transfer whose authorization is USED is pending (funds may have arrived), not "no funds moved"', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null });
    await mock.setAuthStateMode({ used: null }); // another tx executed it first
    const res = await postSettle(await settleBody(1000n));
    expect(res.success).toBe(false);
    expect(res.errorReason).toBe('settlement_pending');
    expect(await mock.getEthCalls()).toBe(1n);
  });

  it('2.22.0 (E7): a reverted transfer whose authorization is still UNUSED fails (no funds moved)', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null });
    await mock.setAuthStateMode({ unused: null });
    const res = await postSettle(await settleBody(1000n));
    expect(res.success).toBe(false);
    expect(res.errorReason).toBe('invalid_transaction_state');
  });

  // ── A parked tx that can never land (2.22.0, F1) ──

  // An EVM session-open signature from a canister-signed deposit authorization.
  async function evmSessionSig(deposit: bigint) {
    const payTo = (await full.gatewayRecipient())[0] as string;
    const signed = await full.signX402Payment(CHAIN_ID, USDC, payTo, deposit, 'USD Coin', '2');
    const a = signed.ok.authorization;
    const sig = hexBytes(a.signature as string);
    return {
      scheme: 'exact',
      network: 'eip155:8453',
      signature: [],
      publicKey: [randomBytes(32)],
      sender: a.from,
      nonce: [],
      authorization: [
        {
          from: a.from,
          to: a.to,
          value: a.value,
          validAfter: a.validAfter,
          validBefore: a.validBefore,
          nonce: hexBytes(a.nonce as string),
          v: sig[64],
          r: sig.slice(0, 32),
          s: sig.slice(32, 64),
        },
      ],
      asset: [],
    };
  }
  const sessionCfg = { maxDeposit: 50_000n, autoClose: false, idleTimeout: [] };

  it('2.22.0 (F1): a pending deposit whose nonce another tx took is dropped by reconcileEvmDeposit', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ pendingThenConfirmed: 999n }); // never mined
    const opened = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(opened).toHaveProperty('err'); // "Settlement pending …": tracked, no session
    // The mock echoes "0x" + the send's 1-based index, zero-padded: the first send after reset.
    const txHash = '0x' + '1'.padStart(64, '0');
    const deps: { txHash: string }[] = await example.listPendingEvmDeposits();
    expect(deps.map((d) => d.txHash)).toContain(txHash);
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('stillPending');
    await mock.setLatestNonce(1_000_000n); // the account has mined past that nonce
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('reverted'); // dropped
  });

  it('round 2 (F1): a receipt read that gives NO answer is never reported dropped', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ pendingThenConfirmed: 999n });
    expect(await full.openSession(sessionCfg, await evmSessionSig(50_000n))).toHaveProperty('err');
    const txHash = '0x' + '1'.padStart(64, '0');
    await mock.setLatestNonce(1_000_000n); // the nonce IS taken…
    // …but providers disagree, or error: a mined deposit read during lag looks like this. Before
    // round 2 both were "dropped" and, with the authorization read as unused, the tracker of a
    // deposit that may have landed was deleted.
    await mock.setReceiptMode({ inconsistent: null });
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('stillPending');
    await mock.setReceiptMode({ error: null });
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('stillPending');
    await mock.setReceiptMode({ pendingThenConfirmed: 999n }); // an agreed "no receipt"
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('reverted');
  });

  it('round 2 (F1): a dropped deposit whose authorization is used, or unreadable, is kept and reported', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ pendingThenConfirmed: 999n });
    expect(await full.openSession(sessionCfg, await evmSessionSig(50_000n))).toHaveProperty('err');
    const txHash = '0x' + '1'.padStart(64, '0');
    await mock.setLatestNonce(1_000_000n);
    await mock.setAuthStateMode({ used: null }); // another tx executed it (or it was cancelled)
    const used = await example.reconcileEvmDeposit(txHash);
    expect(used.err).toContain('used on chain');
    const deps: { txHash: string }[] = await example.listPendingEvmDeposits();
    expect(deps.map((d) => d.txHash)).toContain(txHash); // still tracked
    await mock.setAuthStateMode({ error: null });
    const unknown = await example.reconcileEvmDeposit(txHash);
    expect(unknown.err).toContain('could not be checked');
    await mock.setAuthStateMode({ unused: null });
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('reverted'); // clean up
  });

  it('round 2 (E5): the guard is kept when the transfer reverted — a replay is not broadcast', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null }); // authorization still unused (mock default)
    const body = await settleBody(1000n);
    expect((await postSettle(body)).success).toBe(false);
    expect((await postSettle(body)).success).toBe(false);
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('round 2 (E5): the guard is kept on a maybe-sent broadcast — a replay is not broadcast', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSendMode({ nonceTooHigh: null });
    await mock.setReceiptMode({ pendingThenConfirmed: 999n });
    const body = await settleBody(1000n);
    expect((await postSettle(body)).success).toBe(false);
    expect((await postSettle(body)).success).toBe(false);
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('round 2 (E7, E5): a reverted session deposit — pending if the authorization is used, failed if unused, never re-broadcast', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null });
    await mock.setAuthStateMode({ used: null });
    const used = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(used.err).toContain('Settlement pending');
    await mock.setAuthStateMode({ unused: null });
    const sig = await evmSessionSig(50_000n);
    const unused = await full.openSession(sessionCfg, sig);
    expect(unused.err).toContain('Settlement failed');
    const sent = await mock.sentTxCount();
    const replay = await full.openSession(sessionCfg, sig);
    expect(replay.err).toContain('already broadcast');
    expect(await mock.sentTxCount()).toBe(sent);
  });

  it('round 2: re-applying the current derivation path keeps the sender — its guard survives', async () => {
    if (skip) return;
    await mock.reset();
    const body = await settleBody(1000n);
    expect((await postSettle(body)).success).toBe(true);
    expect(await example.setGatewayDerivationPath([])).toHaveProperty('ok');
    await postSettle(body); // a rebuilt sender would have forgotten it and broadcast again
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('2.22.0 (F1): reconcileSession reports a parked close tx that appears not to have landed', async () => {
    if (skip) return;
    await mock.reset();
    const opened = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(opened).toHaveProperty('ok');
    await mock.setReceiptMode({ pendingThenConfirmed: 999n }); // the refund never mines
    const closed = await full.endSession(opened.ok.id);
    expect(closed).toHaveProperty('settlementPending'); // refund leg parked
    const still = await example.reconcileSession(opened.ok.id);
    expect(still.err).toContain('still pending');
    await mock.setLatestNonce(1_000_000n);
    const dead = await example.reconcileSession(opened.ok.id);
    expect(dead.err).toContain('appears not to have landed');
    expect(dead.err).toContain('verify on chain before forcing');
  });
});
