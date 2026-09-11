// SPDX-License-Identifier: Apache-2.0
use litesvm::{
    types::{FailedTransactionMetadata, TransactionMetadata},
    LiteSVM,
};
use serde::Deserialize;
use solana_address::Address;
use solana_instruction::Instruction;
use solana_instruction_error::InstructionError;
use solana_keypair::Keypair;
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;
use solana_transaction_error::TransactionError;
use std::path::Path;

#[derive(Deserialize)]
struct Fixtures {
    vectors: Vec<HashVector>,
}

#[derive(Deserialize)]
struct HashVector {
    id: String,
    preimage: String,
    sha256: String,
    keccak256: String,
}

fn vectors() -> Vec<HashVector> {
    // Read the same reviewed file that generates the Daml and Solidity fixtures.
    let fixtures: Fixtures =
        serde_json::from_str(include_str!("../../../fixtures/hash-vectors.json")).unwrap();
    assert!(!fixtures.vectors.is_empty());
    fixtures.vectors
}

struct Harness {
    svm: LiteSVM,
    program_id: Address,
    payer: Keypair,
}

impl Harness {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let program_id = Address::new_from_array([0x48; 32]);
        let program_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target/deploy/conditional_lock_hash_vectors.so");
        svm.add_program_from_file(program_id, program_path)
            .expect("Load the SBF program: run ./scripts/test-solana.sh from the repo root first");
        // Ephemeral test keys and balances; no wallet files or RPC connection.
        let payer = Keypair::new();
        svm.airdrop(&payer.pubkey(), 1_000_000_000).unwrap();
        Self {
            svm,
            program_id,
            payer,
        }
    }

    fn invoke(
        &mut self,
        input: Vec<u8>,
    ) -> Result<TransactionMetadata, Box<FailedTransactionMetadata>> {
        let instruction = Instruction {
            program_id: self.program_id,
            accounts: vec![],
            data: input,
        };
        let tx = Transaction::new(
            &[&self.payer],
            Message::new(&[instruction], Some(&self.payer.pubkey())),
            self.svm.latest_blockhash(),
        );
        self.svm.send_transaction(tx).map_err(Box::new)
    }

    fn assert_invalid_input(&mut self, input: Vec<u8>, description: &str) {
        let failure = self.invoke(input).unwrap_err();
        assert_eq!(
            failure.err,
            TransactionError::InstructionError(0, InstructionError::InvalidInstructionData),
            "{description}: {}",
            failure.meta.pretty_logs(),
        );
        assert!(failure.meta.return_data.data.is_empty(), "{description}");
    }
}

#[test]
fn hash_syscalls_match_shared_daml_and_evm_vectors() {
    let mut harness = Harness::new();
    for vector in vectors() {
        let input = hex::decode(&vector.preimage).unwrap();
        assert_eq!(input.len(), 32, "{}: preimage length", vector.id);
        let result = harness
            .invoke(input)
            .unwrap_or_else(|failure| panic!("{}: {failure:?}", vector.id));
        assert_eq!(result.return_data.program_id, harness.program_id);
        assert_eq!(result.return_data.data.len(), 64, "{}", vector.id);
        let data = result.return_data.data;
        assert_eq!(
            hex::encode(&data[..32]),
            vector.sha256,
            "{}: SHA-256",
            vector.id
        );
        assert_eq!(
            hex::encode(&data[32..]),
            vector.keccak256,
            "{}: Keccak-256",
            vector.id,
        );
        println!(
            "{}: SHA-256 and Keccak-256 match ({} compute units)",
            vector.id, result.compute_units_consumed,
        );
    }
}

#[test]
fn rejects_wrong_preimage_lengths() {
    let mut harness = Harness::new();
    for length in [0, 1, 31, 33] {
        harness.assert_invalid_input(vec![0; length], &format!("{length}-byte preimage"));
    }
}

#[test]
fn rejects_hex_text_instead_of_raw_bytes() {
    let mut harness = Harness::new();
    for vector in vectors() {
        harness.assert_invalid_input(vector.preimage.as_bytes().to_vec(), &vector.id);
        harness.assert_invalid_input(format!("0x{}", vector.preimage).into_bytes(), &vector.id);
    }
}
