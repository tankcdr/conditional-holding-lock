# Hash-vector runbook

Preimages are 32 raw bytes, represented as 64 hex characters without a `0x` prefix. The policy accepts uppercase input by normalizing to lowercase before validating it. Digests in terms must already be lowercase.

Daml uses `DA.Crypto.Text.sha256` and `DA.Crypto.Text.keccak256`, which decode the hex before hashing. Solidity uses `sha256(abi.encodePacked(preimage))` and `keccak256(abi.encodePacked(preimage))` with a `bytes32` input. `DA.Text.sha256` hashes UTF-8 text and is deliberately checked to produce a different value.

The six vectors in `fixtures/hash-vectors.json` cover zero, repeated `01`, repeated `ff`, repeated `deadbeef`, ascending bytes, and leading-zero/high-bit bytes. Neither test suite computes its expected digests from the implementation under test.

Generated constants live in:

- `packages/conditional-lock-test/daml/Generated/HashVectors.daml`
- `contracts/evm/test/generated/HashVectorData.sol`

To update reviewed fixtures and regenerate both languages:

```bash
python3 scripts/generate-hash-vectors.py
python3 scripts/generate-hash-vectors.py --check
./scripts/test.sh
./scripts/test-compatibility.sh
```

The normal test command fails if either generated file differs from the JSON. It also fails if Foundry is unavailable. No test downloads an unpinned Solidity library.

`TestHashVectors.daml` checks both raw Daml builtins and the exact helper used by the lock implementation, including uppercase normalization and malformed input rejection. `TestConditionalLock.daml` exercises both SHA-256 and Keccak guards in actual ledger transactions. The [Step 1 report](step-1.md) describes runtime validation.
