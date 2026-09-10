# Conditional Holding Lock

Daml 3.5.2, LF 2.1, against Splice main (`SPLICE_PIN`).

`splice/` is a git submodule of https://github.com/tankcdr/splice on branch
`cip-conditional-holding-lock`. After clone run `./scripts/init-submodules.sh`
(blobless sparse checkout of `token-standard`). Daml edits go in the submodule
so the Splice PR is `git -C splice diff canton-network/splice/main`.

- Build DARs with `./scripts/build-dars.sh`. It symlinks `*-current.dar`.
- Test with `./scripts/test.sh`. Needs Java 17+ (`dpm test` script service).
- Do not hash hex text. Use `DA.Crypto.Text.sha256` / `keccak256` on 64-char lowercase hex of 32 raw bytes.
- Guard evaluation belongs in `splice-token-standard-utils`, not copied into each registry.
- TokenRules is admin-only. Tests (and wallets) disclose or `readAs` the admin so EventLog is visible; Enact still must not require the owner as a submitter.
- Local unpublished packages overlay a stock localnet the same way Canton Swap overlays splice confs: see `localnet-overrides/README.md`.
