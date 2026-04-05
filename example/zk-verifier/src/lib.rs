/// ic402 Reference ZK Verifier — Groth16 on BN254.
///
/// A minimal ICP canister that verifies Groth16 proofs using arkworks.
/// Deploy this alongside your ic402-enabled canister and pass its
/// principal when registering a service with `#ZkGroth16` verification.
///
/// Candid interface:
/// ```
/// service : {
///   verify_groth16 : (proof : blob, public_inputs : vec blob, verification_key : blob) -> (variant { ok; err : text });
/// }
/// ```
///
/// Cost: ~1-5 billion instructions per verification (~$0.005).
/// Fits within ICP's 40B instruction DTS limit.

use ark_bn254::{Bn254, Fr};
use ark_groth16::{Groth16, PreparedVerifyingKey, Proof, VerifyingKey};
use ark_serialize::CanonicalDeserialize;
use candid::CandidType;
use serde::Deserialize;

#[derive(CandidType, Deserialize)]
enum VerifyResult {
    #[serde(rename = "ok")]
    Ok,
    #[serde(rename = "err")]
    Err(String),
}

/// Verify a Groth16 proof over the BN254 curve.
///
/// Arguments:
/// - `proof`: Arkworks-serialized Groth16 proof (compressed, ~192 bytes)
/// - `public_inputs`: Each element is an arkworks-serialized field element (Fr, ~32 bytes)
/// - `verification_key`: Arkworks-serialized VerifyingKey (variable size, depends on circuit)
///
/// Returns `ok` if the proof verifies, `err` with a message otherwise.
#[ic_cdk::update]
fn verify_groth16(proof: Vec<u8>, public_inputs: Vec<Vec<u8>>, verification_key: Vec<u8>) -> VerifyResult {
    // Deserialize verification key
    let vk = match VerifyingKey::<Bn254>::deserialize_compressed(&verification_key[..]) {
        Ok(vk) => vk,
        Err(e) => return VerifyResult::Err(format!("Failed to deserialize verification key: {e}")),
    };

    // Prepare the verification key (precomputes pairing elements)
    let pvk = PreparedVerifyingKey::from(vk);

    // Deserialize proof
    let proof = match Proof::<Bn254>::deserialize_compressed(&proof[..]) {
        Ok(p) => p,
        Err(e) => return VerifyResult::Err(format!("Failed to deserialize proof: {e}")),
    };

    // Deserialize public inputs
    let mut inputs = Vec::with_capacity(public_inputs.len());
    for (i, input_bytes) in public_inputs.iter().enumerate() {
        match Fr::deserialize_compressed(&input_bytes[..]) {
            Ok(fr) => inputs.push(fr),
            Err(e) => return VerifyResult::Err(format!("Failed to deserialize public input {i}: {e}")),
        }
    }

    // Verify
    match Groth16::<Bn254>::verify_proof(&pvk, &proof, &inputs) {
        Ok(true) => VerifyResult::Ok,
        Ok(false) => VerifyResult::Err("Proof verification failed: invalid proof".to_string()),
        Err(e) => VerifyResult::Err(format!("Verification error: {e}")),
    }
}

/// Health check — returns the verifier's capabilities.
#[ic_cdk::query]
fn get_info() -> String {
    "ic402 ZK Verifier: Groth16/BN254 via arkworks. ~1-5B instructions per verification.".to_string()
}

// Required for candid export
ic_cdk::export_candid!();
