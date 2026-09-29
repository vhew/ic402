import { describe, it, expect, beforeAll } from 'vitest';
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import type { HttpAgent } from '@icp-sdk/core/agent';

/**
 * Replica-backed differential for ic402's Ed25519 verifier (src/ic402/Ed25519.mo, 2.16.1).
 *
 * WHY. `test/ed25519.test.mo` pins RFC 8032, Wycheproof and the policy cases in the Motoko
 * interpreter. This file checks the same verifier INSIDE A DEPLOYED CANISTER, against OpenSSL
 * (node:crypto), over thousands of signatures generated fresh on every run — in both
 * directions: every OpenSSL-valid signature must be accepted and every OpenSSL-invalid
 * corruption refused.
 *
 * `mo:ed25519` 0.1.0, which ic402 used before 2.16.1, would fail this: it refused the ~1 in 32
 * signatures with S < 2^247. The run asserts it actually exercised that band.
 *
 * It also bounds what one verification costs. 0.1.0 allocated ~245 MB and burned ~4.96 billion
 * instructions per call (measured); the budgets below are ~2x the vendored verifier's measured
 * 8.4 MB / 206 M, so a regression toward the old cost fails loudly.
 *
 * Requires: pnpm setup:local && bash scripts/predemo.sh
 * IC402_REQUIRE_REPLICA=1 turns a missing replica into a hard failure.
 * IC402_ED25519_PAIRS overrides the number of random pairs (default 2000).
 */

const PAIRS = Number(process.env.IC402_ED25519_PAIRS ?? 2000);
const MAX_MESSAGE = 300;
// Queries in flight at once. More does not help: the local replica runs them on few threads,
// and 25 at once measured ~150 ms per fresh query against ~60 ms at 1-4.
const BATCH = 4;
const MAX_INSTRUCTIONS = 400_000_000n; // measured 206 M
const MAX_ALLOCATED_BYTES = 16_000_000n; // measured 8.4 MB

const sOf = (sig: Uint8Array): bigint =>
  BigInt('0x' + Buffer.from(sig.subarray(32)).reverse().toString('hex'));
const fromHex = (h: string): Uint8Array => Uint8Array.from(Buffer.from(h, 'hex'));

/** An OpenSSL Ed25519 key, with its raw 32-byte public key. */
function newKey(): { priv: crypto.KeyObject; pub: crypto.KeyObject; raw: Uint8Array } {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const der = publicKey.export({ format: 'der', type: 'spki' });
  return { priv: privateKey, pub: publicKey, raw: Uint8Array.from(der.subarray(der.length - 32)) };
}

interface Case {
  sig: Uint8Array;
  msg: Uint8Array;
  pub: Uint8Array;
  /** The reference verdict: OpenSSL's for generated pairs, the fixture's for vendored vectors. */
  expected: boolean;
  label: string;
}

