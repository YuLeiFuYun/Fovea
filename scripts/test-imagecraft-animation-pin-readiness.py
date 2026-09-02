#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).with_name("check-imagecraft-animation-pin-readiness.py")
spec = importlib.util.spec_from_file_location("imagecraft_animation_pin_readiness", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CURRENT = "736d0fb75e9e128642ce418ad984ce5151b1f324"
CANDIDATE = "04e153795b80164983a57b0b871f10d87ba79ea1"
TREE = "5c07f313cf57495b6ffc7f578be8acbdd3e64c13"
PUBLISHED = "1111111111111111111111111111111111111111"


def blocked_study() -> dict[str, object]:
    return {
        "sourceIdentity": {
            "imageCraftHeadCommit": CANDIDATE,
            "imageCraftWorkingTree": TREE,
            "sourcesUnchangedDuringRun": True,
        },
        "pinUpgradeDiscovery": {"productionPinStill": CURRENT},
        "productionPinReadiness": {
            "status": "blocked-unpublished-working-tree-candidate",
            "currentProductionRevision": CURRENT,
            "qualifiedCandidateHeadCommit": CANDIDATE,
            "qualifiedCandidateWorkingTree": TREE,
            "qualifiedCandidateIncludesWorkingTreeChanges": True,
            "qualificationSourceIsClean": False,
            "publishedImmutableCandidateRevision": None,
            "pinUpgradeAuthorized": False,
        },
    }


def main() -> int:
    study = blocked_study()
    assert module.validate_state(CURRENT, CURRENT, study) == []

    moved_early = module.validate_state(CANDIDATE, CANDIDATE, study)
    assert "production ImageCraft pin changed before publication authorization" in moved_early

    premature = copy.deepcopy(study)
    readiness = premature["productionPinReadiness"]
    assert isinstance(readiness, dict)
    readiness["pinUpgradeAuthorized"] = True
    readiness["status"] = "ready-published-clean-qualified"
    premature_errors = module.validate_state(CURRENT, CURRENT, premature)
    assert "authorized pin requires a published immutable revision" in premature_errors
    assert "authorized qualification must have no working-tree changes" in premature_errors
    assert "authorized qualification must record qualificationSourceIsClean=true" in premature_errors

    ready = copy.deepcopy(study)
    ready_identity = ready["sourceIdentity"]
    ready_discovery = ready["pinUpgradeDiscovery"]
    ready_readiness = ready["productionPinReadiness"]
    assert isinstance(ready_identity, dict)
    assert isinstance(ready_discovery, dict)
    assert isinstance(ready_readiness, dict)
    ready_identity["imageCraftHeadCommit"] = PUBLISHED
    ready_identity["imageCraftWorkingTree"] = PUBLISHED
    ready_discovery["productionPinStill"] = CURRENT
    ready_readiness.update(
        {
            "status": "ready-published-clean-qualified",
            "qualifiedCandidateHeadCommit": PUBLISHED,
            "qualifiedCandidateWorkingTree": PUBLISHED,
            "qualifiedCandidateIncludesWorkingTreeChanges": False,
            "qualificationSourceIsClean": True,
            "publishedImmutableCandidateRevision": PUBLISHED,
            "pinUpgradeAuthorized": True,
        }
    )
    assert module.validate_state(PUBLISHED, PUBLISHED, ready) == []

    wrong_pin = module.validate_state(CURRENT, CURRENT, ready)
    assert "authorized pin and qualification must equal the published revision" in wrong_pin

    print("ImageCraft animation pin readiness contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
