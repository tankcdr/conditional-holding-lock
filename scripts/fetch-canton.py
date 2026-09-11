#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fetch the official Canton binary matching a pinned network runtime."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
networks = json.loads((ROOT / "fixtures/runtime-versions.json").read_text())
network = networks[sys.argv[1]]
version = network["canton"]
cache = ROOT / ".localnet/runtimes"
cache.mkdir(parents=True, exist_ok=True)
archive = cache / f"canton-{version}.tar.gz"
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != network["canton_archive_sha256"]:
    temporary = archive.with_suffix(".download")
    url = f"https://github.com/digital-asset/canton/releases/download/v{version}/canton-open-source-{version}.tar.gz"
    subprocess.run(["curl", "-fsSL", "--retry", "3", "--connect-timeout", "15", url, "-o", str(temporary)], check=True)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != network["canton_archive_sha256"]:
        raise SystemExit("Canton release checksum mismatch")
    temporary.replace(archive)
binary = cache / f"canton-open-source-{version}/bin/canton"
if not binary.exists():
    subprocess.run(["tar", "-xzf", str(archive), "-C", str(cache)], check=True)
print(binary)
