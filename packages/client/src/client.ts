import { Principal } from '@icp-sdk/core/principal';

/** Minimal identity interface — any ICP identity that can provide a principal. */
export interface Ic402Identity {
  getPrincipal(): { toText(): string };
}

/** JSON.stringify that handles BigInt values. */
function safeStringify(value: unknown): string {
  return JSON.stringify(value, (_key: string, val: unknown) =>
    typeof val === 'bigint' ? val.toString() : val,
  );
}
import type {
  ContentDelivery,
  Job,
  PaymentReceipt,
  ServiceDefinition,
  SessionIntent,
  SessionState,
  SignedAuthorization,
  SignedTransaction,
  Voucher,
} from './types.js';
import { signVoucher, type VoucherSigner } from './voucher.js';
import {
  Ic402Error,
  classifyNetworkError,
  probeX402 as probeX402Url,
  createEvmClient,
  getEvmNonce,
  getFeeData,
  broadcastTransaction as broadcastTx,
  registerAgent as registerAgentFlow,
  type FetchX402Result,
} from './evm.js';

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
  /** For EVM sessions: the EIP-3009 authorization (signed by the payer). */
  authorization?: {
    from: string;
    to: string;
    value: number | bigint;
    validAfter: number | bigint;
    validBefore: number | bigint;
    nonce: number[];
    v: number;
    r: number[];
    s: number[];
  };
}

export interface Ic402ClientConfig {
  /** Target canister ID. Required for all operations. */
  canisterId: string;
  /** Factory to create actors for canister calls. Required for all operations. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  actorFactory: (canisterId: string) => any;
  /** ICP identity for signing payments */
  identity: Ic402Identity | null;
  /** CAIP-2 network identifier (e.g., "icp:1" for ICP, "eip155:84532" for Base Sepolia) */
  network: string;
  /** Automatically handle 402 responses (ICP: ICRC-2 approve + retry) */
  autoPayment?: boolean;
  /** Budget limits (enforced client-side before calling canister) */
  budget?: BudgetConfig;
  /** Session preferences */
  sessions?: SessionPreferences;
  /** Callback when spending approaches budget limit */
  onBudgetAlert?: (spent: bigint, limit: bigint) => Promise<void>;
  /** Ledger canister ID for ICRC-2 auto-approval (ICP payments) */
  ledger?: string;
  /** Factory for ledger actors. Required for ICP auto-payment. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ledgerActorFactory?: (ledgerCanisterId: string) => any;
  /** Custom EVM RPC URL. If omitted, uses a public RPC for the chain. */
  evmRpcUrl?: string;
  /** Fee buffer added to ICRC-2 approval amount (default: 100_000). */
  approvalFeeBuffer?: bigint;
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
  async call(method: string, args: unknown[], canisterId?: string): Promise<unknown> {
    const cid = canisterId ?? this.config.canisterId;
    const actor = this.config.actorFactory(cid);
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

      // ICRC-2 approve: allow the target canister to spend amount + fee buffer
      const ledgerActor = this.config.ledgerActorFactory(this.config.ledger);
      const approveResult = await ledgerActor.icrc2_approve({
        spender: { owner: Principal.fromText(cid), subaccount: [] },
        amount: requirement.amount + (this.config.approvalFeeBuffer ?? 100_000n),
        fee: [],
        memo: [],
        from_subaccount: [],
        created_at_time: [],
        expected_allowance: [],
        expires_at: [],
      });

      if (approveResult && typeof approveResult === 'object' && 'Err' in approveResult) {
        throw new Error(`ICRC-2 approve failed: ${safeStringify(approveResult.Err)}`);
      }

      this.totalSpent += requirement.amount;

      // Construct PaymentSignature from the requirement's nonce and retry
      const sender = this.config.identity?.getPrincipal().toText() ?? '';
      const sig = {
        scheme: 'exact',
        network: this.config.network,
        signature: requirement.nonce,
        publicKey: [],
        sender,
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
    sessionConfig?: Partial<SessionPreferences>,
    signer?: VoucherSigner,
    canisterId?: string,
  ): Promise<SessionHandle> {
    const cid = canisterId ?? this.config.canisterId;
    const config = sessionConfig;
    const actor = this.config.actorFactory(cid);
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
        spender: { owner: Principal.fromText(cid), subaccount: [] },
        amount: maxDeposit + (this.config.approvalFeeBuffer ?? 100_000n),
        fee: [],
        memo: [],
        from_subaccount: [],
        created_at_time: [],
        expected_allowance: [],
        expires_at: [],
      });

