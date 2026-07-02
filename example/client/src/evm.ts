/**
 * EIP-712 / EIP-3009 signing helpers shared by the demo's EVM rails (Step 3's
 * content purchase and Step 8's session deposit both sign a
 * TransferWithAuthorization for Circle's USDC). Extracted so the two rails sign
 * identically — the signing logic is the same one MetaMask / ethers / viem use.
 */
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { keccak_256 } from '@noble/hashes/sha3.js';

/** The deterministic demo payer, or the key supplied via IC402_DEMO_EVM_KEY. */
export interface DemoPayer {
  /** secp256k1 private key. */
  key: Buffer;
  /** 0x-prefixed EOA address derived from `key`. */
  address: string;
  /** True when the key came from IC402_DEMO_EVM_KEY (a funded override). */
  fromEnv: boolean;
}

/**
 * Derive the demo's payer key + address. Uses IC402_DEMO_EVM_KEY when set, else a
 * deterministic demo EOA. Deliberately NOT Hardhat #0 (0xf39f…266): that key is
 * EIP-7702-delegated on most testnets, so Circle's USDC routes it to the EIP-1271
 * path and rejects its plain ECDSA EIP-3009 signatures — the payer must be a clean
 * EOA (no code). See `evmCodeLen` in steps.ts for the preflight that enforces this.
 */
export function demoPayer(): DemoPayer {
  const envKey = process.env.IC402_DEMO_EVM_KEY?.replace(/^0x/, '');
  const key = envKey
    ? Buffer.from(envKey, 'hex')
    : Buffer.from(keccak_256(new TextEncoder().encode('ic402-demo-evm-payer-v1')));
  const pubUncompressed = secp256k1.getPublicKey(key, false);
  const address =
    '0x' +
    Buffer.from(keccak_256(pubUncompressed.slice(1)))
      .slice(-20)
      .toString('hex');
  return { key, address, fromEnv: !!envKey };
}

/** EIP-712 domain for Circle's USDC (FiatToken). */
export interface Eip712Domain {
  name: string;
  version: string;
  chainId: number;
  /** The token contract address (verifyingContract). */
  verifyingContract: string;
}

/** The six fields of an EIP-3009 TransferWithAuthorization. */
export interface TransferAuthorization {
  from: string;
  to: string;
  value: number;
  validAfter: number;
  validBefore: number;
  nonce: Uint8Array;
}

/** v/r/s split of a signature, plus the signed 32-byte digest. */
export interface SignedAuthorization {
  v: number;
  r: number[];
  s: number[];
  digest: Uint8Array;
}

const enc = (s: string) => new TextEncoder().encode(s);

/** Left-pad a hex string (address) to a 32-byte word. */
function pad32(hex: string): Uint8Array {
  const b = Buffer.from(hex.replace(/^0x/, ''), 'hex');
  const p = new Uint8Array(32);
  p.set(b, 32 - b.length);
  return p;
}

/** Encode a number as a big-endian 32-byte word. */
function u256(n: number): Uint8Array {
  const b = new Uint8Array(32);
  let v = BigInt(n);
  for (let i = 31; i >= 0; i--) {
    b[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return b;
}

/** Concatenate byte arrays. */
function cat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((s, x) => s + x.length, 0));
  let off = 0;
  for (const x of parts) {
    out.set(x, off);
    off += x.length;
  }
  return out;
}

const DOMAIN_TYPEHASH = keccak_256(
  enc('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
);
const AUTH_TYPEHASH = keccak_256(
  enc(
    'TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)',
  ),
);

/**
 * Sign an EIP-3009 TransferWithAuthorization over `domain` with `key`. Produces the
 * EIP-712 digest (`0x1901 ‖ domainSeparator ‖ structHash`) and signs it directly.
 * Returns the v/r/s split the canister expects.
 *
 * @noble/curves v2 defaults `prehash` to TRUE — forced false here so the 32-byte
 * digest is signed as-is. 'recovered' format = `[recovery(1), r(32), s(32)]`.
 */
export function signTransferWithAuthorization(
  key: Buffer,
  domain: Eip712Domain,
  auth: TransferAuthorization,
): SignedAuthorization {
  const domainSeparator = keccak_256(
    cat(
      DOMAIN_TYPEHASH,
      keccak_256(enc(domain.name)),
      keccak_256(enc(domain.version)),
      u256(domain.chainId),
      pad32(domain.verifyingContract),
    ),
  );
  const structHash = keccak_256(
    cat(
      AUTH_TYPEHASH,
      pad32(auth.from),
      pad32(auth.to),
      u256(auth.value),
      u256(auth.validAfter),
      u256(auth.validBefore),
      auth.nonce,
    ),
  );
  const digest = keccak_256(cat(new Uint8Array([0x19, 0x01]), domainSeparator, structHash));
  const sig = secp256k1.sign(digest, key, { lowS: true, prehash: false, format: 'recovered' });
  return {
    v: sig[0] + 27,
    r: Array.from(sig.slice(1, 33)),
    s: Array.from(sig.slice(33, 65)),
    digest,
  };
}

/**
 * Recover the 0x-address that produced `sig` over `digest` (ecrecover). Handy to
 * confirm a signature belongs to the expected payer before submitting it.
 */
export function recoverSigner(
  digest: Uint8Array,
  sig: Pick<SignedAuthorization, 'v' | 'r' | 's'>,
): string {
  const recovered = Uint8Array.from([sig.v - 27, ...sig.r, ...sig.s]);
  const pub = secp256k1.Signature.fromBytes(recovered, 'recovered')
    .recoverPublicKey(digest)
    .toBytes(false);
  return (
    '0x' +
    Buffer.from(keccak_256(pub.slice(1)))
      .slice(-20)
      .toString('hex')
  );
}
