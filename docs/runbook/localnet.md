# Splice localnet at the Mainnet release

The localnet stack is Splice's own compose files, vendored verbatim under `localnet-overrides/splice-0.8.0/`, which is what Canton Mainnet runs today. See [`localnet-overrides/README.md`](../../localnet-overrides/README.md) for the vendored-tree provenance (source tag and commit, how it is re-synced) and the first-party compose layer and admin-token rationale. The driver (`scripts/lib/localnet-compose.sh`, project name `conditional-lock-localnet`) runs Splice's compose and resource-constraints files with the `sv`, `app-provider`, and `app-user` profiles in their `auth-on` variants, using Splice's `compose.env` and `env/common.env` as env files.

```bash
./scripts/localnet-sync.sh [<tag>] [--check]  # Materialize/update the Splice tree
./scripts/localnet.sh                         # Up, wait for readiness, bootstrap
./scripts/localnet.sh --down                  # Stop, keep volumes
./scripts/localnet.sh --clean                 # Stop, delete volumes
./scripts/localnet-bootstrap.sh               # Build DARs, upload three first-party ones to both participants
./scripts/localnet-prove.sh                   # Escrowed-DvP proof, writes evidence
```

Each script also has a `just` recipe and an `npm run localnet:<name>` script. Note that `just check-compatibility` fails when `.env.localnet.example`'s `IMAGE_TAG` is not the Splice version live on Mainnet, so `just release` fails until you re-sync the localnet with `./scripts/localnet-sync.sh`.

## Credentials

