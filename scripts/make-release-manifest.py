#!/usr/bin/env python3
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Write conditional-lock-release.json: the artifact manifest for a release.

Nothing here is cryptographically signed; DAR signing is out of scope for 0.1.0.

Usage: make-release-manifest.py <version> [--allow-dirty]
"""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import dar_identity  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--allow-dirty", action="store_true", help="Skip the clean worktree check for dry runs.")
    args = parser.parse_args()

    status = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).decode()
    dirty = bool(status.strip())
    if dirty and not args.allow_dirty:
        raise SystemExit("Worktree is dirty; git_commit would not describe the bytes being hashed. Commit or pass --allow-dirty for a dry run.")

    git_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip()
    pin = json.loads((ROOT / "SPLICE_PIN").read_text())
    runtimes = json.loads((ROOT / "fixtures/runtime-versions.json").read_text())

    packages = []
    for package, attached in dar_identity.PACKAGES:
        path = dar_identity.built_dar_path(package)
        artifact = dar_identity.dar_artifact(package, path)
        packages.append({
            "file": path.name,
            "package_id": artifact["package_id"],
            "dar_sha256": artifact["dar_sha256"],
            "attached": attached,
        })

    manifest = {
        "release": f"v{args.version}",
        "released_at": date.today().isoformat(),
        "git_commit": git_commit,
        "splice_release": pin["ref"],
        "splice_release_commit": pin["splice_release_commit"],
        "sdk": pin["sdk"],
        "lf": pin["lf"],
        "build_options": ["--explicit-serializable=yes", "--target=2.1"],
        "networks_reference": {
            "mainnet": {"splice_reference": runtimes["mainnet"]["splice"], "canton_exercised_locally": runtimes["mainnet"]["canton"]},
            "testnet": {"splice_reference": runtimes["testnet"]["splice"], "canton_exercised_locally": runtimes["testnet"]["canton"]},
        },
        "packages": packages,
        "splice_dependencies": pin["packages"],
        "hash_vectors_sha256": hashlib.sha256((ROOT / "fixtures/hash-vectors.json").read_bytes()).hexdigest(),
    }
    if args.allow_dirty:
        manifest["dry_run"] = True
        manifest["git_dirty"] = dirty

    changelog_path = ROOT / "CHANGELOG.md"
    if not changelog_path.exists():
        raise SystemExit(f"CHANGELOG.md does not exist; add a '## [{args.version}]' heading with the Package identity block before running this.")
    changelog = changelog_path.read_text()
    heading = re.search(rf"^## \[{re.escape(args.version)}\]", changelog, re.MULTILINE)
    if not heading:
        raise SystemExit(f"CHANGELOG.md is missing heading '## [{args.version}]'")
    rest = changelog[heading.end():]
    next_heading = re.search(r"^## ", rest, re.MULTILINE)
    section = rest[:next_heading.start()] if next_heading else rest
    for package in packages:
        if package["package_id"] not in section:
            raise SystemExit(f"CHANGELOG.md is missing package ID {package['package_id']}; regenerate the Package identity block from the built DARs")

    manifest_path = ROOT / ("conditional-lock-release.dry-run.json" if args.allow_dirty else "conditional-lock-release.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    reloaded = json.loads(manifest_path.read_text())
    if reloaded["splice_dependencies"] != pin["packages"]:
        raise SystemExit("splice_dependencies in the written manifest does not byte-equal SPLICE_PIN.packages")

    print(f"OK: wrote {manifest_path.name} for {manifest['release']} at {git_commit[:12]}")


if __name__ == "__main__":
    main()
