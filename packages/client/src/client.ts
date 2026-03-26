import type {
  ContentDelivery,
  PaymentReceipt,
  SessionIntent,
  SessionState,
  Voucher,
} from './types.js';
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
  /** For EVM sessions: the tx hash proving the USDC deposit on-chain. */
  evmTxHash?: string;
  /** For EVM sessions: the CAIP-2 network (e.g., "eip155:84532"). Overrides config.network. */
  evmNetwork?: string;
  /** For EVM sessions: the payer's EVM address (for refund on close). */
  evmSender?: string;
  /** For EVM sessions: the ERC-20 token contract address. */
  evmToken?: string;
  /** For EVM sessions: the canister's EVM address (settlement recipient). */
  evmRecipient?: string;
}

export interface Ic402ClientConfig {
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
  /** Ledger canister ID for ICRC-2 auto-approval */
  ledger?: string;
  /** Default target canister ID (spender for ICRC-2 approval) */
  canisterId?: string;
  /** Factory to create a ledger actor for ICRC-2 calls. Required for autoPayment. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ledgerActorFactory?: (ledgerCanisterId: string) => any;
}

export interface SessionHandle {
  id: string;
  deposited: bigint;
  consumed: bigint;
  remaining: bigint;
  call(method: string, args: unknown[]): Promise<unknown>;
  callForContent(method: string, args: unknown[]): Promise<ContentDelivery>;
  close(): Promise<PaymentReceipt>;
}

/**
 * ic402 TypeScript client SDK.
 *
 * Handles x402 charge payments and streaming sessions against
 * ic402-enabled ICP canisters.
 */
export class Ic402Client {
  private config: Ic402ClientConfig;
  private totalSpent = 0n;