describe('Ed25519 verification inside a canister', () => {
  let agent: HttpAgent;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let actor: any;
  let skip = false;
  let skipReason = '';

  const rfc = JSON.parse(
    readFileSync(new URL('./fixtures/ed25519/rfc8032.json', import.meta.url), 'utf8'),
  );
  const wycheproof = JSON.parse(
    readFileSync(new URL('./fixtures/ed25519/wycheproof_ed25519.json', import.meta.url), 'utf8'),
  );
  const regressions = JSON.parse(
    readFileSync(new URL('./fixtures/ed25519/regressions.json', import.meta.url), 'utf8'),
  );
  const speccheck = JSON.parse(
    readFileSync(new URL('./fixtures/ed25519/speccheck_cases.json', import.meta.url), 'utf8'),
  );
  const policy = JSON.parse(
    readFileSync(new URL('./fixtures/ed25519/policy.json', import.meta.url), 'utf8'),
  );

  async function canister(c: {
    sig: Uint8Array;
    msg: Uint8Array;
    pub: Uint8Array;
  }): Promise<boolean> {
    return actor.ed25519Verify(Array.from(c.sig), Array.from(c.msg), Array.from(c.pub));
  }

  async function runAll(cases: Case[]): Promise<Case[]> {
    const disagree: Case[] = [];
    for (let i = 0; i < cases.length; i += BATCH) {
      const batch = cases.slice(i, i + BATCH);
      const results = await Promise.all(batch.map(canister));
      batch.forEach((c, j) => {
        if (results[j] !== c.expected) disagree.push(c);
      });
    }
    return disagree;
  }

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      actor = createExampleActor(agent, getCanisterId('example'));
      const v = rfc[0];
      const ok = await canister({
        sig: fromHex(v.signature),
        msg: fromHex(v.message),
        pub: fromHex(v.publicKey),
      });
      if (ok !== true) {
        skip = true;
        skipReason = 'ed25519Verify rejected RFC 8032 TEST 1 — wrong canister build?';
      }
    } catch (e) {
      skip = true;
      skipReason = `no local replica or example canister: ${(e as Error).message}`;
    }
  });

  it('replica is reachable (enforced when IC402_REQUIRE_REPLICA=1)', () => {
    if (process.env.IC402_REQUIRE_REPLICA === '1') {
      expect(skip, skipReason).toBe(false);
    } else if (skip) {
      console.warn(`[ed25519] SKIPPED — ${skipReason}`);
    }
  });

  it(`agrees with OpenSSL on ${PAIRS} fresh random pairs, in both directions`, async () => {
    if (skip) return;
    const cases: Case[] = [];
    let smallS = 0;
    for (let i = 0; i < PAIRS; i++) {
      const key = newKey();
      const msg = new Uint8Array(crypto.randomBytes(crypto.randomInt(0, MAX_MESSAGE + 1)));
      const sig = new Uint8Array(crypto.sign(null, msg, key.priv));
      if (sOf(sig) < 2n ** 247n) smallS++;
      cases.push({
        sig,
        msg,
        pub: key.raw,
        expected: crypto.verify(null, msg, key.pub, sig),
        label: `valid #${i}`,
      });

      // The other direction: one corruption per pair, alternating signature bit and message byte.
      const badSig = Uint8Array.from(sig);
      const badMsg = Uint8Array.from(msg);
      if (i % 2 === 0 || msg.length === 0)
        badSig[crypto.randomInt(0, 64)] ^= 1 << crypto.randomInt(0, 8);
      else badMsg[crypto.randomInt(0, msg.length)] ^= 1 << crypto.randomInt(0, 8);
      cases.push({
        sig: badSig,
        msg: badMsg,
        pub: key.raw,
        expected: crypto.verify(null, badMsg, key.pub, badSig),
        label: `corrupted #${i}`,
      });
    }
    const disagree = await runAll(cases);
    // OpenSSL accepts every fresh signature and refuses every corruption, so the run really does
    // test both directions.
    expect(cases.filter((c) => c.expected).length, 'OpenSSL-valid cases').toBe(PAIRS);
    expect(
      disagree.map((c) => c.label),
      'disagreements with OpenSSL',
    ).toEqual([]);
    // Prove the run reached the band mo:ed25519 0.1.0 refused (expected ~PAIRS/32).
    expect(smallS, 'signatures with S < 2^247 in this run').toBeGreaterThan(0);
    console.log(
      `[ed25519] ${PAIRS} valid + ${PAIRS} corrupted agree with OpenSSL; ${smallS} had S < 2^247`,
    );
  }, 900_000);

  it('every Wycheproof vector matches its expected result, inside the canister', async () => {
    if (skip) return;
    const cases: Case[] = [];
    for (const g of wycheproof.testGroups) {
      for (const t of g.tests) {
        cases.push({
          sig: fromHex(t.sig),
          msg: fromHex(t.msg),
          pub: fromHex(g.publicKey.pk),
          expected: t.result === 'valid',
          label: `tcId ${t.tcId}`,
        });
      }
    }
    expect(cases.length).toBe(151);
    expect((await runAll(cases)).map((c) => c.label)).toEqual([]);
  });

  it('the 0.1.0 regressions: pinned and band vectors accepted, malleated partners refused', async () => {
    if (skip) return;
    const cases: Case[] = [
      { ...hexCase(regressions.pinned), expected: regressions.pinned.valid, label: 'pinned' },
      ...regressions.band.map((b: Fixture, i: number) => ({
        ...hexCase(b),
        expected: b.valid,
        label: `band ${i}`,
      })),
      ...regressions.malleated.flatMap((m: Fixture, i: number) => [
        { ...hexCase(m), expected: true, label: `malleated ${i}: original` },
        {
          ...hexCase({ ...m, sig: m.malleated! }),
          expected: false,
          label: `malleated ${i}: S + 2^256 mod L`,
        },
      ]),
    ];
    expect(cases.length).toBe(13);
    expect((await runAll(cases)).map((c) => c.label)).toEqual([]);
  });

  // Where ic402 is STRICTER than OpenSSL, the differential above cannot see it (OpenSSL accepts
  // small-order and negative-zero public keys), so the policy is pinned here directly. Same
  // verdicts, same reasons, as the speccheck suite in test/ed25519.test.mo.
  it('the ed25519-speccheck policy holds inside the canister', async () => {
    if (skip) return;
    const policyVerdicts = [
      false,
      false,
      true,
      true,
      false,
      false,
      false,
      false,
      false,
      false,
      false,
      false,
    ];
    expect(speccheck.length).toBe(policyVerdicts.length);
    const cases: Case[] = speccheck.map((c: Record<string, string>, i: number) => ({
      sig: fromHex(c.signature),
      msg: fromHex(c.message),
      pub: fromHex(c.pub_key),
      expected: policyVerdicts[i],
      label: `speccheck ${i}`,
    }));
    expect((await runAll(cases)).map((c) => c.label)).toEqual([]);
  });

  it('each policy vector is refused inside the canister', async () => {
    if (skip) return;
    const cases: Case[] = policy.vectors.map((v: Fixture & { name: string }) => ({
      ...hexCase(v),
      expected: v.valid,
      label: v.name,
    }));
    expect(cases.length).toBe(3);
    expect((await runAll(cases)).map((c) => c.label)).toEqual([]);
  });

  it('one verification stays within its instruction and allocation budget', async () => {
    if (skip) return;
    let maxInstr = 0n;
    let maxAlloc = 0n;
    for (let i = 0; i < 8; i++) {
      const key = newKey();
      const msg = new Uint8Array(crypto.randomBytes(MAX_MESSAGE));
      const sig = new Uint8Array(crypto.sign(null, msg, key.priv));
      const cost = await actor.ed25519VerifyCost(
        Array.from(sig),
        Array.from(msg),
        Array.from(key.raw),
      );
      expect(cost.valid).toBe(true);
      if (cost.instructions > maxInstr) maxInstr = cost.instructions;
      if (cost.allocatedBytes > maxAlloc) maxAlloc = cost.allocatedBytes;
    }
    console.log(`[ed25519] worst of 8: ${maxInstr} instructions, ${maxAlloc} bytes allocated`);
    expect(maxInstr < MAX_INSTRUCTIONS, `instructions ${maxInstr} >= ${MAX_INSTRUCTIONS}`).toBe(
      true,
    );
    expect(maxAlloc < MAX_ALLOCATED_BYTES, `allocated ${maxAlloc} >= ${MAX_ALLOCATED_BYTES}`).toBe(
      true,
    );
  });
});

interface Fixture {
  note: string;
  pub: string;
  msg: string;
  sig: string;
  valid?: boolean;
  malleated?: string;
}

function hexCase(v: Fixture): { sig: Uint8Array; msg: Uint8Array; pub: Uint8Array } {
  return { sig: fromHex(v.sig), msg: fromHex(v.msg), pub: fromHex(v.pub) };
}
