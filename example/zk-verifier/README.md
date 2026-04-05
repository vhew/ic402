# ic402 Reference ZK Verifier

A minimal Groth16/BN254 proof verifier canister for use with ic402's service marketplace.

## What this is

A reference implementation of the `ZkVerifierActor` interface that ic402's `ServiceRegistry` calls when a service uses `#ZkGroth16` verification. Deploy this alongside your ic402 canister and pass its principal when registering a service.

This is **not** part of the ic402 library — it's a standalone canister you can fork, modify, or replace with your own verifier.

## Build

```bash
cargo build --target wasm32-unknown-unknown --release
```

The WASM output is at `target/wasm32-unknown-unknown/release/zk_verifier.wasm`.

## Deploy

```bash
icp deploy zk_verifier -e local
```

Or add to your `icp.yaml`:
```yaml
- name: zk_verifier
  recipe:
    type: '@dfinity/rust@v1.0.0'
    configuration:
      cargo_toml: example/zk-verifier/Cargo.toml
      candid: example/zk-verifier/zk_verifier.did
```

## Usage with ic402

When registering a service:
```motoko
registry.registerService(caller, {
  // ...
  verification = #ZkGroth16({
    verificationKey = myCircuitVk;  // arkworks-serialized
    verifierCanister = Principal.fromText("<zk_verifier_canister_id>");
  });
});
```

When an operator submits a job result with a proof, the ServiceRegistry automatically calls this verifier canister. If the proof is valid, payment settles to the operator. If invalid, the job is marked as disputed.

## Cost

~1-5 billion ICP instructions per Groth16 verification ≈ **$0.005**.
100-1000x cheaper than Ethereum's ecPairing precompile.

## Proof format

All serialization uses arkworks `CanonicalDeserialize` (compressed format):
- **Proof**: 2 G1 points + 1 G2 point ≈ 192 bytes
- **Public inputs**: Fr field elements ≈ 32 bytes each
- **Verification key**: Variable size depending on circuit (alpha, beta, gamma, delta + IC points)

Generate proofs with [circom](https://docs.circom.io/) + [snarkjs](https://github.com/iden3/snarkjs), then convert to arkworks format. Or use arkworks directly in Rust.
