import { describe, it, expect, beforeAll } from 'vitest';
import { createLocalAgent, createExampleActor, getCanisterId } from './helpers.js';
import type { HttpAgent } from '@icp-sdk/core/agent';

/**
 * Replica-backed tests for 2.16.0 — the derivation path reaching every deriving site.
 *
 * WHY HERE. Deriving a key needs `ecdsa_public_key`, unreachable from the mops interpreter.
 * Construction and validation live in `test/derivation-paths.test.mo`; the address
 * guarantees are proven here against real tECDSA.
 *
 * THE LOAD-BEARING TEST is the cross-module one: EvmSigner, EvmSender and the Gateway
 * recipient under the SAME path must yield the SAME address. If they disagree, a consumer
 * signs from an address nothing funds while deposits pile up at another — the exact failure
 * this release exists to prevent.
 *
 * Requires: pnpm setup:local && bash scripts/predemo.sh
 * IC402_REQUIRE_REPLICA=1 turns a missing replica into a hard failure.
 */

function unwrap<T>(result: { ok?: T; err?: string }, what: string): T {
  if (result.err !== undefined) throw new Error(`${what} failed: ${result.err}`);
  if (result.ok === undefined) throw new Error(`${what} returned neither ok nor err`);
  return result.ok;
}

const enc = (s: string): number[] => Array.from(new TextEncoder().encode(s));
const PATH_A: number[][] = [enc('engramx'), enc('payments'), enc('secp256k1'), enc('1')];
const PATH_B: number[][] = [enc('engramx'), enc('identity'), enc('secp256k1'), enc('1')];

