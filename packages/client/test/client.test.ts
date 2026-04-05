import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Ic402Client, type Ic402ClientConfig } from '../src/client.js';
import { Ic402Error } from '../src/evm.js';
import type { Job, JobStatus, ServiceDefinition } from '../src/types.js';

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

    it('returns raw result when not { ok } or { paymentRequired }', async () => {
      const mockActor = {
        rawMethod: async () => 'raw-result',
      };

      const client = new Ic402Client(makeConfig({ actorFactory: mockActorFactory(mockActor) }));

      const result = await client.call('rawMethod', []);
      expect(result).toBe('raw-result');
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
      expect(result).toEqual({ jobId: 'job-1' });
      expect(ledgerActor.icrc2_approve).toHaveBeenCalledOnce();
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
});
