/// Test helpers for ic402 integration tests.
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { Secp256k1KeyIdentity } from '@icp-sdk/core/identity/secp256k1';
import { exampleIdlFactory } from '../packages/client/src/idl.js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const LOCAL_REPLICA = 'http://localhost:4944';

/**
 * Load the test-payer identity (must be a canister controller).
 * Handles both SEC1 and PKCS#8 PEM formats.
 */
function loadTestIdentity(): Secp256k1KeyIdentity | undefined {
  const pemPath = process.env.ICP_IDENTITY_PEM || resolve(__dirname, '../.local/test-payer.pem');
  try {
    const pem = readFileSync(pemPath, 'utf-8');
    if (pem.includes('BEGIN EC PRIVATE KEY')) {
      return Secp256k1KeyIdentity.fromPem(pem);
    }
    if (pem.includes('BEGIN PRIVATE KEY')) {
      const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
      const der = Buffer.from(b64, 'base64');
      const secp256k1Oid = Buffer.from([0x2b, 0x81, 0x04, 0x00, 0x0a]);
      if (!der.includes(secp256k1Oid) || der.length < 65) return undefined;
      const secretKey = der.slice(33, 65);
      return Secp256k1KeyIdentity.fromSecretKey(new Uint8Array(secretKey));
    }
  } catch {
    /* PEM not found */
  }
  return undefined;
}

/**
 * Create an HttpAgent for the local replica with the test-payer identity.
 */
export async function createLocalAgent(): Promise<HttpAgent> {
  const identity = loadTestIdentity();
  const agent = await HttpAgent.create({
    host: LOCAL_REPLICA,
    shouldFetchRootKey: true,
    identity: identity ?? undefined,
  });
  return agent;
}

/**
 * Create an actor for the example canister.
 */
export function createExampleActor(agent: HttpAgent, canisterId: string) {
  return Actor.createActor(exampleIdlFactory, {
    agent,
    canisterId,
  });
}

/**
 * Read canister ID from local deployment.
 */
export function getCanisterId(name: string): string {
  const envKey = `CANISTER_ID_${name.toUpperCase()}`;
  const fromEnv = process.env[envKey];
  if (fromEnv) return fromEnv;

  // Try icp CLI
  try {
    const { execSync } = require('child_process');
    return execSync(`icp canister status ${name} -e local --id-only`, {
      encoding: 'utf-8',
      timeout: 5000,
    }).trim();
  } catch {
    /* fall through */
  }

  // Try local canister_ids.json
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const ids = require('../.icp/local/canister_ids.json');
    return ids[name]?.local ?? ids[name];
  } catch {
    throw new Error(
      `Cannot find canister ID for "${name}". Set ${envKey} env var or deploy locally first.`,
    );
  }
}

/**
 * Create an actor for the ckUSDC ledger (ICRC-2 approve).
 */
export function createLedgerActor(agent: HttpAgent, canisterId: string) {
  const { IDL } = require('@icp-sdk/core/candid');
  const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });
  const idlFactory = () =>
    IDL.Service({
      icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ['query']),
      icrc2_approve: IDL.Func(
        [
          IDL.Record({
            spender: Account,
            amount: IDL.Nat,
            fee: IDL.Opt(IDL.Nat),
            memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
            from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
            created_at_time: IDL.Opt(IDL.Nat64),
            expected_allowance: IDL.Opt(IDL.Nat),
            expires_at: IDL.Opt(IDL.Nat64),
          }),
        ],
        // Must match the real ckUSDC ledger's ApproveResult. The Err arm is a record-variant
        // (ApproveError), NOT text — declaring it as IDL.Text makes a genuine approve failure
        // (e.g. InsufficientFunds) decode-crash with a cryptic "type on the wire" error instead
        // of surfacing the actual reason.
        [
          IDL.Variant({
            Ok: IDL.Nat,
            Err: IDL.Variant({
              GenericError: IDL.Record({ message: IDL.Text, error_code: IDL.Nat }),
              TemporarilyUnavailable: IDL.Null,
              Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
              BadFee: IDL.Record({ expected_fee: IDL.Nat }),
              AllowanceChanged: IDL.Record({ current_allowance: IDL.Nat }),
              CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
              TooOld: IDL.Null,
              Expired: IDL.Record({ ledger_time: IDL.Nat64 }),
              InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
            }),
          }),
        ],
        [],
      ),
    });
  return Actor.createActor(idlFactory, { agent, canisterId });
}
