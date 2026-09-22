# splice-app 0.6.7 localnet conf override

Verbatim `cluster/compose/localnet/conf/splice/*` from
digital-asset/decentralized-canton-sync **v0.6.7**. The cn-quickstart
submodule pin ships confs for splice ≤0.6.5; splice ≥0.6.7 renamed the SV/scan
synchronizer-node config keys (`sequencer-admin-client`/`mediator-admin-client`
→ `synchronizer-nodes.current{…}`, `local-synchronizer-node` →
`local-synchronizer-nodes.current`), so the old confs fail with
GENERIC_CONFIG_ERROR "Key not found: 'synchronizer-nodes'".
`docker-compose.localnet.yml` mounts THESE files into the splice container
instead of the quickstart's. Delete this dir once the quickstart submodule is
bumped to a revision that supports splice ≥0.6.7.