Two credentials are in play, both unsafe by design, both from `scripts/lib/localnet_token.py`. The default is an HS256 JWT for user `ledger-api-user`, audience `https://canton.network.global`, secret `unsafe`; the helper reads the user and secret from `env/<node>-auth-on.env` and `conf/canton/<node>/app-auth.conf` in the vendored tree, one per participant. DAR upload uses it. With `--admin`, the tool returns the participant admin token, carrying claims `ClaimPublic`, `ClaimAdmin`, and `ClaimActAsAnyParty` (see [`localnet-overrides/README.md`](../../localnet-overrides/README.md) for why this repository's compose layer adds the act-as-any-party claim and pins the token value). Anything that runs Daml Script needs the admin token: Daml Script allocates its own parties at runtime, Canton grants act-as rights only to the user named in the `AllocateParty` request's `userId` field (which Daml Script does not set; `dpm script --user-id` changes only the submitting user), and Canton 3.5.16 has no `CanActAsAnyParty` right to pre-grant. Authentication stays on; this is a stronger named credential, not a bypass.

Neither credential is loopback-only. Splice's `compose.yaml` binds the nginx UI ports to `${HOST_BIND_IP:-127.0.0.1}`, but publishes the canton participant ports (3901, 3975, and their 2/4 siblings) and the splice validator ports with no bind address, so they listen on every interface. That is Splice's own localnet behaviour, not something this repository changed. Do not run this stack on an untrusted network, and never reuse either credential against a real one. See [`localnet-overrides/README.md`](../../localnet-overrides/README.md) for the same warning about the first-party admin token.

## Ports

Ports follow Splice's pattern (suffixes 901 gRPC Ledger, 902 admin, 975 JSON Ledger, 903 validator admin): app-provider is 3975 JSON / 3901 gRPC / 3903 validator; app-user is 2975 / 2901 / 2903; SV is 4975 / 4901 / 4903. UIs: app-user wallet `http://wallet.localhost:2000`, app-provider wallet `http://wallet.localhost:3000`, SV `http://sv.localhost:4000`, scan `http://scan.localhost:4000`. Postgres is on host port 5433 (`DB_PORT` in `.env.localnet.example`), not Splice's 5432, because another project's stack commonly holds 5432.

## The 94-script suite against localnet

Daml Script derives deterministic party-id hints (e.g., `alice-d4d95138`), so a second proof run against the same persistent participant fails at `allocateParty` with "Party already exists". The preflight detects this and instructs you to run `./scripts/localnet.sh --clean && ./scripts/localnet.sh` first.

The 94-script Daml test suite runs against this localnet, 77 of 94 passing, in a single `dpm script --all` invocation on a fresh ledger:

```bash
T=$(mktemp); chmod 600 "$T"; python3 scripts/lib/localnet_token.py --admin > "$T"
dpm script --all --dar packages/conditional-lock-test/.daml/dist/conditional-lock-test-0.2.0.dar \
  --upload-dar yes --ledger-host 127.0.0.1 --ledger-port 3901 \
  --user-id ledger-api-user --access-token-file "$T"; rm -f "$T"
```

All 17 failures are the same thing: this participant has no controllable clock. It reports `staticTime.supported: false`, so fifteen scripts fail at `setTime` with "setTime is not supported in wallclock mode", and two more (`test_malformedTermsAndFundingFailWithoutConsumingInputs`, `test_durationBoundsAtTheLimitAreAcceptedAndOverTheLimitRejected`) assert on expiry boundaries they cannot reach without one. None fail on party allocation, authentication, or lock semantics. It must be one `--all` invocation rather than one per script, because Daml Script allocates a party once per process but derives the same id hint every time, so a second process collides on the first `allocateParty`.

`dpm test` and `./scripts/test-compatibility.sh` remain the suite's home, each gets a fresh controlled-time ledger per run, and all 94 pass there. What the localnet adds is the other 77 running against the Splice release Mainnet runs.

## The `localnet/` submodule

The `localnet/` submodule (`digital-asset/cn-quickstart`, 0BSD, currently pinned to `33eddeb992d4a16de18685585617a4c54e91ceac`) is no longer used by the stack itself; it provides reference material: the quickstart application, devnet and keycloak modules, and `quickstart/sync-network.sh` as prior art for reading a version out of a network info URL (`quickstart/sync-network.sh` reads `.synchronizer.active.version`; `scripts/localnet-sync.sh` and `scripts/check-compatibility.py` read `.sv.version` the same way).

## Integration test against the mainnet-matched localnet

A CIP-0112 DvP-between-registries integration test runs on the localnet, proving the conditional lock in a real multi-registry settlement. It settles a **real Amulet payment leg** against a **TestTokenV2 delivery leg under the conditional lock**, in a **single atomic transaction**, two commands (`SettlementFactory_SettleBatch` for Amulet and `ConditionalLock_Enact` for TestTokenV2) in one submission, captured in a single `updateId`. One `executor` party acts as the settlement venue and sole member of both Amulet allocations' `settlement.executors`, named in the lock's `Guard_Parties [executor] 1` as the sole enactor. This shape is required for atomicity: Amulet's settlement batch requires the actors to be exactly the allocation's executors, so a two-counterparty `Guard_Parties [alice, bob] 2` enactment cannot submit a single transaction from one participant without external signing. Both counterparties allocate the Amulet payment leg, bob a `SENDERSIDE` allocation (he pays), alice a `RECEIVERSIDE` one (she receives), because Amulet's settlement validation rejects a batch with missing authorization from any party.

A second lock on the same terms with a short deadline proves the expiry path: after the deadline the `ConditionalLock_Enact` is rejected with "no alternative is satisfied"; after `expiresAt` the `ConditionalLock_Expire` returns the full locked amount to alice unlocked, and bob withdraws his Amulet allocation.

The test is re-runnable, fresh `TokenRules`, factory, and lock IDs per run, with parties looked up before being allocated, so no `./scripts/localnet.sh --clean` is needed between runs. Running requires Node 22+ and pnpm. The first `pnpm install` is needed; subsequent runs skip it. The harness refuses to run with a clear message if the localnet is not up:

```bash
./scripts/localnet.sh          # Up, wait, build and upload DARs to both participants
pnpm install
pnpm test:integration          # or: just test-integration
./scripts/localnet.sh --down   # Stop, keep volumes
```

Parties: `alice` is the app-provider participant's validator wallet (seller, holds locked TestTokenV2); `bob` is the app-user participant's wallet (buyer, pays the Amulet); `cl-registry` is the TestTokenV2 registry admin and `cl-executor` the settlement venue, both allocated on app-provider. Once bob has approved, the active lock's signatories are the registry admin, alice as the authorizer, and bob as the approved receiver, so bob's participant is an informee of every lock transaction. Canton rejects at confirmation when an informee's participant cannot resolve the package, which is why both participants get the DARs in the bootstrap step above.

Evidence is recorded by `scripts/record-reference-proof.py --kind dvp` to `docs/runbook/localnet-mainnet-<IMAGE_TAG>-dvp-evidence.json`, capturing the real update ID, both legs' contract IDs, the two-command submission proof, and the time boundaries for the expiry path.

Regenerate the evidence from the last run's artifacts with `just test-integration-evidence` (or `pnpm test:integration:evidence`). It reads what the run recorded and refuses anything it cannot cross-check against the participant's own copy of the update; it is never hand-edited.

One known flake, stated rather than papered over. On one occasion out of more than twenty runs, the suite failed on the first attempt immediately after a cold `./scripts/localnet.sh`, and passed on every attempt after it, including a further cold start. It reported `1 passed | 2 skipped`, which places the failure in the settlement suite's `beforeAll` (the setup that issues the TestTokenV2, creates and approves the lock, and creates both Amulet allocations) and not in the settlement itself, since the expiry test passed in the same run. The likely reading is that some store on the freshly started validators had not caught up; that was not confirmed, and the failure has not reproduced, so no retry was added to hide it. A failed run is safe to repeat: it withdraws every Amulet allocation it created before the error propagates, and writes no run artifacts at all, so nothing stale can be turned into evidence. If the first run after a cold start fails, run it again; if it fails twice, treat that as a real failure and read the error.
