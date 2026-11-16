#!/usr/bin/env bash
# Builds build/Sotto.app: the release binary, Info.plist and an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Sotto
app="build/Sotto.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Replaced by a rename: overwriting the binary in place kills an open copy of the app.
cp "$(swift build -c release --show-bin-path)/Sotto" "$app/Contents/MacOS/Sotto.new"
mv -f "$app/Contents/MacOS/Sotto.new" "$app/Contents/MacOS/Sotto"
cp -f Info.plist "$app/Contents/Info.plist"
# The requirement names the bundle, not the hash of this build, so macOS grants keyed to
# it survive a rebuild.
codesign --force --sign - -r='designated => identifier "com.glowystar.sotto"' "$app"
echo "$PWD/$app"
