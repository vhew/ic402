import { describe, it, expect } from 'vitest';
import { concat, encodeAbiParameters, hashTypedData, keccak256, toHex } from 'viem';

/**
 * INTEROP DRIFT ALARM for colon-namespaced EIP-712 struct names (2.13.1; re-derived 2.18.1
 * and again for viem 2.57.17).
 *
 * ic402's Eip712 encoder hashes a colon name context-free: the canonical type string is
 * `Name:Sub(fields…)` and nothing else — what the motivating venue (Hyperliquid's
 * `HyperliquidTransaction:*` user-signed actions) expects.
 *
 * viem's view of these names has changed under us twice:
 *   - viem <= 2.57.11 accepted them, but its dependency lookup truncated the primaryType at the
 *     first non-word character, so its digest depended on the verifier's types map (singleton map:
 *     agreed with ic402; a map also holding the first segment, or the always-injected EIP712Domain:
 *     diverged). That is why Eip712.validateFields refuses an "EIP712Domain:" first segment.
 *   - viem 2.57.12–2.57.16 (wevm/viem#5308, stricter struct-name validation) REFUSED colon names
 *     outright with InvalidStructTypeError.
 *   - viem >= 2.57.17 (wevm/viem#5403) accepts them again and hashes them context-free: it agrees
 *     with ic402 byte-for-byte, including on a types map that also holds the first segment, and on
 *     "EIP712Domain:X" (checked against 2.57.17 and 2.57.19).
 *
 * So this file pins (1) the Motoko golden digest against an INDEPENDENT EIP-712 computation built
 * from keccak + ABI encoding (no struct-name validation involved), with a control proving that
 * hand encoder equals viem's hashTypedData on a plain name; and (2) current viem's agreement. If
 * viem refuses colon names again, or its digest drifts from the context-free one, (2) fails and
 * the caveat in Eip712.mo (and the EIP712Domain-prefix rejection) must be re-derived against its
 * new behaviour. ic402 keeps refusing "EIP712Domain:" regardless: verifiers on viem <= 2.57.11
 * still compute a different digest for it.
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

const HL_FIELDS = 'string hyperliquidChain,string destination,string amount,uint64 time';

/** EIP-712 domain separator for hlDomain, computed by hand. */
const domainSeparator = keccak256(
  encodeAbiParameters(
    [
      { type: 'bytes32' },
      { type: 'bytes32' },
      { type: 'bytes32' },
      { type: 'uint256' },
      { type: 'address' },
    ],
    [
      keccak256(
        toHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
      ),
      keccak256(toHex(hlDomain.name)),
      keccak256(toHex(hlDomain.version)),
      BigInt(hlDomain.chainId),
      hlDomain.verifyingContract,
    ],
  ),
);

/** keccak256(0x1901 ‖ domainSeparator ‖ hashStruct). */
const digestOf = (structHash: `0x${string}`) =>
  keccak256(concat(['0x1901', domainSeparator, structHash]));

/** EIP-712 digest of hlMessage under `structName`, computed by hand (context-free type string). */
function eip712Digest(structName: string): `0x${string}` {
  return digestOf(
    keccak256(
      encodeAbiParameters(
        [
          { type: 'bytes32' },
          { type: 'bytes32' },
          { type: 'bytes32' },
          { type: 'bytes32' },
          { type: 'uint64' },
        ],
        [
          keccak256(toHex(`${structName}(${HL_FIELDS})`)),
          keccak256(toHex(hlMessage.hyperliquidChain)),
          keccak256(toHex(hlMessage.destination)),
          keccak256(toHex(hlMessage.amount)),
          hlMessage.time,
        ],
      ),
    ),
  );
}

describe('eip712 colon-name interop', () => {
  it('control: the hand-built EIP-712 encoder equals viem hashTypedData on a plain struct name', () => {
    const viaViem = hashTypedData({
      domain: hlDomain,
      types: { Withdraw: hlTypes['HyperliquidTransaction:Withdraw'] },
      primaryType: 'Withdraw',
      message: hlMessage,
    });
    expect(eip712Digest('Withdraw')).toBe(viaViem);
  });

  it('the committed Motoko golden digest equals the independent EIP-712 computation byte-for-byte', () => {
    expect(eip712Digest('HyperliquidTransaction:Withdraw')).toBe(COMMITTED_MOTOKO_DIGEST);
  });

  it('DRIFT ALARM: current viem hashes colon struct names context-free, agreeing with ic402', () => {
    // The venue's real shape: a singleton types map.
    expect(
      hashTypedData({
        domain: hlDomain,
        types: hlTypes,
        primaryType: 'HyperliquidTransaction:Withdraw',
        message: hlMessage,
      }),
      'singleton map',
    ).toBe(COMMITTED_MOTOKO_DIGEST);
    // The map viem <= 2.57.11 got wrong: it also holds a struct named exactly the first segment.
    expect(
      hashTypedData({
        domain: hlDomain,
        types: { ...hlTypes, HyperliquidTransaction: [{ name: 'x', type: 'uint256' }] },
        primaryType: 'HyperliquidTransaction:Withdraw',
        message: hlMessage,
      }),
      'map that also holds the first segment',
    ).toBe(COMMITTED_MOTOKO_DIGEST);
    // "EIP712Domain:X": ic402 refuses this name, but current viem hashes it context-free too.
    const domainX = digestOf(
      keccak256(
        encodeAbiParameters(
          [{ type: 'bytes32' }, { type: 'uint256' }],
          [keccak256(toHex('EIP712Domain:X(uint256 a)')), 1n],
        ),
      ),
    );
    expect(
      hashTypedData({
        domain: hlDomain,
        types: { 'EIP712Domain:X': [{ name: 'a', type: 'uint256' }] },
        primaryType: 'EIP712Domain:X',
        message: { a: 1n },
      }),
      'EIP712Domain:X',
    ).toBe(domainX);
  });
});
