#!/usr/bin/env python3
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Record honest evidence for a devnet-reference.sh run of the escrowed-DvP
with a dispute window (examples/devnet-escrow), against a real participant
under wall-clock time. With --kind dvp, records evidence for the CIP-0112
DvP-between-registries integration harness instead.

Gated: refuses to write evidence that is not backed by the run's own
artifacts. Never reads or writes LEDGER_TOKEN or any Authorization header.
"""
import argparse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import dar_identity  # noqa: E402

FIRST_PARTY_RELEASE_PACKAGES = [
    package for package, attached in dar_identity.PACKAGES if attached
]

# Canton contract IDs observed in this repo's own evidence
# (docs/runbook/localnet-reference-evidence.json) are "00" followed by a long
# run of lowercase hex. This is deliberately not over-fit to one ledger's
# exact length: it is a shape check, not an equality check.
CONTRACT_ID_RE = re.compile(r"^00[0-9a-f]{100,}$")
# Canton 3.5 update IDs on this ledger are a "1220" multihash prefix followed
# by 64 hex characters.
UPDATE_ID_RE = re.compile(r"^1220[0-9a-f]{64}$")
CANTON_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+")
# A JWT is three base64url segments separated by dots; the header segment of a
# compact JWT always starts 'eyJ' (base64 of '{"').
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}")

UPDATE_ID_FALLBACK = (
    "not captured; Daml Script does not return ledger update IDs, so contract "
    "IDs from the script's own return value are recorded instead"
)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", required=True, choices=["localnet", "localnet-mainnet", "devnet"])
    parser.add_argument("--run-dir", required=True, type=Path)
    # Required for --kind reference, which records a staging directory the run
    # itself assembled and uploaded. For --kind dvp it defaults to the built
    # DARs under packages/*/.daml/dist, because those are the exact files
    # scripts/localnet-bootstrap.sh uploaded to both participants; there is no
    # separate staging step to point at.
    parser.add_argument("--dar-dir", type=Path)
    parser.add_argument("--release")
    parser.add_argument("--sandbox-runtime", choices=["mainnet", "testnet"])
    parser.add_argument("--runtime-tag", help="Splice release tag of the participant this ran against "
                                              "(localnet-mainnet); becomes part of the evidence filename")
    parser.add_argument("--kind", choices=["reference", "dvp"], default="reference",
                         help="Which run to record evidence for: the escrowed-DvP-with-a-dispute-window "
                              "reference deployment (default), or the CIP-0112 DvP-between-registries "
                              "integration harness")
    return parser.parse_args()


def parse_timestamp(value, label, script_output_path):
    if not value:
        raise SystemExit(f"{script_output_path}: {label} is missing; cannot check timestamp ordering")
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as exc:
        raise SystemExit(f"{script_output_path}: {label} = {value!r} is not a parseable timestamp: {exc}")
    # Reject a timezone-naive value rather than assuming UTC. Daml's Show always
    # renders a trailing Z, so a naive timestamp means the field was edited by
    # hand; assuming UTC would silently accept it, and mixing a naive value with
    # an aware one would fail the ordering comparison with a TypeError traceback
    # instead of the message every sibling check produces.
    if parsed.tzinfo is None:
        raise SystemExit(
            f"{script_output_path}: {label} = {value!r} has no timezone offset; "
            "the reference deployment records UTC timestamps ending in Z"
        )
    return parsed


def check_contract_id(cid, label, script_output_path):
    if not cid or not CONTRACT_ID_RE.match(cid):
        raise SystemExit(
            f"{script_output_path}: {label} = {cid!r} does not look like a real Canton "
            f"contract ID (expected '00' followed by a long run of lowercase hex); "
            f"the evidence gate rejects fabricated or truncated contract IDs"
        )


def check_update_id(uid, label, script_output_path):
    if not uid or not UPDATE_ID_RE.match(uid):
        raise SystemExit(
            f"{script_output_path}: {label} = {uid!r} does not look like a real Canton "
            f"update ID (expected '1220' followed by 64 lowercase hex characters); "
            f"the evidence gate rejects fabricated or truncated update IDs"
        )


def check_no_secrets(evidence, script_output_path):
    dumped = json.dumps(evidence)
    if "LEDGER_TOKEN" in dumped or "Authorization" in dumped:
        raise SystemExit(
            f"{script_output_path}: evidence contains the literal string 'LEDGER_TOKEN' or "
            f"'Authorization'; refusing to write output that may carry a bearer token"
        )
    jwt_match = JWT_RE.search(dumped)
    if jwt_match:
        raise SystemExit(
            f"{script_output_path}: evidence contains a JWT-shaped string "
            f"({jwt_match.group(0)[:16]}...); refusing to write output that may carry a bearer token"
        )


def release_context(dar_dir):
    artifacts = []
    for package in FIRST_PARTY_RELEASE_PACKAGES:
        version = dar_identity.package_version(package)
        path = (dar_dir / f"{package}-{version}.dar") if dar_dir is not None \
            else dar_identity.built_dar_path(package)
        if not path.exists():
            raise SystemExit(f"Deployed DAR not found: {path}; cannot describe what was uploaded")
        artifacts.append(dar_identity.dar_artifact(package, path))

    splice_pin = json.loads((ROOT / "SPLICE_PIN").read_text())
    git_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()
    git_status = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    git_dirty = bool(git_status.strip())
    return artifacts, splice_pin, git_commit, git_dirty


def record_reference(args):
    run_dir: Path = args.run_dir
    dar_dir: Path = args.dar_dir

    ledger_version_path = run_dir / "ledger-version.json"
    if not ledger_version_path.exists():
        raise SystemExit(f"Missing {ledger_version_path}; the run did not capture the ledger version")
    canton_version_observed = json.loads(ledger_version_path.read_text()).get("version")
    if not canton_version_observed:
        raise SystemExit(f"{ledger_version_path} has no 'version' field")
    if not CANTON_VERSION_RE.match(canton_version_observed):
        raise SystemExit(
            f"{ledger_version_path}: canton_version_observed = {canton_version_observed!r} does not "
            f"look like a Canton version (expected to start with digits.digits.digits)"
        )

    script_output_path = run_dir / "script-output.json"
    if not script_output_path.exists():
        raise SystemExit(f"Missing {script_output_path}; the reference deployment did not run")
    result = json.loads(script_output_path.read_text())

    deadline = result.get("deadline")
    deadline_ts = parse_timestamp(deadline, "deadline", script_output_path)

    all_contract_ids = []
    paths = {}
    # min_outputs is derived from each path, not typed as a magic number: the
    # settle rule releases the whole amount to bob (one output), the award
    # rule splits between alice and bob, its two receivers (at least two
    # outputs).
    for name, lock_key, outputs_key, enacted_key, guards_key, outcome_key, min_outputs, order in (
        ("settle", "settleLockCid", "settleOutputCids", "settleEnactedAt",
         "settleGuards", "settleOutcome", 1, "before"),
        ("award", "awardLockCid", "awardOutputCids", "awardEnactedAt",
         "awardGuards", "awardOutcome", 2, "after"),
    ):
        lock_cid = result.get(lock_key)
        output_cids = result.get(outputs_key)
        guards = result.get(guards_key)
        outcome = result.get(outcome_key)
        if not lock_cid or not output_cids:
            raise SystemExit(
                f"{script_output_path} is missing contract IDs for the {name!r} path "
                f"({lock_key!r}/{outputs_key!r}); the reference deployment evidence is incomplete"
            )
        if not guards or not outcome:
            raise SystemExit(
                f"{script_output_path} is missing the Daml-rendered rule for the {name!r} path "
                f"({guards_key!r}/{outcome_key!r}); the reference deployment evidence is incomplete"
            )
        if len(output_cids) < min_outputs:
            raise SystemExit(
                f"{script_output_path}: {name!r} path has {len(output_cids)} output contract "
                f"ID(s) ({outputs_key!r}), expected at least {min_outputs} given its outcome's "
                f"receivers; the run did not complete as the terms describe"
            )
        check_contract_id(lock_cid, f"{name}.{lock_key}", script_output_path)
        for i, cid in enumerate(output_cids):
            check_contract_id(cid, f"{name}.{outputs_key}[{i}]", script_output_path)
        all_contract_ids.append(lock_cid)
        all_contract_ids.extend(output_cids)

        enacted_at = result.get(enacted_key)
        enacted_ts = parse_timestamp(enacted_at, f"{name}.{enacted_key}", script_output_path)
        if order == "before" and not (enacted_ts < deadline_ts):
            raise SystemExit(
                f"{script_output_path}: settle.{enacted_key} = {enacted_at!r} is not strictly "
                f"before deadline = {deadline!r}; the settle path must enact before the deadline "
                f"passes, and the evidence does not show that it did"
            )
        if order == "after" and not (enacted_ts > deadline_ts):
            raise SystemExit(
                f"{script_output_path}: award.{enacted_key} = {enacted_at!r} is not strictly "
                f"after deadline = {deadline!r}; the award path must enact after the deadline "
                f"passes, and the evidence does not show that it did"
            )

        paths[name] = {
            "name": name,
            "rule": name,
            "guards": guards,
            "outcome": outcome,
            "lock_contract_id": lock_cid,
            "output_contract_ids": output_cids,
            "update_ids": [],
            "deadline": deadline,
            "enacted_at": enacted_at,
        }

    if len(all_contract_ids) != len(set(all_contract_ids)):
        raise SystemExit(
            f"{script_output_path}: contract IDs repeat across the settle and award paths; "
            f"a real run against fresh locks produces distinct contract IDs, so this looks like "
            f"a copy-paste or a replayed run"
        )

    artifacts, splice_pin, git_commit, git_dirty = release_context(dar_dir)

    evidence = {
        "schema_version": 1,
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "network_runtime": args.network,
        "execution": (
            "Escrowed DvP with a dispute window (settle and award) run against a live "
            "Canton participant under wall-clock time, funded and settled through the "
            "TestTokenV2 registry."
        ),
        "release": args.release or "unreleased",
        "git_commit": git_commit,
        "git_dirty": git_dirty,
        "splice_version_reference": splice_pin["tracked_release"],
        "splice_source_ref": splice_pin["ref"],
        "canton_version_observed": canton_version_observed,
        "sdk": splice_pin["sdk"],
        "lf": splice_pin["lf"],
        "artifacts": artifacts,
        "scripts": [paths["settle"], paths["award"]],
        "update_id_source": UPDATE_ID_FALLBACK,
    }
    if args.network == "localnet":
        evidence["sandbox_runtime"] = args.sandbox_runtime or "testnet"
    if args.runtime_tag:
        evidence["splice_image_tag"] = args.runtime_tag

    check_no_secrets(evidence, script_output_path)

    slug = f"{args.network}-{args.runtime_tag}" if args.runtime_tag else args.network
    output_path = ROOT / f"docs/runbook/{slug}-reference-evidence.json"
    output_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Wrote {output_path}")


UPDATE_ID_SOURCE = (
    "the JSON Ledger API v2 submit-and-wait-for-transaction response; unlike the "
    "escrowed-DvP reference path (which runs through Daml Script and cannot "
    "return ledger update IDs, see UPDATE_ID_FALLBACK), this harness submits "
    "directly and records the update ID the ledger returned. The recorded IDs are "
    "then cross-checked: the harness independently re-read each update from the "
    "participant's own /v2/updates/update-by-id after the fact (settlement-update.json, "
    "expire-update.json), and this file rejects the evidence unless the IDs, timestamps, "
    "synchronizer, root choices, and transfer amounts in those raw responses agree with "
    "what is claimed here"
)

DVP_REQUIRED_CHOICES = ("SettlementFactory_SettleBatch", "Allocation_Settle", "ConditionalLock_Enact")
DVP_REQUIRED_PACKAGES = ("splice-amulet", "splice-test-token-v2", "conditional-lock-test-token")
PACKAGE_ID_RE = re.compile(r"^[0-9a-f]{64}$")
DVP_ROOT_CHOICES = sorted(["SettlementFactory_SettleBatch", "ConditionalLock_Enact"])


def load_update_file(run_dir, name, dvp_run_path):
    update_path = run_dir / name
    if not update_path.exists():
        raise SystemExit(
            f"Missing {update_path}; the harness did not record the participant's own copy of the "
            f"update, so {dvp_run_path}'s claims about it cannot be cross-checked"
        )
    doc = json.loads(update_path.read_text())
    # /v2/updates/update-by-id wraps the transaction in the JsUpdate variant
    # ({"update": {"Transaction": {"value": {...}}}}); the deprecated
    # /v2/updates/transaction-by-id returns it flat under "transaction". Accept
    # either, so the gate does not silently read an empty transaction and then
    # reject every field as missing when the harness switches endpoints.
    tx = ((doc.get("update") or {}).get("Transaction") or {}).get("value") \
        or doc.get("transaction")
    if not isinstance(tx, dict) or "updateId" not in tx:
        raise SystemExit(
            f"{update_path}: no transaction found. Expected the participant's /v2/updates "
            f"response, either {{'update': {{'Transaction': {{'value': ...}}}}}} or "
            f"{{'transaction': ...}}; got top-level keys {sorted(doc)}"
        )
    return update_path, tx


def dvp_events(tx):
    """Flatten a transaction's events list into (kind, payload) pairs."""
    pairs = []
    for ev in tx.get("events") or []:
        for kind, payload in ev.items():
            pairs.append((kind, payload))
    return pairs


