# Conditional Holding Lock

Daml 3.5.2, LF 2.1. Canton-swap localnet layout. **Do not commit Splice source or downloaded DARs.**

- Compile against published DARs: `./scripts/fetch-dars.sh` → gitignored `.dars/`.
- First-party Daml is `packages/`. Do not clone canton-network/splice into this repo.
- `localnet/` submodule is cn-quickstart. `localnet-overrides/` is unpublished splice conf.
- CIP PR (if any) is a branch on a Splice fork, not files here.
