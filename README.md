# sotto-mac

A native macOS client for sotto (a separate repository), an end-to-end encrypted one-to-one
messenger with a content-blind relay. It implements the protocol of sotto and has to
interoperate with sotto's command-line client byte for byte.

## Status

- Early. The core holds the key agreement, the ratchet, the client store, the session
  rules and the transport to a relay; the command-line tool `sotto-mac` chats with
  sotto's own command-line client through a sotto relay (`scripts/interop.py` checks it).
  The app `Sotto` runs on the same core: it chats with sotto's command-line client through
  a relay in both directions (`scripts/app-interop.py` checks it with the built app).
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
../../python/sotto/.venv/bin/python scripts/interop.py [--keep DIR]
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

## Run the app against a relay

The app needs a sotto relay. Start the one of the sotto project (a separate repository,
checked out at `../../python/sotto` here), either with Docker or with its console script;
both take the port explicitly, and the app and the clients below dial that port:

```sh
cd ../../python/sotto
RELAY_PORT=8784 RELAY_METRICS_PORT=9784 docker compose up --build -d --wait
# or: RELAY_DATABASE=relay.db RELAY_PORT=8784 uv run sotto-relay
```

Then start the app on its own data directory and that relay:

```sh
scripts/build-app.sh
build/Sotto.app/Contents/MacOS/Sotto --data-dir /tmp/sotto-app --relay ws://127.0.0.1:8784/ws
```

The first launch makes the identity and shows its user id; later launches open the chat
list. The app adds a contact by its user id under a local name (the menu at the top of the
list). Dial the relay as `127.0.0.1`, not `localhost`: the relay of `compose.yaml` refuses a
login signed for another host name.

To talk to the app from sotto's command-line client, give each side the other's id:

```sh
cd ../../python/sotto
uv run sotto --data-dir alice init                      # prints alice's id
uv run sotto --data-dir alice add app <the app's id>
uv run sotto --data-dir alice chat app --relay ws://127.0.0.1:8784/ws
```

The same works with this repository's own tool, which speaks the same protocol:

```sh
swift run sotto-mac --data-dir /tmp/bob init
swift run sotto-mac --data-dir /tmp/bob add app <the app's id>
swift run sotto-mac --data-dir /tmp/bob chat app --relay ws://127.0.0.1:8784/ws
```

An identity can receive once its client has connected one time, because that is when its
prekey bundle reaches the relay: start the app before the first message to it. A message
from someone who is not a contact is dropped.

Launch arguments of the app:

| Argument | What it does |
| --- | --- |
| `--data-dir <dir>` | the directory of the identity (default `~/Library/Application Support/Sotto`, made with mode 0700) |
| `--relay <url>` | the relay (default `ws://127.0.0.1:8765/ws`); an address saved in Settings wins over it |
| `--snapshot <folder>` | draws the window into PNG files and exits; with `--data-dir` from that store, without a connection, otherwise from mock data |
| `--dump` | with `--data-dir`: prints the chats of that store as JSON and exits |
| `--demo` | mock data and no store, with a "Mock" menu; `--first-launch` adds the first-launch screen |
| `--send <name> <text>` | a scripting aid, any number of times: once connected, sends the text to the contact of that local name through the same action as the compose bar |

A text sent to a contact without a session (nobody has written yet) waits in the store
with a clock until a connection fetches the contact's keys, also across a restart. A
message that the relay refuses ends as not sent, with a red mark and the reason on hover.

Next to the store, `app.json` keeps what the store has no place for: the relay address
saved in Settings, how far each chat was read, when each contact and message was
first seen by the app, and every other setting (theme, text size, chat background, send
key, clock, the passcode check, auto-lock, notification and download choices). "Reset
Sotto..." in Settings, Advanced, deletes the store and `app.json` and then the data
directory only if nothing else is left in it.

A local passcode locks the window at launch, after the auto-lock time, on Cmd+L and on
sleep. It only hides the window: the store is not encrypted with it, and it cannot be
recovered.

The end-to-end check of the app (a relay on a free port; the Python client writing to the
app while it runs and while it is closed; the app sending with `--send` to the running
Python client, right after a restart, and while the Python client is away; then a dump and
a snapshot of its store):

```sh
../../python/sotto/.venv/bin/python scripts/app-interop.py [--keep DIR]
```

Both checks keep their data in a temporary directory that they remove at the end;
`--keep DIR` leaves the stores, the relay database and the pictures in DIR.

Limits as they are:

- A plain `ws://` address is dialed only to a loopback host; a relay on another machine
  belongs behind TLS and is dialed as `wss://`.
- The store and `app.json` are not encrypted: whoever can read the data directory holds the
  identity, the keys and the messages.
- One device per identity: when the same identity logs in elsewhere, the relay closes the
  older connection and the app says so instead of reconnecting.
- One-to-one chats, text only. No notifications, no files, no groups. The notification,
  Dock badge, auto-download, download folder and cache settings are saved and shown but
  take effect only with the cards that bring those features.
- No security audit.

## License

Apache-2.0, see [LICENSE](LICENSE).
