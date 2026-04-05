/// EVM client-side utilities for ic402 remote signing.
///
/// Handles the client half of the remote signing pattern:
/// probing x402 URLs, broadcasting signed transactions,
/// polling receipts, and fetching chain state.

import {
  createPublicClient,
  http,
  defineChain,
  keccak256,
  toHex,
  type Hash,
  type TransactionReceipt,
  type PublicClient,
  type Chain,
} from 'viem';
import type { SignedTransaction, SignedAuthorization } from './types.js';

// ── Error classification ──

export type Ic402ErrorKind =
  | 'transient' // Network timeout, RPC rate limit — safe to retry
  | 'no_match' // No payment option for the requested chain
  | 'sign_failed' // Canister refused to sign (policy, frozen, etc.)
  | 'settlement_failed' // Server rejected the signed payment
  | 'broadcast_failed' // EVM RPC rejected the transaction
  | 'insufficient_funds' // Not enough ETH for gas or USDC for payment
  | 'nonce_error' // Nonce too low/high — stale or concurrent tx
  | 'not_confirmed' // Tx broadcast but not confirmed within poll window
  | 'http_error' // Non-402 HTTP error from the server
  | 'config_error' // Missing required config (canisterId, network, etc.)
  | 'unknown'; // Unclassified error

export class Ic402Error extends Error {
  readonly kind: Ic402ErrorKind;
  readonly retryable: boolean;
  readonly detail?: unknown;

  constructor(kind: Ic402ErrorKind, message: string, detail?: unknown) {
    super(message);
    this.name = 'Ic402Error';
    this.kind = kind;
    this.retryable = kind === 'transient' || kind === 'nonce_error';
    this.detail = detail;
  }
}

export function classifyNetworkError(e: unknown): Ic402Error {
  const msg = e instanceof Error ? e.message : String(e);
  if (/timeout|ETIMEDOUT|ECONNREFUSED|ENOTFOUND|fetch failed/i.test(msg)) {
    return new Ic402Error('transient', msg, e);
  }
  if (/rate.?limit|429|too many/i.test(msg)) {
    return new Ic402Error('transient', msg, e);
  }
  return new Ic402Error('unknown', msg, e);
}

function classifyRpcError(e: unknown): Ic402Error {
  const msg = e instanceof Error ? e.message : String(e);
  if (/nonce too low/i.test(msg)) return new Ic402Error('nonce_error', msg, e);
  if (/nonce too high/i.test(msg)) return new Ic402Error('nonce_error', msg, e);
  if (/insufficient funds|gas/i.test(msg)) return new Ic402Error('insufficient_funds', msg, e);
  if (/timeout|rate.?limit|429/i.test(msg)) return new Ic402Error('transient', msg, e);
  return new Ic402Error('broadcast_failed', msg, e);
}

// ── Chain alias mapping (matches Motoko EvmSigner) ──

const CHAIN_ALIASES: Record<number, string> = {
  8453: 'base',
  84532: 'base-sepolia',
  1: 'ethereum',
  11155111: 'ethereum-sepolia',
  43114: 'avalanche',
  43113: 'avalanche-fuji',
  10: 'optimism',
  11155420: 'optimism-sepolia',
  42161: 'arbitrum',
  421614: 'arbitrum-sepolia',
};

// Default public RPCs per chain (free, no API key required)
const DEFAULT_RPC: Record<number, string> = {
  8453: 'https://mainnet.base.org',
  84532: 'https://sepolia.base.org',
  1: 'https://eth.llamarpc.com',
  11155111: 'https://rpc.sepolia.org',
  43114: 'https://api.avax.network/ext/bc/C/rpc',
  43113: 'https://api.avax-test.network/ext/bc/C/rpc',
  10: 'https://mainnet.optimism.io',
  11155420: 'https://sepolia.optimism.io',
  42161: 'https://arb1.arbitrum.io/rpc',
  421614: 'https://sepolia-rollup.arbitrum.io/rpc',
};

/** Build a minimal viem Chain from a chain ID and optional RPC URL. */
function chainForId(chainId: number, rpcUrl?: string): Chain {
  const url = rpcUrl ?? DEFAULT_RPC[chainId];
  if (!url)
    throw new Ic402Error('config_error', `No default RPC for chain ${chainId}. Provide rpcUrl.`);
  return defineChain({
    id: chainId,
    name: CHAIN_ALIASES[chainId] ?? `eip155:${chainId}`,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: {
      default: { http: [url] },
    },
  });
}

