# Ed25519 conformance fixtures

The expectations behind `test/ed25519.test.mo` (Motoko interpreter) and
`test/ed25519.test.ts` (deployed canister). Every one comes from outside ic402: before 2.16.1
ic402's tests signed and verified with the same broken library (`mo:ed25519` 0.1.0), so they
agreed with each other and caught nothing.

`Vectors.mo` is generated from the JSON here by `scripts/gen-ed25519-fixtures.mjs`. The JSON
is the source of truth, and CI regenerates `Vectors.mo` and fails on any diff.

## Files

| File                      | Source                                                                                                                                           | Licence    | sha256                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ------------------------------------------------------------------ |
| `wycheproof_ed25519.json` | [C2SP/wycheproof](https://github.com/C2SP/wycheproof) `testvectors_v1/ed25519_test.json` at `5722833ca004983abd1a91bcb6c24596d50ac0f9`           | Apache-2.0 | `752d2ea7d7c6cf4736381b6cbacb61f8182b126ab7cd9b058f00c50084975536` |
| `speccheck_cases.json`    | [novifinancial/ed25519-speccheck](https://github.com/novifinancial/ed25519-speccheck) `cases.json` at `5e4bfc4542293286e9ad3cb2b805badee00503de` | Apache-2.0 | `08e47a36d9aead288664930505584f353fff113ab854f2800db1e4f5b3540450` |
| `rfc8032.json`            | RFC 8032 section 7.1, the five Ed25519 vectors (TEST 1, 2, 3, 1024, SHA(abc)), transcribed                                                       | RFC text   | —                                                                  |
| `regressions.json`        | Generated for 2.16.1 with node:crypto (OpenSSL 3.6.3) and `@noble/curves` 2.2.0                                                                  | this repo  | —                                                                  |
| `policy.json`             | Constructed for 2.16.1 under the RFC 8032 TEST 1 key; verdicts cross-checked with OpenSSL 3.6.3 and `@noble/curves` 2.2.0                        | this repo  | —                                                                  |

The first two are **byte-for-byte upstream**, so `.prettierignore` lists them. Check one with
`curl -sL <raw URL at the commit> | shasum -a 256` against the table.

## What each set pins

- **Wycheproof** (151 vectors, 10 flags): valid signatures, known-answer tests, S ≥ L
  (`TinkOverflow`, `SignatureMalleability`), truncated, padded and compressed signatures, and
  invalid point encodings. ic402 matches the expected result on all 151.
- **ed25519-speccheck** (12 cases, from "Taming the many EdDSAs", Chalkias et al., 2020):
  the edge cases RFC 8032 leaves open — small-order and mixed-order A and R, cofactored versus
  cofactorless equations, and non-canonical S, R and A (cases 8–11 encode (0, −1) as "negative
  zero", x = 0 with the sign bit set). The policy ic402 takes on each is written next to the case
  in `test/ed25519.test.mo`. It is stricter than OpenSSL on cases 0 and 1 (a small-order public
  key) and 11 (a non-canonical public key), and agrees on the rest.
- **RFC 8032 §7.1**: the five vectors, used both to verify and to pin that the vendored signer
  (which ic402's own tests sign with) is RFC-exact.
- **Regressions**: the vectors that exposed `mo:ed25519` 0.1.0, each with 0.1.0's outcome
  inside a deployed canister recorded under `mo_ed25519_0_1_0`:
  - `pinned`: the valid signature from EngramX's report that 0.1.0 refused (S < 2^247).
  - `band`: two valid signatures with 2^247 ≤ S < 2^247 + 2^240, one refused by 0.1.0 and one
    accepted. The first shows the refusal rule is wider than S < 2^247; the second shows where
    the band stops.
  - `malleated`: five valid signatures 0.1.0 refused, each with its partner
    S' = (S + 2^256) mod L. 0.1.0 **accepted** every partner; OpenSSL, noble and ic402 refuse
    them all.
- **Policy** (3 vectors): Wycheproof and speccheck left three checks unpinned — an adversarial
  review deleted each with every other test still passing. Each vector here is built so that
  exactly one check refuses it:
  - `non-canonical R (y = p + 1)`: the identity encoded without reducing y; only the y < p check
    refuses it.
  - `R = (0, -1), result O = (0, 1)`: the result has R's x but not its y; only the y half of the
    final comparison refuses it.
  - `R negated, result -R`: the result has R's y but not its x; only the x half refuses it.

  All three are invalid under ic402's policy and OpenSSL refuses all three. noble accepts the
  second, because it checks the cofactored equation and the difference is a point of order 2.

## Regenerating

```bash
node scripts/gen-ed25519-fixtures.mjs   # rewrites Vectors.mo; deterministic
```
