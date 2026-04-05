import { describe, it, expect, beforeAll } from 'vitest';
import {
  createLocalAgent,
  createExampleActor,
  createLedgerActor,
  getCanisterId,
} from './helpers.js';
import type { HttpAgent } from '@icp-sdk/core/agent';
import { Principal } from '@icp-sdk/core/principal';

/**
 * Integration tests for ic402 example canister.
 *
 * Require a running local replica with deployed canisters:
 *   pnpm setup:local
 *
 * Run with:
 *   pnpm test:integration
 */

describe('ic402 integration', () => {
  let agent: HttpAgent;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let actor: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let ledger: any;
  let exampleId: string;
  let ledgerId: string;
  let skip = false;

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      exampleId = getCanisterId('example');
      ledgerId = getCanisterId('ckusdc_ledger');
      actor = createExampleActor(agent, exampleId);
      ledger = createLedgerActor(agent, ledgerId);
    } catch {
      skip = true;
    }
  });

  // ── Charges ──

  describe('charges', () => {
    it('returns paymentRequired without payment', async () => {
      if (skip) return;
      const result = await actor.search('test query', []);
      expect(result).toHaveProperty('paymentRequired');
      const reqs = result.paymentRequired;
      expect(Array.isArray(reqs)).toBe(true);
      expect(reqs.length).toBeGreaterThan(0);
      expect(reqs[0].scheme).toBe('exact');
      expect(reqs[0].network).toBeDefined();
      expect(reqs[0].nonce).toBeDefined();
    });

    it('includes both ICP and EVM payment options', async () => {
      if (skip) return;
      const result = await actor.search('test', []);
      const reqs = result.paymentRequired;
      const icpReq = reqs.find((r: { network: string }) => r.network === 'icp:1');
      const evmReq = reqs.find((r: { network: string }) => r.network.startsWith('eip155:'));
      expect(icpReq).toBeDefined();
      expect(evmReq).toBeDefined();
    });

    it('settles ICP payment and returns search results', async () => {
      if (skip) return;

      // 1. Get payment requirements (nonce)
      const reqResult = await actor.search('settlement test', []);
      expect(reqResult).toHaveProperty('paymentRequired');
      const reqs = reqResult.paymentRequired;
      const icpReq = reqs.find((r: { network: string }) => r.network === 'icp:1');
      expect(icpReq).toBeDefined();

      // 2. ICRC-2 approve the example canister to spend the required amount
      const approveResult = await ledger.icrc2_approve({
        spender: {
          owner: Principal.fromText(exampleId),
          subaccount: [],
        },
        amount: BigInt(icpReq.amount) + 10_000n, // add buffer for fee
        fee: [],
        memo: [],
        from_subaccount: [],
        created_at_time: [],
        expected_allowance: [],
        expires_at: [],
      });
      expect(approveResult).toHaveProperty('Ok');

      // 3. Get caller principal from the agent
      const callerPrincipal = await agent.getPrincipal();

      // 4. Call search with payment signature
      const paymentSig = {
        scheme: icpReq.scheme,
        network: icpReq.network,
        signature: new Uint8Array(0),
        publicKey: [],
        sender: callerPrincipal.toText(),
        nonce: icpReq.nonce,
        authorization: [],
      };
      const paidResult = await actor.search('settlement test', [paymentSig]);

      // 5. Verify we got actual search results (not paymentRequired)
      expect(paidResult).toHaveProperty('ok');
      expect(Array.isArray(paidResult.ok)).toBe(true);
    });
  });

  // ── Sessions ──

  describe('sessions', () => {
    it('requestSession returns valid intent', async () => {
      if (skip) return;
      const intent = await actor.requestSession();
      expect(intent.network).toBe('icp:1');
      expect(intent.suggestedDeposit).toBeGreaterThan(0n);
      expect(intent.recipient).toBeDefined();
    });

    it('rejects voucher for nonexistent session', async () => {
      if (skip) return;
      const voucher = {
        sessionId: 'nonexistent',
        cumulativeAmount: 1_000n,
        sequence: 1n,
        signature: new Uint8Array(64),
      };
      const result = await actor.sessionQuery(voucher, 'test');
      expect(result).toHaveProperty('error');
    });

    it('endSession rejects nonexistent session', async () => {
      if (skip) return;
      const result = await actor.endSession('nonexistent');
      // Should return a PaymentResult error variant
      expect(result).toBeDefined();
      const hasError = 'settlementFailed' in result || 'expired' in result;
      expect(hasError).toBe(true);
    });
  });

  // ── Content ──

  describe('content', () => {
    it('upload and list content', async () => {
      if (skip) return;
      const data = new TextEncoder().encode('integration test content');
      const uploadResult = await actor.uploadContent('int-test-doc', 'text/plain', data);
      // ok or contentAlreadyExists (from previous run)
      expect('ok' in uploadResult || 'contentAlreadyExists' in uploadResult).toBe(true);

      const list = await actor.listContent();
      expect(Array.isArray(list)).toBe(true);
      const found = list.find((e: { id: string }) => e.id === 'int-test-doc');
      expect(found).toBeDefined();
      expect(found.mimeType).toBe('text/plain');
    });

    it('getContent returns paymentRequired without payment', async () => {
      if (skip) return;
      const result = await actor.getContent('int-test-doc', []);
      expect(result).toHaveProperty('paymentRequired');
    });

    it('delete content', async () => {
      if (skip) return;
      const result = await actor.deleteContent('int-test-doc');
      expect('ok' in result || 'contentNotFound' in result).toBe(true);
    });
  });

  // ── Services ──

  describe('services', () => {
    it('register and enable a service', async () => {
      if (skip) return;
      const result = await actor.registerService(
        'Integration Test Service',
        'Test service for integration tests',
        { Async: null },
        { Exact: 500n },
        'AutoSettle',
        [],
        [],
        { Poll: null },
        300n,
      );
      expect('ok' in result || ('err' in result && result.err.includes('already exists'))).toBe(
        true,
      );

      const enableResult = await actor.enableService(result.ok ?? 'svc-1');
      expect('ok' in enableResult).toBe(true);
    });

    it('list services returns enabled services', async () => {
      if (skip) return;
      const services = await actor.listServices();
      expect(Array.isArray(services)).toBe(true);
      expect(services.length).toBeGreaterThan(0);
      const svc = services.find((s: { name: string }) => s.name === 'Integration Test Service');
      expect(svc).toBeDefined();
      expect(svc.enabled).toBe(true);
    });

    it('submitServiceRequest returns paymentRequired', async () => {
      if (skip) return;
      const result = await actor.submitServiceRequest(
        'svc-1',
        new TextEncoder().encode('test params'),
        [],
      );
      expect(result).toHaveProperty('paymentRequired');
      const reqs = result.paymentRequired;
      expect(Array.isArray(reqs)).toBe(true);
      expect(reqs[0].amount).toBe(500n);
    });

    it('claim nonexistent job fails', async () => {
      if (skip) return;
      const result = await actor.claimJob('nonexistent-job');
      expect(result).toHaveProperty('err');
    });

    it('getJobStatus returns null for nonexistent job', async () => {
      if (skip) return;
      const result = await actor.getJobStatus('nonexistent-job');
      expect(result).toEqual([]);
    });

    it('getJobResult returns null for nonexistent job', async () => {
      if (skip) return;
      const result = await actor.getJobResult('nonexistent-job');
      expect(result).toEqual([]);
    });
  });

  // ── EVM Signer ──

  describe('evm signer', () => {
    it('signX402Payment returns signed authorization', async () => {
      if (skip) return;
      const result = await actor.signX402Payment(
        84532n,
        '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
        '0x0000000000000000000000000000000000000001',
        100n,
        'USDC',
        '2',
      );
      expect(result).toHaveProperty('ok');
      const ok = result.ok;
      expect(ok.header).toBeDefined();
      expect(typeof ok.header).toBe('string');
      expect(ok.header.length).toBeGreaterThan(100);
      expect(ok.paidAmount).toBe(100n);
      expect(ok.authorization).toBeDefined();
      expect(ok.authorization.from).toMatch(/^0x[0-9a-fA-F]{40}$/);
    });

    it('signErc20Transfer returns signed transaction', async () => {
      if (skip) return;
      const result = await actor.signErc20Transfer(
        84532n,
        '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
        '0x0000000000000000000000000000000000000001',
        1000n,
        0n,
        1000000000n,
        1000000n,
      );
      expect(result).toHaveProperty('ok');
      expect(result.ok.rawTx).toBeDefined();
      expect(result.ok.txHash).toBeDefined();
    });

    it('signEthTransfer returns signed transaction', async () => {
      if (skip) return;
      const result = await actor.signEthTransfer(
        84532n,
        '0x0000000000000000000000000000000000000001',
        1000000000000000n,
        21000n,
        0n,
        1000000000n,
        1000000n,
      );
      expect(result).toHaveProperty('ok');
      expect(result.ok.rawTx).toBeDefined();
    });

    it('signAgentRegistration returns signed transaction', async () => {
      if (skip) return;
      const result = await actor.signAgentRegistration(0n, 1000000000n, 1000000n);
      expect(result).toHaveProperty('ok');
      expect(result.ok.rawTx).toBeDefined();
    });
  });

  // ── Identity ──

  describe('identity', () => {
    it('getAgentCard returns card metadata', async () => {
      if (skip) return;
      const card = await actor.getAgentCard();
      expect(card.name).toBe('KnowledgeBase');
      expect(card.x402Support).toBe(true);
      expect(Array.isArray(card.services)).toBe(true);
      expect(card.services.length).toBeGreaterThan(0);
    });

    it('getEvmAddress returns valid EVM address', async () => {
      if (skip) return;
      const addr = await actor.getEvmAddress();
      expect(typeof addr).toBe('string');
      expect(addr).toMatch(/^0x[0-9a-fA-F]{40}$/);
    });

    it('getAgentId returns null before registration', async () => {
      if (skip) return;
      const result = await actor.getAgentId();
      // Opt encoding: [] means null
      expect(result).toEqual([]);
    });
  });

  // ── EIP-712 Generic Signing ──

  describe('eip-712 signing', () => {
    it('keccak256 hashes correctly', async () => {
      if (skip) return;
      // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
      const result = await actor.keccak256([]);
      expect(result).toBeInstanceOf(Uint8Array);
      expect(result.length).toBe(32);
      // First byte of keccak256("") is 0xc5
      expect(result[0]).toBe(0xc5);
    });

    it('keccak256 of known string matches expected hash', async () => {
      if (skip) return;
      // keccak256("hello") = 0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
      const input = Array.from(new TextEncoder().encode('hello'));
      const result = await actor.keccak256(input);
      expect(result[0]).toBe(0x1c);
      expect(result[1]).toBe(0x8a);
    });

    it('signTypedData returns valid signature', async () => {
      if (skip) return;
      // Use a simple domain separator and struct hash (32 bytes each)
      const domainSep = new Array(32).fill(0);
      domainSep[0] = 0xab;
      const structHash = new Array(32).fill(0);
      structHash[0] = 0xcd;

      const result = await actor.signTypedData(domainSep, structHash);
      expect(result).toHaveProperty('ok');
      const ok = result.ok;
      expect(ok.signature).toBeDefined();
      expect(typeof ok.signature).toBe('string');
      expect(ok.signature.length).toBe(132); // 0x + 130 hex chars (65 bytes)
      expect(ok.signer).toMatch(/^0x[0-9a-fA-F]{40}$/);
      expect(ok.digest).toBeDefined();
      expect(ok.v).toBeGreaterThanOrEqual(27);
      expect(ok.v).toBeLessThanOrEqual(28);
      expect(ok.r).toBeDefined();
      expect(ok.s).toBeDefined();
    });

    it('signTypedData signer matches getEvmAddress', async () => {
      if (skip) return;
      const evmAddr = await actor.getEvmAddress();
      const domainSep = new Array(32).fill(1);
      const structHash = new Array(32).fill(2);

      const result = await actor.signTypedData(domainSep, structHash);
      expect(result.ok.signer.toLowerCase()).toBe(evmAddr.toLowerCase());
    });

    it('different inputs produce different signatures', async () => {
      if (skip) return;
      const domainSep = new Array(32).fill(0);

      const hash1 = new Array(32).fill(0);
      hash1[0] = 1;
      const hash2 = new Array(32).fill(0);
      hash2[0] = 2;

      const sig1 = await actor.signTypedData(domainSep, hash1);
      const sig2 = await actor.signTypedData(domainSep, hash2);

      expect(sig1.ok.signature).not.toBe(sig2.ok.signature);
      expect(sig1.ok.digest).not.toBe(sig2.ok.digest);
    });

    it('full EIP-712 flow: domain + type hash + sign', async () => {
      if (skip) return;
      // Build EIP-712 hashes client-side (same pattern as production use)
      const { keccak_256 } = await import('@noble/hashes/sha3');
      const enc = (s: string) => new TextEncoder().encode(s);
      const uint256 = (n: number) => {
        const b = new Uint8Array(32);
        let v = n;
        for (let i = 31; i >= 0 && v > 0; i--) {
          b[i] = v & 0xff;
          v = Math.floor(v / 256);
        }
        return b;
      };
      const concat = (...a: Uint8Array[]) => {
        const out = new Uint8Array(a.reduce((s, x) => s + x.length, 0));
        let off = 0;
        for (const x of a) {
          out.set(x, off);
          off += x.length;
        }
        return out;
      };

      // Domain separator
      const domainTypeHash = keccak_256(
        enc('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
      );
      const domainSep = keccak_256(
        concat(
          domainTypeHash,
          keccak_256(enc('TestExchange')),
          keccak_256(enc('1')),
          uint256(84532),
          new Uint8Array(32),
        ),
      );
      expect(domainSep.length).toBe(32);

      // Struct hash
      const actionTypeHash = keccak_256(enc('PlaceOrder(string asset,uint256 size)'));
      const structHash = keccak_256(
        concat(actionTypeHash, keccak_256(enc('BTC-PERP')), uint256(100)),
      );

      // Sign via canister — only this call touches tECDSA
      const result = await actor.signTypedData(Array.from(domainSep), Array.from(structHash));
      expect(result).toHaveProperty('ok');
      expect(result.ok.signer).toMatch(/^0x[0-9a-fA-F]{40}$/);
      expect(result.ok.signature.length).toBe(132);
    });
  });

  // ── HTTP Gateway ──

  describe('http gateway', () => {
    it('/ returns canister info (free)', async () => {
      if (skip) return;
      const response = await fetch(`http://${exampleId}.raw.localhost:4944/`);
      expect(response.ok).toBe(true);
      const body = await response.json();
      expect(body.name).toBe('KnowledgeBase');
      expect(body.x402Support).toBe(true);
    });

    it('/content/<id> returns 402 with payment options', async () => {
      if (skip) return;
      // Upload content first
      await actor.uploadContent('http-test', 'text/plain', new TextEncoder().encode('test'));

      const response = await fetch(`http://${exampleId}.raw.localhost:4944/content/http-test`);
      expect(response.status).toBe(402);

      const body = await response.json();
      expect(body.x402Version).toBeDefined();
      expect(Array.isArray(body.accepts)).toBe(true);
      expect(body.accepts.length).toBeGreaterThan(0);
      expect(body.accepts[0].scheme).toBe('exact');

      // Clean up
      await actor.deleteContent('http-test');
    });

    it('/search returns 402', async () => {
      if (skip) return;
      const response = await fetch(`http://${exampleId}.raw.localhost:4944/search?q=test`);
      expect(response.status).toBe(402);
    });

    it('/service/<id> returns 402 or 404', async () => {
      if (skip) return;
      const response = await fetch(`http://${exampleId}.raw.localhost:4944/service/svc-1`);
      // 402 if service was registered in previous test, 404 if not
      expect([402, 404]).toContain(response.status);
    });

    it('/job/<id> returns 404 for nonexistent job', async () => {
      if (skip) return;
      const response = await fetch(`http://${exampleId}.raw.localhost:4944/job/nonexistent`);
      expect(response.status).toBe(404);
    });

    it('/nonexistent returns 404', async () => {
      if (skip) return;
      const response = await fetch(`http://${exampleId}.raw.localhost:4944/nonexistent`);
      expect(response.status).toBe(404);
    });
  });

  // ── ZK Verifier ──

  describe('zk verifier', () => {
    it('get_info returns verifier description', async () => {
      if (skip) return;
      let zkId: string;
      try {
        zkId = getCanisterId('zk_verifier');
      } catch {
        return; // ZK verifier not deployed
      }

      const { IDL } = await import('@icp-sdk/core/candid');
      const { Actor } = await import('@icp-sdk/core/agent');
      const zkIdl = () =>
        IDL.Service({
          get_info: IDL.Func([], [IDL.Text], ['query']),
        });
      const zkActor = Actor.createActor(zkIdl, { agent, canisterId: zkId });
      const info = await zkActor.get_info();
      expect(typeof info).toBe('string');
      expect(info).toContain('Groth16');
    });
  });

  // ── Policy ──

  describe('policy', () => {
    it('setPolicy updates canister policy', async () => {
      if (skip) return;
      // Set a custom policy and verify the canister accepts it
      await actor.setPolicy({
        maxPerTransaction: [100_000n],
        maxPerDay: [1_000_000n],
        rateLimitPerMinute: [60n],
        maxSessionDeposit: [500_000n],
        maxConcurrentSessions: [2n],
        maxSessionDuration: [86_400_000_000_000n],
        sessionIdleTimeout: [3_600_000_000_000n],
        allowedCallers: [],
        blockedCallers: [],
      });
      // If we get here without throwing, the policy was accepted
      expect(true).toBe(true);
    });
  });
});
