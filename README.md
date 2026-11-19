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
- New sessions are agreed by PQXDH (part 6 of the protocol): X25519 with ML-KEM-768 of
  CryptoKit, end-to-end version 2. The core replays every vector of sotto's
  `vectors/pqxdh.json`; ML-KEM encapsulation is randomized and CryptoKit takes no fixed
  randomness, so the vectors of the initiator are replayed with the recorded ciphertext and
  secret, and the own encapsulation is checked by a round trip. Sessions made by X3DH
  before keep working with version 1; no new one is made either way: a bundle without a
  post-quantum prekey ends in `PQ_PREKEY_MISSING`, a new session of version 1 in
  `X3DH_REFUSED`. Both interop scripts make a PQXDH session in each direction. The ratchet
  is the classical Double Ratchet, so the post-quantum part protects the key agreement only,
  and the Ed25519 signatures over the prekeys are classical too.
- Files (part 3 of the protocol) are in the core and the command-line tool: a file of up to
  100 MiB goes to a contact encrypted with the blob cipher, uploaded and downloaded in
  pieces that resume after a cut connection or a restart; `scripts/interop.py` sends files
  both ways with sotto's client, two of them cut in the middle. The app sends and shows
  photos and files (`scripts/app-interop.py` checks both ways, also cut in the middle).
- The profile (part 4 of the protocol): a display name and an avatar sent, encrypted, to
  every contact with a session, and the latest profile of each contact kept and shown; the
  app and sotto's command-line client exchange them both ways (`scripts/app-interop.py`).
- Replies, edits, delete for both, delivery and read receipts and disappearing messages
  (part 5 of the protocol) are in the core, the command-line tool and the app; both
  `scripts/interop.py` and `scripts/app-interop.py` exercise each of them both ways with
  sotto's client. Delete for both and the timer are requests that the other side's client
  honours; nothing can make it do so, and nothing protects a message from the person who
  received it.
- The store is encrypted at rest: SQLCipher over the whole `store.db`, its random 256-bit
  key wrapped to a Secure Enclave key of this Mac that asks for Touch ID or the Mac
  password; the app and `sotto-mac` open it only after that, and every lock drops the key
  (`docs/key-storage.md`). Drafts, settings, pasted pictures and received files are kept
  inside it too, and notifications name nobody and quote nothing by default. The tests
  check that no text of the store is readable in its files, that after a run no file of
  the data folder holds a text, a pasted picture or a received file of it, and that a copy
  of the folder does not open without its Secure Enclave key.
- Not audited. Nobody has reviewed this code for security, so do not trust it with
  anything that matters.

## Build, test, run

Needs macOS 26 or later (ML-KEM-768 of CryptoKit) on a Mac with a Secure Enclave (Apple silicon or a T2 chip) and
Swift 6 (Command Line Tools are enough, Xcode is not needed). SwiftPM fetches
SQLCipher 4.20.0, Zetetic's official Swift package, a binary framework that
`scripts/build-app.sh` copies into the app.

```sh
swift build                 # all targets
scripts/test.sh             # the tests (Swift Testing)
scripts/build-app.sh        # build/Sotto.app, signed ad hoc
open build/Sotto.app
swift run sotto-mac         # the command-line tool
```

The command-line tool has the commands of sotto's `sotto`; its identity lives in
`~/.sotto-mac` unless `--data-dir` names another directory, in the same encrypted store as
the app's, and each command asks for Touch ID or the Mac password once:

```sh
sotto-mac init                      # make an identity, print its user id
sotto-mac add bob <user id>         # add a contact under a local name
sotto-mac contacts
sotto-mac chat bob --relay ws://127.0.0.1:8765/ws   # /quit or end of input ends
sotto-mac reset bob                 # start a new session with bob
sotto-mac send-file bob photo.jpg --caption "hi"   # waits until it is sent or not sent
sotto-mac read-receipts [on|off]    # show or set the read receipts contacts get
```