// ── Payment option parsing ──

export interface PaymentOption {
  recipient: string; // 0x-prefixed
  amount: bigint;
  tokenName: string; // EIP-712 domain name
  tokenVersion: string; // EIP-712 domain version
  network: string; // CAIP-2 network string
  asset: string; // token contract address
}

/**
 * Parse a 402 response and find the cheapest payment option matching the given chain.
 * Matches by CAIP-2 network string (eip155:{chainId}) or common alias (e.g., "base").
 */
export function findPaymentOption(body: string, chainId: number): PaymentOption | null {
  const caip2 = `eip155:${chainId}`;
  const alias = CHAIN_ALIASES[chainId] ?? '';

  // Try to parse as JSON first (structured format)
  try {
    const parsed = JSON.parse(body);
    const accepts: unknown[] = parsed.accepts ?? parsed.x402?.accepts ?? [parsed];

    let best: PaymentOption | null = null;
    let bestAmount = BigInt('0xFFFFFFFFFFFFFFFF');

    for (const entry of accepts) {
      const e = entry as Record<string, unknown>;
      const network = String(e.network ?? '');
      if (network !== caip2 && network !== alias) continue;

      const rawAmount = e.maxAmountRequired ?? e.amount;
      const amount = BigInt(String(rawAmount ?? '0'));
      if (amount <= 0n || amount >= bestAmount) continue;

      const payTo = String(e.payTo ?? '');
      if (!payTo) continue;

      const extra = (e.extra ?? {}) as Record<string, string>;
      best = {
        recipient: payTo,
        amount,
        tokenName: extra.name || 'USD Coin',
        tokenVersion: extra.version || '2',
        network: caip2,
        asset: String(e.asset ?? ''),
      };
      bestAmount = amount;
    }

    return best;
  } catch {
    // Fall back to string splitting (handles non-standard JSON or partial responses)
    return findPaymentOptionFromText(body, chainId, caip2, alias);
  }
}

function findPaymentOptionFromText(
  body: string,
  chainId: number,
  caip2: string,
  alias: string,
): PaymentOption | null {
  const needles = [`"network":"${caip2}"`, ...(alias ? [`"network":"${alias}"`] : [])];

  let best: PaymentOption | null = null;
  let bestAmount = BigInt('0xFFFFFFFFFFFFFFFF');

  for (const needle of needles) {
    const parts = body.split(needle);
    for (let i = 1; i < parts.length; i++) {
      const entry = parts[i]!;
      const payTo = extractJsonField(entry, 'payTo');
      let amount = extractJsonNat(entry, 'maxAmountRequired');
      if (amount === 0n) amount = extractJsonNat(entry, 'amount');
      if (!payTo || amount <= 0n || amount >= bestAmount) continue;

      const name = extractJsonField(entry, 'name') || 'USD Coin';
      const version = extractJsonField(entry, 'version') || '2';
      best = {
        recipient: payTo,
        amount,
        tokenName: name,
        tokenVersion: version,
        network: `eip155:${chainId}`,
        asset: extractJsonField(entry, 'asset') || '',
      };
      bestAmount = amount;
    }
  }

  return best;
}

function extractJsonField(text: string, field: string): string {
  const needle = `"${field}":"`;
  const idx = text.indexOf(needle);
  if (idx === -1) return '';
  const start = idx + needle.length;
  const end = text.indexOf('"', start);
  if (end === -1) return '';
  return text.slice(start, end);
}

function extractJsonNat(text: string, field: string): bigint {
  const needle = `"${field}":"`;
  const idx = text.indexOf(needle);
  if (idx === -1) {
    // Try without quotes around value
    const needle2 = `"${field}":`;
    const idx2 = text.indexOf(needle2);
    if (idx2 === -1) return 0n;
    const start = idx2 + needle2.length;
    const match = text.slice(start, start + 30).match(/^"?(\d+)"?/);
    return match ? BigInt(match[1]!) : 0n;
  }
  const start = idx + needle.length;
  const end = text.indexOf('"', start);
  if (end === -1) return 0n;
  try {
    return BigInt(text.slice(start, end));
  } catch {
    return 0n;
  }
}

// ── x402 probe and fetch ──

