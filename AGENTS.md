# Conditional Holding Lock

Daml 3.5.2, LF 2.1.

This repo follows canton-swap-monorepo’s localnet layout:

- `localnet/` submodule is `digital-asset/cn-quickstart` — how you run Canton.
- `localnet-overrides/` holds splice confs the quickstart pin does not ship.
- `scripts/localnet.sh` starts compose and uploads unpublished CIP DARs.
- `splice/` submodule is the CIP fork (`tankcdr/splice`, `cip-conditional-holding-lock`)
  — how you PR onto Splice. After clone run `./scripts/init-submodules.sh`.

- Build DARs with `./scripts/build-dars.sh`. It symlinks `*-current.dar`.
- Test with `./scripts/test.sh`. Needs Java 17+ (`dpm test` script service).
- Do not hash hex text. Use `DA.Crypto.Text.sha256` / `keccak256` on 64-char lowercase hex of 32 raw bytes.
- Guard evaluation belongs in `splice-token-standard-utils`, not copied into each registry.
- TokenRules is admin-only. Tests (and wallets) disclose or `readAs` the admin so EventLog is visible; Enact still must not require the owner as a submitter.
- Local unpublished packages overlay a stock localnet the same way Canton Swap overlays splice confs: see `localnet-overrides/README.md`.