`chat` prints every message with its number in the log (`#12 bob: hi`), the marks of the
own ones (`#12 sent`, `#12 delivered`, `#12 read`) and one line when the contact edits or
deletes a message or changes the timer; a printed message counts as read. It takes the
commands of sotto's `chat`: `/reply N text`, `/edit N text`, `/delete N` (for both sides)
and `/timer [off|30s|5m|1h|1d|1w]`.

Received files are saved, readable, into the folder `received` of the data directory (a
console has no viewer: the file is its output; the app keeps them inside its store), under
the name the sender gave when it is a plain file name, never over a file that is there; a
file whose sending stopped goes on at the next `chat` or `send-file`.

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

Then start the app on its own data directory and that relay (a store of another data
directory asks for Touch ID or the Mac password as well; only `SOTTO_STORE_PROTECTION=test`
in the environment, which the tests and the check scripts set, makes one that asks
nothing, and the default folders refuse it):

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
| `--snapshot <folder>` | draws the window into PNG files and exits; with `--data-dir` from that store, without a connection, otherwise from mock data; `--only <prefix>` draws only the shots whose name starts with it |
| `--dump` | with `--data-dir`: prints the chats of that store as JSON and exits |
| `--store-info` | with `--data-dir`: prints the SQLCipher version, its crypto provider and the file of the library that serves the store, and exits |
| `--demo` | mock data and no store, with a "Mock" menu; `--first-launch` adds the first-launch screen |
| `--send <name> <text>` | a scripting aid, any number of times: once connected, sends the text to the contact of that local name through the same action as the compose bar |
| `--send-file <name> <path>` | the same for a file, through the action of the send box; a picture goes as a photo |
| `--profile <name> <path>` | a scripting aid: once connected, sets the own profile through the action of "Save" on the Edit profile page, the picture cut to its centered square; an empty path is no picture |
| `--read <name>` | a scripting aid: the chat of that contact counts as open on the screen for the whole run, so its messages are seen as they arrive (their read receipts and timers start) |
| `--reply <name> <text>`, `--edit <name> <text>`, `--delete <name>`, `--timer <name> <seconds>` | scripting aids: once connected, a reply to the newest message of the contact, an edit of the newest own message that can still be edited, a delete for both of the newest own message, and the timer of the chat, each through the action of the screen |

A text sent to a contact without a session (nobody has written yet) waits in the store
with a clock until a connection fetches the contact's keys, also across a restart. A
message that the relay refuses ends as not sent, with a red mark and the reason on hover.

The encrypted store also keeps the app's own notes: the relay address saved in Settings,
how far each chat was read, when each contact and message was first seen by the app, the
draft of each chat, the pinned, muted and archived chats, and every setting (theme, text
size, chat background, send key, clock, the passcode check, auto-lock, notification and
download choices). Next to the store, `app.json` keeps only the theme, which the lock
screen shows before the store opens. The first launch of this version moves an older
`app.json` into the store and leaves it with the theme only. `docs/key-storage.md` lists
every place the app writes anything outside the store. "Reset Sotto..." in Settings,
Advanced, deletes the store, its wrapped key and `app.json` and then the data directory
only if nothing else is left in it.

A new message posts a macOS notification (not for the chat open in the front window, not
for a muted chat) and the Dock icon shows the number of unread messages. By default a
notification says only "New message" from "Sotto": the name of the contact and the text
come back with "Show sender name" and "Show message preview" in Settings, Notifications,
and stay out while the passcode lock is shown, unless that is turned off. Notifications need the bundled
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
received photo or file within the auto-download size of Settings, Data and storage,
downloads by itself and a larger one waits for a click; either way it is kept inside the
encrypted store, and "Save as..." writes a readable copy where the user says. With "Save
received files automatically" (off by default) each received file is written into the
download folder of the settings (Downloads by default) instead, as earlier versions did;
files they saved there stay where they are. Transfers go on after a reconnect and after a restart without a
click. A file that was not sent is sent again from the file it was read from with a
click on its circle: a new upload, as the protocol says. A photo opens in a viewer (zoom,
the other photos of the chat with the arrow keys, "Save as..."), decoded in memory; a file
opens with the system only on a click, from a copy in the folder `temp.noindex` of the data
directory (Spotlight skips it) that is overwritten and removed at launch, on lock and on
quit. Every received
file written to disk is marked as downloaded (quarantine), so macOS asks before it runs
anything a contact sent. A picture pasted into the field stays in memory until it is sent;
then the store keeps it with its message, so that the photo can be shown and sent again.

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

