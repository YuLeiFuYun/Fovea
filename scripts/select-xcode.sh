#!/bin/sh
set -eu

if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    printf '%s\n' "$DEVELOPER_DIR"
    exit 0
fi

for candidate in \
    /Applications/Xcode-beta.app/Contents/Developer \
    /Applications/Xcode.app/Contents/Developer
do
    if [ -x "$candidate/usr/bin/xcodebuild" ]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

latest=$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' -print 2>/dev/null | sort | tail -n 1)
if [ -n "$latest" ] && [ -x "$latest/Contents/Developer/usr/bin/xcodebuild" ]; then
    printf '%s\n' "$latest/Contents/Developer"
    exit 0
fi

printf '%s\n' 'No complete Xcode installation found.' >&2
exit 1
