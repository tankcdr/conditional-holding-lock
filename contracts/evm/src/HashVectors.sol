// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice EVM-side hashes over `bytes32` preimages. Digests MUST match
/// `DA.Crypto.Text.sha256` and `DA.Crypto.Text.keccak256` on the same 32-byte
/// hex preimage.
contract HashVectors {
    function sha256Bytes32(bytes32 preimage) external pure returns (bytes32) {
        return sha256(abi.encodePacked(preimage));
    }

    function keccak256Bytes32(bytes32 preimage) external pure returns (bytes32) {
        // Keep the reference's raw-byte encoding explicit for cross-language comparison.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(preimage));
    }
}
