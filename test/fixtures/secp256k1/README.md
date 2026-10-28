# secp256k1 conformance fixtures

The expectations behind `test/secp256k1.test.mo`, which pins `EvmAddress.ecRecover`: the signer
recovery every EIP-3009 payment check rests on. Every one comes from outside ic402.

`Vectors.mo` is generated from the JSON here by `scripts/gen-secp256k1-fixtures.mjs`. The JSON is
the source of truth, and CI regenerates `Vectors.mo` and fails on any diff.

## Files

| File                                     | Source                                                                                                                                                      | Licence    | sha256                                                             |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------ |
| `ecdsa_secp256k1_sha256_p1363_test.json` | [C2SP/wycheproof](https://github.com/C2SP/wycheproof) `testvectors_v1/ecdsa_secp256k1_sha256_p1363_test.json` at `d17cc89fa5c8f4f4d378b5385ebf75da5d0926c9` | Apache-2.0 | `7a339efc7134fb2495cd32afdbd692e0f86427d3c24e9073f6a7d858bb8788d2` |
| `policy.json`                            | Constructed for this suite; see below                                                                                                                       | this repo  | —                                                                  |

The Wycheproof file is **byte-for-byte upstream**, so `.prettierignore` lists it. Check it with
`curl -sL <raw URL at the commit> | shasum -a 256` against the table.

## Why the P1363 file

Wycheproof ships secp256k1 vectors in several encodings. The P1363 file gives signatures as raw
r || s, the form ic402 receives (inside a 65-byte r || s || v). The DER files spend most of their
vectors on DER parsing, which ic402 never does.

## What it pins

- **Wycheproof** (252 vectors, 13 flags): valid signatures, r and s out of range or zero, values
  that overflow or are off by n, special-case hashes and public keys, small r and s, modular
  inverse and point-doubling edge cases, and wrong-length signatures.
  - ic402 accepts none of the 85 invalid vectors.
  - It matches all 167 valid vectors except tcId 115 and 247. Both are signatures whose nonce
    point R has x >= n, which need recovery id 2 or 3. Ethereum's `ecrecover` (v = 27/28) cannot
    recover them either. The test pins this refusal.
- **Policy** (1 vector): the r + n fallback. When x = r is not on the curve, `ecRecover` retries
  with x = r + n, which Ethereum's `ecrecover` does not. The test pins that ic402 recovers the
  signer here, so the behaviour is recorded rather than accidental. Why it is kept is written at
  the top of `test/secp256k1.test.mo`.

### How the policy vector was built

Pure-stdlib Python, deterministic:

1. Take the smallest t >= 1 with n + t a valid x-coordinate and t not one (t = 7).
2. Let R be the point with x = n + t and even y, so r = t and the recovery parity is 0.
3. Take z = SHA-256(`"ic402 r+n recovery fallback"`), and s = SHA-256(`"ic402 r+n recovery fallback / s"`) mod n, reduced to low s.
4. Compute Q = r⁻¹(sR − zG), and self-check that standard ECDSA verification gives R back.

It was cross-checked with `@noble/curves` 2.4.0:

- `verify` accepts it, with and without the low-s rule.
- Recovery bits 0 and 1 throw (x = r is not on the curve), which is Ethereum's situation.
- Recovery bit 2 recovers Q.

## Regenerating

```bash
node scripts/gen-secp256k1-fixtures.mjs   # rewrites Vectors.mo; deterministic
```
