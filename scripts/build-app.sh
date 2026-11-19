#!/usr/bin/env bash
# Builds build/Sotto.app: the release binary, SQLCipher.framework, Info.plist and an
# ad-hoc signature with the hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Sotto
bin="$(swift build -c release --show-bin-path)"
app="build/Sotto.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
# The framework keeps the Developer ID signature of Zetetic.
rm -rf "$app/Contents/Frameworks/SQLCipher.framework"
cp -R "$bin/SQLCipher.framework" "$app/Contents/Frameworks/"
cp -f .build/checkouts/SQLCipher.swift/LICENSE.md "$app/Contents/Resources/SQLCipher-LICENSE.md"
# Replaced by a rename: overwriting the binary in place kills an open copy of the app.
cp "$bin/Sotto" "$app/Contents/MacOS/Sotto.new"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Sotto.new" 2>/dev/null
mv -f "$app/Contents/MacOS/Sotto.new" "$app/Contents/MacOS/Sotto"
cp -f Info.plist "$app/Contents/Info.plist"
# The requirement names the bundle, not the hash of this build, so macOS grants keyed to
# it survive a rebuild. Under the hardened runtime dyld ignores DYLD_* variables; its one
# entitlement lets the process load SQLCipher.framework, which Zetetic signed as another
# team than this ad-hoc signature.
codesign --force --sign - --options runtime --entitlements Sotto.entitlements \
    -r='designated => identifier "com.glowystar.sotto"' "$app"
echo "$PWD/$app"
