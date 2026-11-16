#!/usr/bin/env bash
# Writes Sources/SottoCore/Proto/sotto.pb.swift from Protocol/sotto.proto.
# --check regenerates into a temporary folder and fails when the tracked file differs.
# protoc is the one of the sotto checkout's venv (grpc_tools); protoc-gen-swift is built
# from this package's own swift-protobuf checkout, so its version follows Package.resolved.
set -euo pipefail
cd "$(dirname "$0")/.."

python="${SOTTO_PYTHON:-$(cd ../../python/sotto && pwd)/.venv/bin/python}"
swift build -c release --product protoc-gen-swift >/dev/null
plugin="$(swift build -c release --show-bin-path)/protoc-gen-swift"

out="Sources/SottoCore/Proto"
if [[ "${1:-}" == "--check" ]]; then
    out="$(mktemp -d)"
    trap 'rm -rf "$out"' EXIT
fi
mkdir -p "$out"
"$python" -m grpc_tools.protoc -IProtocol --plugin="protoc-gen-swift=$plugin" \
    --swift_opt=Visibility=Public --swift_out="$out" Protocol/sotto.proto

if [[ "${1:-}" == "--check" ]]; then
    diff -u Sources/SottoCore/Proto/sotto.pb.swift "$out/sotto.pb.swift"
    echo "sotto.pb.swift is up to date"
fi
