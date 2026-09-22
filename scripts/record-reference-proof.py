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
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import dar_identity  # noqa: E402

FIRST_PARTY_RELEASE_PACKAGES = [
    package for package, attached in dar_identity.PACKAGES if attached
]

RULE_DESCRIPTIONS = {
    "settle": {
        "rule": "settle",
        "guards": "allOf [Guard_Parties [alice, bob] 2, Guard_Before deadline]",
        "outcome": "Outcome_Release with fixedLegs = [Leg \"delivery\" bob amount]; receivers = []",
    },
    "award": {
        "rule": "award",
        "guards": "allOf [Guard_After deadline, Guard_Parties [arbiter] 1]",
        "outcome": "Outcome_Release with fixedLegs = []; receivers = [alice, bob]",
    },
}

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

    script_output_path = run_dir / "script-output.json"
    if not script_output_path.exists():
        raise SystemExit(f"Missing {script_output_path}; the reference deployment did not run")
    result = json.loads(script_output_path.read_text())

    paths = {}
    for name, lock_key, outputs_key in (
        ("settle", "settleLockCid", "settleOutputCids"),
        ("award", "awardLockCid", "awardOutputCids"),
    ):
        lock_cid = result.get(lock_key)
        output_cids = result.get(outputs_key)
        if not lock_cid or not output_cids:
            raise SystemExit(
                f"{script_output_path} is missing contract IDs for the {name!r} path "
                f"({lock_key!r}/{outputs_key!r}); the reference deployment evidence is incomplete"
            )
        paths[name] = {
            "name": name,
            **RULE_DESCRIPTIONS[name],
            "lock_contract_id": lock_cid,
            "output_contract_ids": output_cids,
            "update_ids": [],
        }

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
