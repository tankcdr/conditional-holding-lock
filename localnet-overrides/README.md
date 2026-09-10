# Localnet overlay for unpublished Splice packages

Canton Swap's `localnet-overrides/splice-0.6.7/` is the pattern: the `cn-quickstart` submodule pin ships configs (or DARs) older than the Splice line you actually run, so you mount a local tree into the splice container instead of waiting for the submodule bump.

This CIP is the same kind of change. `splice-app` on localnet does not yet contain `splice-api-token-conditional-lock-v1`. Until it does:

1. Build DARs here with `./scripts/build-dars.sh`.
2. Start localnet from `digital-asset/cn-quickstart` (or the Canton Swap compose overlay).
3. Upload and vet the new DARs on the app-provider participant, the same way Canton Swap's `scripts/localnet-bootstrap.sh` uploads `id-ccse-v2` after the ledger is up.
4. Pin the package in whatever catalog your app uses (`dars.lock`, a JSON pin file, or a wallet `supportedApis` advertisement).

Do not hand-patch a running ledger as a substitute for wiring the upload into bootstrap. Once Splice main ships the package, delete this overlay.

DAR paths after a local build:

```
splice/token-standard/splice-api-token-conditional-lock-v1/.daml/dist/splice-api-token-conditional-lock-v1-1.0.0.dar
splice/token-standard/splice-token-standard-utils/.daml/dist/splice-token-standard-utils-2.0.0.dar
splice/token-standard/examples/splice-test-token-v2/.daml/dist/splice-test-token-v2-1.0.1.dar
```

The factory must be created by the instrument admin (`TokenRules` in the TestTokenV2 reference registry). Wallets discover it through:

```
POST /registry/conditional-lock/v1/lock-factory
```

See `splice/token-standard/splice-api-token-conditional-lock-v1/openapi/conditional-lock-v1.yaml`.
