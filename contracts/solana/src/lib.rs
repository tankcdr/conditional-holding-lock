// SPDX-License-Identifier: Apache-2.0
//! Solana byte-domain reference for the shared conditional-lock hash vectors.
//! Instruction data is exactly 32 raw bytes. Return data is SHA-256 || Keccak-256.

use solana_program::{
    account_info::AccountInfo, entrypoint, entrypoint::ProgramResult, hash, keccak,
    program::set_return_data, program_error::ProgramError, pubkey::Pubkey,
};

entrypoint!(process_instruction);

pub fn process_instruction(
    _program_id: &Pubkey,
    _accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    if instruction_data.len() != 32 {
        return Err(ProgramError::InvalidInstructionData);
    }

    // When built for SBF, these SDK functions invoke sol_sha256 and sol_keccak256.
    let sha_digest = hash::hash(instruction_data).to_bytes();
    let keccak_digest = keccak::hash(instruction_data).to_bytes();
    let mut digests = [0u8; 64];
    digests[..32].copy_from_slice(&sha_digest);
    digests[32..].copy_from_slice(&keccak_digest);
    set_return_data(&digests);
    Ok(())
}