export type FetchX402Result =
  | { status: 'ok'; code: number; body: string; paidAmount: bigint }
  | { status: 'free'; code: number; body: string }
  | { status: 'error'; error: Ic402Error };

/**
 * Probe a URL for x402 payment requirements.
 * Returns the payment option if 402, or the response if free/error.
 */
export type ProbeResult =
  | { status: 'payment_required'; paymentOption: PaymentOption }
  | { status: 'free'; code: number; body: string }
  | { status: 'error'; error: Ic402Error };

/**
 * Probe a URL for x402 payment requirements.
 * Returns the payment option if 402, or the response if free/error.
 */
export async function probeX402(
  url: string,
  chainId: number,
  init?: RequestInit,
): Promise<ProbeResult> {
  let response: Response;
  try {
    response = await fetch(url, { ...init, redirect: 'follow' });
  } catch (e) {
    return { status: 'error', error: classifyNetworkError(e) };
  }

  if (response.status !== 402) {
    const body = await response.text();
    if (response.ok) return { status: 'free', code: response.status, body };
    return {
      status: 'error',
      error: new Ic402Error('http_error', `HTTP ${response.status}: ${body.slice(0, 200)}`, {
        code: response.status,
        body,
      }),
    };
  }

  // Parse 402 — check payment-required header first, then body
  let paymentJson = '';
  const paymentHeader = response.headers.get('payment-required');
  if (paymentHeader) {
    try {
      paymentJson = atob(paymentHeader);
    } catch {
      paymentJson = paymentHeader;
    }
  }
  if (!paymentJson) {
    paymentJson = await response.text();
  }

  const option = findPaymentOption(paymentJson, chainId);
  if (!option) {
    return {
      status: 'error',
      error: new Ic402Error('no_match', `No payment option for eip155:${chainId} in 402 response`),
    };
  }

  return { status: 'payment_required', paymentOption: option };
}

/**
 * Complete x402 fetch: probe → sign via canister → retry with payment header.
 *
 * @param url - The x402-gated URL
 * @param chainId - EVM chain to pay on
 * @param signPayment - Function that calls the canister's signX402Payment endpoint
 * @param init - Optional fetch init (method, headers, body)
 */