      if (approveResult && typeof approveResult === 'object' && 'Err' in approveResult) {
        throw new Error(`ICRC-2 approve failed: ${safeStringify(approveResult.Err)}`);
      }
    }

    const openConfig = {
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

    const evmAuth = config?.authorization;
    const sig = {
      scheme: 'exact',
      network,
      signature: isEvm
        ? Array.from(new TextEncoder().encode(config!.evmTxHash!))
        : new Uint8Array(0),
      publicKey: [pubKey],
      sender: config?.evmSender ?? '',
      nonce: new Uint8Array(32),
      authorization: evmAuth
        ? [
            {
              from: evmAuth.from,
              to: evmAuth.to,
              value: typeof evmAuth.value === 'bigint' ? evmAuth.value : BigInt(evmAuth.value),
              validAfter:
                typeof evmAuth.validAfter === 'bigint'
                  ? evmAuth.validAfter
                  : BigInt(evmAuth.validAfter),
              validBefore:
                typeof evmAuth.validBefore === 'bigint'
                  ? evmAuth.validBefore
                  : BigInt(evmAuth.validBefore),
              nonce: evmAuth.nonce,
              v: evmAuth.v,
              r: evmAuth.r,
              s: evmAuth.s,
            },
          ]
        : [],
    };

    const result = await actor.openSession(openConfig, sig);

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
        throw new Error(`Failed to close session: ${safeStringify(closeResult)}`);
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

  // ── EVM Remote Signing ──

  /**
   * Fetch from an x402-gated URL. The full flow:
   * 1. Client probes the URL → gets 402 with payment requirements
   * 2. Client calls canister signX402Payment → gets signed EIP-3009 header
   * 3. Client retries the URL with the signed X-Payment header
   *
   * @param url - The x402-gated URL to fetch
   * @param actorFactory - Factory to create canister actor
   */
  async fetchX402(
    url: string,
    options?: { init?: RequestInit; chainId?: number },
  ): Promise<FetchX402Result> {
    const { init, chainId } = options ?? {};
    const cid = chainId ?? this.tryExtractChainId();
    if (!cid) {
      return {
        status: 'error',
        error: new Ic402Error(
          'config_error',
          'EVM chain ID required: set config.network to "eip155:<chainId>" or pass chainId to fetchX402',
        ),
      };
    }
    const actor = this.config.actorFactory(this.config.canisterId);

    // 1. Probe
    const probeResult = await probeX402Url(url, cid, init);
    if (probeResult.status === 'free') return probeResult;
    if (probeResult.status === 'error') return probeResult;
    const { paymentOption } = probeResult;

    // Budget check
    if (
      this.config.budget?.maxPerRequest &&
      paymentOption.amount > this.config.budget.maxPerRequest
    ) {
      return {
        status: 'error',
        error: new Ic402Error(
          'budget_exceeded',
          `Amount ${paymentOption.amount} exceeds maxPerRequest ${this.config.budget.maxPerRequest}`,
        ),
      };
    }
    if (
      this.config.budget?.maxTotal &&
      this.totalSpent + paymentOption.amount > this.config.budget.maxTotal
    ) {
      return { status: 'error', error: new Ic402Error('budget_exceeded', 'Total budget exceeded') };
    }

    // 2. Sign via canister
    let signed: SignedAuthorization;
    try {
      // Extract chain ID from payment option's network (e.g., "eip155:8453" → 8453)
      const optionChainId = parseInt(paymentOption.network.replace('eip155:', ''), 10) || cid;
      const result = await actor.signX402Payment(
        optionChainId,
        paymentOption.asset,
        paymentOption.recipient,
        paymentOption.amount,
        paymentOption.tokenName,
        paymentOption.tokenVersion,
      );
      if ('err' in result) {
        return { status: 'error', error: new Ic402Error('sign_failed', result.err) };
      }
      signed = result.ok;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return { status: 'error', error: new Ic402Error('sign_failed', msg, e) };
    }

    this.totalSpent += signed.paidAmount;

    // Alert callback
    if (
      this.config.budget?.alertThreshold &&
      this.config.budget.maxTotal &&
      this.config.onBudgetAlert
    ) {
      const remaining = this.config.budget.maxTotal - this.totalSpent;
      if (remaining <= this.config.budget.alertThreshold) {
        await this.config.onBudgetAlert(this.totalSpent, this.config.budget.maxTotal);
      }
    }

    // 3. Retry with payment header
    let response: Response;
    try {
      const headers = new Headers(init?.headers);
      headers.set('X-Payment', signed.header);
      headers.set('Payment-Signature', signed.header);
      response = await fetch(url, { ...init, headers });
    } catch (e) {
      return { status: 'error', error: classifyNetworkError(e) };
    }

    const body = await response.text();
    if (response.ok)
      return { status: 'ok', code: response.status, body, paidAmount: signed.paidAmount };
    if (response.status === 402)
      return { status: 'error', error: new Ic402Error('settlement_failed', body.slice(0, 200)) };
    return {
      status: 'error',
      error: new Ic402Error('http_error', `HTTP ${response.status}: ${body.slice(0, 200)}`),
    };
  }

  /**
   * Register the canister as an agent on the ERC-8004 IdentityRegistry.
   * Full flow: get chain state → canister signs → client broadcasts → poll receipt.
   *
   * @param actorFactory - Factory to create canister actor
   * @param rpcUrl - Optional custom RPC URL for the target chain
   */
  async registerAgent(
    rpcUrl?: string,
    chainId?: number,
  ): Promise<{ tokenId: bigint | null; txHash: string }> {
    const cid = chainId ?? this.extractChainId();
    const actor = this.config.actorFactory(this.config.canisterId);
    const evmAddress: string = await actor.getEvmAddress();
    const rpc = rpcUrl ?? this.config.evmRpcUrl;

    const result = await registerAgentFlow(
      async (nonce, maxFee, priorityFee) => {
        const r = await actor.signAgentRegistration(nonce, maxFee, priorityFee);
        if ('err' in r) throw new Ic402Error('sign_failed', r.err);
        return r.ok;
      },
      evmAddress,
      cid,
      rpc,
    );

    if (result.tokenId != null) {
      try {
        await actor.setAgentId?.(result.tokenId);
      } catch {
        /* optional */
      }
    }

    return { tokenId: result.tokenId, txHash: result.txHash };
  }

  /**
   * Sign and broadcast an ERC-20 transfer.
   * Client fetches chain state, canister signs, client broadcasts.
   */
  async sendErc20Transfer(
    tokenAddress: string,
    recipient: string,
    amount: bigint,
    rpcUrl?: string,
  ): Promise<{ txHash: string }> {
    const chainId = this.extractChainId();
    const actor = this.config.actorFactory(this.config.canisterId);
    const evmAddress: string = await actor.getEvmAddress();
    const rpc = rpcUrl ?? this.config.evmRpcUrl;

    const client = createEvmClient(chainId, rpc);
    const [nonce, fees] = await Promise.all([getEvmNonce(client, evmAddress), getFeeData(client)]);

    const result = await actor.signErc20Transfer(
      chainId,
      tokenAddress,
      recipient,
      amount,
      nonce,
      fees.maxFeePerGas,
      fees.maxPriorityFeePerGas,
    );
    if ('err' in result) throw new Ic402Error('sign_failed', result.err);

    const txHash = await broadcastTx(client, result.ok.rawTx);
    return { txHash };
  }

  /**
   * Sign and broadcast a native ETH transfer.
   */
  async sendEthTransfer(
    recipient: string,
    amountWei: bigint,
    rpcUrl?: string,
  ): Promise<{ txHash: string }> {
    const chainId = this.extractChainId();
    const actor = this.config.actorFactory(this.config.canisterId);
    const evmAddress: string = await actor.getEvmAddress();
    const rpc = rpcUrl ?? this.config.evmRpcUrl;

    const client = createEvmClient(chainId, rpc);
    const [nonce, fees] = await Promise.all([getEvmNonce(client, evmAddress), getFeeData(client)]);

    const result = await actor.signEthTransfer(
      chainId,
      recipient,
      amountWei,
      21000,
      nonce,
      fees.maxFeePerGas,
      fees.maxPriorityFeePerGas,
    );
    if ('err' in result) throw new Ic402Error('sign_failed', result.err);

    const txHash = await broadcastTx(client, result.ok.rawTx);
    return { txHash };
  }

  /** Extract numeric chain ID from CAIP-2 network string, or null if not EVM. */
  private tryExtractChainId(): number | null {
    const match = this.config.network.match(/^eip155:(\d+)$/);
    return match ? parseInt(match[1]!, 10) : null;
  }

  /** Extract chain ID or throw. */
  private extractChainId(): number {
    const id = this.tryExtractChainId();
    if (id == null)
      throw new Ic402Error(
        'config_error',
        `Expected EVM network (eip155:*), got: ${this.config.network}`,
      );
    return id;
  }

  // ── Service Marketplace ──

  /**
   * List available services from the canister.
   */
  async listServices(): Promise<ServiceDefinition[]> {
    const actor = this.config.actorFactory(this.config.canisterId);
    return actor.listServices();
  }

  /**
   * Submit a paid service request. Handles x402 payment automatically.
   * Returns the job ID for polling.
   */
  async submitServiceRequest(serviceId: string, params: Uint8Array): Promise<{ jobId: string }> {
    const actor = this.config.actorFactory(this.config.canisterId);
    const result = await actor.submitServiceRequest(serviceId, Array.from(params), []);

    if (result && typeof result === 'object' && 'paymentRequired' in result) {
      if (!this.config.autoPayment) {
        throw new Ic402Error('config_error', 'Payment required but autoPayment is disabled');
      }
      if (!this.config.ledger || !this.config.ledgerActorFactory) {
        throw new Ic402Error(
          'config_error',
          'Auto-approval requires ledger and ledgerActorFactory',
        );
      }

      const requirement = result.paymentRequired;
      const amount =
        Array.isArray(requirement) && requirement.length > 0 ? requirement[0].amount : 0n;

      if (this.config.budget?.maxPerRequest && amount > this.config.budget.maxPerRequest) {
        throw new Ic402Error('budget_exceeded', `Amount ${amount} exceeds maxPerRequest`);
      }

      // Approve amount + fee buffer (ICRC-2 transfer_from deducts fee from allowance)
      const approveAmount = amount + (this.config.approvalFeeBuffer ?? 100_000n);
      const ledgerActor = this.config.ledgerActorFactory(this.config.ledger);
      const approveResult = await ledgerActor.icrc2_approve({
        spender: { owner: Principal.fromText(this.config.canisterId), subaccount: [] },
        amount: approveAmount,
        fee: [],
        memo: [],
        from_subaccount: [],
        created_at_time: [],
        expected_allowance: [],
        expires_at: [],
      });
      if (approveResult && typeof approveResult === 'object' && 'Err' in approveResult) {
        throw new Ic402Error(
          'sign_failed',
          `ICRC-2 approve failed: ${safeStringify(approveResult.Err)}`,
        );
      }

      // Convert nonce to proper array — Candid may decode vec nat8 as Uint8Array or indexed object
      const rawNonce = requirement[0]?.nonce ?? new Uint8Array(32);
      const nonce =
        rawNonce instanceof Uint8Array
          ? Array.from(rawNonce)
          : Array.isArray(rawNonce)
            ? rawNonce
            : Object.values(rawNonce as Record<string, number>);
      // Sender must be the caller's principal — derive from identity if available
      const sender = this.config.identity?.getPrincipal().toText() ?? '';
      const sig = {
        scheme: 'exact',
        network: this.config.network,
        signature: nonce,
        publicKey: [],
        sender,
        nonce,
        authorization: [],
      };
      const retryResult = await actor.submitServiceRequest(serviceId, Array.from(params), [sig]);

      if (retryResult && typeof retryResult === 'object' && 'ok' in retryResult) {
        this.totalSpent += amount;
        return retryResult.ok as { jobId: string };
      }
      if (retryResult && typeof retryResult === 'object' && 'error' in retryResult) {
        throw new Ic402Error('sign_failed', retryResult.error as string);
      }
      throw new Ic402Error('unknown', `Unexpected result: ${safeStringify(retryResult)}`);
    }

    if (result && typeof result === 'object' && 'ok' in result) {
      return result.ok as { jobId: string };
    }
    if (result && typeof result === 'object' && 'error' in result) {
      throw new Ic402Error('sign_failed', result.error as string);
    }
    throw new Ic402Error('unknown', `Unexpected result: ${safeStringify(result)}`);
  }

  /**
   * Poll for a job result until completed or max attempts reached.
   * Returns the full job record when done.
   */
  async pollJobResult(jobId: string, maxAttempts = 30, intervalMs = 2000): Promise<Job> {
    const actor = this.config.actorFactory(this.config.canisterId);

    for (let i = 0; i < maxAttempts; i++) {
      const job = await actor.getJob(jobId);
      // Candid opt returns [job] or []
      const j: Job | null = Array.isArray(job) && job.length > 0 ? job[0] : job;
      if (!j) throw new Ic402Error('unknown', `Job not found: ${jobId}`);

      const status = j.status;
      if ('Settled' in status || 'Verified' in status || 'Submitted' in status) {
        return j;
      }
      if ('Disputed' in status) {
        throw new Ic402Error('sign_failed', `Job disputed: ${jobId}`);
      }
      if ('Expired' in status || 'Refunded' in status) {
        throw new Ic402Error('not_confirmed', `Job expired or refunded: ${jobId}`);
      }

      if (i < maxAttempts - 1) {
        await new Promise((r) => setTimeout(r, intervalMs));
      }
    }
    throw new Ic402Error(
      'not_confirmed',
      `Job ${jobId} not completed within ${maxAttempts} attempts`,
    );
  }

  /**
   * Dispute a job result (for BuyerConfirm verification).
   */
  async disputeJob(jobId: string, reason: string): Promise<void> {
    const actor = this.config.actorFactory(this.config.canisterId);
    const result = await actor.disputeJob(jobId, reason);
    if (result && typeof result === 'object' && 'err' in result) {
      throw new Ic402Error('unknown', result.err as string);
    }
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
