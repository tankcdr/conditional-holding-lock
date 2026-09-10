# Localnet overlays (canton-swap pattern)

The `localnet` submodule is `digital-asset/cn-quickstart` pinned to the same
SHA canton-swap uses (`fe56d46`). Two kinds of change are not in that pin:

## 1. Splice confs (`splice-0.6.7/`)

Verbatim `cluster/compose/localnet/conf/splice/*` from splice-app v0.6.7.
Quickstart still has pre-0.6.7 keys (`sequencer-admin-client`); 0.6.7 renamed
them to `synchronizer-nodes.current`. `docker-compose.localnet.yml` mounts
these files into the splice container. Delete once the submodule is bumped.

## 2. CIP DARs

`splice-app` does not contain `splice-api-token-conditional-lock-v1`.
`scripts/localnet-bootstrap.sh` builds the DARs and `POST`s them to
`http://localhost:3975/v2/packages`, the same HTTP upload path canton-swap
uses for `id-ccse-v2`.

```bash
./scripts/localnet.sh              # compose up + bootstrap
./scripts/localnet-bootstrap.sh    # re-upload onto a running box
```
