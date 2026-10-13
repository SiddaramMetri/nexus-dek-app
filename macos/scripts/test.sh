#!/bin/bash
# Run the KavachCore test suite.
# Uses the native build system with explicit Swift Testing paths: under the
# Command Line Tools (no full Xcode) the default build system can't find the
# Testing macro plugin once a package has dependencies or per-target settings.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
[ -d "$FW" ] || FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
exec swift test --build-system native \
  -Xswiftc -I"$FW" -Xswiftc -F"$FW" \
  -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
  -Xlinker -rpath -Xlinker "$FW" "$@"
