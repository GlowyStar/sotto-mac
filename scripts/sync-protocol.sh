#!/usr/bin/env bash
# Copies the schema and the test vectors from a sotto checkout's HEAD into Protocol/
# and rewrites Protocol/MANIFEST: the commit and one "sha256  path" line per file.
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:-../../python/sotto}"
commit="$(git -C "$src" rev-parse HEAD)"
files=(sotto.proto vectors/identity.json vectors/x3dh.json vectors/ratchet.json vectors/blob.json vectors/profile.json)

mkdir -p Protocol/vectors
git -C "$src" show "$commit:proto/sotto.proto" > Protocol/sotto.proto
for name in identity x3dh ratchet blob profile; do
    git -C "$src" show "$commit:vectors/$name.json" > "Protocol/vectors/$name.json"
done

{
    echo "sotto $commit"
    for f in "${files[@]}"; do
        echo "$(shasum -a 256 "Protocol/$f" | cut -d' ' -f1)  $f"
    done
} > Protocol/MANIFEST
cat Protocol/MANIFEST
