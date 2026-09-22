#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read live network versions and verify our pinned published Splice artifacts."""
import hashlib
import html
import json
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent


def fetch(url):
    return subprocess.check_output(["curl", "-fsSL", "--retry", "2", "--connect-timeout", "15", "--max-time", "60", url])


def main():
    pin = json.loads((ROOT / "SPLICE_PIN").read_text())
    expected = json.loads((ROOT / "fixtures/runtime-versions.json").read_text())
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "splice_ref": pin["ref"], "networks": {}, "artifacts": []}
    drift = []
    for name in ("mainnet", "testnet", "devnet"):
        config = expected[name]
        info = json.loads(fetch(config["info_url"]))
        page = html.unescape(re.sub("<[^>]+>", " ", fetch(config["versions_url"]).decode()))
        page = " ".join(page.split())
        canton = re.search(r"Canton version used for validator and SV nodes\s+(\d+\.\d+\.\d+)", page)
        sdk = re.search(r"Daml SDK version used to compile\s+\.dars\s+(\d+\.\d+\.\d+)", page)
        if not canton or not sdk:
            raise SystemExit(f"Cannot parse authoritative {name} version information")
        actual = {"splice": info["sv"]["version"], "canton": canton[1], "sdk": sdk[1]}
        report["networks"][name] = actual
        for key, value in actual.items():
            if value != config[key] and not config.get("informational"):
                drift.append(f"{name}.{key}: expected {config[key]}, live {value}")
    for package in pin["packages"]:
        url = f'https://raw.githubusercontent.com/{pin["repository"]}/{pin["ref"]}/daml/dars/{package["file"]}'
        digest = hashlib.sha256(fetch(url)).hexdigest()
        report["artifacts"].append({"file": package["file"], "sha256": digest, "matches_pin": digest == package["sha256"]})
        if digest != package["sha256"]:
            drift.append(f"{package['file']}: source checksum differs from SPLICE_PIN")
    report["drift"] = drift
    print(json.dumps(report, indent=2))
    if drift:
        print("Compatibility pins need review; update the runtime fixtures and rerun the Ledger API matrix.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
