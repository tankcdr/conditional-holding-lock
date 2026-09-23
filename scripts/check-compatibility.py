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


def tree_sha256(root):
    """Stable digest of a vendored tree's contents, offline and without git.

    Hashes the sorted relative paths, an executable-bit flag, and the bytes
    of every file under `root`, excluding SOURCE.json itself. Shared by
    scripts/localnet-sync.sh (which records it in SOURCE.json when it
    materializes a tree, via `python3 check-compatibility.py --tree-digest`)
    and localnet_row() below (which recomputes it to detect hand-edits), so
    the digest logic lives in exactly one place.
    """
    root = Path(root)
    digest = hashlib.sha256()
    paths = sorted(p for p in root.rglob("*") if p.is_file())
    for p in paths:
        rel = p.relative_to(root).as_posix()
        if rel == "SOURCE.json":
            continue
        executable = 1 if (p.stat().st_mode & 0o111) else 0
        digest.update(rel.encode("utf-8"))
        digest.update(bytes([executable]))
        digest.update(p.read_bytes())
    return digest.hexdigest()


def localnet_row(mainnet_splice, drift):
    """Compare the vendored localnet stack's Splice tag with live Mainnet.

    Appends to `drift` in the same "expected X, live Y" shape the network rows
    use, so `just release` fails when Mainnet moves and the localnet has not
    been re-synced with scripts/localnet-sync.sh.
    """
    row = {"image_tag": None, "overrides_dir": None, "source": None}
    example = ROOT / ".env.localnet.example"
    match = re.search(r"^\s*IMAGE_TAG\s*=\s*(\S+)\s*$", example.read_text(), re.M)
    if not match:
        drift.append(f"localnet: {example.name} has no IMAGE_TAG line")
        return row
    tag = match.group(1).strip('"').strip("'")
    row["image_tag"] = tag

    overrides = ROOT / "localnet-overrides" / f"splice-{tag}"
    row["overrides_dir"] = str(overrides.relative_to(ROOT))
    source_path = overrides / "SOURCE.json"
    if not source_path.exists():
        drift.append(
            f"localnet: {source_path.relative_to(ROOT)} is missing; "
            f"run scripts/localnet-sync.sh to materialize the Splice {tag} localnet tree"
        )
    else:
        source = json.loads(source_path.read_text())
        row["source"] = {k: source.get(k) for k in ("repository", "tag", "commit", "synced_at")}
        if source.get("tag") != tag:
            drift.append(
                f"localnet: {source_path.relative_to(ROOT)} records tag {source.get('tag')}, "
                f"but .env.localnet.example pins IMAGE_TAG {tag}"
            )
        recorded_digest = source.get("tree_sha256")
        if not recorded_digest:
            drift.append(
                f"localnet: {source_path.relative_to(ROOT)} has no tree_sha256; "
                f"run scripts/localnet-sync.sh to record it"
            )
        else:
            actual_digest = tree_sha256(overrides)
            if actual_digest != recorded_digest:
                drift.append(
                    f"localnet: {row['overrides_dir']} has been modified since it was synced "
                    f"(tree digest mismatch); it must match Splice tag {tag} verbatim"
                )

    if mainnet_splice and tag != mainnet_splice:
        drift.append(f"localnet.splice: expected {tag}, live {mainnet_splice}")
    return row


def main():
    pin = json.loads((ROOT / "SPLICE_PIN").read_text())
    expected = json.loads((ROOT / "fixtures/runtime-versions.json").read_text())
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "splice_ref": pin["ref"], "networks": {}, "artifacts": []}
    drift = []
    for name in ("mainnet", "testnet", "devnet"):
        config = expected[name]
        try:
            info = json.loads(fetch(config["info_url"]))
            page = html.unescape(re.sub("<[^>]+>", " ", fetch(config["versions_url"]).decode()))
            page = " ".join(page.split())
            canton = re.search(r"Canton version used for validator and SV nodes\s+(\d+\.\d+\.\d+)", page)
            sdk = re.search(r"Daml SDK version used to compile\s+\.dars\s+(\d+\.\d+\.\d+)", page)
            if not canton or not sdk:
                raise SystemExit(f"Cannot parse authoritative {name} version information")
            actual = {"splice": info["sv"]["version"], "canton": canton[1], "sdk": sdk[1]}
        except (Exception, SystemExit) as exc:
            if not config.get("informational"):
                raise
            report["networks"][name] = {"error": str(exc) or type(exc).__name__}
            continue
        report["networks"][name] = actual
        for key, value in actual.items():
            if value != config[key] and not config.get("informational"):
                drift.append(f"{name}.{key}: expected {config[key]}, live {value}")
    # localnet row: the vendored Splice localnet stack must be at the same
    # release Mainnet is running, which is what "keep the localnet up to date
    # with mainnet" means. The pin lives in .env.localnet.example's IMAGE_TAG
    # (the single tag that selects every Splice image) and is backed by
    # localnet-overrides/splice-<tag>/SOURCE.json, written by
    # scripts/localnet-sync.sh from the Splice tag itself.
    report["localnet"] = localnet_row(report["networks"].get("mainnet", {}).get("splice"), drift)

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
    if len(sys.argv) >= 3 and sys.argv[1] == "--tree-digest":
        print(tree_sha256(sys.argv[2]))
        raise SystemExit(0)
    raise SystemExit(main())
