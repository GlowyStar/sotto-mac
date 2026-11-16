# sotto-mac

A native macOS client for sotto (a separate repository), an end-to-end encrypted one-to-one
messenger with a content-blind relay. It implements the protocol of sotto and has to
interoperate with sotto's command-line client byte for byte.

## Status

- Early. The core holds the key agreement, the ratchet, the client store, the session
  rules and the transport to a relay; the command-line tool `sotto-mac` chats with
  sotto's own command-line client through a sotto relay (`scripts/interop.py` checks it).
  The app window still shows mock data.
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

The command-line tool has the commands of sotto's `sotto`; its identity lives in
`~/.sotto-mac` unless `--data-dir` names another directory:

```sh
sotto-mac init                      # make an identity, print its user id
sotto-mac add bob <user id>         # add a contact under a local name
sotto-mac contacts
sotto-mac chat bob --relay ws://127.0.0.1:8765/ws   # /quit or end of input ends
sotto-mac reset bob                 # start a new session with bob
```

A `ws://` URL is dialed only to a loopback host unless `--insecure` is given. Part of the
tests starts the relay of a sotto checkout at `../../python/sotto` (they are skipped when
it is missing), and so does the interoperability check:

```sh
../../python/sotto/.venv/bin/python scripts/interop.py
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
