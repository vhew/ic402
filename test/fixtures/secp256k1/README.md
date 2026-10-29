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
  - Each accepted signature recovers its key under its own recovery id and not the other. The
    generator finds each id by plain ECDSA verification (R = s⁻¹(zG + rQ)), independently of
    ic402's recovery code, and checks that its verification agrees with Wycheproof on all 252.
  - Out-of-range r or s returns no key at all, and so does x = r off the curve with r + n >= p
    (tcId 33, 35, 204).
- **Policy** (2 vectors): two ways `ecRecover` recovers a key where Ethereum's `ecrecover` does
  not. The test pins both v results for each, so the behaviour is recorded rather than
  accidental. Why both are kept is written at the top of `test/secp256k1.test.mo`.
  - **r + n fallback.** When x = r is not on the curve, `ecRecover` retries with x = r + n.
  - **Parity fallthrough.** When the point for the given v yields the point at infinity,
    `ecRecover` tries the other parity, so both v return the same key.

### How the policy vectors were built

Both use pure-stdlib Python and are deterministic. Each was self-checked with standard ECDSA
verification and cross-checked with `@noble/curves` 2.4.0, whose `verify` accepts both.

**r + n fallback:**

1. Take the smallest t >= 1 such that n + t is a valid x-coordinate and t itself is not (t = 7).
   n + 2, n + 4 and n + 6 are valid too, but so are 2, 4 and 6, so the fallback would never run.
2. Let R be the point with x = n + t and even y, so r = t.
3. Take z = SHA-256(`"ic402 r+n recovery fallback"`), and s = SHA-256(`"ic402 r+n recovery fallback / s"`) mod n, reduced to low s.
4. Compute the signer Q = r⁻¹(sR − zG).

noble: recovery bits 0 and 1 throw (x = r is not on the curve), which is Ethereum's situation.
Bit 2 recovers the signer (ic402's v = 0), and bit 3 recovers the key ic402 returns for v = 1.

**Parity fallthrough:**

1. Take z = SHA-256(`"ic402 recovery parity fallthrough"`), and k = SHA-256(`"ic402 recovery parity fallthrough / k"`) mod n, incremented until R = kG has R.x < n and s is low.
2. Set r = R.x and s = z / k mod n. Under R's own parity, recovery gives r⁻¹(sR − zG), the point
   at infinity. Under the other parity it gives the signer K = (−2z / r)G.

noble: recovery bit 1 (R's parity) throws "point at infinity", which is Ethereum's situation.
Bit 0 recovers K. ic402 returns K for both v.

## Regenerating

```bash
node scripts/gen-secp256k1-fixtures.mjs   # rewrites Vectors.mo; deterministic
```
