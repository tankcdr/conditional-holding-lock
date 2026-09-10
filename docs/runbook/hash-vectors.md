# Hash-vector runbook

Preimages are 32 raw bytes, written as 64 lowercase hex characters. Daml hashes the **decoded bytes** with `DA.Crypto.Text.sha256` and `DA.Crypto.Text.keccak256`. EVM hashes the same bytes with `sha256(bytes32)` and `keccak256(bytes32)`.

Do not hash the UTF-8 of the hex string. `DA.Text.sha256` does that and will not match an EVM HTLC.

Vectors live in `fixtures/hash-vectors.json` and are asserted in:

- `splice/token-standard/examples/splice-test-token-conditional-lock-test/.../TestConditionalLock.daml` (`test_hashVectorsMatchEvm`)
- `contracts/evm/test/HashVectors.t.sol`

Confirmed on SDK 3.5.2: both Daml builtins match the EVM precompiles/builtins on the four shared vectors (zero, `0x01` repeated, `0xff` repeated, `deadbeef` repeated).
