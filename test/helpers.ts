/// Test helpers for ic402 integration tests.
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { exampleIdlFactory } from '../packages/client/src/idl.js';

const LOCAL_REPLICA = 'http://localhost:4944';

/**
 * Create an HttpAgent for the local replica.
 */
export async function createLocalAgent(): Promise<HttpAgent> {
  const agent = await HttpAgent.create({
    host: LOCAL_REPLICA,
    shouldFetchRootKey: true,
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
  // icp CLI stores canister IDs in .icp/local/canister_ids.json
  // For tests, accept via env var or default
  const envKey = `CANISTER_ID_${name.toUpperCase()}`;
  const fromEnv = process.env[envKey];
  if (fromEnv) return fromEnv;

  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const ids = require('../.icp/local/canister_ids.json');
    return ids[name]?.local ?? ids[name];
  } catch {
    throw new Error(`Cannot find canister ID for "${name}". Set ${envKey} env var or deploy locally first.`);
  }
}
