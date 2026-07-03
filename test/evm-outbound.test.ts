import { describe, it, expect, beforeAll } from 'vitest';
import { createLocalAgent, getCanisterId } from './helpers.js';
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
const exampleIdl = () =>
  IDL.Service({
    sweepEvm: IDL.Func([IDL.Nat, IDL.Text, IDL.Text, IDL.Nat], [sweepResult], []),
  });

const ReceiptMode = IDL.Variant({
  confirmed: IDL.Null,
  reverted: IDL.Null,
  pendingThenConfirmed: IDL.Nat,
});
const FeeMode = IDL.Variant({ consistent: IDL.Null, inconsistentOutlier: IDL.Null });
const SendMode = IDL.Variant({ ok: IDL.Null, nonceTooHigh: IDL.Null });
const mockIdl = () =>
  IDL.Service({
    setReceiptMode: IDL.Func([ReceiptMode], [], []),
    setFeeMode: IDL.Func([FeeMode], [], []),
    setSendMode: IDL.Func([SendMode], [], []),
    reset: IDL.Func([], [], []),
    sentTxCount: IDL.Func([], [IDL.Nat], ['query']),
    getSentTxs: IDL.Func([], [IDL.Vec(IDL.Text)], ['query']),
    getReceiptPolls: IDL.Func([], [IDL.Nat], ['query']),
  });

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
  let skip = false;

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      const exampleId = getCanisterId('example');
      const mockId = getCanisterId('evm_rpc_mock'); // throws if the fixture isn't deployed
      example = Actor.createActor(exampleIdl, { agent, canisterId: exampleId });
      mock = Actor.createActor(mockIdl, { agent, canisterId: mockId });
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
    const res = await sweep();
    expect(res).toHaveProperty('pending');
    expect(await mock.sentTxCount()).toBe(1n);
  });
});
