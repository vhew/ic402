/// Generate test Groth16 fixtures for the ic402 ZK verifier demo.
///
/// Circuit: prove knowledge of `x` such that `x * x = y` (public: y=25, private: x=5).
///
/// Run: cargo run --example gen_fixtures
/// Produces: fixtures/{proof.bin, vk.bin, public_input.bin}

use ark_bn254::{Bn254, Fr};
use ark_ff::Field;
use ark_groth16::Groth16;
use ark_relations::r1cs::{ConstraintSynthesizer, ConstraintSystemRef, SynthesisError};
use ark_serialize::CanonicalSerialize;
use ark_snark::SNARK;
use ark_std::rand::{SeedableRng, rngs::StdRng};
use std::fs;

/// Trivial circuit: x * x = y (prove you know the square root of y)
#[derive(Clone)]
struct SquareCircuit {
    x: Option<Fr>, // private witness
    y: Option<Fr>, // public input
}

impl ConstraintSynthesizer<Fr> for SquareCircuit {
    fn generate_constraints(self, cs: ConstraintSystemRef<Fr>) -> Result<(), SynthesisError> {
        use ark_relations::r1cs::LinearCombination;

        // Private witness: x
        let x_val = self.x.unwrap_or_default();
        let x_var = cs.new_witness_variable(|| Ok(x_val))?;

        // Public input: y
        let y_val = self.y.unwrap_or_default();
        let y_var = cs.new_input_variable(|| Ok(y_val))?;

        // Constraint: x * x = y
        let mut lc_x = LinearCombination::zero();
        lc_x += (Fr::ONE, x_var);

        let mut lc_y = LinearCombination::zero();
        lc_y += (Fr::ONE, y_var);

        cs.enforce_constraint(lc_x.clone(), lc_x, lc_y)?;

        Ok(())
    }
}

fn main() {
    let mut rng = StdRng::seed_from_u64(42); // deterministic — fixtures are reproducible

    // Circuit: 5 * 5 = 25
    let x = Fr::from(5u64);
    let y = x * x; // 25

    let circuit = SquareCircuit {
        x: Some(x),
        y: Some(y),
    };

    // Generate proving and verification keys
    let (pk, vk) = Groth16::<Bn254>::circuit_specific_setup(circuit.clone(), &mut rng).unwrap();

    // Generate proof
    let proof = Groth16::<Bn254>::prove(&pk, circuit, &mut rng).unwrap();

    // Verify (sanity check)
    let public_inputs = vec![y]; // y = 25
    let pvk = ark_groth16::prepare_verifying_key(&vk);
    let valid = Groth16::<Bn254>::verify_proof(&pvk, &proof, &public_inputs).unwrap();
    assert!(valid, "Proof verification failed!");
    println!("Proof verified successfully (x=5, y=25)");

    // Serialize to compressed format
    let mut proof_bytes = Vec::new();
    proof.serialize_compressed(&mut proof_bytes).unwrap();

    let mut vk_bytes = Vec::new();
    vk.serialize_compressed(&mut vk_bytes).unwrap();

    let mut input_bytes = Vec::new();
    y.serialize_compressed(&mut input_bytes).unwrap();

    // Write fixtures
    fs::create_dir_all("fixtures").unwrap();
    fs::write("fixtures/proof.bin", &proof_bytes).unwrap();
    fs::write("fixtures/vk.bin", &vk_bytes).unwrap();
    fs::write("fixtures/public_input.bin", &input_bytes).unwrap();

    println!("Fixtures written:");
    println!("  proof.bin:        {} bytes", proof_bytes.len());
    println!("  vk.bin:           {} bytes", vk_bytes.len());
    println!("  public_input.bin: {} bytes", input_bytes.len());

    // Also write as hex for easy embedding in tests
    println!("\nHex (for embedding in demo):");
    println!("  proof: {}", hex::encode(&proof_bytes));
    println!("  vk:    {}", hex::encode(&vk_bytes));
    println!("  input: {}", hex::encode(&input_bytes));
}

mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }
}
