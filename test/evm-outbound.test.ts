import { describe, it, expect, beforeAll, beforeEach } from 'vitest';
import { randomBytes } from 'node:crypto';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { Secp256k1KeyIdentity } from '@icp-sdk/core/identity/secp256k1';
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
// 2.24.0: settleToSplit's argument and result (mirrors packages/client/src/idl.ts).
const PaymentSignatureIdl = IDL.Record({
  scheme: IDL.Text,
  network: IDL.Text,
  signature: IDL.Vec(IDL.Nat8),
  publicKey: IDL.Opt(IDL.Vec(IDL.Nat8)),
  sender: IDL.Text,
  nonce: IDL.Vec(IDL.Nat8),
  authorization: IDL.Opt(
    IDL.Record({
      from: IDL.Text,
      to: IDL.Text,
      value: IDL.Nat,
      validAfter: IDL.Nat,
      validBefore: IDL.Nat,
      nonce: IDL.Vec(IDL.Nat8),
      v: IDL.Nat8,
      r: IDL.Vec(IDL.Nat8),
      s: IDL.Vec(IDL.Nat8),
    }),
  ),
  asset: IDL.Opt(IDL.Text),
});
const PaymentResultIdl = IDL.Variant({
  ok: IDL.Record({
    id: IDL.Text,
    amount: IDL.Nat,
    token: IDL.Text,
    sender: IDL.Text,
    recipient: IDL.Text,
    network: IDL.Text,
    timestamp: IDL.Int,
    txHash: IDL.Opt(IDL.Text),
    sessionId: IDL.Opt(IDL.Text),
    refunded: IDL.Opt(IDL.Nat),
  }),
  insufficientFunds: IDL.Text,
  invalidSignature: IDL.Text,
  expired: IDL.Text,
  policyDenied: IDL.Text,
  tokenNotAccepted: IDL.Text,
  networkNotSupported: IDL.Text,
  settlementFailed: IDL.Text,
  settlementPending: IDL.Text,
  reputationTooLow: IDL.Nat,
  depositBelowMinimum: IDL.Nat,
});

