#!/usr/bin/env python3
"""macOS Seatbelt policy for untrusted local component candidate composition."""

from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

POLICY_ID = "FOVEA-COMPONENT-CANDIDATE-SANDBOX-V1"
BUILD_SYSTEM = "native"
PROJECT_TEMP_SUBDIRECTORIES = (
    "FoveaTests",
    "FoveaBenchmark",
    "FoveaAuthGallery",
    "FoveaTransport",
    "FoveaBenchmarkArtifacts",
    "fovea-transport-handoff",
)
PROJECT_TEMP_PREFIXES = (
    "fovea-t100-",
    "t100-",
)


@dataclass(frozen=True)
class SandboxLayout:
    temporary_root: Path
    fovea_source: Path
    state_root: Path
    candidate_sources: tuple[Path, ...]
    host_home: Path
    user_temp: Path

    @classmethod
    def create(
        cls,
        *,
        temporary_root: Path,
        fovea_source: Path,
        state_root: Path,
        candidate_sources: Sequence[Path],
        host_home: Path | None = None,
    ) -> "SandboxLayout":
        resolved_root = temporary_root.resolve()
        resolved_fovea = fovea_source.resolve()
        resolved_state = state_root.resolve()
        resolved_candidates = tuple(path.resolve() for path in candidate_sources)
        resolved_home = (host_home or Path.home()).resolve()
        user_temp_output = subprocess.run(
            ["getconf", "DARWIN_USER_TEMP_DIR"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
        resolved_user_temp = Path(user_temp_output).resolve()
        return cls(
            temporary_root=resolved_root,
            fovea_source=resolved_fovea,
            state_root=resolved_state,
            candidate_sources=resolved_candidates,
            host_home=resolved_home,
            user_temp=resolved_user_temp,
        )


def _scheme_string(value: str | Path) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def _scheme_regex(pattern: str) -> str:
    return "#" + json.dumps(pattern, ensure_ascii=False)


def _regex_literal(value: str) -> str:
    # Seatbelt's regex dialect treats an escaped '-' as a literal backslash plus '-'.
    return re.escape(value).replace("\\-", "-")


def render_profile(layout: SandboxLayout) -> str:
    """Render a deny-write/deny-network profile with narrow Swift toolchain exceptions."""

    temporary_items = layout.user_temp / "TemporaryItems"
    temporary_items.mkdir(parents=True, exist_ok=True)
    user_temp_pattern = re.escape(layout.user_temp.as_posix())

    lines = [
        "(version 1)",
        "(debug deny)",
        "(allow default)",
        "(deny network*)",
        "(deny file-write*)",
        f"(allow file-write* (subpath {_scheme_string(layout.state_root)}))",
        f"(allow file-write* (subpath {_scheme_string(layout.fovea_source / 'Packages')}))",
        f"(allow file-write* (literal {_scheme_string(layout.fovea_source / 'Package.resolved')}))",
        f"(allow file-write* (subpath {_scheme_string(temporary_items)}))",
        "(allow file-write* (regex "
        + _scheme_regex(rf"^{user_temp_pattern}/TemporaryDirectory\.[^/]+(/.*)?$")
        + "))",
        f"(allow file-write* (subpath {_scheme_string(layout.user_temp / 'swift-generated-sources')}))",
    ]
    lines.extend(
        f"(allow file-write* (subpath {_scheme_string(layout.user_temp / name)}))"
        for name in PROJECT_TEMP_SUBDIRECTORIES
    )
    lines.extend(
        "(allow file-write* (regex "
        + _scheme_regex(
            rf"^{user_temp_pattern}/{_regex_literal(prefix)}[^/]+(/.*)?$"
        )
        + "))"
        for prefix in PROJECT_TEMP_PREFIXES
    )
    lines.extend(
        [
            "(allow file-write* (regex "
            + _scheme_regex(rf"^{user_temp_pattern}/xcrun_db(-[^/]+)?$")
            + "))",
            f"(allow file-write-data (literal {_scheme_string('/dev/dtracehelper')}))",
            f"(allow file-write-data (literal {_scheme_string('/dev/null')}))",
            f"(deny file-read* (subpath {_scheme_string(layout.host_home)}))",
            f"(allow file-read* (subpath {_scheme_string(layout.temporary_root)}))",
        ]
    )
    for candidate in layout.candidate_sources:
        if not candidate.is_relative_to(layout.temporary_root):
            lines.append(
                f"(allow file-read* (subpath {_scheme_string(candidate)}))"
            )
    return "\n".join(lines) + "\n"


def prepare_state_environment(
    layout: SandboxLayout, base: Mapping[str, str]
) -> dict[str, str]:
    home = layout.state_root / "home"
    temp = layout.state_root / "tmp"
    cache = layout.state_root / "cache"
    config = layout.state_root / "config"
    security = layout.state_root / "security"
    scratch = layout.state_root / "scratch"
    for directory in (home, temp, cache, config, security, scratch):
        directory.mkdir(parents=True, exist_ok=True)

    environment = dict(base)
    environment.update(
        {
            "HOME": str(home),
            "TMPDIR": str(temp),
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "SWIFTPM_MODULECACHE_OVERRIDE": str(cache / "module-cache"),
            "CLANG_MODULE_CACHE_PATH": str(cache / "clang"),
        }
    )
    return environment


def swiftpm_state_options(layout: SandboxLayout) -> list[str]:
    return [
        "--disable-sandbox",
        "--cache-path",
        str(layout.state_root / "cache"),
        "--config-path",
        str(layout.state_root / "config"),
        "--security-path",
        str(layout.state_root / "security"),
        "--scratch-path",
        str(layout.state_root / "scratch"),
    ]


def sandbox_command(profile: Path, command: Sequence[str]) -> list[str]:
    return ["/usr/bin/sandbox-exec", "-f", str(profile.resolve()), *command]


def profile_digest(profile: str) -> str:
    return hashlib.sha256(profile.encode()).hexdigest()


def _escape_probe_source() -> str:
    return r'''#!/usr/bin/env python3
import errno
import json
import socket
import sys
from pathlib import Path

state_root = Path(sys.argv[1])
host_read_target = Path(sys.argv[2])
fovea_write_target = Path(sys.argv[3])
outside_write_target = Path(sys.argv[4])
candidate_write_targets = [Path(value) for value in sys.argv[5:]]
results = []


def expect_denied(name, operation):
    try:
        operation()
    except PermissionError as error:
        if error.errno not in (errno.EPERM, errno.EACCES):
            raise
        results.append({"name": name, "status": "denied", "errno": error.errno})
        return
    except OSError as error:
        if error.errno not in (errno.EPERM, errno.EACCES):
            raise
        results.append({"name": name, "status": "denied", "errno": error.errno})
        return
    raise RuntimeError(f"sandbox escape probe unexpectedly succeeded: {name}")


allowed = state_root / "probes" / "allowed-write.txt"
allowed.parent.mkdir(parents=True, exist_ok=True)
allowed.write_text("allowed\n")
results.append({"name": "dedicated-state-write", "status": "allowed"})

expect_denied("host-source-read", lambda: host_read_target.read_bytes())
expect_denied("isolated-fovea-source-write", lambda: fovea_write_target.open("ab").write(b"x"))
expect_denied("host-write-escape", lambda: outside_write_target.write_text("escape\n"))
for index, target in enumerate(candidate_write_targets):
    expect_denied(
        f"candidate-snapshot-write-{index}",
        lambda target=target: target.open("ab").write(b"x"),
    )

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.25)
try:
    result = sock.connect_ex(("127.0.0.1", 9))
finally:
    sock.close()
if result not in (errno.EPERM, errno.EACCES):
    raise RuntimeError(f"network denial probe returned errno={result}, expected EPERM/EACCES")
results.append({"name": "network-connect", "status": "denied", "errno": result})

report = {
    "schemaVersion": 1,
    "status": "passed",
    "cases": results,
    "networkDenied": True,
    "hostSourceReadDenied": True,
    "hostWriteEscapeDenied": True,
    "isolatedFoveaSourceWriteDenied": True,
    "candidateSnapshotWritesDenied": True,
    "dedicatedStateWriteAllowed": True,
}
(state_root / "probes" / "result.json").write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n"
)
'''


def run_escape_probes(
    *,
    layout: SandboxLayout,
    profile_path: Path,
    environment: Mapping[str, str],
    host_read_target: Path,
    outside_write_target: Path,
) -> dict[str, object]:
    probes = layout.state_root / "probes"
    probes.mkdir(parents=True, exist_ok=True)
    script = probes / "probe.py"
    script.write_text(_escape_probe_source())
    script.chmod(0o755)
    result_path = probes / "result.json"
    if result_path.exists():
        result_path.unlink()
    if outside_write_target.exists():
        outside_write_target.unlink()

    command = sandbox_command(
        profile_path,
        [
            "/usr/bin/python3",
            str(script),
            str(layout.state_root),
            str(host_read_target.resolve()),
            str((layout.fovea_source / "Package.swift").resolve()),
            str(outside_write_target.resolve(strict=False)),
            *[
                str((candidate / "Package.swift").resolve())
                for candidate in layout.candidate_sources
            ],
        ],
    )
    completed = subprocess.run(
        command,
        cwd=layout.temporary_root,
        env=dict(environment),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise RuntimeError("component sandbox escape probes failed:\n" + completed.stdout)
    if outside_write_target.exists():
        raise RuntimeError("component sandbox host write escape created an artifact")
    if not result_path.is_file():
        raise RuntimeError("component sandbox escape probe report is missing")
    report = json.loads(result_path.read_text())
    if report.get("status") != "passed":
        raise RuntimeError("component sandbox escape probe report did not pass")
    return report
