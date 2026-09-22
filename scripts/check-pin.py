#!/usr/bin/env python3
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Check SPLICE_PIN's tag identity: shape, consistency, and upstream position.

Does not fetch or verify DAR digests; scripts/check-compatibility.py already
does that and `just release` runs it as a separate step.
"""
import json
from pathlib import Path
import re
import subprocess
from subprocess import CalledProcessError

ROOT = Path(__file__).resolve().parent.parent


def main():
    pin = json.loads((ROOT / "SPLICE_PIN").read_text())
    ref = pin.get("ref", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", ref):
        raise SystemExit(
            f"SPLICE_PIN.ref {ref!r} must be an unprefixed version like 0.8.1; "
            "canton-network/splice tags are unprefixed and a leading 'v' 404s on "
            "raw.githubusercontent.com."
        )
    if "tracked_branch" in pin:
        raise SystemExit("SPLICE_PIN still has a 'tracked_branch' key; remove it now that a release tag is tracked.")
    if "tracked_release" not in pin:
        raise SystemExit("SPLICE_PIN is missing 'tracked_release'.")
    if pin["tracked_release"] != ref:
        raise SystemExit(f"SPLICE_PIN.tracked_release {pin['tracked_release']!r} does not match ref {ref!r}.")

    try:
        output = subprocess.check_output(
            ["gh", "api", f"repos/{pin['repository']}/git/ref/tags/{ref}"],
            stderr=subprocess.PIPE,
        )
    except CalledProcessError as exc:
        raise SystemExit(f"tag {ref} not found in {pin['repository']}: {exc.stderr.decode().strip()}")

    ref_obj = json.loads(output)
    if isinstance(ref_obj, list):
        raise SystemExit(f"tag {ref} not found in {pin['repository']}")

    obj = ref_obj["object"]
    sha = obj["sha"]
    if obj.get("type") == "tag":
        sha = subprocess.check_output(
            ["gh", "api", f"repos/{pin['repository']}/git/tags/{sha}", "--jq", ".object.sha"]
        ).decode().strip()

    if sha != pin["splice_release_commit"]:
        raise SystemExit(
            f"Upstream tag {ref} now resolves to commit {sha}; expected commit {pin['splice_release_commit']}. "
            "The upstream tag has MOVED; do not update splice_release_commit without review."
        )

    print(f"OK: SPLICE_PIN ref {ref} resolves to commit {sha}")


if __name__ == "__main__":
    main()
