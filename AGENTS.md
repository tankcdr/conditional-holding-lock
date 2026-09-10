# Conditional Holding Lock

Daml 3.5.2, LF 2.1. Canton-swap localnet layout. **Do not commit Splice source.**

- `localnet/` submodule is `digital-asset/cn-quickstart`.
- `localnet-overrides/` holds splice confs the quickstart pin does not ship.
- CIP Daml is https://github.com/tankcdr/splice/tree/cip-conditional-holding-lock
  Clone with `./scripts/clone-splice.sh` into gitignored `./splice`, or set `SPLICE_DIR`.
- Build DARs with `./scripts/build-dars.sh`. Test with `./scripts/test.sh` (Java 17+).
- Hash preimages are 64-char lowercase hex of 32 raw bytes via `DA.Crypto.Text`.
