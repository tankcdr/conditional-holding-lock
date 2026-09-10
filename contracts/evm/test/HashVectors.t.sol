// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HashVectors} from "../src/HashVectors.sol";

/// @dev Shared with `TestConditionalLock.daml`. These are `sha256(bytes32)` /
/// `keccak256(bytes32)` over the raw 32-byte preimage, not over hex text.
contract HashVectorsTest is Test {
    HashVectors internal h;

    bytes32 internal constant PREIMAGE_ZERO = bytes32(0);
    bytes32 internal constant SHA256_ZERO =
        0x66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925;
    bytes32 internal constant KECCAK256_ZERO =
        0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563;

    bytes32 internal constant PREIMAGE_01 = bytes32(uint256(0x0101010101010101010101010101010101010101010101010101010101010101));
    bytes32 internal constant SHA256_01 =
        0x72cd6e8422c407fb6d098690f1130b7ded7ec2f7f5e1d30bd9d521f015363793;
    bytes32 internal constant KECCAK256_01 =
        0xcebc8882fecbec7fb80d2cf4b312bec018884c2d66667c67a90508214bd8bafc;

    bytes32 internal constant PREIMAGE_FF = bytes32(~uint256(0));
    bytes32 internal constant SHA256_FF =
        0xaf9613760f72635fbdb44a5a0a63c39f12af30f950a6ee5c971be188e89c4051;
    bytes32 internal constant KECCAK256_FF =
        0xa9c584056064687e149968cbab758a3376d22aedc6a55823d1b3ecbee81b8fb9;

    bytes32 internal constant PREIMAGE_DEADBEEF =
        0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;
    bytes32 internal constant SHA256_DEADBEEF =
        0x8200cf0ce11447bf6353cbac964d07d1c390d61d07e6c5d0214450b3add6449b;
    bytes32 internal constant KECCAK256_DEADBEEF =
        0x86c47f76ff4a6cb8ee9c172982eda47e895262b5a6a7582aaf7d97295ce1d8d4;

    function setUp() public {
        h = new HashVectors();
    }

    function test_sha256_bytes32_vectors() public view {
        assertEq(h.sha256Bytes32(PREIMAGE_ZERO), SHA256_ZERO);
        assertEq(h.sha256Bytes32(PREIMAGE_01), SHA256_01);
        assertEq(h.sha256Bytes32(PREIMAGE_FF), SHA256_FF);
        assertEq(h.sha256Bytes32(PREIMAGE_DEADBEEF), SHA256_DEADBEEF);
    }

    function test_keccak256_bytes32_vectors() public view {
        assertEq(h.keccak256Bytes32(PREIMAGE_ZERO), KECCAK256_ZERO);
        assertEq(h.keccak256Bytes32(PREIMAGE_01), KECCAK256_01);
        assertEq(h.keccak256Bytes32(PREIMAGE_FF), KECCAK256_FF);
        assertEq(h.keccak256Bytes32(PREIMAGE_DEADBEEF), KECCAK256_DEADBEEF);
    }
}
