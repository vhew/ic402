import { describe, it, expect } from 'vitest';
import { hashTypedData } from 'viem';

/**
 * INTEROP DRIFT ALARM for colon-namespaced EIP-712 struct names (2.13.1).
 *
 * ic402's Eip712 encoder hashes a colon name context-free: the canonical type string is
 * `Name:Sub(fields…)` and nothing else. viem does NOT — its dependency lookup truncates the
 * primaryType at the first non-word character (regex `^\w*` with the u flag, in
 * findTypeDependencies), so what viem hashes for a colon name is CONTINGENT ON THE VERIFIER'S
 * TYPES MAP:
 *
 *   - singleton map (the motivating venue's real shape): viem, ethers, and ic402 agree — pinned
 *     here against the exact digest committed in test/eip712.test.mo's Motoko golden vector;
 *   - a map that ALSO contains a struct named exactly the first segment: viem silently appends
 *     that struct to its type string and the digest diverges (ethers hard-throws "ambiguous"
 *     on the same map). Fail-closed — ic402's single-group string can never equal viem's
 *     two-group one — but a confusing signature-rejection outage, so policy layers should
 *     refuse to register a namespaced type whose first segment names another registered type.
 *
 * If viem ever changes this truncation behaviour, these pins fail and the caveat in
 * Eip712.mo's isStructName comment (and the EIP712Domain-prefix rejection built on it) must be
 * re-derived — that is exactly the drift this file exists to announce.
 */

const hlTypes = {
  'HyperliquidTransaction:Withdraw': [
    { name: 'hyperliquidChain', type: 'string' },
    { name: 'destination', type: 'string' },
    { name: 'amount', type: 'string' },
    { name: 'time', type: 'uint64' },
  ],
};
const hlMessage = {
  hyperliquidChain: 'Mainnet',
  destination: '0x2222222222222222222222222222222222222222',
  amount: '123.45',
  time: 1754300000000n,
};
const hlDomain = {
  name: 'HyperliquidSignTransaction',
  version: '1',
  chainId: 42161,
  verifyingContract: '0x0000000000000000000000000000000000000000',
} as const;

// The digest pinned in test/eip712.test.mo ("typeHash + hashStruct + FULL DIGEST match viem").
const COMMITTED_MOTOKO_DIGEST =
  '0x3c26236b8c2b1514bff511f1410bee0cf51735e6cde94cd995e4e502f2ab2ae7';

describe('eip712 colon-name interop (viem truncation contingency)', () => {
  it('singleton types map: viem matches the committed Motoko golden digest byte-for-byte', () => {
    const digest = hashTypedData({
      domain: hlDomain,
      types: hlTypes,
      primaryType: 'HyperliquidTransaction:Withdraw',
      message: hlMessage,
    });
    expect(digest).toBe(COMMITTED_MOTOKO_DIGEST);
  });

  it('first-segment collision in the types map makes viem DIVERGE (the documented contingency)', () => {
    const digest = hashTypedData({
      domain: hlDomain,
      types: {
        ...hlTypes,
        // A verifier still carrying a legacy bare-prefix struct: viem's truncated lookup key
        // ("HyperliquidTransaction") now resolves, and viem appends this struct's definition
        // to its encodeType output — a different type string, a different digest.
        HyperliquidTransaction: [{ name: 'nonce', type: 'uint64' }],
      },
      primaryType: 'HyperliquidTransaction:Withdraw',
      message: hlMessage,
    });
    expect(digest).not.toBe(COMMITTED_MOTOKO_DIGEST);
  });

  it('EIP712Domain first segment diverges UNCONDITIONALLY (why ic402 rejects it)', () => {
    // viem injects an EIP712Domain entry into every types map, so the truncated lookup always
    // resolves for this prefix — no verifier configuration avoids the divergence, which is why
    // Eip712.validateFields refuses "EIP712Domain:*" outright.
    const domain = {
      name: 'D',
      version: '1',
      chainId: 1,
      verifyingContract: '0x0000000000000000000000000000000000000000',
    } as const;
    const viaViem = hashTypedData({
      domain,
      types: { 'EIP712Domain:X': [{ name: 'a', type: 'uint256' }] },
      primaryType: 'EIP712Domain:X',
      message: { a: 1n },
    });
    // The context-free digest ic402 (and ethers) would produce, computed in the Motoko review
    // probe: 0x3848a679… — viem's differs because its type string carries the injected domain
    // struct as a trailing group.
    expect(viaViem).not.toBe('0x3848a6791a65e5ee7ad14a77637d5089d9e0471586f7753732e5b1b208f50761');
  });
});
