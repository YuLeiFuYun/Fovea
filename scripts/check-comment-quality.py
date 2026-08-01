#!/usr/bin/env python3
"""检查中文注释基线，同时避免用机械注释数量替代可读性。"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path

from component_paths import ComponentPathError, resolve_reference
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ROOTS = [
    ROOT / "Sources",
    ROOT / "Tests",
    ROOT / "Tools",
    ROOT / "Examples",
]
LARGE_FILE_ROOTS = [
    ROOT / "Sources",
    ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench",
]
OUTPUT = ROOT / ".artifacts/style/comment-quality.json"
DOCUMENTED_PRODUCTION_FILE_LINES = 80
LARGE_FILE_LINES = 180
LARGE_FILE_MINIMUM_COMMENT_LINES = 2
MAX_COMMENT_RATIO = 0.35

# 这些短语描述高风险设计理由；检查它们是为了防止关键解释在重构时被静默删掉。
RATIONALE_OBLIGATIONS = {
    "Sources/FoveaCore/AsyncPermitPool.swift": ["最短处理时间", "防饥饿", "容量保留"],
    "Sources/FoveaCore/ImageLoadCoordinator.swift": ["ContentID", "磁盘 I/O"],
    "Sources/FoveaCore/PipelineCache.swift": ["半提交"],
    "component://ImageCraft/Sources/ImageCraftImageIO/EncodedImageSecurityInspector.swift": ["终止标记", "尾随载荷"],
    "Sources/FoveaHTTP/HTTPCachePolicy.swift": ["失败关闭"],
    "Sources/FoveaSwiftUI/FoveaImagePhaseContent.swift": ["透明"],
}


def is_english_only_comment(line: str) -> bool:
    stripped = line.strip()
    if not stripped.startswith("//"):
        return False
    text = re.sub(r"^//[/!]?\s*", "", stripped)
    letters = sum(character.isascii() and character.isalpha() for character in text)
    han = sum("\u4e00" <= character <= "\u9fff" for character in text)
    return letters >= 8 and han == 0


def main() -> int:
    files: list[dict[str, object]] = []
    errors: list[str] = []
    package_lines = (ROOT / "Package.swift").read_text().splitlines()
    for index, line in enumerate(package_lines, 1):
        if index == 1 and line.startswith("// swift-tools-version:"):
            continue
        if is_english_only_comment(line):
            errors.append(f"纯英文注释：Package.swift lines={[index]}")
    total_lines = 0
    total_comments = 0
    for root in ROOTS:
        for path in sorted(root.rglob("*.swift")):
            lines = path.read_text().splitlines()
            comment_lines = [line for line in lines if line.strip().startswith("//")]
            english = [index + 1 for index, line in enumerate(lines) if is_english_only_comment(line)]
            if english:
                errors.append(
                    f"纯英文注释：{path.relative_to(ROOT)} lines={english[:12]}"
                )
            requires_large_file_comment = any(
                path.is_relative_to(scope) for scope in LARGE_FILE_ROOTS
            )
            if (
                requires_large_file_comment
                and len(lines) >= DOCUMENTED_PRODUCTION_FILE_LINES
                and not comment_lines
            ):
                errors.append(
                    f"生产 Swift 文件零解释性注释：{path.relative_to(ROOT)} "
                    f"lines={len(lines)}"
                )
            if (
                requires_large_file_comment
                and len(lines) >= LARGE_FILE_LINES
                and len(comment_lines) < LARGE_FILE_MINIMUM_COMMENT_LINES
            ):
                errors.append(
                    f"大型生产 Swift 文件缺少职责/边界注释：{path.relative_to(ROOT)} "
                    f"lines={len(lines)} comments={len(comment_lines)}"
                )
            ratio = len(comment_lines) / max(1, len(lines))
            if ratio > MAX_COMMENT_RATIO and len(lines) >= 40:
                errors.append(
                    f"注释比例异常偏高，可能存在逐行复述：{path.relative_to(ROOT)} "
                    f"ratio={ratio:.3f}"
                )
            total_lines += len(lines)
            total_comments += len(comment_lines)
            files.append(
                {
                    "file": str(path.relative_to(ROOT)),
                    "lines": len(lines),
                    "commentLines": len(comment_lines),
                    "commentRatio": round(ratio, 6),
                }
            )

    for relative, phrases in RATIONALE_OBLIGATIONS.items():
        try:
            path = resolve_reference(relative)
        except ComponentPathError as error:
            errors.append(f"关键设计理由路径解析失败：{relative}: {error}")
            continue
        if not path.is_file():
            errors.append(f"关键设计理由路径不存在：{relative}")
            continue
        text = path.read_text()
        missing = [phrase for phrase in phrases if phrase not in text]
        if missing:
            errors.append(f"关键设计理由缺失：{relative} missing={missing}")

    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "swiftFiles": len(files),
        "sourceLines": total_lines,
        "commentLines": total_comments,
        "commentRatio": round(total_comments / max(1, total_lines), 6),
        "documentedProductionFileLines": DOCUMENTED_PRODUCTION_FILE_LINES,
        "largeFileMinimumCommentLines": LARGE_FILE_MINIMUM_COMMENT_LINES,
        "englishOnlyCommentLines": 0 if not any("纯英文注释" in e for e in errors) else None,
        "rationaleObligationCount": sum(len(value) for value in RATIONALE_OBLIGATIONS.values()),
        "errors": errors,
        "files": files,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(
        "Comment quality: "
        f"files={len(files)} comments={total_comments} ratio={report['commentRatio']} "
        f"obligations={report['rationaleObligationCount']}"
    )
    print(f"Artifact: {OUTPUT.relative_to(ROOT)}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