describe('derivation path at every deriving site', () => {
  let agent: HttpAgent;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let actor: any;
  let skip = false;
  let skipReason = '';

  beforeAll(async () => {
    try {
      agent = await createLocalAgent();
      actor = createExampleActor(agent, getCanisterId('example'));
      const probe = await actor.senderAddressAt([]);
      if (probe.err !== undefined) {
        skip = true;
        skipReason = `replica cannot derive EVM addresses: ${probe.err}`;
      }
    } catch (e) {
      skip = true;
      skipReason = `no local replica or example canister: ${(e as Error).message}`;
    }
  });

  it('replica derives EVM addresses (enforced when IC402_REQUIRE_REPLICA=1)', () => {
    if (process.env.IC402_REQUIRE_REPLICA === '1') {
      expect(skip, skipReason).toBe(false);
    } else if (skip) {
      console.warn(`[derivation-paths] SKIPPED — ${skipReason}`);
    }
  });

  // ── The invariant this release exists for ──

  it('EvmSigner, EvmSender and the identity agree on ONE address per path', async () => {
    if (skip) return;
    for (const [label, path] of [
      ['A', PATH_A],
      ['B', PATH_B],
    ] as const) {
      const signer = unwrap<string>(await actor.evmAddressAt(path), `evmAddressAt(${label})`);
      const sender = unwrap<string>(await actor.senderAddressAt(path), `senderAddressAt(${label})`);
      const ident = unwrap<string>(
        await actor.identityAddressAt(path),
        `identityAddressAt(${label})`,
      );

      expect(signer).toMatch(/^0x[0-9a-fA-F]{40}$/);
      expect(sender.toLowerCase(), `sender vs signer on path ${label}`).toEqual(
        signer.toLowerCase(),
      );
      expect(ident.toLowerCase(), `identity vs signer on path ${label}`).toEqual(
        signer.toLowerCase(),
      );
    }
  });

  it('and that agreement is not vacuous — the two paths differ', async () => {
    if (skip) return;
    // Without this, the test above would pass if every site ignored the path entirely.
    const a = unwrap<string>(await actor.senderAddressAt(PATH_A), 'senderAddressAt(A)');
    const b = unwrap<string>(await actor.senderAddressAt(PATH_B), 'senderAddressAt(B)');
    expect(a.toLowerCase()).not.toEqual(b.toLowerCase());
  });

  // ── Per-site: two paths differ, and the default form ≡ explicit [] ──

  describe('EvmSender', () => {
    it('two paths derive different addresses', async () => {
      if (skip) return;
      const a = unwrap<string>(await actor.senderAddressAt(PATH_A), 'A');
      const b = unwrap<string>(await actor.senderAddressAt(PATH_B), 'B');
      expect(a.toLowerCase()).not.toEqual(b.toLowerCase());
    });

    it('the explicit [] form matches the default signer address', async () => {
      if (skip) return;
      // `getEvmAddress` is the pre-2.16.0 default-form signer built at actor init.
      const legacy: string = await actor.getEvmAddress();
      const explicitEmpty = unwrap<string>(await actor.senderAddressAt([]), 'senderAddressAt([])');
      expect(explicitEmpty.toLowerCase()).toEqual(legacy.toLowerCase());
    });

    it('refuses an over-limit path with #err', async () => {
      if (skip) return;
      const res = await actor.senderAddressAt(Array.from({ length: 255 }, () => [0x01]));
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/too long/i);
      expect(res.err).not.toMatch(/candid|decoding|UserError/i);
    });
  });

  describe('Identity', () => {
    it('two paths derive different addresses', async () => {
      if (skip) return;
      const a = unwrap<string>(await actor.identityAddressAt(PATH_A), 'A');
      const b = unwrap<string>(await actor.identityAddressAt(PATH_B), 'B');
      expect(a.toLowerCase()).not.toEqual(b.toLowerCase());
    });

    it('the explicit [] form matches the default address', async () => {
      if (skip) return;
      const legacy: string = await actor.getEvmAddress();
      const explicitEmpty = unwrap<string>(
        await actor.identityAddressAt([]),
        'identityAddressAt([])',
      );
      expect(explicitEmpty.toLowerCase()).toEqual(legacy.toLowerCase());
    });

    it('the keyed cache does not return one path’s key for another', async () => {
      if (skip) return;
      // Before 2.16.0 the cache was a single unkeyed `var`. Interleaving the calls is what
      // would expose a slot being reused: A, then B, then A again.
      const a1 = unwrap<string>(await actor.identityAddressAt(PATH_A), 'a1');
      const b = unwrap<string>(await actor.identityAddressAt(PATH_B), 'b');
      const a2 = unwrap<string>(await actor.identityAddressAt(PATH_A), 'a2');
      expect(a2.toLowerCase()).toEqual(a1.toLowerCase());
      expect(b.toLowerCase()).not.toEqual(a1.toLowerCase());
    });

    it('refuses an over-limit path with #err', async () => {
      if (skip) return;
      const res = await actor.identityAddressAt(Array.from({ length: 255 }, () => [0x01]));
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/too long/i);
    });
  });

  describe('Gateway recipient — the same-path invariant', () => {
    // These replace an earlier pair of tests that asserted the BUG as correct: they expected
    // deriveEvmRecipientAt to return #ok on an already-filled slot and the recipient to stay
    // put, which is exactly the silent split this release exists to prevent.

    it('the gateway sender and the published recipient are ONE address', async () => {
      if (skip) return;
      // The load-bearing check. `gatewaySenderAddress` derives through the gateway's OWN
      // path — not a standalone EvmSenderAt — so this fails if the internal sender and the
      // recipient ever diverge.
      const recipient: string[] = await actor.gatewayRecipient();
      expect(recipient.length, 'setup:local should have derived a recipient').toBe(1);
      const sender = unwrap<string>(await actor.gatewaySenderAddress(), 'gatewaySenderAddress');
      expect(sender.toLowerCase()).toEqual(recipient[0].toLowerCase());
    });

    it('REFUSES a labelled path it cannot apply, instead of reporting success', async () => {
      if (skip) return;
      // The slot is already filled at the default path here (setup derives it), so asking
      // for a labelled one must FAIL. Returning #ok would tell a consumer its path was
      // applied while the gateway keeps publishing the old address.
      const res = await actor.deriveGatewayRecipientAt(PATH_A);
      expect(res.err, 'a path that cannot be applied must not report success').toBeDefined();
      expect(res.err).toMatch(/different path|cannot move|sender is on a different/i);

      // And the published recipient must not have moved.
      const after: string[] = await actor.gatewayRecipient();
      const sender = unwrap<string>(await actor.gatewaySenderAddress(), 'gatewaySenderAddress');
      expect(after[0].toLowerCase()).toEqual(sender.toLowerCase());
    });

    it('the current path is reported, and re-deriving it is idempotent #ok', async () => {
      if (skip) return;
      const path: number[][] = await actor.gatewayDerivationPath();
      // setup:local leaves the gateway on the default empty path.
      expect(path).toEqual([]);
      // Asking for the path the recipient actually IS on is truthfully #ok.
      const res = await actor.deriveGatewayRecipientAt(path);
      expect(res.err, "the gateway's own path must be accepted").toBeUndefined();
    });

    it('setEvmDerivationPath refuses to move a gateway whose recipient exists', async () => {
      if (skip) return;
      // A published recipient cannot move, so the setter must refuse once it is derived —
      // otherwise the sender would walk away from the address payers already have.
      const res = await actor.setGatewayDerivationPath(PATH_A);
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/cannot move|already derived/i);
    });

    it('setEvmDerivationPath refuses an over-limit path', async () => {
      if (skip) return;
      const res = await actor.setGatewayDerivationPath(Array.from({ length: 255 }, () => [0x01]));
      expect(res.err).toBeDefined();
      expect(res.err).toMatch(/too long/i);
    });
  });

  describe('EvmSigner (2.15.0, re-checked against the new sites)', () => {
    it('two paths derive different addresses', async () => {
      if (skip) return;
      const a = unwrap<string>(await actor.evmAddressAt(PATH_A), 'A');
      const b = unwrap<string>(await actor.evmAddressAt(PATH_B), 'B');
      expect(a.toLowerCase()).not.toEqual(b.toLowerCase());
    });

    it('the explicit [] form matches the default address', async () => {
      if (skip) return;
      const legacy: string = await actor.getEvmAddress();
      const explicitEmpty = unwrap<string>(await actor.evmAddressAt([]), 'evmAddressAt([])');
      expect(explicitEmpty.toLowerCase()).toEqual(legacy.toLowerCase());
    });
  });
});
