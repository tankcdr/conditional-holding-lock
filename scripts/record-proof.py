#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the matrix result and record the exact artifacts it exercised."""
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import dar_identity  # noqa: E402

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
for package, _attached in dar_identity.PACKAGES:
    path = dar_identity.built_dar_path(package)
    artifacts.append(dar_identity.dar_artifact(package, path))
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