  constructor(config: Ic402ClientConfig) {
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
      throw new Error(
        'actorFactory required: provide a function that creates an actor for the canister',
      );
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
      if (
        this.config.budget?.maxPerRequest &&
        requirement.amount > this.config.budget.maxPerRequest
      ) {
        throw new Error(
          `Amount ${requirement.amount} exceeds maxPerRequest ${this.config.budget.maxPerRequest}`,
        );
      }

      if (
        this.config.budget?.maxTotal &&
        this.totalSpent + requirement.amount > this.config.budget.maxTotal
      ) {
        throw new Error('Total budget exceeded');
      }

      if (!this.config.ledger || !this.config.ledgerActorFactory) {
        throw new Error('Auto-approval requires ledger and ledgerActorFactory in config');
      }

      // ICRC-2 approve: allow the target canister to spend the required amount
      const ledgerActor = this.config.ledgerActorFactory(this.config.ledger);
      const approveResult = await ledgerActor.icrc2_approve({
        spender: { owner: canisterId, subaccount: [] },
        amount: requirement.amount,
        fee: [],
        memo: [],
        from_subaccount: [],
        created_at_time: [],
        expected_allowance: [],
        expires_at: [],
      });

      if (approveResult && typeof approveResult === 'object' && 'Err' in approveResult) {
        throw new Error(`ICRC-2 approve failed: ${JSON.stringify(approveResult.Err)}`);
      }

      this.totalSpent += requirement.amount;

      // Construct PaymentSignature from the requirement's nonce and retry
      const sig = {
        scheme: 'exact',
        network: this.config.network,
        signature: requirement.nonce,
        publicKey: [],
        sender: '',
        nonce: requirement.nonce,
        authorization: [],
      };

      // Retry: replace the last arg (optional PaymentSignature) with our sig
      const retryArgs = [...args];
      retryArgs[retryArgs.length - 1] = [sig];
      const retryResult = await actor[method](...retryArgs);

      if (retryResult && typeof retryResult === 'object' && 'ok' in retryResult) {
        return retryResult.ok;
      }
      return retryResult;
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
    let intent: SessionIntent = await actor.requestSession();

    // For EVM sessions, override the intent's network, token, and recipient
    if (config?.evmNetwork) {
      intent = {
        ...intent,
        network: config.evmNetwork,
        ...(config.evmToken ? { token: config.evmToken } : {}),
        ...(config.evmRecipient ? { recipient: config.evmRecipient } : {}),
      };
    }

    const maxDeposit =
      config?.maxDeposit ?? this.config.sessions?.maxDeposit ?? intent.suggestedDeposit;
    const autoClose = config?.autoClose ?? this.config.sessions?.autoClose ?? true;
    const idleTimeout = config?.idleTimeout ?? this.config.sessions?.idleTimeout;

    // Check budget
    if (
      this.config.budget?.maxSessionDeposit &&
      maxDeposit > this.config.budget.maxSessionDeposit
    ) {
      throw new Error(
        `Deposit ${maxDeposit} exceeds maxSessionDeposit ${this.config.budget.maxSessionDeposit}`,
      );
    }

    const isEvm = !!config?.evmTxHash;
    const network = config?.evmNetwork ?? this.config.network;

    // ICRC-2 approve deposit amount (ICP sessions only)
    if (!isEvm && this.config.autoPayment && this.config.ledger && this.config.ledgerActorFactory) {
      const ledgerActor = this.config.ledgerActorFactory(this.config.ledger);
      const approveResult = await ledgerActor.icrc2_approve({
        spender: { owner: canisterId, subaccount: [] },
        amount: maxDeposit,
        fee: [],
        memo: [],
        from_subaccount: [],
        created_at_time: [],
        expected_allowance: [],
        expires_at: [],
      });

      if (approveResult && typeof approveResult === 'object' && 'Err' in approveResult) {
        throw new Error(`ICRC-2 approve failed: ${JSON.stringify(approveResult.Err)}`);
      }
    }

    const sessionConfig = {
      maxDeposit,
      autoClose,
      idleTimeout: idleTimeout ? [idleTimeout] : [],
    };

    // Construct a payment signature.
    // publicKey: Ed25519 public key for voucher verification (both ICP and EVM).
    // signature: empty for ICP, EVM tx hash bytes for EVM.
    // sender: empty for ICP (filled by identity), payer's EVM address for EVM.
    let pubKey: Uint8Array = new Uint8Array(32);
    if (signer) {
      pubKey = new Uint8Array(await signer.getPublicKey());
    }

    const sig = {
      scheme: 'exact',
      network,
      signature: isEvm
        ? Array.from(new TextEncoder().encode(config!.evmTxHash!))
        : new Uint8Array(0),
      publicKey: [Array.from(pubKey)],
      sender: config?.evmSender ?? '',
      nonce: new Uint8Array(32),
      authorization: [],
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
      get consumed() {
        return consumed;
      },
      get remaining() {
        return state.deposited - consumed;
      },

      async call(method: string, callArgs: unknown[]): Promise<unknown> {
        // Calculate new cumulative amount (costPerCall from intent, or 1 unit)
        // costPerCall is opt nat — Candid decodes as [bigint] or []
        const rawCost = intent.costPerCall;
        const cost =
          Array.isArray(rawCost) && rawCost.length > 0
            ? BigInt(rawCost[0])
            : typeof rawCost === 'bigint'
              ? rawCost
              : 1n;
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

      async callForContent(method: string, callArgs: unknown[]): Promise<ContentDelivery> {
        const cost = intent.costPerCall ?? 1n;
        consumed += cost;
        sequence += 1n;

        let sig: Uint8Array = new Uint8Array(64);
        if (signer) {
          sig = new Uint8Array(await signVoucher(signer, state.id, consumed, sequence));
        }

        const v: Voucher = {
          sessionId: state.id,
          cumulativeAmount: consumed,
          sequence,
          signature: sig,
        };

        const callResult = await actor[method](v, ...callArgs);
        if (callResult && typeof callResult === 'object' && 'ok' in callResult) {
          return callResult.ok as ContentDelivery;
        }
        if (callResult && typeof callResult === 'object' && 'error' in callResult) {
          throw new Error(callResult.error as string);
        }
        return callResult as ContentDelivery;
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
   * Fetch content from a ContentDelivery response.
   * Handles all delivery methods: inline, httpUrl, canisterQuery, assetCanister.
   */
  async fetchContent(
    delivery: ContentDelivery,
    options?: {
      canisterId?: string;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      actorFactory?: (canisterId: string) => any;
    },
  ): Promise<Uint8Array> {
    const method = delivery.delivery;

    if ('inline' in method) {
      return method.inline;
    }

    if ('httpUrl' in method) {
      // M-4: Validate URL scheme before fetching
      const httpUrl = method.httpUrl;
      if (!/^https?:\/\//i.test(httpUrl)) {
        throw new Error(`Invalid httpUrl: must use http(s) scheme`);
      }
      const response = await fetch(httpUrl);
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      return new Uint8Array(await response.arrayBuffer());
    }

    if ('assetCanister' in method) {
      const { canisterId, path } = method.assetCanister;
      // M-4: Validate canisterId format (ICP principal) and path (no traversal)
      const cidStr = String(canisterId);
      if (!/^[a-z0-9-]+$/.test(cidStr)) {
        throw new Error(`Invalid canisterId format: ${cidStr}`);
      }
      if (typeof path !== 'string' || !path.startsWith('/') || path.includes('..')) {
        throw new Error(`Invalid asset path: must start with / and not contain ..`);
      }
      const url = `https://${cidStr}.icp0.io${path}`;
      const response = await fetch(url);
      if (!response.ok)
        throw new Error(`Asset canister ${response.status}: ${response.statusText}`);
      return new Uint8Array(await response.arrayBuffer());
    }

    if ('canisterQuery' in method) {
      const { method: queryMethod, chunkCount } = method.canisterQuery;
      const cid = options?.canisterId;
      if (!cid || !options?.actorFactory) {
        throw new Error('canisterId and actorFactory required for canisterQuery delivery');
      }
      const actor = options.actorFactory(cid);
      const chunks: Uint8Array[] = [];
      for (let i = 0n; i < chunkCount; i++) {
        const chunk = await actor[queryMethod](delivery.grant, Number(i));
        chunks.push(new Uint8Array(chunk as ArrayBuffer));
      }
      const totalLength = chunks.reduce((acc, c) => acc + c.length, 0);
      const result = new Uint8Array(totalLength);
      let offset = 0;
      for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.length;
      }
      return result;
    }

    throw new Error('Unknown delivery method');
  }

  /**
   * Discover agents via ERC-8004 registries.
   *
   * Stub: returns empty array. ERC-8004 IdentityRegistry and ReputationRegistry
   * contracts are deployed but registries are sparse — no real agent data to
   * query yet. When registries are populated, this will use viem to query
   * on-chain agent cards filtered by chain, skills, and reputation.
   */
  async discoverAgents(_query: {
    chain: string;
    skills?: string[];
    x402Support?: boolean;
    minReputation?: number;
  }): Promise<Array<{ agentId: number; name: string; endpoint: string; reputation: number }>> {
    return [];
  }
}
