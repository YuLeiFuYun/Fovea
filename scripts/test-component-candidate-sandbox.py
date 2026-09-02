#!/usr/bin/env python3
"""Regression checks for component-candidate sandbox project temp prefixes."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from component_candidate_sandbox import (  # noqa: E402
    PROJECT_TEMP_PREFIXES,
    SandboxLayout,
    prepare_state_environment,
    render_profile,
    sandbox_command,
)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="foveacandidatesandboxtest") as directory:
        root = Path(directory)
        fovea_source = root / "Fovea"
        state_root = root / "State"
        for path in (fovea_source, state_root):
            path.mkdir()

        layout = SandboxLayout.create(
            temporary_root=root,
            fovea_source=fovea_source,
            state_root=state_root,
            candidate_sources=(),
        )
        environment = prepare_state_environment(layout, os.environ)
        profile_path = state_root / "candidate-sandbox.sb"
        profile_path.write_text(render_profile(layout))

        probe = (
            "import pathlib,sys; "
            "p=pathlib.Path(sys.argv[1]); "
            "p.mkdir(); "
            "f=p/'probe.txt'; "
            "f.write_text('ok'); "
            "f.unlink(); "
            "p.rmdir()"
        )
        for prefix in PROJECT_TEMP_PREFIXES:
            target = layout.user_temp / f"{prefix}sandbox-regression-{os.getpid()}"
            completed = subprocess.run(
                sandbox_command(
                    profile_path,
                    ["/usr/bin/python3", "-c", probe, str(target)],
                ),
                cwd=root,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if completed.returncode != 0:
                raise AssertionError(
                    f"project temp prefix {prefix!r} was denied by Seatbelt:\n"
                    + completed.stdout
                )

    print("component candidate sandbox project-temp regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
