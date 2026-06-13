/// EIP-712 typed data construction for TransferWithAuthorization.
///
/// Builds the typed data structure that standard x402 clients sign
/// for EIP-3009 USDC transfers. Works with any EIP-712 signer
/// (viem, ethers, MetaMask, etc.).

/** EIP-712 domain for USDC contracts (Circle FiatTokenV2). */
export function usdcDomain(chainId: number, tokenAddress: string) {
  return {
    name: 'USD Coin' as const,
    version: '2' as const,
    chainId,
    verifyingContract: tokenAddress as `0x${string}`,
  };
}

/** EIP-712 type definition for TransferWithAuthorization. */
export const TRANSFER_WITH_AUTHORIZATION_TYPES = {
  TransferWithAuthorization: [
    { name: 'from', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce', type: 'bytes32' },
  ],
} as const;

/** Parameters for building a TransferWithAuthorization. */
export interface TransferAuthorizationParams {
  from: string; // payer address (0x-prefixed)
  to: string; // recipient address (canister's EVM address)
  value: bigint; // USDC amount
  validAfter?: number; // unix timestamp (default: 0 = immediately)
  validBefore?: number; // unix timestamp (default: now + 5 minutes)
}

/** Generate a random bytes32 hex string for the EIP-3009 nonce.
 *  C-2: Requires Web Crypto API — no insecure Math.random() fallback. */
export function randomNonce(): string {
  if (typeof globalThis.crypto === 'undefined' || !globalThis.crypto.getRandomValues) {
    throw new Error(
      'ic402: Web Crypto API required for secure nonce generation. ' +
        'Ensure globalThis.crypto.getRandomValues is available (Node.js >= 19, modern browsers, or polyfill).',
    );
  }
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return (
    '0x' +
    Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')
  );
}

/** Build the EIP-712 message for TransferWithAuthorization. */
export function buildTransferAuthorizationMessage(params: TransferAuthorizationParams) {
  const nonce = randomNonce();
  const validAfter = params.validAfter ?? 0;
  const validBefore = params.validBefore ?? Math.floor(Date.now() / 1000) + 300;

  return {
    from: params.from as `0x${string}`,
    to: params.to as `0x${string}`,
    value: params.value,
    validAfter: BigInt(validAfter),
    validBefore: BigInt(validBefore),
    nonce: nonce as `0x${string}`,
  };
}

// (removed) buildX402PaymentHeader — it emitted a conflicting x402Version:1 payload, was never
// used internally, and produced an incomplete payload (no v2 `accepted` echo). The live payment
// flow builds the v2 PaymentPayload header inline in evm.ts (probeX402 → pay). Build the v2
// header there or via the canister's signX402Payment, which echoes the chosen requirement.
