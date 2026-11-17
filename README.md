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
- Files (part 3 of the protocol) are in the core and the command-line tool: a file of up to
  100 MiB goes to a contact encrypted with the blob cipher, uploaded and downloaded in
  pieces that resume after a cut connection or a restart; `scripts/interop.py` sends files
  both ways with sotto's client, two of them cut in the middle. The app sends and shows
  photos and files (`scripts/app-interop.py` checks both ways, also cut in the middle).
- The profile (part 4 of the protocol): a display name and an avatar sent, encrypted, to
  every contact with a session, and the latest profile of each contact kept and shown; the
  app and sotto's command-line client exchange them both ways (`scripts/app-interop.py`).
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
sotto-mac send-file bob photo.jpg --caption "hi"   # waits until it is sent or not sent
```

Received files are saved into the folder `received` of the data directory, under the name
the sender gave when it is a plain file name, never over a file that is there; a file whose
sending stopped goes on at the next `chat` or `send-file`.

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
| `--send-file <name> <path>` | the same for a file, through the action of the send box; a picture goes as a photo |
| `--profile <name> <path>` | a scripting aid: once connected, sets the own profile through the action of "Save" on the Edit profile page, the picture cut to its centered square; an empty path is no picture |

A text sent to a contact without a session (nobody has written yet) waits in the store
with a clock until a connection fetches the contact's keys, also across a restart. A
message that the relay refuses ends as not sent, with a red mark and the reason on hover.

Next to the store, `app.json` keeps what the store has no place for: the relay address
saved in Settings, how far each chat was read, when each contact and message was
first seen by the app, the draft of each chat, the pinned, muted and archived chats, and
every other setting (theme, text size, chat background, send key, clock, the passcode
check, auto-lock, notification and download choices). "Reset
Sotto..." in Settings, Advanced, deletes the store and `app.json` and then the data
directory only if nothing else is left in it.

A new message posts a macOS notification (not for the chat open in the front window, not
for a muted chat; without its text while the passcode lock is shown, unless that is turned
off) and the Dock icon shows the number of unread messages. Notifications need the bundled
app: under `swift run` none are posted. Search finds chats by name and messages by text,
across chats from the list and inside the open chat (Cmd+F); the emoji button opens the
macOS character palette. All of this stays on the Mac: nothing new is sent to the relay.

Photos and files: the paperclip of the compose bar (or Cmd+Shift+A) offers Photo or File,
files can be dropped on the chat, and a picture or files can be pasted into the compose
field; a send box shows them with a caption field before they go, each as its own message.
A picture goes as a photo with its size and a small JPEG preview made on the Mac, unless
"Send as file" is checked, which sends it with an empty media type so that it shows as a
file. A transfer shows a ring with its progress: a click on the ring cancels a sending
(the message is deleted, which ends its upload) or pauses a download (the bytes stay). A
received photo or file within the auto-download size of Settings, Data and storage, is
saved into the download folder of the settings (Downloads by default) by itself; a larger
one waits for a click. Transfers go on after a reconnect and after a restart without a
click. A file that was not sent is sent again from the file it was read from with a
click on its circle: a new upload, as the protocol says. A photo opens in a viewer (zoom,
the other photos of the chat with the arrow keys, "Save as..."); a file opens with the
system only on a click, and every received file is marked as downloaded (quarantine), so
macOS asks before it runs anything a contact sent. A picture pasted into the field is kept as a PNG in the folder
`Pasted` of the data directory, so that the photo can be shown and sent again.

The profile: Settings shows the own photo, name and short id at the top; a click on the
photo opens the file panel and then the crop box, a click on the name the Edit profile page
(photo, display name, the id and its QR code drawn with Core Image). "Save" keeps the profile
in the store and sends it to every contact with a session: the name at once, the photo as a
512 x 512 JPEG uploaded to each contact as its own blob, with a 128 x 128 JPEG thumbnail
inside the message. A contact without a session gets it with its first session, and both
sides send theirs again after a reset. The profile a contact sends is kept, its photo
downloaded by itself into the store (no file is written), and shown in the chat list, the
chat header and the contact panel; the local name stays the name of the contact everywhere,
and the contact panel shows the name the contact set under it. A profile is never a message:
no row, no unread count, no notification, and an archived chat stays archived. A lost photo
comes back only with the contact's next change or the next new session.

A local passcode locks the window at launch, after the auto-lock time, on Cmd+L and on
sleep. It only hides the window: the store is not encrypted with it, and it cannot be
recovered.

The end-to-end check of the app (a relay on a free port; the Python client writing to the
app while it runs and while it is closed; the app sending with `--send` to the running
Python client, right after a restart, and while the Python client is away; a photo and a
file each way, compared byte for byte; a large upload and a large download of the app, each
cut by killing the app in the middle and ended whole after its next start; then a dump and
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
  identity, the keys and the messages. With message previews on, macOS also keeps the text
  of each notification in its own notification database, outside the data directory.
- One device per identity: when the same identity logs in elsewhere, the relay closes the
  older connection and the app says so instead of reconnecting.
- One-to-one chats with texts, photos and files. No groups, no albums. The command-line
  tool prints a profile that arrives but cannot set its own. "Ask where to save
  each file" and the storage figures and "Clear cache" of Data and storage are shown but do
  nothing yet. A new auto-download size or download folder holds for the files that arrive
  after the change.
- A chat is muted until it is unmuted: there are no timed mutes. Pinned chats keep the
  order in which they were pinned; they are not reordered by dragging.
- No security audit.

## License

Apache-2.0, see [LICENSE](LICENSE).
