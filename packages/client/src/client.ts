import type { PaymentReceipt, SessionIntent, SessionState, Voucher } from './types.js';
import { signVoucher, type VoucherSigner } from './voucher.js';

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
 * Handles x402 charge payments and streaming sessions against
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
   *
   * Flow: call method → if #paymentRequired → icrc2_approve → create sig → retry
   */
  async call(
    canisterId: string,
    method: string,
    args: unknown[],
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    actorFactory?: (canisterId: string) => any,
  ): Promise<unknown> {
    if (!actorFactory) {
      throw new Error('actorFactory required: provide a function that creates an actor for the canister');
    }

    const actor = actorFactory(canisterId);
    const result = await actor[method](...args);

    // Check for payment required response
    if (result && typeof result === 'object' && 'paymentRequired' in result) {
      if (!this.config.autoPayment) {
        throw new Error('Payment required but autoPayment is disabled');
      }

      const requirement = result.paymentRequired;

      // Check budget limits
      if (this.config.budget?.maxPerRequest && requirement.amount > this.config.budget.maxPerRequest) {
        throw new Error(`Amount ${requirement.amount} exceeds maxPerRequest ${this.config.budget.maxPerRequest}`);
      }

      if (this.config.budget?.maxTotal && this.totalSpent + requirement.amount > this.config.budget.maxTotal) {
        throw new Error('Total budget exceeded');
      }

      // TODO: icrc2_approve for the amount, then construct PaymentSignature and retry
      // For MVP, the caller must handle approval externally
      throw new Error('Auto-approval not yet implemented — approve ICRC-2 externally and pass signature');
    }

    if (result && typeof result === 'object' && 'ok' in result) {
      return result.ok;
    }

    return result;
  }

  /**
   * Open a streaming session with escrow deposit.
   *
   * Flow: requestSession → calculate deposit → icrc2_approve → openSession → SessionHandle
   */
  async openSession(
    canisterId: string,
    config?: Partial<SessionPreferences>,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    actorFactory?: (canisterId: string) => any,
    signer?: VoucherSigner,
  ): Promise<SessionHandle> {
    if (!actorFactory) {
      throw new Error('actorFactory required');
    }

    const actor = actorFactory(canisterId);
    const intent: SessionIntent = await actor.requestSession();

    const maxDeposit = config?.maxDeposit ?? this.config.sessions?.maxDeposit ?? intent.suggestedDeposit;
    const autoClose = config?.autoClose ?? this.config.sessions?.autoClose ?? true;
    const idleTimeout = config?.idleTimeout ?? this.config.sessions?.idleTimeout;

    // Check budget
    if (this.config.budget?.maxSessionDeposit && maxDeposit > this.config.budget.maxSessionDeposit) {
      throw new Error(`Deposit ${maxDeposit} exceeds maxSessionDeposit ${this.config.budget.maxSessionDeposit}`);
    }

    // TODO: icrc2_approve for deposit amount
    // For MVP, caller must approve externally before calling openSession

    const sessionConfig = {
      maxDeposit,
      autoClose,
      idleTimeout: idleTimeout ? [idleTimeout] : [],
    };

    // Construct a payment signature (placeholder — approval must be done externally)
    const sig = {
      scheme: 'exact',
      network: this.config.network,
      signature: new Uint8Array(64),
      sender: '', // Will be filled from identity
      nonce: new Uint8Array(32),
    };

    const result = await actor.openSession(sessionConfig, sig);

    if ('err' in result) {
      throw new Error(`Failed to open session: ${result.err}`);
    }

    const state: SessionState = result.ok;
    let sequence = 0n;
    let consumed = 0n;

    const handle: SessionHandle = {
      id: state.id,
      deposited: state.deposited,
      get consumed() { return consumed; },
      get remaining() { return state.deposited - consumed; },

      async call(method: string, callArgs: unknown[]): Promise<unknown> {
        // Calculate new cumulative amount (costPerCall from intent, or 1 unit)
        const cost = intent.costPerCall ?? 1n;
        consumed += cost;
        sequence += 1n;

        // Sign voucher
        let signature: Uint8Array = new Uint8Array(64);
        if (signer) {
          signature = new Uint8Array(await signVoucher(signer, state.id, consumed, sequence));
        }

        const voucher: Voucher = {
          sessionId: state.id,
          cumulativeAmount: consumed,
          sequence,
          signature,
        };

        const callResult = await actor[method](voucher, ...callArgs);
        if (callResult && typeof callResult === 'object' && 'ok' in callResult) {
          return callResult.ok;
        }
        if (callResult && typeof callResult === 'object' && 'error' in callResult) {
          throw new Error(callResult.error);
        }
        return callResult;
      },

      async close(): Promise<PaymentReceipt> {
        const closeResult = await actor.endSession(state.id);
        if ('ok' in closeResult) {
          return closeResult.ok;
        }
        throw new Error(`Failed to close session: ${JSON.stringify(closeResult)}`);
      },
    };

    return handle;
  }

  /**
   * Discover agents via ERC-8004 registries.
   * Stub: returns empty array (registries are sparse).
   */
  async discoverAgents(_query: {
    chain: string;
    skills?: string[];
    x402Support?: boolean;
    minReputation?: number;
  }): Promise<Array<{ agentId: number; name: string; endpoint: string; reputation: number }>> {
    // TODO: query ERC-8004 IdentityRegistry + ReputationRegistry via viem
    return [];
  }
}
