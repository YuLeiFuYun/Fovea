#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXAMPLE="$ROOT/Examples/FoveaWorkbenchApp"
GENERATED_METADATA="$EXAMPLE/FoveaWorkbench/App/WorkbenchBuildMetadata.generated.swift"
command -v xcodegen >/dev/null 2>&1 || {
  printf '%s\n' 'xcodegen is required to regenerate FoveaWorkbench.xcodeproj' >&2
  exit 2
}

FOVEA_SOURCE_REVISION=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf '%s' unbound)
FOVEA_SOURCE_DIRTY=false
FOVEA_SOURCE_TREE=unbound
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  STATUS=$(git -C "$ROOT" status --porcelain -- . \
    ':(exclude)Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj' \
    ':(exclude)Examples/FoveaWorkbenchApp/FoveaWorkbench/App/WorkbenchBuildMetadata.generated.swift')
  if test -n "$STATUS"; then
    FOVEA_SOURCE_DIRTY=true
  fi

  TEMP_INDEX=$(mktemp "${TMPDIR:-/tmp}/fovea-workbench-index.XXXXXX")
  trap 'rm -f "$TEMP_INDEX"' EXIT HUP INT TERM
  GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT" read-tree HEAD
  GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT" add -A -- .
  GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT" rm -r --cached --ignore-unmatch -- \
    Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj \
    Examples/FoveaWorkbenchApp/FoveaWorkbench/App/WorkbenchBuildMetadata.generated.swift \
    >/dev/null 2>&1 || true
  FOVEA_SOURCE_TREE=$(GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT" write-tree)
  rm -f "$TEMP_INDEX"
  trap - EXIT HUP INT TERM
fi

cat > "$GENERATED_METADATA" <<EOF
// 由 scripts/generate-ios-example.sh 生成，请勿手工编辑。
enum WorkbenchBuildMetadata {
    static let revision = "$FOVEA_SOURCE_REVISION"
    static let sourceTree = "$FOVEA_SOURCE_TREE"
    static let includesWorkingTreeChanges = $FOVEA_SOURCE_DIRTY
}
EOF

xcrun swift-format format \
  --configuration "$ROOT/.swift-format" \
  --in-place "$GENERATED_METADATA"
xcrun swift-format lint \
  --configuration "$ROOT/.swift-format" \
  --strict "$GENERATED_METADATA"

cd "$EXAMPLE"
xcodegen generate --spec project.yml --project .
