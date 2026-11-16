#!/usr/bin/env bash
# Runs the Swift Testing tests under Command Line Tools: without Xcode, swift test finds
# neither Testing.framework nor lib_TestingInterop.dylib by itself.
set -euo pipefail
cd "$(dirname "$0")/.."

dev="$(xcode-select -p)/Library/Developer"
fw="$dev/Frameworks"
lib="$dev/usr/lib"
swift test \
    -Xswiftc -F -Xswiftc "$fw" \
    -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$lib" \
    "$@"
