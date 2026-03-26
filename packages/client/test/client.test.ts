import { describe, it, expect } from 'vitest';
import { Ic402Client, type Ic402ClientConfig } from '../src/client.js';

function makeConfig(overrides?: Partial<Ic402ClientConfig>): Ic402ClientConfig {
  return {
    identity: {},
    network: 'icp:1',
    ...overrides,
  };
}

describe('Ic402Client', () => {
  describe('budget enforcement', () => {
    it('maxPerRequest throws when amount exceeds limit', async () => {
      const client = new Ic402Client(
        makeConfig({
          autoPayment: true,
          budget: { maxPerRequest: 100n },
        }),
      );

      const mockActor = {
        testMethod: async () => ({
          paymentRequired: { amount: 200n, nonce: new Uint8Array(32) },
        }),
      };

      await expect(
        client.call('canister-id', 'testMethod', [null], () => mockActor),
      ).rejects.toThrow('exceeds maxPerRequest');
    });

    it('maxTotal throws when cumulative spend exceeds limit', async () => {
      const client = new Ic402Client(
        makeConfig({
          autoPayment: true,
          budget: { maxTotal: 50n },
          ledger: 'ledger-id',
          ledgerActorFactory: () => ({
            icrc2_approve: async () => ({ Ok: 0n }),
          }),
        }),
      );

      let callCount = 0;
      const mockActor = {
        testMethod: async () => {
          callCount++;
          if (callCount === 1) {
            return { paymentRequired: { amount: 100n, nonce: new Uint8Array(32) } };
          }
          return { ok: 'success' };
        },
      };

      await expect(
        client.call('canister-id', 'testMethod', [null], () => mockActor),
      ).rejects.toThrow('Total budget exceeded');
    });

    it('maxSessionDeposit throws when deposit exceeds limit', async () => {
      const client = new Ic402Client(
        makeConfig({
          budget: { maxSessionDeposit: 50n },
        }),
      );

      const mockActor = {
        requestSession: async () => ({
          network: 'icp:1',
          token: 'ledger',
          recipient: 'recipient',
          suggestedDeposit: 100n,
          expiry: 0n,
        }),
      };

      await expect(client.openSession('canister-id', {}, () => mockActor)).rejects.toThrow(
        'exceeds maxSessionDeposit',
      );
    });
  });

  describe('call()', () => {
    it('throws without actorFactory', async () => {
      const client = new Ic402Client(makeConfig());
      await expect(client.call('cid', 'method', [])).rejects.toThrow('actorFactory required');
    });

    it('unwraps { ok: ... } result', async () => {
      const client = new Ic402Client(makeConfig());
      const mockActor = {
        getData: async () => ({ ok: { value: 42 } }),
      };

      const result = await client.call('cid', 'getData', [], () => mockActor);
      expect(result).toEqual({ value: 42 });
    });

    it('throws on paymentRequired when autoPayment is false', async () => {
      const client = new Ic402Client(makeConfig({ autoPayment: false }));
      const mockActor = {
        paidMethod: async () => ({
          paymentRequired: { amount: 100n, nonce: new Uint8Array(32) },
        }),
      };

      await expect(client.call('cid', 'paidMethod', [null], () => mockActor)).rejects.toThrow(
        'autoPayment is disabled',
      );
    });

    it('returns raw result when not { ok } or { paymentRequired }', async () => {
      const client = new Ic402Client(makeConfig());
      const mockActor = {
        rawMethod: async () => 'raw-result',
      };

      const result = await client.call('cid', 'rawMethod', [], () => mockActor);
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
});
