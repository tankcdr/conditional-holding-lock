# Changelog

All notable changes to the code in this repository are recorded here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and the release line follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**This is not the CIP changelog.** The CIP's own revision history is a different document, lives
in the CIP text under `docs/cip/`, and is owned separately. Do not merge the two.

**Versioning rule.** The release version lives in three places only: the git tag, this file, and
the generated release manifest `conditional-lock-release.json`. The four first-party Daml packages
keep `version: 1.0.0` in their `daml.yaml`. A Daml-LF package ID is a content hash over the package
name, its version, the LF version, the package IDs of its dependencies, and the serialized module
ASTs, so bumping the version field would change the interface package ID — and that ID is pinned
upstream in Splice's `daml/dars.lock`. The release version therefore moves in the tag while the
package coordinates stay still.

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-09-22

Initial out-of-tree release. The interface is a strawman for the Conditional Holding Lock CIP and
will change while the interface issues are open, so expect to re-pin. A package ID is a content
hash; every interface edit invalidates every adopter's pin, and there is no in-place amendment.

### Added

- `splice-api-token-conditional-lock-v1` — the three CIP interfaces and data types.
- `conditional-lock-utils` — reference guard evaluator, terms validator, and outcome resolver,
  adoptable without the TestTokenV2 adapter.
- `conditional-lock-test-token` — TestTokenV2 adapter with V1/V2 holding views and V2 events.
- `conditional-lock-test` — the 70-script proof suite.
- Release tooling: `scripts/check-pin.py`, `scripts/verify-reproducible.sh`,
  `scripts/make-release-manifest.py`, and the shared `scripts/lib/dar_identity.py`, which is now
  the single implementation of the DAR `Main-Dalf:` parse outside `scripts/fetch-dars.py`.
- Just recipes `check-pin`, `verify-reproducible`, `release <version>`, and
  `release-dry-run <version>`, mirrored as npm scripts (pass the version after `--`, as in
  `npm run release -- 0.1.0`).
- This `CHANGELOG.md` and the release notes under `docs/release-notes/`.

### Build and dependency notes

- Repinned `SPLICE_PIN` from an untagged Splice `main` commit (`6b82367e`) to Splice release tag
  `0.8.1`. All six DAR SHA-256 values are unchanged by the repin: the tag was chosen to match the
  reviewed bytes, not the bytes edited to fit the tag. The pin now also records
  `splice_release_commit`, so a moved upstream tag is detectable. Note that `canton-network/splice`
  tags are unprefixed (`0.8.1`), while `digital-asset/decentralized-canton-sync` releases are
  spelled `v0.8.1`; only the unprefixed form resolves on `raw.githubusercontent.com`.
- Split the policy evaluator into `conditional-lock-utils`, and changed five validator signatures
  so each reads its bounds from an explicit `Limits` argument rather than from a module constant.
- Refreshed the network reference to the live values checked 2026-09-22: Mainnet Splice 0.8.0 /
  Canton 3.5.16, Testnet Splice 0.8.1 / Canton 3.5.17. `just check-compatibility` exits 0 again.

### Build inputs

Daml SDK 3.5.2, Daml-LF 2.1, Splice release 0.8.1 (commit `fb3c8c8a`), built with
`--explicit-serializable=yes --target=2.1`.

### Package identity

| Package | Package ID | Attached | Changed |
| --- | --- | --- | --- |
| `splice-api-token-conditional-lock-v1` | `cc541d14181e265667ea06c6e738e2415881ec49f849474da63319fcfb10d5ac` | yes | new |
| `conditional-lock-utils` | `02e296d5a8317990106aebc51db5b20e0f1391646e03d0d23d18b25e5b10e5d3` | yes | new |
| `conditional-lock-test-token` | `245c8e38d10ca6e3c74cd9b3a3ef770cdecf616cee5d096b405fe4d712e6844f` | yes | new |
| `conditional-lock-test` | `7a9bb8ba33e2a01eb233e2eec929e406b39f557be491a2f8816f231798f1ce65` | no | new |

A DAR's SHA-256 is download integrity; the package ID is package identity. Neither implies the
other — the same package can ship as two DAR files with different digests, which is exactly what
`splice-token-standard-utils-2.0.0` does across Splice 0.7.4 and 0.8.1.

`conditional-lock-test` is not attached to the release: it is the proof suite, it depends on
`daml-script`, and no consumer should put it in `data-dependencies`. It is recorded in the manifest
with `"attached": false` for the record.

`dpm publish` is out of scope for this release; GitHub Releases are the citable artifact channel.
DAR signing is out of scope for this release — the SHA-256 values in the generated
`conditional-lock-release.json` manifest are the only provenance.

[Unreleased]: https://github.com/tankcdr/conditional-holding-lock/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tankcdr/conditional-holding-lock/releases/tag/v0.1.0
