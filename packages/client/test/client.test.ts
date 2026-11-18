import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Ic402Client, type Ic402ClientConfig } from '../src/client.js';
import { Ic402Error } from '../src/evm.js';
import type { Job, ServiceDefinition } from '../src/types.js';

function makeConfig(overrides?: Partial<Ic402ClientConfig>): Ic402ClientConfig {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const defaultActorFactory = (cid: string) => ({ _cid: cid }) as any;
  return {
    canisterId: 'test-canister',
    actorFactory: defaultActorFactory,
    identity: { getPrincipal: () => ({ toText: () => 'test-principal' }) },
    network: 'icp:1',
    ...overrides,
  };
}

// openSession requires a signer (2.17.0); a real-looking, non-zero key.
const testSigner = {
  sign: async () => new Uint8Array(64),
  getPublicKey: async () => new Uint8Array(32).fill(2),
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function mockActorFactory(actor: Record<string, unknown>): (cid: string) => any {
  return () => actor;
}

function makeJob(overrides?: Partial<Job>): Job {
  return {
    id: 'job-1',
    serviceId: 'svc-1',
    buyer: 'buyer-principal',
    operator: [],
    params: new Uint8Array([1, 2, 3]),
    paymentReceiptId: 'receipt-1',
    amount: 100n,
    actualCost: [],
    status: { Pending: null },
    result: [],
    proof: [],
    createdAt: 0n,
    expiresAt: 0n,
    completedAt: [],
    deliveryCallback: [],
    ...overrides,
  };
}

describe('Ic402Client', () => {
  describe('call()', () => {
    it('unwraps { ok: ... } result', async () => {
      const mockActor = {
        getData: async () => ({ ok: { value: 42 } }),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.call('getData', []);
      expect(result).toEqual({ value: 42 });
    });

    it('throws on paymentRequired when autoPayment is false', async () => {
      const mockActor = {
        paidMethod: async () => ({
          paymentRequired: { amount: 100n, nonce: new Uint8Array(32) },
        }),
      };

      const client = new Ic402Client(
        makeConfig({
          autoPayment: false,
          actorFactory: mockActorFactory(mockActor),
        }),
      );

      await expect(client.call('paidMethod', [null])).rejects.toThrow('autoPayment is disabled');
    });

    it('H5: auto-pays against the real `vec PaymentRequirement` wire shape', async () => {
      const nonce = new Uint8Array(32).fill(7);
      let approvedAmount: bigint | undefined;
      let retried = false;
      const mockActor = {
        // opt PaymentSignature arg: [] (none) on the first call, [sig] on the retry.
        paidMethod: async (optSig: unknown[]) => {
          if (Array.isArray(optSig) && optSig.length > 0) {
            retried = true;
            return { ok: { value: 'delivered' } };
          }
          // Candid `vec PaymentRequirement` decodes to a JS array, NOT a bare record.
          return { paymentRequired: [{ amount: 5_000n, nonce }] };
        },
      };
      const mockLedger = {
        icrc2_approve: async (arg: { amount: bigint }) => {
          approvedAmount = arg.amount;
          return { Ok: 1n };
        },
      };
      const client = new Ic402Client(
        makeConfig({
          canisterId: 'ryjl3-tyaaa-aaaaa-aaaba-cai', // valid principal — call() does Principal.fromText(cid)
          autoPayment: true,
          ledger: 'ryjl3-tyaaa-aaaaa-aaaba-cai',
          actorFactory: mockActorFactory(mockActor),
          ledgerActorFactory: mockActorFactory(mockLedger),
        }),
      );

      const result = await client.call('paidMethod', [[]]);
      // S3 (2.17.0): this ledger has no icrc1_fee → the legacy +100_000 is kept, no crash
      expect(approvedAmount).toBe(5_000n + 100_000n);
      expect(retried).toBe(true);
      expect(result).toEqual({ value: 'delivered' });
    });

    // S2 (2.17.0). Fails on: `+ 100_000n` restored; `expires_at: []`.
    it('approves exactly amount + icrc1_fee() with a 5-minute expires_at', async () => {
      const seen: { amount: bigint; expires_at: bigint[] }[] = [];
      const nonce = new Uint8Array(32).fill(7);
      const cid = 'ryjl3-tyaaa-aaaaa-aaaba-cai';
      const client = new Ic402Client(
        makeConfig({
          canisterId: cid,
          autoPayment: true,
          ledger: cid,
          actorFactory: mockActorFactory({
            paidMethod: async (optSig: unknown[]) =>
              optSig.length > 0
                ? { ok: 'delivered' }
                : { paymentRequired: [{ amount: 1_000n, nonce }] },
          }),
          ledgerActorFactory: mockActorFactory({
            icrc1_fee: async () => 10_000n,
            icrc2_approve: async (arg: { amount: bigint; expires_at: bigint[] }) => {
              seen.push(arg);
              return { Ok: 1n };
            },
          }),
        }),
      );
      const now = BigInt(Date.now()) * 1_000_000n;
      await client.call('paidMethod', [[]]);
      expect(seen[0]!.amount).toBe(11_000n);
      expect(seen[0]!.expires_at).toHaveLength(1);
      expect(seen[0]!.expires_at[0]!).toBeGreaterThan(now);
      expect(seen[0]!.expires_at[0]!).toBeLessThanOrEqual(now + 360_000_000_000n);
    });

    it('returns raw result when not { ok } or { paymentRequired }', async () => {
      const mockActor = {
        rawMethod: async () => 'raw-result',
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.call('rawMethod', []);
      expect(result).toBe('raw-result');
    });
  });

  describe('fetchContent() canisterQuery (H6)', () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const grant = { grantId: 'g1' } as any;

    it('unwraps the `opt blob` chunk and returns the real bytes, not zero bytes', async () => {
      const chunkA = new Uint8Array([1, 2, 3]);
      const chunkB = new Uint8Array([4, 5]);
      const mockActor = {
        // getChunk : (AccessGrant, nat) -> (opt blob) — agent-js yields [] | [Uint8Array].
        getChunk: async (_g: unknown, i: number) => (i === 0 ? [chunkA] : [chunkB]),
      };
      const client = new Ic402Client(makeConfig());
      const delivery = {
        grant,
        delivery: { canisterQuery: { method: 'getChunk', chunkCount: 2n } },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any;

      const bytes = await client.fetchContent(delivery, {
        canisterId: 'content-canister',
        actorFactory: mockActorFactory(mockActor),
      });
      expect(Array.from(bytes)).toEqual([1, 2, 3, 4, 5]);
    });

    it('throws when a chunk opt is empty (expired grant / index out of range)', async () => {
      const mockActor = { getChunk: async () => [] as unknown[] };
      const client = new Ic402Client(makeConfig());
      const delivery = {
        grant,
        delivery: { canisterQuery: { method: 'getChunk', chunkCount: 1n } },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any;

      await expect(
        client.fetchContent(delivery, {
          canisterId: 'content-canister',
          actorFactory: mockActorFactory(mockActor),
        }),
      ).rejects.toThrow('unavailable');
    });
  });

  describe('SessionHandle.call() accounting (C8)', () => {
    // Minimal mock-actor pieces to obtain a real SessionHandle from openSession().
    const intent = {
      suggestedDeposit: 10_000n,
      costPerCall: [500n],
      minDeposit: [],
      network: 'icp:1',
      token: 'tok',
      recipient: 'r',
      expiry: 0n,
      description: [],
    };
    const sessionBoilerplate = {
      requestSession: async () => intent,
      openSession: async () => ({ ok: { id: 'sess-1', deposited: 10_000n } }),
    };

    it('does NOT advance consumed/sequence when the canister call throws (transient failure)', async () => {
      const mockActor = {
        ...sessionBoilerplate,
        useService: async () => {
          throw new Error('transient RPC failure');
        },
      };
      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));
      const handle = await client.openSession(undefined, testSigner);
      expect(handle.consumed).toBe(0n);

      await expect(handle.call('useService', [])).rejects.toThrow('transient RPC failure');

      // The session must remain usable: a desynced cumulative/sequence here would brick
      // every subsequent voucher.
      expect(handle.consumed).toBe(0n);
      expect(handle.remaining).toBe(10_000n);
    });

    it('does NOT advance consumed when the canister returns an error variant', async () => {
      const mockActor = {
        ...sessionBoilerplate,
        useService: async () => ({ error: 'Budget exhausted' }),
      };
      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));
      const handle = await client.openSession(undefined, testSigner);

      await expect(handle.call('useService', [])).rejects.toThrow('Budget exhausted');
      expect(handle.consumed).toBe(0n);
    });

    // S1 (2.17.0). Fails on: vouchers (call or callForContent) sent via the client's actor;
    // close() via the session actor.
    it('sends vouchers through signer.actorFactory and close() through the client actor', async () => {
      const sessionActor = {
        sessionQuery: vi.fn().mockResolvedValue({ ok: 'a' }),
        sessionContent: vi.fn().mockResolvedValue({ ok: {} }),
        endSession: vi.fn(),
      };
      const clientActor = {
        ...sessionBoilerplate,
        sessionQuery: vi.fn(),
        endSession: vi.fn().mockResolvedValue({ ok: { amount: 500n } }),
      };
      const signer = {
        sign: async () => new Uint8Array(64),
        getPublicKey: async () => new Uint8Array(32),
        actorFactory: () => sessionActor,
      };
      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(clientActor) }));
      const handle = await client.openSession(undefined, signer);
      await handle.call('sessionQuery', ['q']);
      await handle.callForContent('sessionContent', ['c']);
      await handle.close();
      expect(sessionActor.sessionQuery).toHaveBeenCalledOnce();
      expect(sessionActor.sessionContent).toHaveBeenCalledOnce();
      expect(clientActor.sessionQuery).not.toHaveBeenCalled();
      expect(clientActor.endSession).toHaveBeenCalledOnce();
      expect(sessionActor.endSession).not.toHaveBeenCalled();
    });

    it('DOES advance consumed after a successful call', async () => {
      const mockActor = {
        ...sessionBoilerplate,
        useService: async () => ({ ok: 'served' }),
      };
      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));
      const handle = await client.openSession(undefined, testSigner);

      const r = await handle.call('useService', []);
      expect(r).toBe('served');
      expect(handle.consumed).toBe(500n);
      expect(handle.remaining).toBe(9_500n);
    });

    // S4 (2.17.0). Fails on: a zero key sent without a signer; approving the cap (maxDeposit)
    // rather than the deposit the canister pulls; approvalFeeBuffer ignored; no expiry.
    it('openSession needs a signer and approves min(suggestedDeposit, maxDeposit) + fee, expiring', async () => {
      const approve = vi.fn().mockResolvedValue({ Ok: 1n });
      const client = new Ic402Client(
        makeConfig({
          canisterId: 'aaaaa-aa',
          autoPayment: true,
          ledger: 'aaaaa-aa',
          approvalFeeBuffer: 7n,
          sessions: { maxDeposit: 100_000n },
          actorFactory: mockActorFactory(sessionBoilerplate),
          ledgerActorFactory: () => ({ icrc1_fee: async () => 10_000n, icrc2_approve: approve }),
        }),
      );
      await expect(client.openSession()).rejects.toThrow('VoucherSigner');
      expect(approve).not.toHaveBeenCalled();
      await client.openSession(undefined, testSigner);
      expect(approve.mock.calls[0]![0].amount).toBe(10_007n); // the intent suggests 10_000
      expect(approve.mock.calls[0]![0].expires_at).toHaveLength(1);
    });
  });

  describe('fetchContent', () => {
    it('inline delivery returns blob', async () => {
      const client = new Ic402Client(makeConfig());
      const delivery = {
        grant: {} as never,
        delivery: { inline: new Uint8Array([1, 2, 3]) },
      };

      const result = await client.fetchContent(delivery);
      expect(result).toEqual(new Uint8Array([1, 2, 3]));
    });

    it('unknown delivery method throws', async () => {
      const client = new Ic402Client(makeConfig());
      const delivery = {
        grant: {} as never,
        delivery: { unknownMethod: 'foo' } as never,
      };

      await expect(client.fetchContent(delivery)).rejects.toThrow('Unknown delivery method');
    });
  });

  describe('fetchX402', () => {
    let originalFetch: typeof globalThis.fetch;

    beforeEach(() => {
      originalFetch = globalThis.fetch;
    });

    afterEach(() => {
      globalThis.fetch = originalFetch;
    });

    it('returns free result for non-402 response', async () => {
      globalThis.fetch = vi.fn().mockResolvedValue(new Response('hello world', { status: 200 }));

      const client = new Ic402Client(makeConfig({ network: 'eip155:84532' }));

      const result = await client.fetchX402('https://example.com/data');
      expect(result.status).toBe('free');
      if (result.status === 'free') {
        expect(result.code).toBe(200);
        expect(result.body).toBe('hello world');
      }
    });

    it('returns error when no payment option matches chain', async () => {
      const paymentBody = JSON.stringify({
        accepts: [
          {
            network: 'eip155:8453',
            payTo: '0xRecipient',
            amount: '1000',
            asset: '0xUSDC',
          },
        ],
      });

      globalThis.fetch = vi.fn().mockResolvedValue(new Response(paymentBody, { status: 402 }));

      // chainId 1 (ethereum) won't match the eip155:8453 option
      const client = new Ic402Client(makeConfig({ network: 'eip155:1' }));

      const result = await client.fetchX402('https://example.com/paid');
      expect(result.status).toBe('error');
      if (result.status === 'error') {
        expect(result.error.kind).toBe('no_match');
      }
    });

    it('signs and retries on 402', async () => {
      const paymentBody = JSON.stringify({
        accepts: [
          {
            network: 'eip155:84532',
            payTo: '0xRecipient',
            amount: '100',
            asset: '0xUSDC',
            extra: { name: 'USD Coin', version: '2' },
          },
        ],
      });

      let callCount = 0;
      globalThis.fetch = vi.fn().mockImplementation(async (_url: string, init?: RequestInit) => {
        callCount++;
        if (callCount === 1) {
          // First call: return 402
          return new Response(paymentBody, { status: 402 });
        }
        // Second call: check for payment header and return 200
        const headers = new Headers(init?.headers);
        expect(headers.get('X-Payment')).toBe('signed-header-base64');
        expect(headers.get('Payment-Signature')).toBe('signed-header-base64');
        return new Response('paid content', { status: 200 });
      });

      const mockActor = {
        signX402Payment: vi.fn().mockResolvedValue({
          ok: {
            header: 'signed-header-base64',
            paidAmount: 100n,
            authorization: {
              from: '0xPayer',
              to: '0xRecipient',
              value: 100n,
              validAfter: 0n,
              validBefore: 999999999999n,
              nonce: '0x1234',
              signature: '0xsig',
            },
          },
        }),
      };

      const client = new Ic402Client(
        makeConfig({
          network: 'eip155:84532',
          actorFactory: mockActorFactory(mockActor),
        }),
      );

      const result = await client.fetchX402('https://example.com/paid');
      expect(result.status).toBe('ok');
      if (result.status === 'ok') {
        expect(result.body).toBe('paid content');
        expect(result.paidAmount).toBe(100n);
      }

      expect(mockActor.signX402Payment).toHaveBeenCalledOnce();
      expect(callCount).toBe(2);
    });

    it('returns config_error when no chainId available', async () => {
      const client = new Ic402Client(
        makeConfig({ network: 'icp:1' }), // non-EVM network
      );

      const result = await client.fetchX402('https://example.com/paid');
      expect(result.status).toBe('error');
      if (result.status === 'error') {
        expect(result.error.kind).toBe('config_error');
      }
    });

    // 2.22.0: after the paid request is sent, a failure is possibly paid — fundsMoved, not
    // retryable (a retry signs a second authorization).
    // Fails on: the paid-request catch using classifyNetworkError (transient, retryable), the
    // body-read failure escaping, or a non-402 status after paying without fundsMoved.
    it('a failure after the paid request is sent is possibly paid, never retryable', async () => {
      const challenge = JSON.stringify({
        accepts: [{ network: 'eip155:84532', payTo: '0xR', amount: '100', asset: '0xUSDC' }],
      });
      const actor = {
        signX402Payment: vi.fn().mockResolvedValue({
          ok: { header: 'h', paidAmount: 100n, authorization: {} },
        }),
      };
      const client = new Ic402Client(
        makeConfig({ network: 'eip155:84532', actorFactory: mockActorFactory(actor) }),
      );
      const broken = new ReadableStream({
        start(c) {
          c.error(new Error('connection reset'));
        },
      });
      for (const answer of [
        async () => {
          throw new Error('The operation was aborted due to timeout');
        },
        async () => new Response(broken, { status: 200 }),
        async () => new Response('upstream error', { status: 502 }),
      ]) {
        let n = 0;
        globalThis.fetch = vi
          .fn()
          .mockImplementation(async () =>
            ++n === 1 ? new Response(challenge, { status: 402 }) : answer(),
          );
        const r = await client.fetchX402('https://example.com/paid');
        expect(r.status).toBe('error');
        if (r.status === 'error') {
          expect(r.error.fundsMoved).toBe(true);
          expect(r.error.retryable).toBe(false);
        }
      }
    });

    it('returns sign_failed when actor returns err', async () => {
      const paymentBody = JSON.stringify({
        accepts: [
          {
            network: 'eip155:84532',
            payTo: '0xRecipient',
            amount: '100',
            asset: '0xUSDC',
          },
        ],
      });

      globalThis.fetch = vi.fn().mockResolvedValue(new Response(paymentBody, { status: 402 }));

      const mockActor = {
        signX402Payment: vi.fn().mockResolvedValue({
          err: 'Signing policy violation',
        }),
      };

      const client = new Ic402Client(
        makeConfig({
          network: 'eip155:84532',
          actorFactory: mockActorFactory(mockActor),
        }),
      );

      const result = await client.fetchX402('https://example.com/paid');
      expect(result.status).toBe('error');
      if (result.status === 'error') {
        expect(result.error.kind).toBe('sign_failed');
      }
    });
  });

  describe('submitServiceRequest', () => {
    it('handles paymentRequired and auto-pays', async () => {
      // Use a valid ICP principal ID for canisterId (aaaaa-aa is the management canister)
      const validCanisterId = 'aaaaa-aa';
      let submitCallCount = 0;
      const mockActor = {
        submitServiceRequest: vi.fn().mockImplementation(async () => {
          submitCallCount++;
          if (submitCallCount === 1) {
            return {
              paymentRequired: [{ amount: 50n, nonce: new Uint8Array(32) }],
            };
          }
          return { ok: { jobId: 'job-1' } };
        }),
      };

      const ledgerActor = {
        icrc2_approve: vi.fn().mockResolvedValue({ Ok: 0n }),
      };

      const client = new Ic402Client(
        makeConfig({
          canisterId: validCanisterId,
          autoPayment: true,
          ledger: 'aaaaa-aa',
          ledgerActorFactory: () => ledgerActor,
          actorFactory: mockActorFactory(mockActor),
        }),
      );

      const result = await client.submitServiceRequest('svc-1', new Uint8Array([1]));
      expect(result).toEqual({ jobId: 'job-1', paidAmount: 50n });
      expect(ledgerActor.icrc2_approve).toHaveBeenCalledOnce();
      expect(ledgerActor.icrc2_approve.mock.calls[0]![0].expires_at).toHaveLength(1);
      expect(mockActor.submitServiceRequest).toHaveBeenCalledTimes(2);
    });

    it('throws when autoPayment disabled', async () => {
      const mockActor = {
        submitServiceRequest: vi.fn().mockResolvedValue({
          paymentRequired: [{ amount: 50n, nonce: new Uint8Array(32) }],
        }),
      };

      const client = new Ic402Client(
        makeConfig({
          autoPayment: false,
          actorFactory: mockActorFactory(mockActor),
        }),
      );

      await expect(client.submitServiceRequest('svc-1', new Uint8Array([1]))).rejects.toThrow(
        'autoPayment is disabled',
      );
    });

    it('throws when ledger not configured', async () => {
      const mockActor = {
        submitServiceRequest: vi.fn().mockResolvedValue({
          paymentRequired: [{ amount: 50n, nonce: new Uint8Array(32) }],
        }),
      };

      const client = new Ic402Client(
        makeConfig({
          autoPayment: true,
          // no ledger or ledgerActorFactory
          actorFactory: mockActorFactory(mockActor),
        }),
      );

      await expect(client.submitServiceRequest('svc-1', new Uint8Array([1]))).rejects.toThrow(
        'ledger',
      );
    });

    it('returns ok result without payment flow', async () => {
      const mockActor = {
        submitServiceRequest: vi.fn().mockResolvedValue({
          ok: { jobId: 'free-job' },
        }),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.submitServiceRequest('svc-1', new Uint8Array([1]));
      expect(result).toEqual({ jobId: 'free-job' });
    });

    it('throws on error result', async () => {
      const mockActor = {
        submitServiceRequest: vi.fn().mockResolvedValue({
          error: 'Service unavailable',
        }),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.submitServiceRequest('svc-1', new Uint8Array([1]))).rejects.toThrow(
        'Service unavailable',
      );
    });
  });

  describe('pollJobResult', () => {
    it('returns job when status is Settled', async () => {
      const settledJob = makeJob({ status: { Settled: null } });
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([settledJob]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.pollJobResult('job-1', 5, 10);
      expect(result).toEqual(settledJob);
      expect(mockActor.getJob).toHaveBeenCalledTimes(1);
    });

    it('returns job when status is Verified', async () => {
      const verifiedJob = makeJob({ status: { Verified: null } });
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([verifiedJob]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.pollJobResult('job-1', 5, 10);
      expect(result).toEqual(verifiedJob);
    });

    it('returns job when status is Submitted', async () => {
      const submittedJob = makeJob({ status: { Submitted: null } });
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([submittedJob]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.pollJobResult('job-1', 5, 10);
      expect(result).toEqual(submittedJob);
    });

    it('polls until job completes', async () => {
      let callCount = 0;
      const mockActor = {
        getJob: vi.fn().mockImplementation(async () => {
          callCount++;
          if (callCount < 3) {
            return [makeJob({ status: { Pending: null } })];
          }
          return [makeJob({ status: { Settled: null } })];
        }),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.pollJobResult('job-1', 5, 10);
      expect(result.status).toEqual({ Settled: null });
      expect(mockActor.getJob).toHaveBeenCalledTimes(3);
    });

    it('throws on Disputed status', async () => {
      const disputedJob = makeJob({ status: { Disputed: null } });
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([disputedJob]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.pollJobResult('job-1', 5, 10)).rejects.toThrow('disputed');
    });

    it('throws on Expired status', async () => {
      const expiredJob = makeJob({ status: { Expired: null } });
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([expiredJob]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.pollJobResult('job-1', 5, 10)).rejects.toThrow('expired or refunded');
    });

    it('throws on Refunded status', async () => {
      const refundedJob = makeJob({ status: { Refunded: null } });
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([refundedJob]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.pollJobResult('job-1', 5, 10)).rejects.toThrow('expired or refunded');
    });

    it('throws on timeout', async () => {
      const mockActor = {
        getJob: vi.fn().mockResolvedValue([makeJob({ status: { Pending: null } })]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.pollJobResult('job-1', 2, 10)).rejects.toThrow(
        'not completed within 2 attempts',
      );
    });

    it('throws when job not found (null)', async () => {
      const mockActor = {
        getJob: vi.fn().mockResolvedValue(null),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.pollJobResult('nonexistent', 2, 10)).rejects.toThrow('Job not found');
    });

    it('throws when job not found (undefined)', async () => {
      const mockActor = {
        getJob: vi.fn().mockResolvedValue(undefined),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.pollJobResult('nonexistent', 2, 10)).rejects.toThrow('Job not found');
    });
  });

  describe('listServices', () => {
    it('returns services from actor', async () => {
      const services: ServiceDefinition[] = [
        {
          id: 'svc-1',
          name: 'Summarize',
          description: 'Text summarization',
          serviceType: { Async: null },
          pricing: { Exact: 100n },
          verification: { AutoSettle: null },
          delivery: { Poll: null },
          timeout: 60_000_000_000n,
          operatorId: 'operator-1',
          enabled: true,
          createdAt: 0n,
        },
        {
          id: 'svc-2',
          name: 'Translate',
          description: 'Translation service',
          serviceType: { Sync: null },
          pricing: { Upto: 200n },
          verification: { BuyerConfirm: { disputeWindowSeconds: 3600n } },
          delivery: { Both: null },
          timeout: 120_000_000_000n,
          operatorId: 'operator-2',
          enabled: true,
          createdAt: 0n,
        },
      ];

      const mockActor = {
        listServices: vi.fn().mockResolvedValue(services),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.listServices();
      expect(result).toEqual(services);
      expect(result).toHaveLength(2);
      expect(mockActor.listServices).toHaveBeenCalledOnce();
    });

    it('returns empty array when no services', async () => {
      const mockActor = {
        listServices: vi.fn().mockResolvedValue([]),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.listServices();
      expect(result).toEqual([]);
    });
  });

  describe('disputeJob', () => {
    it('calls actor disputeJob successfully', async () => {
      const mockActor = {
        disputeJob: vi.fn().mockResolvedValue({ ok: null }),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.disputeJob('job-1', 'Result is incorrect')).resolves.toBeUndefined();

      expect(mockActor.disputeJob).toHaveBeenCalledWith('job-1', 'Result is incorrect');
    });

    it('throws on error result', async () => {
      const mockActor = {
        disputeJob: vi.fn().mockResolvedValue({ err: 'Not the buyer' }),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.disputeJob('job-1', 'Bad result')).rejects.toThrow('Not the buyer');
    });

    it('does not throw when result has no err', async () => {
      const mockActor = {
        disputeJob: vi.fn().mockResolvedValue(null),
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      await expect(client.disputeJob('job-1', 'reason')).resolves.toBeUndefined();
    });
  });

  // 2.22.0 (M4/I2): a per-call ceiling the SDK enforces BEFORE approving, so a caller (the MCP)
  // that confirmed and reserved an amount from one canister answer cannot be made to approve what a
  // second answer asks.
  describe('payment ceiling (maxAmount, M4)', () => {
    const cid = 'aaaaa-aa';
    const nonce = new Uint8Array(32).fill(7);

    // Fails on: call()'s checkCeiling removed (approves 5_000 + fee and pays).
    it('call() refuses a paymentRequired above maxAmount before approving', async () => {
      const approve = vi.fn().mockResolvedValue({ Ok: 1n });
      const paidMethod = vi
        .fn()
        .mockResolvedValue({ paymentRequired: [{ amount: 5_000n, nonce }] });
      const client = new Ic402Client(
        makeConfig({
          canisterId: cid,
          autoPayment: true,
          ledger: cid,
          actorFactory: mockActorFactory({ paidMethod }),
          ledgerActorFactory: () => ({ icrc2_approve: approve }),
        }),
      );
      await expect(
        client.call('paidMethod', [[]], undefined, { maxAmount: 4_999n }),
      ).rejects.toThrow('above maxAmount');
      expect(approve).not.toHaveBeenCalled();
      expect(paidMethod).toHaveBeenCalledOnce(); // no paid retry
    });

    // Fails on: submitServiceRequest's checkCeiling removed. A 0 quote must not mean "unlimited".
    it('submitServiceRequest with maxAmount 0n refuses any payment before approving', async () => {
      const approve = vi.fn().mockResolvedValue({ Ok: 1n });
      const submit = vi.fn().mockResolvedValue({ paymentRequired: [{ amount: 50n, nonce }] });
      const client = new Ic402Client(
        makeConfig({
          canisterId: cid,
          autoPayment: true,
          ledger: cid,
          actorFactory: mockActorFactory({ submitServiceRequest: submit }),
          ledgerActorFactory: () => ({ icrc2_approve: approve }),
        }),
      );
      const err = await client
        .submitServiceRequest('svc', new Uint8Array([1]), { maxAmount: 0n })
        .catch((e) => e);
      expect(err).toBeInstanceOf(Ic402Error);
      expect(err.paymentNotSent).toBe(true);
      expect(approve).not.toHaveBeenCalled();
      expect(submit).toHaveBeenCalledOnce();
    });

    // Fails on: the ceiling compared with >= (an amount equal to the confirmed one refused), or
    // paidAmount taken from anything but the requirement the SDK approved.
    it('submitServiceRequest pays an amount equal to maxAmount and reports it as paidAmount', async () => {
      const approve = vi.fn().mockResolvedValue({ Ok: 1n });
      const submit = vi
        .fn()
        .mockResolvedValueOnce({ paymentRequired: [{ amount: 50n, nonce }] })
        .mockResolvedValueOnce({ ok: { jobId: 'job-9' } });
      const client = new Ic402Client(
        makeConfig({
          canisterId: cid,
          autoPayment: true,
          ledger: cid,
          approvalFeeBuffer: 10n,
          actorFactory: mockActorFactory({ submitServiceRequest: submit }),
          ledgerActorFactory: () => ({ icrc2_approve: approve }),
        }),
      );
      const r = await client.submitServiceRequest('svc', new Uint8Array([1]), { maxAmount: 50n });
      expect(r).toEqual({ jobId: 'job-9', paidAmount: 50n });
      expect(approve.mock.calls[0]![0].amount).toBe(60n); // amount + fee, the fee on top
    });
  });

  // 2.22.0 (I5): the MCP releases a spend reservation only on errors raised BEFORE the paying call.
  describe('paymentNotSent marks refusals before the paying call (I5)', () => {
    const cid = 'aaaaa-aa';
    const nonce = new Uint8Array(32).fill(7);
    const intent = {
      suggestedDeposit: 10_000n,
      costPerCall: [500n],
      minDeposit: [],
      network: 'icp:1',
      token: 'tok',
      recipient: 'r',
      expiry: 0n,
      description: [],
    };

    // Fails on: submitServiceRequest's approve #Err thrown without paymentNotSent; the unpaid
    // request's {error} thrown without it; a post-payment {error} thrown WITH it.
    it('submitServiceRequest: approve #Err and an unpaid refusal are not-sent; a paid error is not', async () => {
      const make = (submit: unknown, approveResult: unknown) =>
        new Ic402Client(
          makeConfig({
            canisterId: cid,
            autoPayment: true,
            ledger: cid,
            actorFactory: mockActorFactory({ submitServiceRequest: submit }),
            ledgerActorFactory: () => ({
              icrc2_approve: vi.fn().mockResolvedValue(approveResult),
            }),
          }),
        );
      const required = { paymentRequired: [{ amount: 50n, nonce }] };

      const approveErr = await make(vi.fn().mockResolvedValue(required), {
        Err: { InsufficientFunds: null },
      })
        .submitServiceRequest('svc', new Uint8Array([1]))
        .catch((e) => e);
      expect(approveErr.paymentNotSent).toBe(true);

      const unpaid = await make(vi.fn().mockResolvedValue({ error: 'Service disabled' }), {
        Ok: 1n,
      })
        .submitServiceRequest('svc', new Uint8Array([1]))
        .catch((e) => e);
      expect(unpaid.paymentNotSent).toBe(true);

      const paidSubmit = vi
        .fn()
        .mockResolvedValueOnce(required)
        .mockResolvedValueOnce({ error: 'Payment expired' });
      const paid = await make(paidSubmit, { Ok: 1n })
        .submitServiceRequest('svc', new Uint8Array([1]))
        .catch((e) => e);
      expect(paid).toBeInstanceOf(Ic402Error);
      expect(paid.paymentNotSent).toBe(false);
    });

    // Fails on: openSession's approve #Err thrown as a plain Error (no paymentNotSent).
    it('openSession: approve #Err is not-sent; an openSession #err after it is not', async () => {
      const make = (approveResult: unknown, openSession: unknown) =>
        new Ic402Client(
          makeConfig({
            canisterId: cid,
            autoPayment: true,
            ledger: cid,
            approvalFeeBuffer: 0n,
            actorFactory: mockActorFactory({ requestSession: async () => intent, openSession }),
            ledgerActorFactory: () => ({
              icrc2_approve: vi.fn().mockResolvedValue(approveResult),
            }),
          }),
        );
      const approveErr = await make({ Err: { TemporarilyUnavailable: null } }, vi.fn())
        .openSession(undefined, testSigner)
        .catch((e) => e);
      expect(approveErr).toBeInstanceOf(Ic402Error);
      expect(approveErr.paymentNotSent).toBe(true);

      const openErr = await make({ Ok: 1n }, async () => ({ err: 'Insufficient allowance' }))
        .openSession(undefined, testSigner)
        .catch((e) => e);
      expect(openErr.paymentNotSent).toBe(false);
    });
  });

  // 2.22.0 (I6): after paying, call() never hands back a non-ok answer as a plain value.
  describe('call() after payment (I6)', () => {
    const cid = 'aaaaa-aa';
    const nonce = new Uint8Array(32).fill(7);
    const paying = (retryAnswer: unknown, approve = vi.fn().mockResolvedValue({ Ok: 1n })) =>
      new Ic402Client(
        makeConfig({
          canisterId: cid,
          autoPayment: true,
          ledger: cid,
          actorFactory: mockActorFactory({
            paidMethod: async (optSig: unknown[]) =>
              optSig.length > 0 ? retryAnswer : { paymentRequired: [{ amount: 10n, nonce }] },
          }),
          ledgerActorFactory: () => ({ icrc2_approve: approve }),
        }),
      );

    // Fails on: the post-payment {error} branch removed (the error came back as a value).
    it('throws a post-payment {error}, fundsMoved when the canister says the payment moved', async () => {
      const err = await paying({
        error:
          'Settlement pending — do NOT retry payment with a new nonce: ledger call rejected after it may have run',
      })
        .call('paidMethod', [[]])
        .catch((e) => e);
      expect(err).toBeInstanceOf(Ic402Error);
      expect(err.fundsMoved).toBe(true);
    });

    // Fails on: the post-payment {paymentRequired} branch removed (a fresh 402 came back as a value).
    it('throws on a fresh paymentRequired after paying, and pays only once', async () => {
      const approve = vi.fn().mockResolvedValue({ Ok: 1n });
      const err = await paying({ paymentRequired: [{ amount: 10n, nonce }] }, approve)
        .call('paidMethod', [[]])
        .catch((e) => e);
      expect(err).toBeInstanceOf(Ic402Error);
      expect(err.kind).toBe('settlement_failed');
      expect(approve).toHaveBeenCalledOnce();
    });
  });

  // 2.22.0 (C2 follow-up): the canister answers a payment whose settlement is merely in flight with
  // #policyDenied("…already in progress — retry this same payment…"). Retryable with the same
  // payment; neither funds-moved nor a refusal before payment (the MCP keeps its reservation).
  // Fails on: settleError not recognising the in-progress text (kind sign_failed, retryable false).
  it('a settlement already in progress is retryable, not fundsMoved, not paymentNotSent', async () => {
    const nonce = new Uint8Array(32).fill(7);
    const submit = vi
      .fn()
      .mockResolvedValueOnce({ paymentRequired: [{ amount: 50n, nonce }] })
      .mockResolvedValueOnce({
        error:
          'Policy: A settlement with this payment is already in progress — retry this same payment in a few seconds; do not pay with a new nonce.',
      });
    const client = new Ic402Client(
      makeConfig({
        canisterId: 'aaaaa-aa',
        autoPayment: true,
        ledger: 'aaaaa-aa',
        actorFactory: mockActorFactory({ submitServiceRequest: submit }),
        ledgerActorFactory: () => ({ icrc2_approve: vi.fn().mockResolvedValue({ Ok: 1n }) }),
      }),
    );
    const err = await client.submitServiceRequest('svc', new Uint8Array([1])).catch((e) => e);
    expect(err).toBeInstanceOf(Ic402Error);
    expect(err.retryable).toBe(true);
    expect(err.fundsMoved).toBe(false);
    expect(err.paymentNotSent).toBe(false);
  });

  // Option C — the settle boundary tags Ic402Error.fundsMoved when the canister marks the payment as
  // already moved (settle #ok then job failed, or #settlementPending). The MCP keys its refund guard
  // off this flag, so pin it here at the single string-match seam. See docs/decisions/settled-then-job-failed.md.
  describe('funds-moved signal at the settle boundary (Option C)', () => {
    const intent = {
      suggestedDeposit: 10_000n,
      costPerCall: [500n],
      minDeposit: [],
      network: 'icp:1',
      token: 'tok',
      recipient: 'r',
      expiry: 0n,
      description: [],
    };

    it('openSession #settlementPending → Ic402Error.fundsMoved=true (MCP must KEEP the reservation)', async () => {
      const mockActor = {
        requestSession: async () => intent,
        openSession: async () => ({
          err: 'Settlement pending — do NOT retry payment: EVM deposit broadcast but not yet confirmed (tx 0xabc)',
        }),
      };
      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));
      const err = await client.openSession(undefined, testSigner).catch((e) => e);
      expect(err).toBeInstanceOf(Ic402Error);
      expect(err.fundsMoved).toBe(true);
      expect(err.retryable).toBe(false);
    });

    it('openSession with a no-funds-moved error → fundsMoved=false (safe to refund the reservation)', async () => {
      const mockActor = {
        requestSession: async () => intent,
        openSession: async () => ({ err: 'Policy: rate limit exceeded' }),
      };
      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));
      const err = await client.openSession(undefined, testSigner).catch((e) => e);
      expect(err).toBeInstanceOf(Ic402Error);
      expect(err.fundsMoved).toBe(false);
    });
  });
});
