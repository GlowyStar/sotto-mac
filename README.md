# sotto-mac

A native macOS client for sotto (a separate repository), an end-to-end encrypted one-to-one
messenger with a content-blind relay. It implements the protocol of sotto and has to
interoperate with sotto's command-line client byte for byte.

## Status

- Early. The repository holds the package layout, the protocol schema and test vectors
  copied from sotto, the generated protobuf code and an empty app window. There is no
  key agreement, no ratchet and no networking yet.
- Not audited. Nobody has reviewed this code for security, so do not trust it with
  anything that matters.

## Build, test, run

Needs macOS 14 or later and Swift 6 (Command Line Tools are enough, Xcode is not needed).

```sh
swift build                 # all targets
scripts/test.sh             # the tests (Swift Testing)
scripts/build-app.sh        # build/Sotto.app, signed ad hoc
open build/Sotto.app
swift run sotto-mac         # the command-line tool
```

The protocol files in `Protocol/` come from a sotto checkout and are pinned by
`Protocol/MANIFEST`:

```sh
scripts/sync-protocol.sh [path to a sotto checkout]   # copy them again
scripts/generate-proto.sh                             # regenerate Sources/SottoCore/Proto
scripts/generate-proto.sh --check                     # fail if the generated code is stale
```

`generate-proto.sh` uses `protoc` from the sotto checkout's Python environment
(`grpc_tools`) and builds `protoc-gen-swift` from this package's own swift-protobuf
dependency.

## License

Apache-2.0, see [LICENSE](LICENSE).
