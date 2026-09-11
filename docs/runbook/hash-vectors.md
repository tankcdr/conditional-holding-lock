# Hash-vector runbook

Preimages are 32 raw bytes, represented as 64 hex characters without a `0x` prefix. The policy accepts uppercase input by normalizing to lowercase before validating it. Digests in terms must already be lowercase.

Daml uses `DA.Crypto.Text.sha256` and `DA.Crypto.Text.keccak256`, which decode the hex before hashing. Solidity uses `sha256(abi.encodePacked(preimage))` and `keccak256(abi.encodePacked(preimage))` with a `bytes32` input. `DA.Text.sha256` hashes UTF-8 text and is deliberately checked to produce a different value.

Solana uses `solana_program::hash::hash` and `solana_program::keccak::hash` in a compiled SBF program. These invoke the runtime's [`sol_sha256` and `sol_keccak256` syscalls](https://solana.com/docs/core/programs/syscall-reference#hashing). The instruction contains exactly the 32 decoded bytes; return data contains the 32-byte SHA-256 digest followed by the 32-byte Keccak-256 digest.

The six vectors in `fixtures/hash-vectors.json` cover zero, repeated `01`, repeated `ff`, repeated `deadbeef`, ascending bytes, and leading-zero/high-bit bytes. All three suites use reviewed expected digests from that file, independent of the implementation under test.

Generated constants live in:

- `packages/conditional-lock-test/daml/Generated/HashVectors.daml`
- `contracts/evm/test/generated/HashVectorData.sol`

`contracts/solana/tests/hash_vectors.rs` reads the shared JSON directly with `include_str!`, so it needs no generated copy.

To update reviewed fixtures and regenerate both languages:

```bash
python3 scripts/generate-hash-vectors.py
python3 scripts/generate-hash-vectors.py --check
./scripts/test.sh
./scripts/test-compatibility.sh
```

The normal test command fails if either generated file differs from the JSON. It also fails if Foundry or the Solana build tools are unavailable. No test downloads an unpinned Solidity library.

`TestHashVectors.daml` checks both raw Daml builtins and the exact helper used by the lock implementation, including uppercase normalization and malformed input rejection. `TestConditionalLock.daml` exercises both SHA-256 and Keccak guards in actual ledger transactions. The [Step 1 report](step-1.md) describes runtime validation.

## Solana proof

```bash
./scripts/test-solana.sh
# Equivalent:
npm run test:solana
```

The script builds `contracts/solana/src/lib.rs` with `cargo-build-sbf --tools-version v1.52 --arch v0`, then loads the resulting `.so` into [LiteSVM](https://github.com/LiteSVM/litesvm). The tests submit signed transactions and compare program return data. They do not invoke the Rust processor directly or substitute host SDK hash functions for SBF execution. Missing or unloadable SBF artifacts fail the suite.

The three tests cover both hash algorithms across all six shared vectors, rejection of 0/1/31/33-byte preimages, and rejection of 64-character hex or `0x`-prefixed hex text. This catches byte/text encoding mistakes, leading-zero loss, byte-order mistakes on the asymmetric vectors, and substituting SHA3-256 for Keccak-256.

The host Rust toolchain is pinned to 1.89.0 in the Solana directory. LiteSVM is pinned to 0.9.1 and its Agave runtime dependencies to 3.1.14 through `Cargo.toml` and `Cargo.lock`. The CLI used for validation is Agave 3.1.14. Both SBF builds and host tests use `--locked`; dependency updates are explicit changes to the lockfile. First execution can download Rust components, SBF tools, and Cargo dependencies. Compiled output and any build-tool-generated key files stay under the ignored `contracts/solana/target/` directory.

Execution is entirely local, with ephemeral test keys and balances, without starting a validator or using an existing Solana wallet. This is a hash compatibility proof. It does not implement Solana token custody or demonstrate a complete Canton/Solana swap, and it does not certify a live cluster's version or feature set.