const exampleIdl = () =>
  IDL.Service({
    sweepEvm: IDL.Func([IDL.Nat, IDL.Text, IDL.Text, IDL.Nat], [sweepResult], []),
    // 2.23.1: lift every EVM payer cooldown (controller-only).
    clearEvmPayerCooldowns: IDL.Func([], [IDL.Nat], []),
    liftEvmPayerCooldown: IDL.Func([IDL.Nat, IDL.Text, IDL.Text], [IDL.Bool], []),
    // 2.23.2: lift a chain's gas stop (controller-only).
    liftEvmGasStop: IDL.Func([IDL.Nat], [IDL.Bool], []),
    // 2.24.0: split payees (controller-only).
    setEvmSplitCeiling: IDL.Func(
      [IDL.Opt(IDL.Nat)],
      [IDL.Variant({ ok: IDL.Null, err: IDL.Text })],
      [],
    ),
    settleToSplit: IDL.Func(
      [PaymentSignatureIdl, IDL.Opt(IDL.Nat), IDL.Text, IDL.Nat],
      [PaymentResultIdl],
      [],
    ),
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
  undecodable: IDL.Null,
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
  insufficientFundsInconsistent: IDL.Null,
  undecodable: IDL.Null,
});
const AuthStateMode = IDL.Variant({
  unused: IDL.Null,
  used: IDL.Null,
  error: IDL.Null,
  undecodable: IDL.Null,
});
const SimulationMode = IDL.Variant({
  ok: IDL.Null,
  reverted: IDL.Null,
  revertedInconsistent: IDL.Null,
  inconsistent: IDL.Null,
  error: IDL.Null,
});
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
    setSimulationMode: IDL.Func([SimulationMode], [], []),
    setHoldSimulations: IDL.Func([IDL.Bool], [], []),
    getSimulations: IDL.Func([], [IDL.Nat], ['query']),
    getLastSimulation: IDL.Func(
      [],
      [
        IDL.Opt(
          IDL.Record({
            to: IDL.Opt(IDL.Text),
            from: IDL.Opt(IDL.Text),
            gas: IDL.Opt(IDL.Nat),
            input: IDL.Text,
          }),
        ),
      ],
      ['query'],
    ),
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

  // 2.23.1: most payments in this suite come from one payer (the canister signs for itself), and a
  // sent transfer that reverts or stays unconfirmed cools that payer down (an hour, or 5 minutes).
  // Several tests do that on purpose, so every test starts with no payer cooling down.
  beforeEach(async () => {
    if (skip) return;
    await example.clearEvmPayerCooldowns();
    await example.liftEvmGasStop(CHAIN_ID); // 2.23.2: an InsufficientFunds test stops the chain
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
    // 2.23.2: any send that could not pay gas stops every send on the chain (GasStops).
    expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(true);
  });

  it('2.22.0: InsufficientFunds but the pending nonce moved past the tx → maybe sent (#pending), never a retry', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSendMode({ insufficientFunds: null }); // pending nonce advances per read
    await mock.setReceiptMode({ pendingThenConfirmed: 99n });
    const res = await sweep();
    expect(res).toHaveProperty('pending');
    expect(await mock.sentTxCount()).toBe(1n);
    expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(false); // 2.23.2: it may be sent — no stop
  });

  it('2.23.2: providers that disagree, one reporting no gas and none accepting, stop the chain too; the send stays maybe-sent', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSendMode({ insufficientFundsInconsistent: null });
    await mock.setReceiptMode({ pendingThenConfirmed: 99n });
    const res = await sweep();
    expect(res).toHaveProperty('pending'); // maybe sent: polled, never re-sent
    expect(await mock.sentTxCount()).toBe(1n);
    expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(true);
  });

  it('2.23.2: only a controller can lift a gas stop', async () => {
    if (skip) return;
    const stranger = Actor.createActor(exampleIdl, {
      agent: await HttpAgent.create({
        identity: Secp256k1KeyIdentity.generate(),
        host: 'http://localhost:4944',
        shouldFetchRootKey: true,
      }),
      canisterId: exampleId,
    });
    await expect(stranger.liftEvmGasStop(CHAIN_ID)).rejects.toThrow();
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
    expect(first.errorReason).toBe('settlement_retry'); // 2.23.1: nothing sent, retry the same payment
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
    // 2.23.1: any revert of a sent transfer cools the payer down, whatever the token then says.
    expect(await example.clearEvmPayerCooldowns()).toBe(1n);
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

  // ── Simulate before signing; one inbound transfer in flight per payer (2.23.1) ──
  //
  // Every payment in this suite is signed by the canister for itself, so they all share one payer.

  it('2.23.1: a transfer the token refuses in simulation is not signed or sent; the same payment goes through once it would succeed', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSimulationMode({ reverted: null }); // e.g. a payer holding no USDC
    const body = await settleBody(1000n);
    const refused = await postSettle(body);
    expect(refused.success).toBe(false);
    expect(refused.errorReason).toBe('invalid_transaction_state');
    expect(await mock.getSimulations()).toBe(1n);
    expect(await mock.sentTxCount()).toBe(0n);
    await mock.setSimulationMode({ ok: null });
    // Nothing was sent, so the authorization claim and the payer slot were both freed.
    expect((await postSettle(body)).success).toBe(true);
    expect(await mock.sentTxCount()).toBe(1n);
  });

  it('2.23.1: a simulation with no agreed answer is refused too — nothing signed or sent', async () => {
    if (skip) return;
    for (const [mode, reason] of [
      [{ revertedInconsistent: null }, 'invalid_transaction_state'], // every provider reverts: final
      [{ inconsistent: null }, 'settlement_retry'], // no agreed answer: retry the same payment
      [{ error: null }, 'settlement_retry'],
    ] as const) {
      await mock.reset();
      await mock.setSimulationMode(mode);
      const res = await postSettle(await settleBody(1000n));
      expect(res.success).toBe(false);
      expect(res.errorReason).toBe(reason);
      expect(await mock.getSimulations()).toBe(1n);
      expect(await mock.sentTxCount()).toBe(0n);
    }
  });

  it('2.23.1: the simulation is the exact call then sent, against the paid token', async () => {
    if (skip) return;
    await mock.reset();
    expect((await postSettle(await settleBody(1000n))).success).toBe(true);
    const [sim] = await mock.getLastSimulation();
    expect((sim.to[0] as string).toLowerCase()).toBe(USDC.toLowerCase());
    // Run as the broadcast runs: from the canister's own address, with its gas limit.
    const self = (await full.gatewayRecipient())[0] as string;
    expect((sim.from[0] as string).toLowerCase()).toBe(self.toLowerCase());
    expect(sim.gas).toEqual([120_000n]);
    const [rawTx] = (await mock.getSentTxs()) as string[];
    expect(rawTx.toLowerCase()).toContain((sim.input as string).replace(/^0x/, '').toLowerCase());
  });

  it('2.23.1: a session deposit the token refuses in simulation opens nothing and sends nothing', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSimulationMode({ reverted: null });
    const res = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(res.err).toContain('simulation before signing reverted');
    expect(await mock.sentTxCount()).toBe(0n);
  });

  it('2.23.2: a broadcast the canister cannot pay gas for stops payments and sends on the chain, before signing (a payment before its simulation)', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSendMode({ insufficientFunds: null });
    await mock.setPendingNonce([7n]); // the re-read finds the same nonce: nothing was sent
    // The simulation passes (it has no gas price), so the deposit is signed; the broadcast fails.
    const first = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(first.err).toContain('Insufficient ETH for gas');
    expect(first.err).toContain('refused for the next 10 minutes');
    expect(await mock.getSimulations()).toBe(1n);
    expect(await mock.sentTxCount()).toBe(1n);
    // Funded or not, the chain stays stopped: refused before the simulation, so no check, no
    // signature and no send.
    await mock.setSendMode({ ok: null });
    await mock.setPendingNonce([]);
    const body = await settleBody(1000n);
    const stopped = await postSettle(body);
    expect(stopped.success).toBe(false);
    expect(stopped.errorReason).toBe('invalid_transaction_state'); // the operator's to fix: final
    const open = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(open.err).toContain('cannot pay gas on chain 8453');
    const swept = await sweep(); // outbound sends too
    expect(swept.err).toContain('cannot pay gas on chain 8453');
    expect(await mock.getSimulations()).toBe(1n);
    expect(await mock.sentTxCount()).toBe(1n);
    // The operator lifts the stop once the address is funded; the same payment then goes through,
    // since nothing of it was held.
    expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(true);
    expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(false);
    expect((await postSettle(body)).success).toBe(true);
    expect(await mock.sentTxCount()).toBe(2n);
    expect(await example.clearEvmPayerCooldowns()).toBe(0n); // the payer was never at fault
  });

  it('a payer close whose refund is signed but refused for gas parks it with its tx; nothing is sent again until the operator reconciles', async () => {
    if (skip) return;
    await mock.reset();
    const opened = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(opened).toHaveProperty('ok');
    const sends = await mock.sentTxCount(); // the deposit
    await mock.setSendMode({ insufficientFunds: null });
    await mock.setPendingNonce([7n]); // the re-read finds the same nonce
    try {
      const first = await full.endSession(opened.ok.id);
      // Two providers refused the signed refund, but a third may have accepted it: maybe sent, so
      // the session is parked under that tx. Before, it reopened "safe to retry", and the next close
      // (the payer's, or the sweep's once the session idled out and the stop ended) signed it again.
      const [rawRefund] = ((await mock.getSentTxs()) as string[]).slice(-1);
      const refundHash = '0x' + Buffer.from(keccak_256(hexBytes(rawRefund))).toString('hex');
      expect(first.settlementPending).toContain('refused it for lack of gas');
      expect(first.settlementPending).toContain(refundHash);
      expect(await mock.sentTxCount()).toBe(sends + 1n);
      const again = await full.endSession(opened.ok.id);
      expect(again.settlementFailed).toContain('a close is in progress (#closing)');
      // Funded and lifted: still nothing is sent; the operator's confirm-only reconcile finds it mined.
      await mock.setSendMode({ ok: null });
      await mock.setPendingNonce([]);
      expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(true);
      const reconciled = await example.reconcileSession(opened.ok.id);
      expect(reconciled.ok).toContain('Refund confirmed on-chain');
      expect(reconciled.ok).toContain(refundHash);
      expect(await mock.sentTxCount()).toBe(sends + 1n);
    } finally {
      // Whatever failed above, free the payer's one session slot for the tests after this one.
      await mock.setSendMode({ ok: null });
      await mock.setPendingNonce([]);
      await example.liftEvmGasStop(CHAIN_ID);
      await full.endSession(opened.ok.id); // refused once parked or closed
    }
  });

  // ── Split payees (2.24.0) ──
  //
  // The 0xSplits push split v2.2 (no owner) paying a finder its share and the canister the rest.
  // Computed here independently of the canister's EvmSplits (same formula; pinned by vectors the
  // deployed factory returns), so the two cross-check.
  const FINDER = '0x9f8e7d6c5b4a39281706fedcba9876543210fedc';
  function splitAddress(finder: string, seller: string, shareBps: number): string {
    const w = (n: bigint | number) => BigInt(n).toString(16).padStart(64, '0');
    const a = (x: string) => x.toLowerCase().replace(/^0x/, '').padStart(64, '0');
    const enc =
      w(0x40) +
      w(0) +
      w(0x80) +
      w(0xe0) +
      w(10000) +
      w(0) +
      w(2) +
      a(finder) +
      a(seller) +
      w(2) +
      w(shareBps) +
      w(10000 - shareBps) +
      w(0);
    const inner = Buffer.from(keccak_256(Buffer.from(enc, 'hex'))).toString('hex');
    const pre =
      'ff' +
      '8e8eb0cc6ae34a38b67d5cf91aca38f60bc3ecf4' +
      inner +
      '45b1cff75f6e3ad2b2df0c59635a8d507669cada88ba862dcce929e591ea7356';
    return (
      '0x' +
      Buffer.from(keccak_256(Buffer.from(pre, 'hex')))
        .toString('hex')
        .slice(24)
    );
  }
  // A canister-signed authorization paying `payTo`, as a PaymentSignature.
  async function sigTo(payTo: string, amount: bigint) {
    const signed = await full.signX402Payment(CHAIN_ID, USDC, payTo, amount, 'USD Coin', '2');
    const au = signed.ok.authorization;
    const sig = hexBytes(au.signature as string);
    return {
      scheme: 'exact',
      network: 'eip155:8453',
      signature: [],
      publicKey: [],
      sender: au.from,
      nonce: [],
      authorization: [
        {
          from: au.from,
          to: au.to,
          value: au.value,
          validAfter: au.validAfter,
          validBefore: au.validBefore,
          nonce: hexBytes(au.nonce as string),
          v: sig[64],
          r: sig.slice(0, 32),
          s: sig.slice(32, 64),
        },
      ],
      asset: [USDC],
    };
  }

  it('2.24.0: split payees are off by default — a payment to a split is refused before anything is signed', async () => {
    if (skip) return;
    await mock.reset();
    expect(await example.setEvmSplitCeiling([])).toHaveProperty('ok');
    const self = (await full.gatewayRecipient())[0] as string;
    const split = splitAddress(FINDER, self, 500);
    const res = await example.settleToSplit(await sigTo(split, 1000n), [1000n], FINDER, 500n);
    expect(res.policyDenied).toContain('Split payees are off');
    expect(await mock.getSimulations()).toBe(0n);
    expect(await mock.sentTxCount()).toBe(0n);
  });

  it('2.24.0: with a ceiling set, a payment to the exact split settles; the transfer pays the split and the receipt names it', async () => {
    if (skip) return;
    await mock.reset();
    expect(await example.setEvmSplitCeiling([1000n])).toHaveProperty('ok');
    const self = (await full.gatewayRecipient())[0] as string;
    const split = splitAddress(FINDER, self, 500);
    // Signed with the split spelled in upper case: the receipt still names the canonical form.
    const res = await example.settleToSplit(
      await sigTo('0x' + split.slice(2).toUpperCase(), 1000n),
      [1000n],
      FINDER,
      500n,
    );
    expect(res.ok.recipient).toBe(split);
    expect(res.ok.amount).toBe(1000n); // the full payment; the canister's share arrives on distribution
    const [rawTx] = (await mock.getSentTxs()) as string[];
    expect(rawTx.toLowerCase()).toContain(split.slice(2)); // transferWithAuthorization(…, to = split, …)
    const [sim] = await mock.getLastSimulation();
    expect((sim.input as string).toLowerCase()).toContain(split.slice(2));
    expect(await example.setEvmSplitCeiling([])).toHaveProperty('ok');
  });

  it('2.24.0: another split, a share over the ceiling, or a bad ceiling is refused; plain settle still refuses a split', async () => {
    if (skip) return;
    await mock.reset();
    expect(await example.setEvmSplitCeiling([1000n])).toHaveProperty('ok');
    const self = (await full.gatewayRecipient())[0] as string;
    const split = splitAddress(FINDER, self, 500);
    // Signed to the 500-bps split, claimed at 600: the recomputed split differs.
    const wrong = await example.settleToSplit(await sigTo(split, 1000n), [1000n], FINDER, 600n);
    expect(wrong.invalidSignature).toContain('must be the split');
    const over = await example.settleToSplit(
      await sigTo(splitAddress(FINDER, self, 1001), 1000n),
      [1000n],
      FINDER,
      1001n,
    );
    expect(over.policyDenied).toContain('ceiling of 1000');
    // settle's own recipient check is unchanged: a split is not this canister (the HTTP /settle
    // route, which calls settle).
    const signed = await full.signX402Payment(CHAIN_ID, USDC, split, 1000n, 'USD Coin', '2');
    const plain = await postSettle(
      JSON.stringify({
        x402Version: 2,
        paymentPayload: JSON.parse(
          Buffer.from(signed.ok.header as string, 'base64').toString('utf8'),
        ),
        paymentRequirements: {
          scheme: 'exact',
          network: 'eip155:8453',
          amount: '1000',
          asset: USDC,
          payTo: split,
          extra: { name: 'USD Coin', version: '2' },
        },
      }),
    );
    expect(plain.success).toBe(false);
    expect(await mock.getSimulations()).toBe(0n);
    expect(await mock.sentTxCount()).toBe(0n);
    expect(await example.setEvmSplitCeiling([10000n])).toHaveProperty('err');
    expect(await example.setEvmSplitCeiling([0n])).toHaveProperty('err');
    expect(await example.setEvmSplitCeiling([])).toHaveProperty('ok');
  });

  it('2.24.0: only a controller can set the ceiling or settle to a split', async () => {
    if (skip) return;
    const stranger = Actor.createActor(exampleIdl, {
      agent: await HttpAgent.create({
        identity: Secp256k1KeyIdentity.generate(),
        host: 'http://localhost:4944',
        shouldFetchRootKey: true,
      }),
      canisterId: exampleId,
    });
    await expect(stranger.setEvmSplitCeiling([1000n])).rejects.toThrow();
    const self = (await full.gatewayRecipient())[0] as string;
    await expect(
      stranger.settleToSplit(
        await sigTo(splitAddress(FINDER, self, 500), 1000n),
        [1000n],
        FINDER,
        500n,
      ),
    ).rejects.toThrow();
  });

  // Poll until `cond` holds (a held simulation has been reached), or fail.
  async function until(cond: () => Promise<boolean>): Promise<void> {
    for (let k = 0; k < 100; k++) {
      if (await cond()) return;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error('condition not reached');
  }
  const simulationReached = async () => (await mock.getSimulations()) === 1n;

  it('2.23.1: one transfer in flight per payer — a second payment from the same wallet is refused as busy, then goes through', async () => {
    if (skip) return;
    await mock.reset();
    const b1 = await settleBody(1000n);
    const b2 = await settleBody(1000n);
    await mock.setHoldSimulations(true); // the first settle stays in flight, holding the payer's slot
    const first = postSettle(b1);
    try {
      await until(simulationReached);
      const busy = await postSettle(b2);
      expect(busy.success).toBe(false);
      expect(busy.errorReason).toBe('settlement_retry'); // busy: nothing sent, retry the same payment
      // The refusal left the first payment's slot held: a third is busy too.
      expect((await postSettle(await settleBody(1000n))).errorReason).toBe('settlement_retry');
    } finally {
      await mock.setHoldSimulations(false);
    }
    expect((await first).success).toBe(true);
    expect(await mock.getSimulations()).toBe(1n); // the busy one was refused before its simulation
    expect(await mock.sentTxCount()).toBe(1n);
    // The slot was freed when the first returned: the refused payment goes through unchanged.
    expect((await postSettle(b2)).success).toBe(true);
    expect(await mock.sentTxCount()).toBe(2n);
  });

  it('2.23.1: settle and session open share the payer slot', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null }); // the deposit reverts, so no session is left open
    await mock.setHoldSimulations(true);
    const opening = full.openSession(sessionCfg, await evmSessionSig(50_000n));
    try {
      await until(simulationReached); // the open holds the payer's slot
      const busy = await postSettle(await settleBody(1000n));
      expect(busy.success).toBe(false);
      expect(busy.errorReason).toBe('settlement_retry');
    } finally {
      await mock.setHoldSimulations(false);
    }
    expect((await opening).err).toContain('Settlement failed');
    expect(await mock.getSimulations()).toBe(1n);
    await mock.setReceiptMode({ confirmed: null });
    // Its deposit reverted with the authorization unused, which cools the payer down; lift that
    // to see that the open also freed the slot when it returned.
    expect(await example.clearEvmPayerCooldowns()).toBe(1n);
    expect((await postSettle(await settleBody(1000n))).success).toBe(true);
  });

  // A payment on a paid route carries the server nonce of its 402 challenge
  // (accepted.extra.ic402Nonce), as @ic402/client sends it.
  async function searchPayment(): Promise<string> {
    const challenge = await fetch(`${raw()}/search?q=x`);
    expect(challenge.status).toBe(402);
    const req = (await challenge.json()).accepts.find(
      (a: { network: string }) => a.network === 'eip155:8453',
    );
    const signed = await full.signX402Payment(
      CHAIN_ID,
      USDC,
      req.payTo,
      BigInt(req.amount),
      'USD Coin',
      '2',
    );
    const payload = JSON.parse(Buffer.from(signed.ok.header as string, 'base64').toString('utf8'));
    payload.accepted = req;
    return Buffer.from(JSON.stringify(payload)).toString('base64');
  }
  const paySearch = (header: string) =>
    fetch(`${raw()}/search?q=x`, { headers: { 'PAYMENT-SIGNATURE': header } });

  it('2.23.1: a payment refused as busy frees its server nonce — retried unchanged, it goes through', async () => {
    if (skip) return;
    await mock.reset();
    const h1 = await searchPayment();
    const h2 = await searchPayment();
    await mock.setHoldSimulations(true);
    const first = paySearch(h1);
    try {
      await until(simulationReached);
      expect((await paySearch(h2)).status).toBe(402); // busy
    } finally {
      await mock.setHoldSimulations(false);
    }
    expect((await first).status).toBe(200);
    expect((await paySearch(h2)).status).toBe(200); // its nonce was unlocked, not left in flight
    expect(await mock.sentTxCount()).toBe(2n);
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
    expect(await example.clearEvmPayerCooldowns()).toBe(1n); // 2.23.1: the payer is held meanwhile
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
    const replay = await postSettle(body);
    expect(replay.success).toBe(false);
    expect(replay.errorReason).toBe('settlement_pending'); // the guard, checked before the cooldown
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
    expect(await example.clearEvmPayerCooldowns()).toBe(1n); // 2.23.1: any revert cools the payer
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
  // ── A reply the canister cannot decode (the mock's #undecodable modes) ──
  //
  // The canister traps decoding the reply after its await, where no `catch` runs; the call that made
  // the outcall is rejected, and that reject reaches whoever awaited it.

  it('a close whose receipt reply cannot be decoded parks the refund under its tx, and reconcileSession confirms it', async () => {
    if (skip) return;
    await mock.reset();
    const opened = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(opened).toHaveProperty('ok');
    const sends: bigint = await mock.sentTxCount(); // the deposit
    await mock.setReceiptMode({ undecodable: null });
    try {
      // The refund was broadcast, then its confirm call was rejected. Before, the reject went up
      // through the close: the session rested #closing with no parked tx, and reconcileSession
      // answered "no parked tx — use forceResolveSession".
      const closed = await full.endSession(opened.ok.id);
      const refundHash = '0x' + (sends + 1n).toString().padStart(64, '0'); // the mock's echo
      expect(closed.settlementPending).toContain(refundHash);
      await mock.setReceiptMode({ confirmed: null });
      const reconciled = await example.reconcileSession(opened.ok.id);
      expect(reconciled.ok).toContain('Refund confirmed on-chain');
      expect(reconciled.ok).toContain(refundHash);
      expect(await mock.sentTxCount()).toBe(sends + 1n); // sent once
    } finally {
      await mock.setReceiptMode({ confirmed: null });
      await full.endSession(opened.ok.id); // refused once parked or closed
    }
  });

  it('a close whose send reply cannot be decoded parks the refund as maybe broadcast; the send lock is released', async () => {
    if (skip) return;
    await mock.reset();
    const opened = await full.openSession(sessionCfg, await evmSessionSig(50_000n));
    expect(opened).toHaveProperty('ok');
    const sends: bigint = await mock.sentTxCount();
    await mock.setSendMode({ undecodable: null });
    try {
      // The mock had the raw tx before its reply failed: it may be in a mempool, with no hash back.
      const closed = await full.endSession(opened.ok.id);
      expect(closed.settlementPending).toContain('may have been broadcast');
      expect(await mock.sentTxCount()).toBe(sends + 1n);
      const reconciled = await example.reconcileSession(opened.ok.id);
      expect(reconciled.err).toContain('no tx hash came back');
      // The sender trapped after taking its single-flight send lock; its `finally` released it.
      await mock.setSendMode({ ok: null });
      expect(await sweep()).toHaveProperty('confirmed');
    } finally {
      await mock.setSendMode({ ok: null });
      await full.endSession(opened.ok.id);
    }
  });

  // A pending session deposit: tracked by reconcileEvmDeposit under the first send's hash.
  async function pendingDeposit(): Promise<string> {
    await mock.setReceiptMode({ pendingThenConfirmed: 999n });
    expect(await full.openSession(sessionCfg, await evmSessionSig(50_000n))).toHaveProperty('err');
    expect(await example.clearEvmPayerCooldowns()).toBe(1n); // 2.23.1: the payer is held meanwhile
    return '0x' + '1'.padStart(64, '0');
  }
  const tracked = async (txHash: string) =>
    ((await example.listPendingEvmDeposits()) as { txHash: string }[]).some(
      (d) => d.txHash === txHash,
    );

  it('reconcileEvmDeposit keeps a deposit tracked when its receipt read is rejected', async () => {
    if (skip) return;
    await mock.reset();
    const txHash = await pendingDeposit();
    await mock.setReceiptMode({ undecodable: null });
    // Before, the entry was removed before the read, and the reject lost it: a retry answered
    // #notFound, and pendingEvmDepositCount() read 0 for the drain check before an upgrade.
    const res = await example.reconcileEvmDeposit(txHash);
    expect(res.err).toContain('rejected');
    expect(await tracked(txHash)).toBe(true);
    await mock.setReceiptMode({ pendingThenConfirmed: 999n });
    await mock.setLatestNonce(1_000_000n);
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('reverted'); // clean up
  });

  it('reconcileEvmDeposit keeps a deposit tracked when its authorization read is rejected', async () => {
    if (skip) return;
    await mock.reset();
    const txHash = await pendingDeposit();
    await mock.setLatestNonce(1_000_000n); // its nonce was taken and no receipt: it appears dropped
    await mock.setAuthStateMode({ undecodable: null });
    const res = await example.reconcileEvmDeposit(txHash);
    expect(res.err).toContain('could not be checked');
    expect(await tracked(txHash)).toBe(true);
    await mock.setAuthStateMode({ unused: null });
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('reverted'); // clean up
  });

  it('reconcileEvmDeposit does not restore a deposit whose refund send was rejected: the refund may have gone out', async () => {
    if (skip) return;
    await mock.reset();
    const txHash = await pendingDeposit();
    await mock.setReceiptMode({ confirmed: null }); // the deposit mined
    await mock.setSendMode({ undecodable: null }); // the refund's send reply cannot be decoded
    const sends: bigint = await mock.sentTxCount();
    const res = await example.reconcileEvmDeposit(txHash);
    expect(res.err).toContain('may have been broadcast');
    expect(await mock.sentTxCount()).toBe(sends + 1n);
    expect(await tracked(txHash)).toBe(false);
    await mock.setSendMode({ ok: null });
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('notFound'); // no second refund
    expect(await mock.sentTxCount()).toBe(sends + 1n);
  });

  it('reconcileEvmDeposit does not restore a deposit whose refund was signed but refused for gas: it may have gone out', async () => {
    if (skip) return;
    await mock.reset();
    const txHash = await pendingDeposit();
    await mock.setReceiptMode({ confirmed: null }); // the deposit mined
    await mock.setSendMode({ insufficientFunds: null });
    await mock.setPendingNonce([7n]); // the re-read finds the same nonce
    const sends: bigint = await mock.sentTxCount();
    // Two providers refused the signed refund, but a third may have accepted it. Before, the entry
    // was restored ("nothing broadcast"), and the next reconcile signed the refund again.
    const res = await example.reconcileEvmDeposit(txHash);
    const [rawRefund] = ((await mock.getSentTxs()) as string[]).slice(-1);
    const refundHash = '0x' + Buffer.from(keccak_256(hexBytes(rawRefund))).toString('hex');
    expect(res.err).toContain('may have gone out');
    expect(res.err).toContain(refundHash);
    expect(await mock.sentTxCount()).toBe(sends + 1n);
    expect(await tracked(txHash)).toBe(false);
    await mock.setSendMode({ ok: null });
    await mock.setPendingNonce([]);
    expect(await example.liftEvmGasStop(CHAIN_ID)).toBe(true);
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('notFound'); // no second refund
    expect(await mock.sentTxCount()).toBe(sends + 1n);
  });

  it('reconcileEvmDeposit keeps a reverted deposit whose authorization is used, or unreadable, and reports it', async () => {
    if (skip) return;
    await mock.reset();
    const txHash = await pendingDeposit();
    await mock.setReceiptMode({ reverted: null });
    // Anyone can submit the authorization: another tx may have executed it first, and the deposit
    // arrived. Before, the revert alone dropped the entry, and the runbook said "re-sign".
    await mock.setAuthStateMode({ used: null });
    expect((await example.reconcileEvmDeposit(txHash)).err).toContain('used on chain');
    expect(await tracked(txHash)).toBe(true);
    await mock.setAuthStateMode({ error: null });
    expect((await example.reconcileEvmDeposit(txHash)).err).toContain('could not be checked');
    expect(await tracked(txHash)).toBe(true);
    await mock.setAuthStateMode({ unused: null });
    expect(await example.reconcileEvmDeposit(txHash)).toHaveProperty('reverted');
    expect(await tracked(txHash)).toBe(false);
  });

  // ── Cooldown and the budget of refused checks (2.23.1). Keep these last: the budget test leaves
  // the budget spent for about a minute. ──

  // An authorization from another payer: the canister's signer at another derivation path, so the
  // cooldown it triggers leaves the suite's usual payer alone. EIP-712 hashed here, signed there.
  const OTHER_PATH = [Uint8Array.of(0x23, 0x01)];
  const u256 = (n: bigint) => Buffer.from(n.toString(16).padStart(64, '0'), 'hex');
  const word = (a: string) =>
    Buffer.from(a.replace(/^0x/, '').toLowerCase().padStart(64, '0'), 'hex');
  const k256 = (b: Uint8Array) => Buffer.from(keccak_256(b));
  // An EIP-3009 authorization signed by the canister's signer at `path`, for `value` to the gateway.
  async function otherPayerAuthorization(path: Uint8Array[], value: bigint) {
    const payTo = (await full.gatewayRecipient())[0] as string;
    const from = (await full.evmAddressAt(path)).ok as string;
    const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const nonce = randomBytes(32);
    const text = (t: string) => Buffer.from(t);
    const domainSeparator = k256(
      Buffer.concat([
        k256(
          text(
            'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)',
          ),
        ),
        k256(text('USD Coin')),
        k256(text('2')),
        u256(CHAIN_ID),
        word(USDC),
      ]),
    );
    const structHash = k256(
      Buffer.concat([
        k256(
          text(
            'TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)',
          ),
        ),
        word(from),
        word(payTo),
        u256(value),
        u256(0n),
        u256(validBefore),
        nonce,
      ]),
    );
    const signed = await full.signTypedDataAt(path, domainSeparator, structHash);
    return { from, payTo, validBefore, nonce, signature: signed.ok.signature as string };
  }

  async function otherPayerSettleBody(path: Uint8Array[] = OTHER_PATH): Promise<string> {
    const a = await otherPayerAuthorization(path, 1000n);
    const body = JSON.parse(await settleBody(1000n));
    body.paymentPayload.payload = {
      signature: a.signature,
      authorization: {
        from: a.from,
        to: a.payTo,
        value: '1000',
        validAfter: '0',
        validBefore: a.validBefore.toString(),
        nonce: '0x' + a.nonce.toString('hex'),
      },
    };
    return JSON.stringify(body);
  }

  // An EVM session-open signature from another payer (see evmSessionSig).
  async function otherPayerSessionSig(path: Uint8Array[], deposit: bigint) {
    const a = await otherPayerAuthorization(path, deposit);
    const sig = hexBytes(a.signature);
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
          to: a.payTo,
          value: deposit,
          validAfter: 0n,
          validBefore: a.validBefore,
          nonce: a.nonce,
          v: sig[64],
          r: sig.slice(0, 32),
          s: sig.slice(32, 64),
        },
      ],
      asset: [],
    };
  }

  it('2.23.1: a payer whose transfer reverts with its authorization unused is cooled down; others are not', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null }); // passes the simulation, reverts, authorization unused
    const first = await postSettle(await otherPayerSettleBody());
    expect(first.success).toBe(false);
    expect(first.errorReason).toBe('invalid_transaction_state');
    expect(await mock.sentTxCount()).toBe(1n);
    const next = await postSettle(await otherPayerSettleBody());
    expect(next.success).toBe(false);
    expect(next.errorReason).toBe('unexpected_settle_error'); // cooling down: final, not "retry"
    expect(await mock.getSimulations()).toBe(1n); // refused before its simulation
    expect(await mock.sentTxCount()).toBe(1n);
    await mock.setReceiptMode({ confirmed: null });
    expect((await postSettle(await settleBody(1000n))).success).toBe(true); // the usual payer is not cooled
    expect(await example.clearEvmPayerCooldowns()).toBe(1n);
    expect((await postSettle(await otherPayerSettleBody())).success).toBe(true); // lifted
  });

  it('2.23.1: an asset spelled without 0x still cools the payer down after a revert', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ reverted: null });
    const body = JSON.parse(await settleBody(1000n));
    const bare = USDC.replace(/^0x/, '');
    body.paymentRequirements.asset = bare;
    body.paymentPayload.accepted.asset = bare;
    const res = await postSettle(JSON.stringify(body));
    expect(res.errorReason).toBe('invalid_transaction_state'); // the token was read: authorization unused
    expect(await mock.getEthCalls()).toBe(1n);
    expect(await example.clearEvmPayerCooldowns()).toBe(1n);
  });

  it('2.23.1: a payer whose transfer is unconfirmed after the polls is held; an operator can lift one payer', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setReceiptMode({ pendingThenConfirmed: 999n });
    expect((await postSettle(await settleBody(1000n))).errorReason).toBe('settlement_pending');
    await mock.setReceiptMode({ confirmed: null });
    const held = await postSettle(await settleBody(1000n));
    expect(held.errorReason).toBe('unexpected_settle_error'); // held: final for now, nothing sent
    expect(await mock.sentTxCount()).toBe(1n);
    const self = (await full.gatewayRecipient())[0] as string;
    expect(await example.liftEvmPayerCooldown(CHAIN_ID, USDC, self)).toBe(true);
    expect((await postSettle(await settleBody(1000n))).success).toBe(true);
  });

  it('2.23.1: the budget bounds simulations in flight — a burst of opens from many wallets checks at most 10', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSimulationMode({ reverted: null }); // unfunded wallets: every check refuses
    // Distinct callers (no shared open lock), each paying from its own wallet. Candid calls reach
    // the canister together; HTTP through the local gateway arrives about ten at a time.
    const N = 16;
    const payers = [];
    for (let i = 0; i < N; i++) {
      const caller = await HttpAgent.create({
        identity: Secp256k1KeyIdentity.generate(),
        host: 'http://localhost:4944',
        shouldFetchRootKey: true,
      });
      payers.push({
        actor: createExampleActor(caller, exampleId),
        sig: await otherPayerSessionSig([Uint8Array.of(0x30, i)], 50_000n),
      });
    }
    await mock.setHoldSimulations(true);
    let returned = 0;
    let results: { err?: string }[] = [];
    try {
      const opens = payers.map((p) =>
        p.actor.openSession(sessionCfg, p.sig).then((r: { err?: string }) => {
          returned++;
          return r;
        }),
      );
      // Every open is then either held in its check or already refused.
      await until(async () => (await mock.getSimulations()) + BigInt(returned) >= BigInt(N));
      // At most the 10 tokens, plus one if a refill fell inside the burst (one every 6 s).
      expect(await mock.getSimulations()).toBeLessThanOrEqual(11n);
      await mock.setHoldSimulations(false);
      results = await Promise.all(opens);
    } finally {
      await mock.setHoldSimulations(false);
    }
    const unchecked = results.filter((r) =>
      String(r.err).includes('budget for checking payments'),
    ).length;
    expect(BigInt(unchecked) + (await mock.getSimulations())).toBe(BigInt(N));
    expect(await mock.sentTxCount()).toBe(0n);
  });

  it('2.23.1: refused checks are budgeted — after about 10 in a minute, payments are not checked until one refills', async () => {
    if (skip) return;
    await mock.reset();
    await mock.setSimulationMode({ reverted: null }); // every check refuses, as for an unfunded payer
    let refusedUnchecked = false;
    for (let i = 0; i < 30 && !refusedUnchecked; i++) {
      const sig = await evmSessionSig(50_000n); // sign first, so the open follows the last refusal closely
      const before = await mock.getSimulations();
      const res = await full.openSession(sessionCfg, sig);
      if (String(res.err).includes('budget for checking payments')) {
        expect(String(res.err)).toContain('retry this same payment');
        expect(await mock.getSimulations()).toBe(before); // not checked: no outcall
        refusedUnchecked = true;
      }
    }
    expect(refusedUnchecked).toBe(true);
    expect(await mock.sentTxCount()).toBe(0n);
  });
});
