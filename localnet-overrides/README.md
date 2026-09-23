# Localnet overrides

The localnet stack consists of two parts: Splice's own vendored tree and one file of ours.

## Splice tree

`splice-0.8.0/` is the directory `cluster/compose/localnet/` from the Splice repository
(`canton-network/splice`, tag `0.8.0`, commit `9330dba9e31b8893bec09ece2f5dbb496fcf17b5`),
downloaded verbatim and never hand-edited. The `SOURCE.json` file in that directory records the
repository, tag, commit hash, source (local checkout or tarball), extraction path, and timestamp.

`scripts/localnet-sync.sh [<tag>] [--check]` re-materializes this tree whenever Mainnet moves to
a new Splice version. It reads the current Mainnet version from
`https://docs.global.canton.network.sync.global/info` (or accepts an explicit tag), resolves the
tag's commit against the Splice GitHub API, and extracts `cluster/compose/localnet/` into the
appropriate directory. Idempotent: if the tree is already materialized and byte-identical
(excluding `SOURCE.json`), nothing is changed. The `--check` flag diffs without modifying anything.

## First-party file

`conditional-lock.compose.yaml` is the only file in this directory that we maintain. It is a
Docker Compose layer on the `canton` service, pinning the app-provider participant's admin token
(`scripts/lib/localnet_token.py --admin` reads it back out of this file).

Daml Script allocates its own parties at runtime. Canton's AllocateParty grants act-as rights
only to the user named in the request (which Daml Script does not set), so a token for a generic
user cannot act as the parties the script just created. The admin token carries `ClaimActAsAnyParty`.
The localnet runs Splice's vendored `auth-on` profiles; Splice's tree already enables the admin
claim. This layer adds the act-as-any-party claim and pins a fixed token value. Authentication
stays on; DAR upload and `scripts/localnet-bootstrap.sh` still use the HS256 user token. The
token is unsafe and public by design—exactly like the `secret = "unsafe"` Splice ships in the
same tree. It grants full control of a throwaway local participant that binds to this machine
only. Never reuse this value, this mechanism, or this file against any real network.
