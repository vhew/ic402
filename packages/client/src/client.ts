import type { PaymentReceipt, SessionIntent, SessionState } from './types.js';

export interface BudgetConfig {
  maxPerRequest?: bigint;
  maxPerDay?: bigint;
  maxTotal?: bigint;
  maxSessionDeposit?: bigint;
  alertThreshold?: bigint;
}

export interface SessionPreferences {
  preferSession?: boolean;
  maxDeposit?: bigint;
  autoClose?: boolean;
  idleTimeout?: bigint;
}

export interface AgentflowClientConfig {
  /** ICP identity for signing payments */
  identity: unknown; // @icp-sdk/core Ed25519KeyIdentity
  /** CAIP-2 network identifier */
  network: string;
  /** Automatically handle 402 responses */
  autoPayment?: boolean;
  /** Budget limits */
  budget?: BudgetConfig;
  /** Session preferences */
  sessions?: SessionPreferences;
  /** Callback when budget alert threshold is hit */
  onBudgetAlert?: (spent: bigint, limit: bigint) => Promise<void>;
}

export interface SessionHandle {
  id: string;
  deposited: bigint;
  consumed: bigint;
  remaining: bigint;
  call(method: string, args: unknown[]): Promise<unknown>;
  close(): Promise<PaymentReceipt>;
}

/**
 * agentflow TypeScript client SDK.
 *
 * Handles x402 charge payments and MPP-style sessions against
 * agentflow-enabled ICP canisters.
 */
export class AgentflowClient {
  private config: AgentflowClientConfig;
  private totalSpent = 0n;

  constructor(config: AgentflowClientConfig) {
    this.config = config;
  }

  /**
   * Call a canister method, auto-handling 402 payment if needed.
   */
  async call(canisterId: string, method: string, args: unknown[]): Promise<unknown> {
    // TODO: call canister, handle 402, sign ICRC-2 approval, retry
    throw new Error('Not yet implemented');
  }

  /**
   * Open a streaming session with escrow deposit.
   */
  async openSession(canisterId: string, config?: Partial<SessionPreferences>): Promise<SessionHandle> {
    // TODO: request session intent, deposit via ICRC-2, return handle
    throw new Error('Not yet implemented');
  }

  /**
   * Discover agents via ERC-8004 registries.
   */
  async discoverAgents(query: {
    chain: string;
    skills?: string[];
    x402Support?: boolean;
    minReputation?: number;
  }): Promise<Array<{ agentId: number; name: string; endpoint: string; reputation: number }>> {
    // TODO: query ERC-8004 IdentityRegistry + ReputationRegistry via viem
    throw new Error('Not yet implemented');
  }
}