export async function fetchX402(
  url: string,
  chainId: number,
  signPayment: (
    recipient: string,
    amount: bigint,
    tokenName: string,
    tokenVersion: string,
  ) => Promise<SignedAuthorization>,
  init?: RequestInit,
): Promise<FetchX402Result> {
  // 1. Probe
  const probeResult = await probeX402(url, chainId, init);
  if (probeResult.status === 'free') return probeResult;
  if (probeResult.status === 'error') return probeResult;

  const { paymentOption } = probeResult;

  // 2. Sign via canister
  let signed: SignedAuthorization;
  try {
    signed = await signPayment(
      paymentOption.recipient,
      paymentOption.amount,
      paymentOption.tokenName,
      paymentOption.tokenVersion,
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const kind: Ic402ErrorKind = /policy|frozen|not.*owner|not.*operator/i.test(msg)
      ? 'sign_failed'
      : 'unknown';
    return { status: 'error', error: new Ic402Error(kind, msg, e) };
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
  if (response.ok) {
    return { status: 'ok', code: response.status, body, paidAmount: signed.paidAmount };
  }
  if (response.status === 402) {
    return { status: 'error', error: new Ic402Error('settlement_failed', body.slice(0, 200)) };
  }
  return {
    status: 'error',
    error: new Ic402Error('http_error', `HTTP ${response.status}: ${body.slice(0, 200)}`, {
      code: response.status,
    }),
  };
}

// ── EVM RPC utilities ──

/**
 * Create a viem public client for the given chain.
 * Uses the chain's default public RPC, or a custom URL.
 */
export function createEvmClient(chainId: number, rpcUrl?: string): PublicClient {
  const chain = chainForId(chainId, rpcUrl);
  return createPublicClient({ chain, transport: http(rpcUrl) }) as PublicClient;
}

/**
 * Get the current nonce for an address.
 */
export async function getEvmNonce(client: PublicClient, address: string): Promise<bigint> {
  return BigInt(await client.getTransactionCount({ address: address as `0x${string}` }));
}

/**
 * Get current fee data (maxFeePerGas, maxPriorityFeePerGas).
 */
export async function getFeeData(
  client: PublicClient,
): Promise<{ maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const block = await (client as any).getBlock({ blockTag: 'latest' });
  const baseFee: bigint = block.baseFeePerGas ?? 1_000_000_000n;
  const minPriority = 1_000_000n;
  const priorityFee =
    baseFee > 1_500_000_000n ? 1_500_000_000n : baseFee > minPriority ? baseFee : minPriority;
  return {
    maxFeePerGas: 2n * baseFee + priorityFee,
    maxPriorityFeePerGas: priorityFee,
  };
}

/**
 * Broadcast a signed raw transaction and return the tx hash.
 */
export async function broadcastTransaction(client: PublicClient, rawTx: string): Promise<Hash> {
  try {
    const hash = await client.request({
      method: 'eth_sendRawTransaction',
      params: [rawTx as `0x${string}`],
    });
    return hash as Hash;
  } catch (e) {
    throw classifyRpcError(e);
  }
}

/**
 * Poll for a transaction receipt until confirmed or max attempts reached.
 */
export async function pollReceipt(
  client: PublicClient,
  txHash: Hash,
  maxAttempts = 10,
  intervalMs = 3000,
): Promise<TransactionReceipt | null> {
  for (let i = 0; i < maxAttempts; i++) {
    try {
      const receipt = await client.getTransactionReceipt({ hash: txHash });
      if (receipt) return receipt;
    } catch {
      // Not yet mined
    }
    if (i < maxAttempts - 1) {
      await new Promise((r) => setTimeout(r, intervalMs));
    }
  }
  return null;
}

/**
 * Parse AgentRegistered event from transaction logs.
 * event AgentRegistered(uint256 indexed tokenId, address indexed owner, ...)
 */
export function parseAgentRegisteredEvent(receipt: TransactionReceipt): bigint | null {
  // M-8: Hash the event signature and compare against topics[0]
  const eventSigHash = keccak256(toHex('AgentRegistered(uint256,address,string,string,bool)'));
  for (const log of receipt.logs) {
    if (log.topics.length >= 2 && log.topics[0] === eventSigHash) {
      // topics[1] is the indexed tokenId
      const tokenId = log.topics[1];
      if (tokenId) {
        try {
          return BigInt(tokenId);
        } catch {
          continue;
        }
      }
    }
  }
  return null;
}

// ── High-level workflows ──

/**
 * Full agent registration flow: get chain state → sign via canister → broadcast → poll.
 *
 * @param signRegistration - Function that calls the canister's signAgentRegistration endpoint
 * @param chainId - Target EVM chain
 * @param rpcUrl - Optional custom RPC URL
 */
export async function registerAgent(
  signRegistration: (
    nonce: bigint,
    maxFeePerGas: bigint,
    maxPriorityFeePerGas: bigint,
  ) => Promise<SignedTransaction>,
  canisterEvmAddress: string,
  chainId: number,
  rpcUrl?: string,
): Promise<{ tokenId: bigint | null; txHash: Hash; receipt: TransactionReceipt | null }> {
  let client: PublicClient;
  try {
    client = createEvmClient(chainId, rpcUrl);
  } catch (e) {
    throw new Ic402Error(
      'config_error',
      `Failed to create EVM client: ${e instanceof Error ? e.message : String(e)}`,
    );
  }

  // 1. Get chain state
  let nonce: bigint;
  let fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint };
  try {
    [nonce, fees] = await Promise.all([
      getEvmNonce(client, canisterEvmAddress),
      getFeeData(client),
    ]);
  } catch (e) {
    throw classifyNetworkError(e);
  }

  // 2. Sign via canister
  let signed: SignedTransaction;
  try {
    signed = await signRegistration(nonce, fees.maxFeePerGas, fees.maxPriorityFeePerGas);
  } catch (e) {
    throw new Ic402Error('sign_failed', e instanceof Error ? e.message : String(e), e);
  }

  // 3. Broadcast (classifyRpcError handles nonce/gas/funds errors)
  const txHash = await broadcastTransaction(client, signed.rawTx);

  // 4. Poll for receipt
  const receipt = await pollReceipt(client, txHash);
  if (!receipt) {
    throw new Ic402Error(
      'not_confirmed',
      `Tx ${txHash} submitted but not confirmed within poll window`,
    );
  }

  // 5. Parse event
  const tokenId = parseAgentRegisteredEvent(receipt);

  return { tokenId, txHash, receipt };
}
