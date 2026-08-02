#!/bin/zsh
set -eu

ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

printf '%s\n' 'Restarting system simdiskimaged with administrator privileges...'
sudo launchctl kickstart -k system/com.apple.CoreSimulator.simdiskimaged

printf '%s\n' 'Restarting the user CoreSimulator service...'
killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
sleep 5

printf '%s\n' 'Checking simctl control-plane responsiveness...'
xcrun simctl list devices available >/dev/null

printf '%s\n' 'Checking for uninterruptible CoreSimulator processes...'
python3 "$ROOT/scripts/check-comparative-coresimulator-health.py"

printf '%s\n' 'CoreSimulator recovery passed.'
