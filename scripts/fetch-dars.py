#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""SPLICE_PIN is the single source of dependency versions and identities."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    pin = json.loads((ROOT / "SPLICE_PIN").read_text())
    ref = os.environ.get("SPLICE_DARS_REF", pin["ref"])
    directory = ROOT / ".dars"
    directory.mkdir(exist_ok=True)
    for package in pin["packages"]:
        target = directory / package["file"]
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == package["sha256"]:
            print(f"verified {target.name}", flush=True)
            continue
        url = f'https://raw.githubusercontent.com/{pin["repository"]}/{ref}/daml/dars/{target.name}'
        print(f"fetch {target.name} at {ref}", flush=True)
        with tempfile.NamedTemporaryFile(dir=directory) as temporary:
            subprocess.run(["curl", "-fsSL", "--retry", "3", "--connect-timeout", "15", "--max-time", "120",
                            url, "-o", temporary.name], check=True)
            data = Path(temporary.name).read_bytes()
            if hashlib.sha256(data).hexdigest() != package["sha256"]:
                raise SystemExit(f"Checksum mismatch for {target.name}; review SPLICE_PIN before updating dependencies.")
            with zipfile.ZipFile(temporary.name) as archive:
                manifest = archive.read("META-INF/MANIFEST.MF").decode().replace("\r\n ", "").replace("\n ", "")
                main_dalf = manifest.split("Main-Dalf: ")[1].splitlines()[0]
                if Path(main_dalf).stem[-64:] != package["package_id"]:
                    raise SystemExit(f"Package ID mismatch for {target.name}")
            staged = directory / (target.name + ".verified")
            staged.write_bytes(data)
            staged.replace(target)


if __name__ == "__main__":
    main()
