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
in Splice's `daml/dars.lock` on the proposed branch of PR 7294 (not yet on Splice `main`). The
release version therefore moves in the tag while the
package coordinates stay still.

## [Unreleased]

### Fixed

- The DvP evidence recorder now requires the expiry path to return the holding to the seller (the run file's claimed owner, the expire update's own event, `parties.alice`, and the delivery leg's sender must agree) and records the ledger's rejection text as observed, with its HTTP status line, instead of a constant. `scripts/tests/dvp-evidence-tamper.sh` corrupts each of those fields in a copy of the last run and requires the recorder to reject it; `just test-integration-evidence` runs it.
- `scripts/localnet-sync.sh` repins an existing `.env.localnet` alongside the example. A `.env.localnet` from before the Splice compose stack (no `IMAGE_TAG` line) cannot be repaired by substitution, so the sync refuses it and the compose driver says to delete it; it is recreated from the example on the next run. The tamper test also corrupts the raw expire update together with the claim, so only the seller comparison can catch it.

### Changed
- The escrowed-DvP reference deployment and 57 of the 70 Daml Script tests now run against a
  Docker localnet at the Mainnet release, not only against in-process sandboxes. The 13 that
  do not are the ones needing a controllable clock; the localnet participant reports
  `staticTime.supported: false`.

- The localnet stack is now vendored from Splice's own `cluster/compose/localnet/` at the
  Mainnet release (Splice 0.8.0, commit `9330dba9e31b8893bec09ece2f5dbb496fcf17b5`), rather
  than a hand-copied 0.6.7-era layout. `scripts/localnet-sync.sh` re-materializes the tree
  when Mainnet updates. `just check-compatibility` detects when the localnet drifts and fails
  `just release` until re-synced.
- The `localnet/` submodule is pinned but no longer used by the localnet stack itself; it
  provides reference material (prior art for the network-version discovery pattern that
  `scripts/localnet-sync.sh` and `scripts/check-compatibility.py` use).

### Removed

- The legacy hand-copied `docker-compose.localnet.yml` and `localnet-overrides/splice-0.6.7/`
  configuration files have been deleted.

### Added

- `scripts/localnet-sync.sh [<tag>] [--check]` — downloads and extracts the Splice localnet
  tree for a given release tag (or the current Mainnet version if none given); idempotent and
  diff-checkable with `--check`.
- `localnet-overrides/conditional-lock.compose.yaml` — the only first-party file in the
  overrides directory, a compose layer pinning the app-provider participant's admin token
  (`scripts/lib/localnet_token.py --admin`). Required for Daml Script to run under auth-on
  profiles (Daml Script allocates its own parties; Canton 3.5.16 has no CanActAsAnyParty
  right to pre-grant).
- `scripts/localnet-prove.sh` runs the escrowed-DvP proof against the localnet's
  app-provider participant, writing evidence to
  `docs/runbook/localnet-mainnet-<IMAGE_TAG>-reference-evidence.json`. It now includes a
  preflight check: if the participant already hosted a reference deployment, Daml Script fails
  on allocateParty (deterministic party-id hints cause collision on rerun). The preflight
  instructs you to run `./scripts/localnet.sh --clean && ./scripts/localnet.sh` first.
- A new `integration/` package proves CIP-0112 DvP between registries on the localnet: a real
  Amulet (Canton Coin) payment leg against a TestTokenV2 delivery leg under the conditional
  lock, settled atomically in one transaction via the JSON Ledger API. The harness generates
  fresh `TokenRules`, factory, and lock IDs per run and looks up parties before allocating,
  so it is re-runnable without ledger reset. Evidence is written by
  `scripts/record-reference-proof.py --kind dvp` to
  `docs/runbook/localnet-mainnet-<IMAGE_TAG>-dvp-evidence.json`, capturing the real update ID
  carrying both legs. `scripts/localnet-bootstrap.sh` now uploads the three first-party DARs
  to both the app-provider and app-user participants, because the receiver's participant is
  an informee of every lock transaction and Canton rejects at confirmation if the informee
  participant cannot resolve the package; uploading only to app-provider left every
  cross-participant lock failing at confirmation.

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
- Reference deployment scripts: `scripts/deploy-dars.sh` (the single JSON Ledger API /v2/packages
  upload path, now also used by `scripts/quickstart-check.sh`), `scripts/devnet-reference.sh`,
  `scripts/record-reference-proof.py`, and `scripts/devnet-status.sh`.
- `examples/devnet-escrow/` — the escrowed-DvP-with-dispute-window script the reference deployment runs.
- `docs/adoption-evidence.md` — adoption evidence log and reference-deployment record.
- Just recipes `check-pin`, `verify-reproducible`, `release <version>`, and
  `release-dry-run <version>` (pass the version after `--`, as in `npm run release -- 0.1.0`),
  and `devnet-deploy`, `devnet-reference`, and `devnet-status`, all mirrored as npm scripts.
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
- Added an informational DevNet row to `scripts/check-compatibility.py` and
  `fixtures/runtime-versions.json`. DevNet differences do not fail the check because DevNet runs
  ahead of the pinned release; live DevNet reports Splice 0.8.3 / Canton 3.5.18.

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
