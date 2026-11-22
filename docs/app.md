# The app in detail

How the app `Sotto` behaves, screen by screen, and what it does not do yet. The short version, with
the build steps, is the [README](../README.md); where the keys live is [key storage](key-storage.md).

- [Launch arguments](#launch-arguments)
- [Sending and refusals](#sending-and-refusals)
- [What the store keeps](#what-the-store-keeps)
- [Notifications and search](#notifications-and-search)
- [Photos and files](#photos-and-files)
- [The profile](#the-profile)
- [Replies, edits and receipts](#replies-edits-and-receipts)
- [The safety number](#the-safety-number)
- [Locking](#locking)
- [Limits](#limits)

## Launch arguments

| Argument | What it does |
| :--- | :--- |
| `--data-dir <dir>` | the directory of the identity (default `~/Library/Application Support/Sotto`, made with mode 0700) |
| `--relay <url>` | the relay (default `ws://127.0.0.1:8765/ws`); an address saved in Settings wins over it |
| `--snapshot <folder>` | draws the window into PNG files and exits; with `--data-dir` from that store, without a connection, otherwise from mock data; `--only <prefix>` draws only the shots whose name starts with it |
| `--dump` | with `--data-dir`: prints the chats of that store as JSON and exits |
| `--safety-number <name>` | with `--data-dir`: prints the safety number with the contact of that local name in the rows of the contact panel, then the text of its QR code, and exits |
| `--store-info` | with `--data-dir`: prints the SQLCipher version, its crypto provider and the file of the library that serves the store, and exits |
| `--demo` | mock data and no store, with a "Mock" menu; `--first-launch` adds the first-launch screen |
| `--send <name> <text>` | a scripting aid, any number of times: once connected, sends the text to the contact of that local name through the same action as the compose bar |
| `--send-file <name> <path>` | the same for a file, through the action of the send box; a picture goes as a photo |
| `--profile <name> <path>` | a scripting aid: once connected, sets the own profile through the action of "Save" on the Edit profile page, the picture cut to its centered square; an empty path is no picture |
| `--read <name>` | a scripting aid: the chat of that contact counts as open on the screen for the whole run, so its messages are seen as they arrive (their read receipts and timers start) |
| `--reply <name> <text>`, `--edit <name> <text>`, `--delete <name>`, `--timer <name> <seconds>`, `--reset <name>` | scripting aids: once connected, a reply to the newest message of the contact, an edit of the newest own message that can still be edited, a delete for both of the newest own message, the timer of the chat, and a new session with the contact, each through the action of the screen |

The flags that print, draw or act on the chats serve the check scripts and answer for a store of
the test kind only, the kind that `SOTTO_STORE_PROTECTION=test` makes: `--dump`, `--snapshot` and
`--safety-number` with `--data-dir`, and `--send`, `--send-file`, `--profile`, `--read`,
`--reply`, `--edit`, `--delete`, `--timer` and `--reset`. Any other store, the owner's included,
is refused before it is unlocked, with no sheet ("--dump: only a store of the test kind answers
this"). `--store-info` works on any store, and `--demo` or `--snapshot` without `--data-dir` draw
mock data.

## Sending and refusals

A text sent to a contact without a session (nobody has written yet) waits in the store with a
clock until a connection fetches the contact's keys, also across a restart. A message that the
relay refuses ends as not sent, with a red mark and the reason on hover.

## What the store keeps

The encrypted store also keeps the app's own notes: the relay address saved in Settings, how far
each chat was read, when each contact and message was first seen by the app, the draft of each
chat, the pinned, muted and archived chats, and every setting (theme, text size, chat background,
send key, clock, the passcode check, auto-lock, notification and download choices). Next to the
store, `app.json` keeps only the theme, which the lock screen shows before the store opens. The
first launch of this version moves an older `app.json` into the store and leaves it with the theme
only. [Key storage](key-storage.md) lists every place the app writes anything outside the store.
"Reset Sotto..." in Settings, Advanced, deletes the store, its wrapped key and `app.json` and then
the data directory only if nothing else is left in it.

## Notifications and search

A new message posts a macOS notification (not for the chat open in the front window, not for a
muted chat) and the Dock icon shows the number of unread messages. By default a notification says
only "New message" from "Sotto": the name of the contact and the text come back with "Show sender
name" and "Show message preview" in Settings, Notifications, and stay out while the passcode lock
is shown, unless that is turned off. Notifications need the bundled app: under `swift run` none are
posted. Search finds chats by name and messages by text, across chats from the list and inside the
open chat (Cmd+F); the emoji button opens the macOS character palette. All of this stays on the
Mac: nothing new is sent to the relay.

## Photos and files

The paperclip of the compose bar (or Cmd+Shift+A) offers Photo or File, files can be dropped on
the chat, and a picture or files can be pasted into the compose field; a send box shows them with
a caption field before they go, each as its own message. A picture goes as a photo with its size
and a small JPEG preview made on the Mac, unless "Send as file" is checked, which sends it with an
empty media type so that it shows as a file.

A transfer shows a ring with its progress: a click on the ring cancels a sending (the message is
deleted, which ends its upload) or pauses a download (the bytes stay). A received photo or file
within the auto-download size of Settings, Data and storage, downloads by itself and a larger one
waits for a click; either way it is kept inside the encrypted store, and "Save as..." writes a
readable copy where the user says. With "Save received files automatically" (off by default) each
received file is written into the download folder of the settings (Downloads by default) instead,
as earlier versions did; files they saved there stay where they are. Transfers go on after a
reconnect and after a restart without a click. A file that was not sent is sent again from the
file it was read from with a click on its circle: a new upload, as the protocol says.

A photo opens in a viewer (zoom, the other photos of the chat with the arrow keys, "Save as..."),
decoded in memory; a file opens with the system only on a click, from a copy in the folder
`temp.noindex` of the data directory (Spotlight skips it) that is overwritten and removed at
launch, on lock and on quit. Every received file written to disk is marked as downloaded
(quarantine), so macOS asks before it runs anything a contact sent. A picture pasted into the field
stays in memory until it is sent; then the store keeps it with its message, so that the photo can
be shown and sent again.

## The profile

Settings shows the own photo, name and short id at the top; a click on the photo opens the file
panel and then the crop box, a click on the name the Edit profile page (photo, display name, the id
and its QR code drawn with Core Image). "Save" keeps the profile in the store and sends it to every
contact with a session: the name at once, the photo as a 512 x 512 JPEG uploaded to each contact as
its own blob, with a 128 x 128 JPEG thumbnail inside the message. A contact without a session gets
it with its first session, and both sides send theirs again after a reset.

The profile a contact sends is kept, its photo downloaded by itself into the store (no file is
written), and shown in the chat list, the chat header and the contact panel; the local name stays
the name of the contact everywhere, and the contact panel shows the name the contact set under it.
A profile is never a message: no row, no unread count, no notification, and an archived chat stays
archived. A lost photo comes back only with the contact's next change or the next new session.

## Replies, edits and receipts

A right click on a message offers Reply, Edit (an own message, up to ten times within a day of
sending; also the Up arrow in an empty field) and Delete, whose box asks whether to delete an own
message for the contact too. A reply shows the quoted message in its bubble, and a click on the
quote scrolls to it.

An own message shows a clock while it waits, one check once the relay stored it, two checks once
the contact's app has it and two in the full colour once the contact has seen it; a message counts
as seen when it is on the screen in the open chat of the front window. Read receipts can be turned
off in Settings, Privacy and security; the contact then sees "delivered" only.

Disappearing messages are set per chat from the chat header's menu or the contact panel (off, 30
seconds up to 4 weeks): an own message goes that long after it was sent, one of the contact that
long after it was seen, with its file, also after a restart; the header and each such message show
the timer, and a change of the timer shows as a line in the chat.

## The safety number

The contact panel shows the 60 digits of the safety number with the contact under its id, and
"Verify safety number" opens a box with the digits, their QR code and "Mark as verified" or "Clear
verification". A verified contact has a small mark after its name in the chat header and the panel.
The mark is the user's own note: the contact does not learn it, and nothing but the user and a
deleted contact clears it, since the protocol never takes another key for a contact.

When the identity of a contact signs a second encryption key, which only someone with its secret
key can do, Sotto refuses it (`IDENTITY_KEY_MISMATCH`) and the chat shows a red warning under the
header that says what it means and what to do, until it is closed; the safety number stays the
same, and so does the mark.

## Locking

The app starts locked and opens the store after the system sheet of Touch ID or the Mac password.
After the auto-lock time (5 minutes by default), on Cmd+L, on sleep, when the screen of the Mac
locks or it switches to another user (these three unless turned off) and on quit it overwrites the
store key in memory and closes the store, also on the first-launch screen; the next unlock asks
again. On sleep the Mac waits until the store is closed (30 seconds at most).

A text or a picture copied from a chat is marked for clipboard managers as concealed and
transient, and a lock clears the pasteboard while it still holds it. A local passcode, when set, is
asked after that: it only covers the window, nothing is encrypted with it, and it cannot be
recovered. While the store is locked the app has no connection.

## Limits

- A plain `ws://` address is dialed only to a loopback host; a relay on another machine belongs
  behind TLS and is dialed as `wss://`.
- The private keys of the post-quantum prekeys, the 64-byte ML-KEM seeds, live in the encrypted
  store with the other private keys ([key storage](key-storage.md)); the last-resort one goes with
  its signed prekey, a one-time one when the session it started is accepted.
- What leaves the store is readable: a copy made with "Save as..." or "Save received files
  automatically", a file opened in another app until its message goes or the store locks, what
  "Copy" puts on the pasteboard until a lock, and, with the name or the preview turned on, what
  macOS keeps of each notification in its own notification database. A store, an `app.json` or
  pasted pictures of a previous version are encrypted or moved on the first launch and their plain
  files overwritten, but older Time Machine snapshots and backups keep them
  ([key storage](key-storage.md)).
- The presence check stops someone at the keyboard who does not know the Mac password, and any copy
  of the store taken to another Mac or read offline. It does not stop code that runs as the user:
  such code can ask for the same sheet in Sotto's name, and an approval given as usual opens the
  chats to it; it can wait for the next normal unlock; and while Sotto is unlocked it reads what the
  window shows. Whoever knows the Mac password gets the chats, and a Time Machine backup or a local
  snapshot of the data folder opens on this Mac with it, also one from before a Reset
  ([key storage](key-storage.md)).
- One device per identity: when the same identity logs in elsewhere, the relay closes the older
  connection and the app says so instead of reconnecting.
- One-to-one chats with texts, photos and files. No groups, no albums, no reactions or forwards.
  Nothing proves that the contact's app deleted a message. The command-line tool prints a profile
  that arrives but cannot set its own. "Ask where to save each file" and the storage figures and
  "Clear cache" of Data and storage are shown but do nothing yet. A new auto-download size or
  download folder holds for the files that arrive after the change.
- A chat is muted until it is unmuted: there are no timed mutes. Pinned chats keep the order in
  which they were pinned; they are not reordered by dragging.
- The Mac does not scan a QR code: safety numbers are compared by reading them.
- No security audit.
