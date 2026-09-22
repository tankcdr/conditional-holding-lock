#!/usr/bin/env python3
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Record honest evidence for a devnet-reference.sh run of the escrowed-DvP
with a dispute window (examples/devnet-escrow), against a real participant
under wall-clock time.

Gated: refuses to write evidence that is not backed by the run's own
artifacts. Never reads or writes LEDGER_TOKEN or any Authorization header.
"""
import argparse
from datetime import datetime, timezone
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
CANTON_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+")

UPDATE_ID_FALLBACK = (
    "not captured; Daml Script does not return ledger update IDs, so contract "
    "IDs from the script's own return value are recorded instead"
)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", required=True, choices=["localnet", "devnet"])
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--dar-dir", required=True, type=Path)
    parser.add_argument("--release")
    parser.add_argument("--sandbox-runtime", choices=["mainnet", "testnet"])
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


def main():
    args = parse_args()
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

    artifacts = []
    for package in FIRST_PARTY_RELEASE_PACKAGES:
        version = dar_identity.package_version(package)
        path = dar_dir / f"{package}-{version}.dar"
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

    assert "LEDGER_TOKEN" not in evidence and "Authorization" not in json.dumps(evidence)

    output_path = ROOT / f"docs/runbook/{args.network}-reference-evidence.json"
    output_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Wrote {output_path}")


if __name__ == "__main__":
    main()
