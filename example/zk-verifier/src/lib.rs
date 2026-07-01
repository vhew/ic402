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
use candid::{CandidType, Principal};
use serde::Deserialize;
use std::cell::RefCell;

#[derive(CandidType, Deserialize)]
enum VerifyResult {
    #[serde(rename = "ok")]
    Ok,
    #[serde(rename = "err")]
    Err(String),
}

thread_local! {
    // L24: principals allowed to call verify_groth16 (the ic402 canister(s) that use this verifier).
    // EMPTY = allow-all (backward-compatible default). Once the controller registers callers via
    // set_authorized_callers, only they may call — closing the unauthenticated cycle-drain: this
    // canister runs under ICP's reverse-gas model, so an open ~1-5B-instruction update lets anyone
    // burn its cycles for free. Persisted across upgrades (pre/post_upgrade).
    static AUTHORIZED_CALLERS: RefCell<Vec<Principal>> = const { RefCell::new(Vec::new()) };
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
    // L24: reject unauthorized callers BEFORE the ~1-5B-instruction verification (cycle-drain
    // defense). Empty allowlist = allow-all until the controller configures it.
    let authorized = AUTHORIZED_CALLERS.with(|a| {
        let a = a.borrow();
        a.is_empty() || a.contains(&ic_cdk::caller())
    });
    if !authorized {
        return VerifyResult::Err("Unauthorized caller".to_string());
    }

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

/// Controller-only: set the principals allowed to call verify_groth16 (the ic402 canister(s) that
/// use this verifier). Closes the unauthenticated cycle-drain (L24). Pass an empty vec to revert to
/// allow-all. Register your ic402 canister's principal here after wiring the #ZkGroth16 service.
#[ic_cdk::update]
fn set_authorized_callers(callers: Vec<Principal>) -> VerifyResult {
    if !ic_cdk::api::is_controller(&ic_cdk::caller()) {
        return VerifyResult::Err("Only a controller may set authorized callers".to_string());
    }
    AUTHORIZED_CALLERS.with(|a| *a.borrow_mut() = callers);
    VerifyResult::Ok
}

/// The principals currently allowed to call verify_groth16 (empty = allow-all).
#[ic_cdk::query]
fn get_authorized_callers() -> Vec<Principal> {
    AUTHORIZED_CALLERS.with(|a| a.borrow().clone())
}

/// Health check — returns the verifier's capabilities.
#[ic_cdk::query]
fn get_info() -> String {
    "ic402 ZK Verifier: Groth16/BN254 via arkworks. ~1-5B instructions per verification.".to_string()
}

// L24: persist the authorized-caller allowlist across upgrades.
#[ic_cdk::pre_upgrade]
fn pre_upgrade() {
    let callers = AUTHORIZED_CALLERS.with(|a| a.borrow().clone());
    ic_cdk::storage::stable_save((callers,)).expect("failed to save authorized callers");
}

#[ic_cdk::post_upgrade]
fn post_upgrade() {
    if let Ok((callers,)) = ic_cdk::storage::stable_restore::<(Vec<Principal>,)>() {
        AUTHORIZED_CALLERS.with(|a| *a.borrow_mut() = callers);
    }
}

// Required for candid export
ic_cdk::export_candid!();