Replies, edits and receipts: a right click on a message offers Reply, Edit (an own message,
up to ten times within a day of sending; also the Up arrow in an empty field) and Delete,
whose box asks whether to delete an own message for the contact too. A reply shows the
quoted message in its bubble, and a click on the quote scrolls to it. An own message shows
a clock while it waits, one check once the relay stored it, two checks once the contact's
app has it and two in the full colour once the contact has seen it; a message counts as
seen when it is on the screen in the open chat of the front window. Read receipts can be
turned off in Settings, Privacy and security; the contact then sees "delivered" only.
Disappearing messages are set per chat from the chat header's menu or the contact panel
(off, 30 seconds up to 4 weeks): an own message goes that long after it was sent, one of the
contact that long after it was seen, with its file, also after a restart; the header and
each such message show the timer, and a change of the timer shows as a line in the chat.

The app starts locked and opens the store after the system sheet of Touch ID or the Mac
password. After the auto-lock time, on Cmd+L, on sleep (unless turned off) and on quit it
closes the store and overwrites its key in memory; the next unlock asks again. A local
passcode, when set, is asked after that: it only covers the window, nothing is encrypted
with it, and it cannot be recovered. While the store is locked the app has no connection.

The end-to-end check of the app (a relay on a free port; the Python client writing to the
app while it runs and while it is closed; the app sending with `--send` to the running
Python client, right after a restart, and while the Python client is away; a photo and a
file each way, compared byte for byte, the received ones as the store keeps them; a large
upload and a large download of the app, each cut by killing the app in the middle and
ended whole after its next start; the profiles both ways; a reply, an edit, a delete for
both, the read marks and a message under a short timer each way; then a check that no file
of the app's data folder holds a text or a file of the run in the clear, a dump and a
snapshot of its store):

```sh
../../python/sotto/.venv/bin/python scripts/app-interop.py [--keep DIR]
```

Both checks keep their data in a temporary directory that they remove at the end;
`--keep DIR` leaves the stores, the relay database and the pictures in DIR.

Limits as they are:

- A plain `ws://` address is dialed only to a loopback host; a relay on another machine
  belongs behind TLS and is dialed as `wss://`.
- The private keys of the post-quantum prekeys, the 64-byte ML-KEM seeds, live in the
  encrypted store with the other private keys (`docs/key-storage.md`); the last-resort one
  goes with its signed prekey, a one-time one when the session it started is accepted.
- What leaves the store is readable: a copy made with "Save as..." or "Save received
  files automatically", a file opened in another app while the store is open, what
  "Copy" puts on the pasteboard, and, with the name or the preview turned on, what macOS
  keeps of each notification in its own notification database. A store, an `app.json` or
  pasted pictures of a previous version are encrypted or moved on the first launch and
  their plain files overwritten, but older Time Machine snapshots and backups keep them
  (`docs/key-storage.md`).
- Whoever knows the Mac password, or has malware running as the user while the store is
  open, gets the chats.
- One device per identity: when the same identity logs in elsewhere, the relay closes the
  older connection and the app says so instead of reconnecting.
- One-to-one chats with texts, photos and files. No groups, no albums, no reactions or
  forwards. Nothing proves that the contact's app deleted a message. The command-line
  tool prints a profile that arrives but cannot set its own. "Ask where to save
  each file" and the storage figures and "Clear cache" of Data and storage are shown but do
  nothing yet. A new auto-download size or download folder holds for the files that arrive
  after the change.
- A chat is muted until it is unmuted: there are no timed mutes. Pinned chats keep the
  order in which they were pinned; they are not reordered by dragging.
- No security audit.

## License

Apache-2.0, see [LICENSE](LICENSE). The app carries SQLCipher, under Zetetic's BSD-style
Community Edition licence, which `scripts/build-app.sh` copies into the bundle as
`Contents/Resources/SQLCipher-LICENSE.md`.
