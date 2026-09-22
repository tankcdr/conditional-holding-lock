# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Shared DAR identity parsing: the single manifest-parsing implementation."""
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parent.parent.parent

# Canonical ordered list of first-party packages: (package, attached_to_release).
# The single source of truth for "which packages, and is each one a release artifact".
PACKAGES = (
    ("splice-api-token-conditional-lock-v1", True),
    ("conditional-lock-utils", True),
    ("conditional-lock-test-token", True),
    ("conditional-lock-test", False),
)


def main_package_id(dar_path) -> str:
    """Return the main package ID encoded in a DAR's manifest."""
    with zipfile.ZipFile(dar_path) as archive:
        manifest = archive.read("META-INF/MANIFEST.MF").decode().replace("\r\n ", "").replace("\n ", "")
        main_dalf = manifest.split("Main-Dalf: ")[1].splitlines()[0]
    return Path(main_dalf).stem[-64:]


def dar_artifact(package: str, dar_path) -> dict:
    """Return {package, package_id, dar_sha256} for a built DAR."""
    path = Path(dar_path)
    return {
        "package": package,
        "package_id": main_package_id(path),
        "dar_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def package_version(package: str) -> str:
    """Read the `version:` field out of a package's daml.yaml."""
    daml_yaml = ROOT / f"packages/{package}/daml.yaml"
    match = re.search(r"^version:\s*(\S+)\s*$", daml_yaml.read_text(), re.MULTILINE)
    if not match:
        raise SystemExit(f"No 'version:' field found in {daml_yaml}")
    return match[1]


def built_dar_path(package: str) -> Path:
    """Resolve the built DAR path for a first-party package by its daml.yaml version."""
    return ROOT / f"packages/{package}/.daml/dist/{package}-{package_version(package)}.dar"
