#!/bin/zsh
# Runs the unit tests (Tests/DebriefTests) and the recorder self-test.
# Command Line Tools ship the Swift Testing macro plugin but not on the default search path,
# so `swift test` alone fails with "plugin for module 'TestingMacros' not found".
set -euo pipefail
cd "${0:A:h}/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
EXTRA=()
[[ -d "$PLUGINS" ]] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
swift test "${EXTRA[@]}" "$@" 2>&1 | grep -v "ld: warning: search path"
swift run RecorderSelfTest 2>&1 | grep -v "ld: warning: search path" | tail -5