def dvp_created_events(tx):
    return [payload for kind, payload in dvp_events(tx) if kind == "CreatedEvent"]


def dvp_find_created(tx, cid, label, update_path):
    for payload in dvp_created_events(tx):
        if payload.get("contractId") == cid:
            return payload
    raise SystemExit(f"{update_path}: no CreatedEvent for {label} = {cid!r} in transaction.events")


def dvp_root_events(tx):
    """A node is a root when no other node's [nodeId, lastDescendantNodeId] span
    strictly contains it. ExercisedEvents carry their own span; CreatedEvents
    have no descendants, so their span is just themselves."""
    nodes = []
    for kind, payload in dvp_events(tx):
        node_id = payload.get("nodeId")
        last_id = payload.get("lastDescendantNodeId", node_id) if kind == "ExercisedEvent" else node_id
        nodes.append((node_id, last_id, kind, payload))
    roots = []
    for node_id, last_id, kind, payload in nodes:
        contained = any(
            (other_id, other_last) != (node_id, last_id) and other_id <= node_id and last_id <= other_last
            for other_id, other_last, _, _ in nodes
        )
        if not contained:
            roots.append((kind, payload))
    return roots


def record_dvp(args):
    checked_at_dt = datetime.now(timezone.utc)
    run_dir: Path = args.run_dir
    dvp_run_path = run_dir / "dvp-run.json"
    if not dvp_run_path.exists():
        raise SystemExit(f"Missing {dvp_run_path}; the DvP-between-registries harness did not run")
    result = json.loads(dvp_run_path.read_text())

    canton_version_observed = result.get("canton_version_observed")
    if not canton_version_observed:
        raise SystemExit(f"{dvp_run_path} has no 'canton_version_observed' field")
    if not CANTON_VERSION_RE.match(canton_version_observed):
        raise SystemExit(
            f"{dvp_run_path}: canton_version_observed = {canton_version_observed!r} does not "
            f"look like a Canton version (expected to start with digits.digits.digits)"
        )

    settlement = result.get("settlement") or {}
    expiry = result.get("expiry") or {}
    delivery = settlement.get("delivery") or {}
    payment = settlement.get("payment") or {}
    packages_observed = result.get("packages_observed") or {}

    artifacts, splice_pin, git_commit, git_dirty = release_context(args.dar_dir)

    # Gate 2/3: update IDs are well-formed and distinct.
    settlement_update_id = settlement.get("update_id")
    expire_update_id = expiry.get("expire_update_id")
    check_update_id(settlement_update_id, "settlement.update_id", dvp_run_path)
    check_update_id(expire_update_id, "expiry.expire_update_id", dvp_run_path)
    if settlement_update_id == expire_update_id:
        raise SystemExit(
            f"{dvp_run_path}: settlement.update_id and expiry.expire_update_id are identical "
            f"({settlement_update_id!r}); the settlement and the expiry are separate transactions, "
            f"so identical update IDs mean a copied field"
        )

    # Gate 4: contract IDs are well-formed and distinct.
    amulet_allocation_cids = settlement.get("amulet_allocation_cids") or []
    contract_id_fields = [
        ("settlement.delivery.holding_contract_id", delivery.get("holding_contract_id")),
        ("settlement.payment.holding_contract_id", payment.get("holding_contract_id")),
        ("settlement.lock_contract_id", settlement.get("lock_contract_id")),
        ("expiry.returned_contract_id", expiry.get("returned_contract_id")),
        ("expiry.amulet_allocation_withdrawn_cid", expiry.get("amulet_allocation_withdrawn_cid")),
    ] + [
        (f"settlement.amulet_allocation_cids[{i}]", cid) for i, cid in enumerate(amulet_allocation_cids)
    ]
    for label, cid in contract_id_fields:
        check_contract_id(cid, label, dvp_run_path)
    all_contract_ids = [cid for _, cid in contract_id_fields]
    if len(all_contract_ids) != len(set(all_contract_ids)):
        raise SystemExit(
            f"{dvp_run_path}: contract IDs repeat across the settlement and expiry paths; "
            f"a real run against fresh contracts produces distinct contract IDs, so this looks like "
            f"a copy-paste or a replayed run"
        )

    # Gate 5: exactly one submission carried both legs.
    command_count = settlement.get("command_count")
    if command_count != 2:
        raise SystemExit(
            f"{dvp_run_path}: settlement.command_count = {command_count!r}, expected 2; fewer or "
            f"more means it was not one submission carrying both legs"
        )

    # Gate 6: the payment leg is real Canton Coin, the delivery leg is TestTokenV2.
    payment_package = payment.get("package_name")
    if payment_package != "splice-amulet":
        raise SystemExit(
            f"{dvp_run_path}: settlement.payment.package_name = {payment_package!r}, expected "
            f"'splice-amulet'; the payment leg must be real Canton Coin, not a substitute"
        )
    delivery_package = delivery.get("package_name")
    if delivery_package != "splice-test-token-v2":
        raise SystemExit(
            f"{dvp_run_path}: settlement.delivery.package_name = {delivery_package!r}, expected "
            f"'splice-test-token-v2'; the delivery leg must be the published TestTokenV2 package, "
            f"not a substitute"
        )

    # Gate 7: all three packages were observed, each a well-formed package ID, all distinct.
    for name in DVP_REQUIRED_PACKAGES:
        if name not in packages_observed:
            raise SystemExit(
                f"{dvp_run_path}: packages_observed is missing {name!r}; the run did not observe "
                f"the package it depends on"
            )
        package_id = packages_observed[name]
        if not package_id or not PACKAGE_ID_RE.match(package_id):
            raise SystemExit(
                f"{dvp_run_path}: packages_observed[{name!r}] = {package_id!r} does not look like "
                f"a package ID (expected exactly 64 lowercase hex characters)"
            )
    observed_package_ids = [packages_observed[name] for name in DVP_REQUIRED_PACKAGES]
    if len(observed_package_ids) != len(set(observed_package_ids)):
        raise SystemExit(
            f"{dvp_run_path}: packages_observed has repeated package IDs across "
            f"{DVP_REQUIRED_PACKAGES}; three distinct packages should have three distinct IDs"
        )

    # Gate 8: all three choices were exercised.
    choices_exercised = settlement.get("choices_exercised") or []
    for choice in DVP_REQUIRED_CHOICES:
        if choice not in choices_exercised:
            raise SystemExit(
                f"{dvp_run_path}: settlement.choices_exercised = {choices_exercised!r} is missing "
                f"{choice!r}; the run does not show this choice being exercised"
            )

    # Gate 9: transfer leg IDs are present and follow the CIP 3.7 <lockId>/<ruleId>/<legId> shape.
    lock_id = settlement.get("lock_id")
    transfer_leg_ids = settlement.get("transfer_leg_ids") or []
    if not transfer_leg_ids:
        raise SystemExit(f"{dvp_run_path}: settlement.transfer_leg_ids is empty; no leg was recorded")
    for i, leg_id in enumerate(transfer_leg_ids):
        if not lock_id or not str(leg_id).startswith(f"{lock_id}/"):
            raise SystemExit(
                f"{dvp_run_path}: settlement.transfer_leg_ids[{i}] = {leg_id!r} does not start with "
                f"settlement.lock_id ({lock_id!r}) followed by '/'; the CIP section 3.7 leg "
                f"identifier is <lockId>/<ruleId>/<legId>"
            )

    # Gate 10: the settlement and the expiry are separate locks.
    expiry_lock_id = expiry.get("lock_id")
    if lock_id == expiry_lock_id:
        raise SystemExit(
            f"{dvp_run_path}: settlement.lock_id and expiry.lock_id are identical ({lock_id!r}); "
            f"the settlement and the expiry must be separate locks"
        )

    # Gate 11: the rejection must come after the deadline, or the guard did nothing.
    deadline_ts = parse_timestamp(expiry.get("deadline"), "expiry.deadline", dvp_run_path)
    expires_at_ts = parse_timestamp(expiry.get("expires_at"), "expiry.expires_at", dvp_run_path)
    enact_rejected_ts = parse_timestamp(
        expiry.get("enact_rejected_at"), "expiry.enact_rejected_at", dvp_run_path
    )
    if not (deadline_ts < expires_at_ts):
        raise SystemExit(
            f"{dvp_run_path}: expiry.deadline = {expiry.get('deadline')!r} is not strictly before "
            f"expiry.expires_at = {expiry.get('expires_at')!r}; the rejection must come after the "
            f"deadline or the run does not show the guard doing anything"
        )
    if not (enact_rejected_ts > deadline_ts):
        raise SystemExit(
            f"{dvp_run_path}: expiry.enact_rejected_at = {expiry.get('enact_rejected_at')!r} is not "
            f"strictly after expiry.deadline = {expiry.get('deadline')!r}; the rejection must come "
            f"after the deadline or the run does not show the guard doing anything"
        )

    # Gate 12: the rejection reason names the guard that fired.
    enact_rejection = expiry.get("enact_rejection") or ""
    if "no alternative is satisfied" not in enact_rejection:
        raise SystemExit(
            f"{dvp_run_path}: expiry.enact_rejection = {enact_rejection!r} does not contain "
            f"'no alternative is satisfied'; the run does not show the expected guard rejection"
        )

    # Gate 13: the expiry path returns the same locked amount it would have delivered.
    returned_amount = expiry.get("returned_amount")
    delivery_amount = delivery.get("amount")
    if returned_amount != delivery_amount:
        raise SystemExit(
            f"{dvp_run_path}: expiry.returned_amount = {returned_amount!r} does not equal "
            f"settlement.delivery.amount = {delivery_amount!r}; the expiry path must return the "
            f"same locked amount it would have delivered"
        )

    # --- Cross-checks against the participant's own raw update responses. These are
    # independently re-read `/v2/updates/update-by-id` responses (see the --kind dvp
    # harness), not the submit response, so they catch a claimed evidence field that
    # does not match what the participant itself recorded. ---
    settlement_update_path, settlement_tx = load_update_file(run_dir, "settlement-update.json", dvp_run_path)
    expire_update_path, expire_tx = load_update_file(run_dir, "expire-update.json", dvp_run_path)

    # Gate 14: settlement update ID matches the participant's own recorded response.
    settlement_tx_update_id = settlement_tx.get("updateId")
    if settlement_tx_update_id != settlement_update_id:
        raise SystemExit(
            f"{settlement_update_path}: transaction.updateId = {settlement_tx_update_id!r} does not "
            f"match settlement.update_id = {settlement_update_id!r} in {dvp_run_path}; a claimed "
            f"update ID that does not match the participant's own recorded response is fabricated"
        )
    expire_tx_update_id = expire_tx.get("updateId")
    if expire_tx_update_id != expire_update_id:
        raise SystemExit(
            f"{expire_update_path}: transaction.updateId = {expire_tx_update_id!r} does not match "
            f"expiry.expire_update_id = {expire_update_id!r} in {dvp_run_path}; a claimed update ID "
            f"that does not match the participant's own recorded response is fabricated"
        )

    # Gate 15: effective_at matches the settlement update's own timestamp and parses.
    effective_at = settlement.get("effective_at")
    settlement_effective_at = settlement_tx.get("effectiveAt")
    if effective_at != settlement_effective_at:
        raise SystemExit(
            f"{dvp_run_path}: settlement.effective_at = {effective_at!r} does not equal "
            f"{settlement_update_path}'s transaction.effectiveAt = {settlement_effective_at!r}"
        )
    parse_timestamp(effective_at, "settlement.effective_at", dvp_run_path)

    # Gate 16: synchronizer_id matches both raw updates' own synchronizer.
    synchronizer_id = result.get("synchronizer_id")
    settlement_sync_id = settlement_tx.get("synchronizerId")
    if synchronizer_id != settlement_sync_id:
        raise SystemExit(
            f"{dvp_run_path}: synchronizer_id = {synchronizer_id!r} does not equal "
            f"{settlement_update_path}'s transaction.synchronizerId = {settlement_sync_id!r}"
        )
    expire_sync_id = expire_tx.get("synchronizerId")
    if synchronizer_id != expire_sync_id:
        raise SystemExit(
            f"{dvp_run_path}: synchronizer_id = {synchronizer_id!r} does not equal "
            f"{expire_update_path}'s transaction.synchronizerId = {expire_sync_id!r}"
        )

    # Gate 17: exactly two root nodes in the settlement update, and command_count is
    # derived from them rather than asserted about itself.
    settlement_roots = dvp_root_events(settlement_tx)
    if len(settlement_roots) != 2:
        raise SystemExit(
            f"{settlement_update_path}: found {len(settlement_roots)} root node(s) in "
            f"transaction.events by nodeId/lastDescendantNodeId containment, expected exactly 2; "
            f"a DvP settlement is one submission carrying exactly two top-level commands"
        )
    if command_count != len(settlement_roots):
        raise SystemExit(
            f"{dvp_run_path}: settlement.command_count = {command_count!r} does not equal the "
            f"{len(settlement_roots)} root node(s) found in {settlement_update_path}; command_count "
            f"must be derived from the participant's own recorded response, not asserted about itself"
        )
    non_exercised_roots = [kind for kind, _ in settlement_roots if kind != "ExercisedEvent"]
    if non_exercised_roots:
        raise SystemExit(
            f"{settlement_update_path}: a root node is a {non_exercised_roots[0]!r}, not an "
            f"ExercisedEvent; the top-level commands of a settlement are choice exercises"
        )
    root_choices = sorted(payload.get("choice") for _, payload in settlement_roots)
    if root_choices != DVP_ROOT_CHOICES:
        raise SystemExit(
            f"{settlement_update_path}: root node choices = {root_choices!r}, expected one each of "
            f"{DVP_ROOT_CHOICES!r}; the settlement must be exactly a settle-batch and an enact"
        )
    settle_batch_root = next(
        payload for _, payload in settlement_roots if payload.get("choice") == "SettlementFactory_SettleBatch"
    )

    # Gate 18: every claimed choice actually appears in the settlement update's own events.
    all_choices_in_update = {
        payload.get("choice") for kind, payload in dvp_events(settlement_tx) if kind == "ExercisedEvent"
    }
    for choice in choices_exercised:
        if choice not in all_choices_in_update:
            raise SystemExit(
                f"{dvp_run_path}: settlement.choices_exercised includes {choice!r}, which does not "
                f"appear as a choice in any event of {settlement_update_path}"
            )
    if "Allocation_Settle" not in all_choices_in_update:
        raise SystemExit(
            f"{settlement_update_path}: no event has choice 'Allocation_Settle'; a settlement "
            f"between two allocations must exercise it"
        )

    # Gate 19: the delivery and payment holding CreatedEvents are real, in the right
    # package, and their on-ledger owner/amount match what is claimed.
    delivery_cid = delivery.get("holding_contract_id")
    delivery_created = dvp_find_created(
        settlement_tx, delivery_cid, "settlement.delivery.holding_contract_id", settlement_update_path
    )
    if delivery_created.get("packageName") != "splice-test-token-v2":
        raise SystemExit(
            f"{settlement_update_path}: CreatedEvent for {delivery_cid!r} has packageName = "
            f"{delivery_created.get('packageName')!r}, expected 'splice-test-token-v2'"
        )
    delivery_holding = (delivery_created.get("createArgument") or {}).get("holding") or {}
    delivery_owner = (delivery_holding.get("account") or {}).get("owner")
    if delivery_owner != delivery.get("receiver"):
        raise SystemExit(
            f"{settlement_update_path}: delivery CreatedEvent's holding.account.owner = "
            f"{delivery_owner!r} does not equal settlement.delivery.receiver = "
            f"{delivery.get('receiver')!r}"
        )
    if delivery_holding.get("amount") != delivery.get("amount"):
        raise SystemExit(
            f"{settlement_update_path}: delivery CreatedEvent's holding.amount = "
            f"{delivery_holding.get('amount')!r} does not equal settlement.delivery.amount = "
            f"{delivery.get('amount')!r}"
        )

    payment_cid = payment.get("holding_contract_id")
    payment_created = dvp_find_created(
        settlement_tx, payment_cid, "settlement.payment.holding_contract_id", settlement_update_path
    )
    if payment_created.get("packageName") != "splice-amulet":
        raise SystemExit(
            f"{settlement_update_path}: CreatedEvent for {payment_cid!r} has packageName = "
            f"{payment_created.get('packageName')!r}, expected 'splice-amulet'"
        )
    payment_arg = payment_created.get("createArgument") or {}
    if payment_arg.get("owner") != payment.get("receiver"):
        raise SystemExit(
            f"{settlement_update_path}: payment CreatedEvent's owner = {payment_arg.get('owner')!r} "
            f"does not equal settlement.payment.receiver = {payment.get('receiver')!r}"
        )
    payment_amount_onledger = (payment_arg.get("amount") or {}).get("initialAmount")
    if payment_amount_onledger != payment.get("amount"):
        raise SystemExit(
            f"{settlement_update_path}: payment CreatedEvent's amount.initialAmount = "
            f"{payment_amount_onledger!r} does not equal settlement.payment.amount = "
            f"{payment.get('amount')!r}"
        )

    # Gate 20: delivery and payment do not go to the same party.
    if delivery.get("receiver") == payment.get("receiver"):
        raise SystemExit(
            f"{dvp_run_path}: settlement.delivery.receiver and settlement.payment.receiver are both "
            f"{delivery.get('receiver')!r}; a settlement where one party receives both legs is not "
            f"a delivery versus payment"
        )

    # Gate 21: payment sender and receiver are distinct, and match the settle-batch
    # root's own transfer leg, catching a self-transfer.
    payment_sender = payment.get("sender")
    if payment_sender == payment.get("receiver"):
        raise SystemExit(
            f"{dvp_run_path}: settlement.payment.sender and settlement.payment.receiver are both "
            f"{payment_sender!r}; a self-transfer is not a payment"
        )
    settle_transfer_legs = (settle_batch_root.get("choiceArgument") or {}).get("transferLegs") or []
    if not settle_transfer_legs:
        raise SystemExit(
            f"{settlement_update_path}: the SettlementFactory_SettleBatch root has no "
            f"choiceArgument.transferLegs[0]; cannot cross-check the payment leg"
        )
    settle_leg = settle_transfer_legs[0]
    leg_sender_owner = (settle_leg.get("sender") or {}).get("owner")
    leg_receiver_owner = (settle_leg.get("receiver") or {}).get("owner")
    if leg_sender_owner != payment_sender:
        raise SystemExit(
            f"{dvp_run_path}: settlement.payment.sender = {payment_sender!r} does not equal the "
            f"settle-batch root's choiceArgument.transferLegs[0].sender.owner = {leg_sender_owner!r}"
        )
    if leg_receiver_owner != payment.get("receiver"):
        raise SystemExit(
            f"{dvp_run_path}: settlement.payment.receiver = {payment.get('receiver')!r} does not "
            f"equal the settle-batch root's choiceArgument.transferLegs[0].receiver.owner = "
            f"{leg_receiver_owner!r}"
        )

    # Gate 22: delivery and payment amounts parse as decimals and are strictly positive.
    for label, amount_value in (
        ("settlement.delivery.amount", delivery.get("amount")),
        ("settlement.payment.amount", payment.get("amount")),
    ):
        try:
            parsed_amount = Decimal(str(amount_value))
        except (InvalidOperation, TypeError):
            raise SystemExit(f"{dvp_run_path}: {label} = {amount_value!r} does not parse as a decimal")
        if not (parsed_amount > 0):
            raise SystemExit(f"{dvp_run_path}: {label} = {amount_value!r} is not strictly greater than zero")

    # Gate 23: the expiry path returns the holding to the delivery's authorizer side
    # (not to the delivery receiver), with the claimed amount matching the expire
    # update's own CreatedEvent.
    returned_cid = expiry.get("returned_contract_id")
    returned_created = dvp_find_created(
        expire_tx, returned_cid, "expiry.returned_contract_id", expire_update_path
    )
    if returned_created.get("packageName") != "splice-test-token-v2":
        raise SystemExit(
            f"{expire_update_path}: CreatedEvent for {returned_cid!r} has packageName = "
            f"{returned_created.get('packageName')!r}, expected 'splice-test-token-v2'"
        )
    returned_holding = (returned_created.get("createArgument") or {}).get("holding") or {}
    returned_owner = (returned_holding.get("account") or {}).get("owner")
    if returned_owner == delivery.get("receiver"):
        raise SystemExit(
            f"{expire_update_path}: the returned holding's owner = {returned_owner!r} equals "
            f"settlement.delivery.receiver; the expiry path must return the contract to the "
            f"delivery's authorizer side, not to the delivery receiver"
        )
    if returned_holding.get("amount") != expiry.get("returned_amount"):
        raise SystemExit(
            f"{expire_update_path}: returned holding's amount = {returned_holding.get('amount')!r} "
            f"does not equal expiry.returned_amount = {expiry.get('returned_amount')!r}"
        )

    # Gate 24: transfer leg IDs have exactly three '/'-separated, non-empty components,
    # the first equal to settlement.lock_id. The CIP section 3.7 identifier is
    # <lockId>/<ruleId>/<legId>; a prefix-only check would accept "<lockId>/x".
    for i, leg_id in enumerate(transfer_leg_ids):
        leg_parts = str(leg_id).split("/")
        if len(leg_parts) != 3 or any(not part for part in leg_parts) or leg_parts[0] != lock_id:
            raise SystemExit(
                f"{dvp_run_path}: settlement.transfer_leg_ids[{i}] = {leg_id!r} is not "
                f"'<lockId>/<ruleId>/<legId>' with settlement.lock_id ({lock_id!r}) as the first "
                f"of exactly three non-empty components; the CIP section 3.7 leg identifier has "
                f"exactly three components"
            )

    # Gate 25: packages_observed matches the package IDs this repository actually built.
    artifact_by_package = {artifact["package"]: artifact["package_id"] for artifact in artifacts}
    for name, observed_id in packages_observed.items():
        if name in artifact_by_package and observed_id != artifact_by_package[name]:
            raise SystemExit(
                f"{dvp_run_path}: packages_observed[{name!r}] = {observed_id!r} does not equal the "
                f"{name!r} package ID this repository built ({artifact_by_package[name]!r}); a "
                f"package ID in the evidence that does not match the DAR this repository actually "
                f"built means the run used a different build"
            )

    # Gate 26: run_nonce and recorded_at are present, and recorded_at is neither in
    # the future nor more than 24 hours stale relative to when evidence is checked.
    run_nonce = result.get("run_nonce")
    if not run_nonce or not isinstance(run_nonce, str):
        raise SystemExit(f"{dvp_run_path}: run_nonce is missing or empty; cannot identify this run")
    recorded_at = result.get("recorded_at")
    recorded_at_ts = parse_timestamp(recorded_at, "recorded_at", dvp_run_path)
    if recorded_at_ts > checked_at_dt:
        raise SystemExit(
            f"{dvp_run_path}: recorded_at = {recorded_at!r} is in the future relative to when this "
            f"evidence is being checked; a run artifact cannot be recorded before it happened"
        )
    if (checked_at_dt - recorded_at_ts).total_seconds() > 24 * 3600:
        raise SystemExit(
            f"{dvp_run_path}: recorded_at = {recorded_at!r} is more than 24 hours before this "
            f"evidence is being checked; a run artifact this old is a stale artifact"
        )

    evidence = {
        "schema_version": 1,
        "checked_at": checked_at_dt.isoformat(),
        "network_runtime": args.network,
        "execution": (
            "CIP-0112 DvP between registries settled atomically in one transaction: a real "
            "Canton Coin (Amulet) payment leg against TestTokenV2 delivered under our "
            "conditional-lock interface, plus the expiry path returning the locked delivery "
            "when no alternative is satisfied."
        ),
        "release": args.release or "unreleased",
        "git_commit": git_commit,
        "git_dirty": git_dirty,
        "splice_version_reference": splice_pin["tracked_release"],
        "splice_source_ref": splice_pin["ref"],
        "canton_version_observed": canton_version_observed,
        "sdk": splice_pin["sdk"],
        "lf": splice_pin["lf"],
        "artifacts": artifacts,
        "splice_image_tag": result.get("splice_image_tag"),
        "parties": result.get("parties"),
        "packages_observed": packages_observed,
        "synchronizer_id": result.get("synchronizer_id"),
        "settlements": [settlement, expiry],
        "update_id_source": UPDATE_ID_SOURCE,
        "cross_checked": {
            "settlement_root_choices": root_choices,
            "settlement_update_id_recorded": settlement_tx_update_id,
            "expire_update_id_recorded": expire_tx_update_id,
        },
    }
    if args.runtime_tag:
        evidence["splice_image_tag"] = args.runtime_tag

    check_no_secrets(evidence, dvp_run_path)

    slug = f"{args.network}-{args.runtime_tag}" if args.runtime_tag else args.network
    output_path = ROOT / f"docs/runbook/{slug}-dvp-evidence.json"
    output_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Wrote {output_path}")


def main():
    args = parse_args()
    if args.kind == "dvp":
        record_dvp(args)
    else:
        if args.dar_dir is None:
            raise SystemExit("--dar-dir is required for --kind reference: the reference deployment "
                             "stages the DARs it uploads, and the evidence records that staging "
                             "directory rather than whatever happens to be built now")
        record_reference(args)


if __name__ == "__main__":
    main()
