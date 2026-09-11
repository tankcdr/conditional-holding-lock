// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {HashVectors} from "../src/HashVectors.sol";
import {HashVectorData} from "./generated/HashVectorData.sol";

/// Both languages consume generated constants from the same reviewed JSON.
/// No forge-std checkout or network dependency is needed to run these tests.
contract HashVectorsTest {
    HashVectors internal h = new HashVectors();

    function test_sha256_bytes32_vectors() public view {
        HashVectorData.Vector[] memory vectors = HashVectorData.vectors();
        for (uint256 i; i < vectors.length; ++i) {
            require(h.sha256Bytes32(vectors[i].preimage) == vectors[i].shaDigest, vectors[i].id);
        }
    }

    function test_keccak256_bytes32_vectors() public view {
        HashVectorData.Vector[] memory vectors = HashVectorData.vectors();
        for (uint256 i; i < vectors.length; ++i) {
            require(h.keccak256Bytes32(vectors[i].preimage) == vectors[i].keccakDigest, vectors[i].id);
        }
    }
}
