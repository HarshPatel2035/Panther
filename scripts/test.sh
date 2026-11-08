#!/bin/bash
# Runs the test suite. The Command Line Tools ship the Swift Testing macro plugin in a folder
# swift test doesn't search by default, so point the compiler at it (no-op with full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
EXTRA=()
[ -d "$PLUGINS" ] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
exec swift test "${EXTRA[@]}" "$@"
