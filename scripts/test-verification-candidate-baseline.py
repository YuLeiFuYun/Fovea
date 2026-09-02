#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).with_name("run-verification-profile.py")
spec = importlib.util.spec_from_file_location("fovea_verification_profile", SCRIPT)
assert spec is not None and spec.loader is not None
profile = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = profile
spec.loader.exec_module(profile)


def run(root: Path, *argv: str) -> None:
    subprocess.run(list(argv), cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main() -> int:
    semantic_impact = {
        "categories": ["benchmark", "docs", "tooling"],
        "changedFiles": ["Tools/Performance/w5_yyimage_semantic_replay_oracle.py"],
    }
    iteration_names = {phase.name for phase in profile.iteration_static_phases(semantic_impact)}
    assert "w5-apng-semantic-replay-oracle" in iteration_names, iteration_names
    runner_impact = {
        "categories": ["tooling"],
        "changedFiles": ["scripts/run-w5-animated-simulator-lab.py"],
    }
    runner_iteration_names = {
        phase.name for phase in profile.iteration_static_phases(runner_impact)
    }
    assert "w5-animated-simulator-runner-contract" in runner_iteration_names, runner_iteration_names
    mac_impact = {
        "categories": ["source", "tests", "tooling"],
        "changedFiles": ["Tools/Performance/capture_w5_appkit_display_link.py"],
    }
    mac_iteration_names = {
        phase.name for phase in profile.iteration_static_phases(mac_impact)
    }
    assert "w5-appkit-display-link-capture-contract" in mac_iteration_names, mac_iteration_names
    assert "w5-appkit-callback-timing-capture-contract" in mac_iteration_names, mac_iteration_names
    assert "w5-appkit-refresh-timing-capture-contract" in mac_iteration_names, mac_iteration_names
    assert "w5-appkit-resource-proxy-capture-contract" in mac_iteration_names, mac_iteration_names
    mac_evidence_impact = {
        "categories": ["docs"],
        "changedFiles": ["docs/research/w5-appkit-refresh-timing-physical-2026-08.json"],
    }
    mac_evidence_names = {
        phase.name for phase in profile.iteration_static_phases(mac_evidence_impact)
    }
    assert "w5-appkit-refresh-timing-capture-contract" in mac_evidence_names, mac_evidence_names
    pin_impact = {
        "categories": ["docs", "tooling"],
        "changedFiles": ["docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json"],
    }
    pin_iteration_names = {
        phase.name for phase in profile.iteration_static_phases(pin_impact)
    }
    assert "imagecraft-animation-pin-readiness" in pin_iteration_names, pin_iteration_names
    assert "imagecraft-animation-pin-readiness-contract" in pin_iteration_names, pin_iteration_names
    sandbox_impact = {
        "categories": ["tooling"],
        "changedFiles": ["scripts/component_candidate_sandbox.py"],
    }
    sandbox_iteration_names = {
        phase.name for phase in profile.iteration_static_phases(sandbox_impact)
    }
    assert "component-candidate-sandbox-contract" in sandbox_iteration_names, sandbox_iteration_names
    static_names = {phase.name for phase in profile.static_phases(include_docs=True)}
    assert "w5-apng-semantic-replay-oracle" in static_names, static_names
    assert "w5-animated-simulator-runner-contract" in static_names, static_names
    assert "w5-appkit-display-link-capture-contract" in static_names, static_names
    assert "w5-appkit-callback-timing-capture-contract" in static_names, static_names
    assert "w5-appkit-refresh-timing-capture-contract" in static_names, static_names
    assert "w5-appkit-resource-proxy-capture-contract" in static_names, static_names
    assert "imagecraft-animation-pin-readiness" in static_names, static_names
    assert "imagecraft-animation-pin-readiness-contract" in static_names, static_names
    assert "component-candidate-sandbox-contract" in static_names, static_names

    original_root = profile.ROOT
    original_artifacts = profile.ARTIFACTS
    with tempfile.TemporaryDirectory(prefix="fovea-candidate-baseline-") as temporary:
        root = Path(temporary)
        run(root, "git", "init", "-q")
        run(root, "git", "config", "user.email", "test@example.invalid")
        run(root, "git", "config", "user.name", "Fovea Baseline Test")
        (root / ".gitignore").write_text(".artifacts/\n")
        (root / "Sources").mkdir()
        tracked = root / "Sources" / "Tracked.swift"
        deleted = root / "Sources" / "Deleted.swift"
        tracked.write_text("let value = 1\n")
        deleted.write_text("let deleted = true\n")
        run(root, "git", "add", ".gitignore", "Sources")
        run(root, "git", "commit", "-qm", "baseline")

        profile.ROOT = root
        profile.ARTIFACTS = root / ".artifacts" / "verification"
        initial = profile.source_state()
        baseline_path = profile.write_candidate_baseline(
            ".artifacts/verification/candidate-baselines/test.json",
            initial,
        )
        assert baseline_path.is_file()
        assert profile.source_state().working_tree == initial.working_tree

        tracked.write_text("let value = 2\n")
        deleted.unlink()
        (root / "Sources" / "Untracked.swift").write_text("let newValue = true\n")
        current = profile.source_state()
        _, payload = profile.load_candidate_baseline(
            str(baseline_path), current_head=current.head_commit
        )
        paths = profile.changed_files_between_trees(
            str(payload["workingTree"]), current.working_tree
        )
        assert paths == [
            "Sources/Deleted.swift",
            "Sources/Tracked.swift",
            "Sources/Untracked.swift",
        ], paths

        run(root, "git", "add", "-A")
        run(root, "git", "commit", "-qm", "head drift")
        try:
            profile.load_candidate_baseline(str(baseline_path), current_head=profile.source_state().head_commit)
        except ValueError as error:
            assert "HEAD differs" in str(error)
        else:
            raise AssertionError("HEAD drift must invalidate candidate baseline")

        outside = root.parent / "outside-baseline.json"
        try:
            profile.candidate_baseline_path(str(outside), require_existing=False)
        except ValueError as error:
            assert "inside the repository" in str(error)
        else:
            raise AssertionError("outside baseline path must be rejected")

        malformed = root / ".artifacts" / "verification" / "malformed.json"
        malformed.write_text(json.dumps({"schemaVersion": 1, "headCommit": "x", "workingTree": "x"}))
        try:
            profile.load_candidate_baseline(str(malformed), current_head=profile.source_state().head_commit)
        except ValueError:
            pass
        else:
            raise AssertionError("malformed baseline must be rejected")

    profile.ROOT = original_root
    profile.ARTIFACTS = original_artifacts
    print("candidate baseline contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
