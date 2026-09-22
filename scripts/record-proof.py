#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the matrix result and record the exact artifacts it exercised."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
network, run_path = sys.argv[1:]
run = Path(run_path)
config = json.loads((ROOT / "fixtures/runtime-versions.json").read_text())[network]
version = json.loads((run / "ledger-version.json").read_text())["version"]
results = json.loads((run / "results.json").read_text())
required = {
    "TestHashVectors:test_hashVectorsMatchEvm",
    "TestConditionalLock:test_approverAuthorityPersistsAndAuthorizerDoesNotEnact",
    "TestConditionalLock:test_oneStepBothActorsAndAuthorizerChange",
    "TestConditionalLock:test_atomicDvpAcrossTwoTestTokenV2Registries",
    "TestConditionalLock:test_atomicDvpRollsBackFirstEnactWhenSecondFails",
    "TestWorkedExamples:test_example_htlcLeg",
    "TestWorkedExamples:test_example_dvpBetweenRegistries",
    "TestWorkedExamples:test_example_arbiterEscrow",
    "TestWorkedExamples:test_example_vesting",
    "TestWorkedExamples:test_example_collateral",
    "TestWorkedExamples:test_example_conditionalPayment",
    "TestPolicyLimits:test_cipFloorsAreSatisfied",
    "TestPolicyLimits:test_belowCipFloorIsRejected",
    "TestPolicyLimits:test_limitsMetadataMatchesAdvertised",
    "TestPolicyLimits:test_limitsRoundTripThroughMetadata",
    "TestPolicyLimits:test_limitsFromMetadataRejectsMalformed",
    "TestPolicyLimits:test_witnessPreimageBoundIsEnforced",
    "TestPolicyLimits:test_eachLimitKeyCarriesItsOwnField",
    "TestPolicyLimits:test_pureValidatorsReadBoundsFromTheirArgument",
    "TestPolicyLimits:test_legValidatorsReadBoundsFromTheirArgument",
    "TestPolicyLimits:test_validateTermsReadsBoundsFromItsArgument",
    "TestRegistryLimits:test_preimageCountAtTheLimitIsAcceptedAndOverTheLimitRejected",
}
if version != config["canton"] or not required.issubset(results) or any("result" not in r for r in results.values()):
    raise SystemExit("Runtime mismatch, missing core proofs, or failed scripts; see " + str(run))
artifacts = []
for package in ("splice-api-token-conditional-lock-v1", "conditional-lock-utils", "conditional-lock-test-token", "conditional-lock-test"):
    path = ROOT / f"packages/{package}/.daml/dist/{package}-1.0.0.dar"
    with zipfile.ZipFile(path) as archive:
        manifest = archive.read("META-INF/MANIFEST.MF").decode().replace("\r\n ", "").replace("\n ", "")
        main = manifest.split("Main-Dalf: ")[1].splitlines()[0]
    artifacts.append({"package": package, "package_id": Path(main).stem[-64:], "dar_sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
evidence = {
    "checked_at": datetime.now(timezone.utc).isoformat(),
    "network_runtime": network,
    "execution": "local Canton OSS, single participant and synchronizer, static time, real Ledger API",
    "splice_version_reference": config["splice"],
    "canton_version_observed": version,
    "sdk": config["sdk"],
    "lf": "2.1",
    "splice_source_ref": json.loads((ROOT / "SPLICE_PIN").read_text())["ref"],
    "artifacts": artifacts,
    "passed": sorted(results),
}
(run / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
print(f"PASS: {len(results)} Daml scripts on Canton {version} ({network} runtime)")
