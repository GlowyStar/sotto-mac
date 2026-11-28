# Key storage

## Decision (2026-11-19)

The whole store, `store.db` and its rollback journal, is encrypted with SQLCipher under a
random 256-bit key; that key is kept on disk only wrapped to a Secure Enclave key of this
Mac, whose use needs the user's presence (Touch ID or the Mac password; Apple's
documentation of the policy names a paired Apple Watch too, which was not tried here).
Nothing about the store is in the keychain. The directory keeps mode 0700 and the files 0600.

Since SOTTO-45 it holds the private keys of PQXDH too (below, "Post-quantum prekeys").
Since SOTTO-43 the store also holds what the app kept beside it: its notes (drafts, read
positions, pins, settings), pasted pictures and received files. What still leaves it, and
why, is listed in "What is written outside the store".

| Part | What it is |
| --- | --- |
| Pages | SQLCipher 4.20.0 community edition by Zetetic (the official Swift package `SQLCipher.swift`, a binary framework signed with Zetetic's Developer ID), crypto provider CommonCrypto. Its defaults of version 4: every page of 4096 bytes is AES-256-CBC with a random IV and an HMAC-SHA512, the journal likewise; the first 16 bytes of the file are its salt. |
| Store key | 32 bytes from `SecRandomCopyBytes`, made on this Mac, given to SQLCipher as a raw key (`x'<64 hex digits>'` through `sqlite3_key`), so no passphrase derivation runs. |
| Wrap | HPKE of RFC 9180 in base mode, CryptoKit `HPKE.Ciphersuite.P256_SHA256_AES_GCM_256` (DHKEM P-256 with HKDF-SHA256, HKDF-SHA256, AES-256-GCM), to the public key of the Secure Enclave key; info `sotto-mac store key 1 <kind>`, no associated data. |
| Secure Enclave key | `SecureEnclave.P256.KeyAgreement.PrivateKey`, access control `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with `.privateKeyUsage` and, for the presence kind, `.userPresence`: the Secure Enclave itself asks for the user's presence (Touch ID or the Mac password; on the Apple Watch see above) before each key agreement. The private key never leaves the chip; its `dataRepresentation` is a blob that only this Secure Enclave can use. |
| `store.key` | JSON next to the store, mode 0600, put in place by `link(2)`, which never replaces a key already there: `version` 1, `protection` (`presence` or `test`), `enclaveKey` (the blob), `encapsulatedKey` (65 bytes), `sealedKey` (the 32 bytes and the 16-byte tag), and `plainStore` while the key waits to encrypt a plain store of the previous version (below), after which a rename replaces the file by one without it and with the same key. |

Every connection checks, before it serves anything, that its key opens the pages (else
"the key does not open this store") and that `PRAGMA cipher_version` is not empty (else
"the store is not served by SQLCipher"). The code links SQLCipher's `sqlite3_*` by the
two-level namespace of macOS, so a system `libsqlite3` that a system framework loads into
the same process never serves the store; `Sotto --store-info` prints the version, the
provider and the file of the library that serves it, and `scripts/app-interop.py` checks
that this file is the framework inside `Sotto.app`.

## Post-quantum prekeys

Since SOTTO-45 new sessions are agreed by PQXDH (part 6 of the protocol), and the store
holds two tables more, which a store of an earlier version gains when it opens; no table
or column of before changes, so an existing encrypted store opens as it is.

| Table | What it holds |
| --- | --- |
| `pq_prekeys` | one row per post-quantum prekey whose private key the client holds: its id, the 64-byte seed d \|\| z of ML-KEM-768 (FIPS 203, ML-KEM.KeyGen_internal), from which CryptoKit derives the private and the public key, and the id of its signed prekey for the last-resort key, none for a one-time key. The public keys and their signatures are made again from the seed for each upload and are not stored |
| `pq_prekey_ids` | the counter of their ids, one row |

- The seed is the private key, as the reference keeps it; nothing else of an ML-KEM key is
  written, and it lives only in these encrypted pages, like the X25519 private keys of the
  signed and the one-time prekeys beside it.
- The last-resort key is made in the transaction of its signed prekey and deleted with it
  at the end of the grace period. A one-time key is deleted in the transaction that
  accepts the session it started, with the bounds of the protocol: at most 400 held, the
  lowest ids deleted first, and those of a refused upload deleted at once.
- The shared secret of an encapsulation, the ciphertext and the input of the key
  derivation are never stored: the initiator keeps the ciphertext only inside the initial
  header of its session until the first reply, as the protocol says. A session's version
  is the first byte of its session associated data; X3DH sessions of before keep version
  1.
- `secure_delete` is on, so a deleted seed is overwritten in its page. What CryptoKit
  copies while it derives a key or decapsulates is out of this code's reach, as for the
  other keys.

## The verified mark

Since SOTTO-47 the store holds the mark of section 45 of the protocol in a table of its
own, as the reference does; a store of an earlier version gains it when it opens, with no
contact marked, and nothing else changes.

| Table | What it holds |
| --- | --- |
| `verified_contacts` | one row per contact that the user marked as verified after comparing the safety number: its identity key. The row goes with the contact |

The mark never leaves the Mac: no frame or message carries it, and setting or clearing it
changes no other row. The safety number itself is not stored: it is computed from the two
public identity keys when it is shown and kept in memory only. When a key that a contact's
identity signed in place of the pinned one is refused, the time goes into the app's notes
(`app_notes`, by user id) until the user closes the warning or deletes the contact.

## Hidden chats

Since SOTTO-50 a chat can be hidden behind a phrase. Every row of it leaves `store.db` for a
second SQLCipher file of the data folder, `vault.db`, and the chat shows again only when the
phrase is typed into the search of the chat list. A forgotten phrase cannot be recovered: nothing
else opens the vault, and its chats are lost with it.

| Part | What it is |
| --- | --- |
| `vault.db` | A store with the schema of `store.db` and the same SQLCipher defaults (pages of 4096 bytes, AES-256-CBC, HMAC-SHA512, the first 16 bytes its salt, no plaintext header), keyed by the phrase through SQLCipher's own key derivation: PBKDF2-HMAC-SHA512 with 1,600,000 rounds (`Vault.kdfIterations`) in place of the default 256,000. One open took 0.50 to 0.51 s on an Apple M4 Pro under macOS 26.6, for the right phrase, a wrong one and the decoy alike. The phrase is the text without the spaces around it, in Unicode form C, of at least 8 characters. |
| The decoy | Every data folder has `vault.db` from the first open of its store, a store of an earlier version included: an empty vault under a random raw key that is never kept, so random bytes of the size an empty vault has. A folder without hidden chats looks like one with them. Making a vault replaces it. |
| One vault | One phrase opens it, and it holds any number of chats. Hiding a chat with a phrase that does not open it asks first, the same way whether a vault exists or not; a yes makes a new vault under the phrase, and the file it replaces, the decoy or a vault under another phrase, is overwritten with zeros and removed. |
| `inbox_key` | In `store.db` one P-256 public key, in `vault.db` the same key with its private half. A store gets one at its first open whose private half is dropped at once; making a vault puts the vault's public key in its place. |
| `sealed_inbox` | In `store.db`, the envelopes of senders who are no contacts: the Deliver (sender, message id, payload) sealed with HPKE of RFC 9180 in base mode, `P256_SHA256_AES_GCM_256`, info `sotto-mac sealed inbox 1`, to the inbox key, oldest first. It holds at most 1000 envelopes and 16 MiB, the bounds of a queue of the relay; the oldest go first. |
| `vault_moves` | In `vault.db`, a contact whose move into the vault or out of it a stop may have cut short. |

- `store.db` never records whether a vault exists or whom it holds. An envelope of a sender who is
  not a contact of `store.db` is sealed there and acked, and its result stays `NOT_A_CONTACT` as
  before: the relay does not keep it, so the messages of a hidden chat never fill its queue, which
  would stop every other chat. A hidden contact and a stranger look the same in `store.db`.
- Opening the vault opens the sealed inbox: every envelope that opens with the vault's private key
  and comes from a contact of the vault goes through the vault's client in order, as if it arrived
  now, and owes its delivery receipt then; every other one is deleted.
- The vault is a full store with a client of its own: contacts, sessions, records, seen ids,
  outbox, messages, files and notes. It also holds a copy of the identity and the prekeys of
  `store.db`, copied when it opens and after every change of them while it is open; making,
  uploading and rotating prekeys stays the work of `store.db`. A one-time prekey (X25519 or
  ML-KEM) that a session through the vault used is deleted in `store.db` too.
- While the vault is open a Deliver goes to the client whose store has its sender, and the
  outboxes of both are sent; the window shows the chats of both, the hidden ones with a mark.
- Hiding moves every row of the contact and what the app's notes keep of the chat (read position,
  times, draft, pin, mute, archive, timer changes, refused key) in three commits: into the vault
  with the move noted there, out of `store.db` with its notes, the note cleared. A stop after the
  first leaves the chat in both files until the next open of the vault, which takes the rows of
  `store.db`, the newer ones, in place of its copy and deletes them from `store.db`: nothing is
  doubled or lost. Unhiding is the same the other way. The rows of a hidden chat are never written
  to `store.db`, also not after a crash or a power cut.
- Positions of messages, pending texts and files of the vault are taken from the counters of
  `store.db`, so that no position is given twice.
- A received file of a hidden chat stays in the vault: "Save received files automatically" does not
  apply to it.
- Every lock (below) closes the vault with `store.db`: its connection ends, and SQLCipher wipes the
  key it derived. The phrase passes through memory as a Swift string (the search field, the box),
  which is released, not overwritten. Texts of a hidden chat not sent yet wait in the vault's
  outbox for its next open. A change of the relay address reconnects and closes the vault too.

What hiding does not do:
- The relay still sees who writes to whom and when; hiding is local.
- The contact sees no delivered mark until the vault is opened.
- A new session that the contact starts while the vault stays closed longer than the grace of a
  replaced signed prekey (37 days, `Client.signedPrekeyGraceSeconds`) is lost when the vault
  opens; messages on a session that exists keep.
- A flood of senders who are not contacts can push the waiting envelopes of a hidden chat out of
  the sealed inbox.
- The size and the modification time of `vault.db` can hint that it is used: an empty vault has
  the size of the decoy, a used one grows. The inbox key of `store.db` changes when a vault is
  made, and its counters of positions move on with the messages of the vault.
- Copies the owner saved outside Sotto ("Save as...", a file opened in another app, the pasteboard)
  are his own.
- A contact of the vault added again to `store.db` while the vault is closed is a chat of
  `store.db`; its hidden copy stays in the vault, out of sight, until the other one is deleted.

## Unlock and lock

- The app starts locked. At launch it shows the system sheet of Touch ID or the Mac password
  (or a paired Apple Watch, where macOS offers it) with the reason "open your chats"; the
  evaluated `LAContext` is handed to the Secure Enclave key, so one sheet unwraps the key.
  Cancel leaves the window on "Sotto is locked" with an Unlock button, which asks again. The passcode, when one is set, is asked
  after the store opens: it still only covers the window.
- The idle time of Auto-lock (5 minutes by default), Cmd+L, "Lock Sotto now", sleep, the
  lock of the Mac screen and a switch to another user (these three with "Lock when the Mac
  sleeps or locks", on by default) and quit overwrite the key bytes at once, then stop the messenger
  and close every connection to the store, the transport's and the open vault's included; the next
  unlock asks again, and the vault waits for its phrase. A lock works from the moment the store is open, also on the first-launch screen
  before Continue. On sleep the Mac waits for it: Sotto answers the system's sleep
  notification of IOKit (`IOAllowPowerChange`) once the store is closed, and macOS sleeps
  anyway after 30 seconds. A lock also clears the pasteboard while it still holds a text or
  a picture copied from the chats (below). While the store is locked there is no
  connection to the relay, so messages wait there.
- `sotto-mac` unwraps the key once per command; the sheet names the data directory.
- In memory the key lives in an `mlock`ed buffer that `memset_s` overwrites on lock, and
  its hex spelling for SQLCipher in a second buffer overwritten after each open. Out of
  this code's reach: the copies CryptoKit makes while it unwraps, the key schedule inside
  an open SQLCipher connection (SQLCipher wipes it when the connection closes), decrypted
  pages in SQLite's cache and the texts the window held, which are released on lock, not
  overwritten.

## Two kinds: presence and test

- `presence` is the kind of every store unless a run asks otherwise. `test` makes the
  Secure Enclave key with `.privateKeyUsage` only: it opens without a prompt, so tests and
  scripts never show a sheet on the screen. It still binds the store to this Mac.
- The only way to ask for `test` is the environment variable `SOTTO_STORE_PROTECTION=test`
  (that exact value; any other value counts as absent). No flag, setting or menu chooses
  it, and a launch from the Finder or the Dock has no such variable. `scripts/test.sh`,
  `scripts/interop.py` and `scripts/app-interop.py` set it for what they start.
- The owner directories, `~/Library/Application Support/Sotto` and `~/.sotto-mac`, refuse
  `test`: the variable there is an error, not a fallback. They are compared by path
  without regard to case, by device and inode, and, for a folder not made yet, by the
  device and inode of its parent and its name, so another spelling or a link does not get
  around it.
- The kind is written in `store.key` and bound into the HPKE info. A run that asks for one
  kind refuses a key of the other kind before the Secure Enclave is used: a test store put
  into a default folder does not open there, and a real store opened by a script with the
  variable does not open either, so it shows no prompt. A store never changes its kind.
- The tests call `StoreKeys.unlock(_:protection: .test)` themselves or rely on the variable
  of `scripts/test.sh`; `sotto-mac test-query` (left out of its help) answers the scripts'
  read-only checks from a store of the test kind only.
- The scripting flags of the app answer for a store of the test kind only: `--dump`,
  `--snapshot` and `--safety-number` with `--data-dir`, and `--send`, `--send-file`,
  `--profile`, `--read`, `--reply`, `--edit`, `--delete`, `--timer` and `--reset` (which act
  on the default folder without `--data-dir`). The kind is read from `store.key` (for a
  folder without one, from what the run asks for) before anything is unlocked, and again
  from the key held after the unlock: any other store is refused ("--dump: only a store of
  the test kind answers this", exit 1) and no sheet shows. Without this rule any process of
  the user could start the app binary on the owner's folder with `--dump` while Sotto is
  locked, and the sheet would name Sotto and say "open your chats" as at every launch.
  `--store-info` prints no chat and works on any store; `--demo` and `--snapshot` without
  `--data-dir` draw mock data. The commands of `sotto-mac` are the owner's tool by hand and
  work on any store: each shows a sheet that names its folder, none prints the stored
  history, and `chat` prints only what arrives while it runs.

## The store of the previous version

A store without `store.key` whose file starts with `SQLite format 3` is the plain store of
the previous version. The first open makes the key (one sheet) and then:

1. exports the plain store with `sqlcipher_export` into `store.db.encrypting`, a new file
   under the key;
2. checks that every table has as many rows in the copy as in the plain store, and
   syncs the copy (`F_FULLFSYNC`);
3. hard-links the plain store as `store.db.plain` and renames the copy over `store.db`:
   until this rename the plain store is the store and whole, after it the encrypted one is;
4. writes zeros over the whole of `store.db.plain`, syncs it and removes it.

The key made over a plain store says so in `store.key` (`plainStore`), and once the
encrypted store is in place `store.key` is replaced, under the same lock, by one without
it. Only such a key encrypts a plain `store.db`: next to any other key, a key of a version
before this record included, a plain file is refused ("... is a plain SQLite file, but
this store was encrypted already") and left as it is. So whoever can write the folder
while Sotto is locked cannot have a store of his own, with an identity he chose, encrypted
under the key that is there. This does not make the files of the folder authentic: the
same writer can delete `store.key` and `store.db` and leave a plain store, which the next
launch takes for one of the previous version after the usual sheet; the owner's chats are
then gone from the window. A store left by an encryption of the version before this record
that stopped before its rename (`store.key` there, `store.db` still plain) is refused as
well; if no encrypted store ever lived in that folder, removing `store.key` lets the next
launch encrypt it.

Every open of a store holds an exclusive `flock` on the data directory while it checks
for leftovers, migrates and opens, and `store.key` is put in place by a link that never
replaces one already there, so two processes that start together make one key and migrate
once. A stop at any step leaves one whole store: the next open removes an unfinished
`.encrypting`, and overwrites a `.plain` that is not the store any more (one that still is the
store, the same inode, is only unlinked and the export runs again). Reset overwrites and
removes these leftovers too.

What the overwrite cannot reach: APFS writes the zeros to new blocks and the SSD remaps
blocks itself, so the old plain blocks stay on the disk until they are reused or trimmed,
unreadable through the file system but not destroyed; local Time Machine snapshots and
backups made before the first launch of this version keep the plain file whole. FileVault
protects them while the Mac is off. To leave no plain copy behind, delete the local
snapshots (`tmutil listlocalsnapshots /`, `tmutil deletelocalsnapshots <date>`) and the
older backups after that first launch.

A store without `store.key` whose pages are encrypted does not open ("the store is
encrypted and its key ... is missing"); no new key is made over it.

## Notes and pasted pictures of the previous version

The first open of a store by this version (the store has no row in `app_notes`) moves what
the previous version kept outside it:

1. the notes of `app.json` (relay address, read positions, first-seen times, drafts, pins,
   muted and archived chats, timer changes, settings) are committed into `app_notes`;
   notification name and preview are set off, since that file cannot tell a choice to
   show them from the old default, and every other setting stays as it was;
2. `app.json` is overwritten with zeros, synced and removed, and written again holding the
   theme only (or not at all when no theme was chosen);
3. every picture in the folder `Pasted` of the data folder that a sent file names is
   committed into `kept_files` with that file; then every file of the folder is
   overwritten with zeros and removed, and the folder too.

A stop before step 1 commits leaves everything as it was; after it the store holds the
notes and the next open only finishes step 2 (a file that holds more than the theme is
overwritten again). The limits of the overwrite are those of the store above: APFS, the
SSD and older snapshots and backups keep the old blocks.

## Reset

"Reset Sotto..." deletes `store.db`, its journal, `vault.db` with its journal, `store.key` and
`app.json`, overwrites and removes the folder `temp.noindex`, and drops the key. The next store gets a new key
after one more sheet.

Deleting `store.key` does not erase the Secure Enclave key it wrapped: that key stays in
the chip, and `store.key` held only its blob and the wrapped store key. Pages of the old
store left on the disk do not open without a copy of `store.key`, but a Time Machine backup
or a local APFS snapshot taken before the Reset holds both files, and it opens on this Mac
with Touch ID or the Mac password like the store it was. To leave nothing that opens, delete
the local snapshots taken before the Reset (`tmutil listlocalsnapshots /`,
`tmutil deletelocalsnapshots <date>`) and the backups that hold the data folder.

## A Mac without a Secure Enclave

Macs with Apple silicon or a T2 chip have one. On any other Mac the store does not open:
the app shows "this Mac has no Secure Enclave, which the store key needs" under its Unlock
button and `sotto-mac` prints it and exits 1. There is no fallback to a weaker key.

## What it protects and what it does not

- Stopped: a copy of the store taken to another Mac or read offline (a disk image, a disk
  in another machine, a backup restored elsewhere): the pages open only with the store key,
  which exists only wrapped to the Secure Enclave of this Mac.
- Stopped: someone at the keyboard of this Mac who does not know the Mac password. The
  Secure Enclave asks for the user's presence first; whoever knows the Mac password opens
  the chats.
- Not stopped: a copy on this Mac. It opens with the user's presence wherever it lies: in
  another folder, in a Time Machine backup or a local snapshot, also one from before a
  Reset (above). Whether another account of this Mac, such as an administrator who copies
  the folder with sudo, can use the Secure Enclave key was not measured.
- Not stopped: code that runs as the user. It can ask for the same sheet in Sotto's name
  (with a program of its own, or a changed copy of Sotto, which an ad-hoc signature does
  not bind to the key; the scripting flags of Sotto itself refuse such a store, above), and
  a user who approves it as usual opens the chats to it; it can wait for the next normal
  unlock; and while Sotto is unlocked it reads what the window shows. The hardened runtime
  of the signature makes dyld ignore `DYLD_INSERT_LIBRARIES` (`scripts/app-interop.py`
  checks it), but the app bundle is the user's files, and whoever can write them can
  replace the code.
- Not protected: what the user lets out of the store, each listed in "What is written
  outside the store" below: a copy made with "Save as..." or by automatic saving, a file
  opened in another app, the pasteboard, and notifications with the name or the preview
  turned on.

## Files

The same encrypted file holds the files of part 3 (section 33.7 of the protocol): an upload
with the whole encrypted blob until its message is committed, the attachment of each sent
and received file with its file key, and the bytes of a download so far. Where a received
file goes once its blob is here is the caller's choice (`Transport.Downloads`):

- the app, by default: its bytes stay in the store, in `kept_files` beside its row of
  `files`, and leave only through "Save as..." (a readable copy where the user says, marked
  as downloaded) or a click that opens it (below). A photo is decoded in memory for the
  bubble and the viewer, never written; the decoded bubble pictures sit in a cache bounded
  at 256 MB of pixels that a lock empties;
- the app with "Save received files automatically" in Data and storage (off by default),
  and `sotto-mac` always (into `received` in its data directory): the file is written in
  readable form, outside the encryption, into the folder instead of the store, mode 0600
  in a folder of mode 0700, marked as downloaded. Files that a previous version saved
  there stay: they are the user's files now.

A kept file goes into `kept_files` and out of it (Save as, Open) 1 MB at a time through
SQLite's blob calls, so a large one is never copied whole on its way; only a photo to
decode or copy and a file sent again are read whole.

A sent file read from a file of the user is not copied into the store: its path is kept and
the file stays his. A pasted picture is in no file: it is held in memory until it is sent,
and then `kept_files` keeps it with the sent file, for the bubble, "Save as..." and a retry.
A file of `kept_files` goes with its row of `files` (a trigger deletes it with the row), so
a delete, an expiry or a deleted contact takes it too, under `secure_delete`.

The store grows by every file it keeps (at most 100 MB each). "Clear cache" of Data and
storage, which would drop kept files that the relay still holds, is not built yet.

## Deleted and expired messages

A delete for both, an expired timer and a delete for me remove the message row, its file
rows and downloaded bytes in one transaction, with `secure_delete` on, and leave a trace
of the author and the id only (section 39.4 of the protocol); the text of every quote of
the message is cleared in the same transaction. After a delete for both or an expiry, a
received file that was saved into a folder is removed after the commit; the file a sent
one was read from is the user's own and stays.

## What is written outside the store

Every place where the app (`Sotto`) or `sotto-mac` writes anything of the chats, or that
shows it, outside `store.db`; "before" is the version of 2026-11-19 (SOTTO-42), "now" this
version (SOTTO-43). `test-query`, `--dump` and `--snapshot` are tools of the scripts that
print or draw on request, for a store of the test kind only; they are left out.

| Place | Before | Now |
| --- | --- | --- |
| `store.db`, `store.db-journal` | the store, encrypted | the same, now also holding the app's notes (`app_notes`) and the files it keeps (`kept_files`) |
| `store.key` | the wrapped store key; nothing of the chats | unchanged |
| `vault.db` (SOTTO-50) | none | the hidden chats under their phrase, or the decoy (above) |
| `app.json` in the data folder | in the clear: the relay address, the last read position and the first-seen time of each contact by its id, the time of every message, the drafts, pinned, muted and archived chats, timer changes, every setting with the passcode check (salt and HMAC) and the download folder | the theme only, which the lock screen shows before the store opens; the rest is in `app_notes`. An older file is moved once and overwritten (above) |
| `Pasted` in the data folder | every pasted picture as a readable PNG, for the bubble and a retry | not written: a pasted picture is in memory until it is sent, then in `kept_files`. An older folder is moved into the store and overwritten |
| `temp.noindex` in the data folder (new) | none | a file the store keeps, written when the user clicks it so that its app can open it (a photo never is): 0600 in a 0700 folder that Spotlight skips, marked as downloaded, excluded from backups (which keeps it out of Time Machine, not out of a local APFS snapshot taken while it is there); overwritten and removed as soon as its message goes (a delete by either side, an expiry, a deleted contact), at launch, on lock, on quit and by Reset. Readable while it is there; the app that opened it keeps what it read, and macOS may list its name among that app's recent items |
| The download folder (Downloads by default) | every received file of the app, readable | nothing by default; with "Save received files automatically" each received file, as before. What is already there stays; after a delete for both or an expiry a file saved there is still removed |
| Where "Save as..." points | a copy of the file | the same, from the store when it keeps the file: the user's own copy, readable, marked as downloaded when it was received |
| `received` in the data directory of `sotto-mac` | every received file, readable | unchanged: the file is what the console command delivers, with no viewer to show it from the store |
| Notifications (macOS keeps them in its own database, outside the data folder) | the contact's local name and the text of the message | "Sotto" and "New message" by default; name and text only with "Show sender name" and "Show message preview" on. The identifiers of a notification still carry the chat's id (the contact's public id) and the message position, for the grouping and the click; how long macOS keeps them is its own. A hidden chat's notification is always "Sotto" and "New message" and carries the group `hidden` and the position only, and a closing vault takes it away |
| Dock badge | the unread count | unchanged; no text |
| Pasteboard | what the user copies: a text, a picture, an id | a text or a picture copied from the chats (Copy text, Copy image, Cmd+C in a bubble, in the viewer or in the field) is marked `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, which clipboard managers that follow nspasteboard.org neither show nor keep, and a lock clears the pasteboard while it still holds that copy. Until then every app may read it, and Universal Clipboard may carry it to the user's other devices. An id copied with "Copy id" is public and left as it is |
| Logs | none through the unified log; the app writes a line to stderr when a scripting flag names no contact, `sotto-mac` prints the chats to its terminal | unchanged |
| Caches | none on disk: pictures and thumbnails in memory, the socket on an ephemeral `URLSession` (no URL cache, no cookies), SQLite temporary tables in memory | the same; the pictures decoded for the window are dropped on lock |
| User defaults and saved window state | the window frame and the theme of a version before the settings page | unchanged; nothing of the chats |

## Why not the keychain: what was observed (before 2026-11-19)

A small app was signed ad hoc with a designated requirement by identifier
(`designated => identifier "<bundle id>"`), the way `scripts/build-app.sh` signs Sotto.
It stored a generic password (service `com.glowystar.sotto.spike`) in the default
file-based login keychain on macOS 26, then read it back from other builds. Every read of
the secret set `kSecUseAuthenticationUI` to `kSecUseAuthenticationUIFail` and was stopped
after 15 seconds if it had not returned.

| Step | Result |
| --- | --- |
| `SecItemAdd`, then read by the same build | `0`, the secret comes back, no prompt |
| One source line changed, rebuilt, re-signed (new code hash, same identifier), read | blocked: no status within 15 s, the keychain access prompt is shown despite `kSecUseAuthenticationUIFail` |
| Same item read by an ad-hoc app with another bundle identifier | blocked the same way |
| The attributes only (no `kSecReturnData`), from either app | `0`, no prompt |
| `kSecUseDataProtectionKeychain: true`, add | `-34018` (`errSecMissingEntitlement`) |
| Delete by the rebuilt app, then look up | `0`, then `-25300` (item gone) |

## Why the keychain is not used for the key

- The file-based keychain binds an item's access to the code hash of the build that made
  it, not to the designated requirement. Every rebuild of an ad-hoc app loses silent
  access to its own secrets and asks the user, and `kSecUseAuthenticationUIFail` does not
  turn that prompt into an error: a background read would hang on a dialog.
- The data protection keychain, which keys access by the application identifier, refuses
  an ad-hoc app outright: it needs a keychain access group entitlement, which needs a
  real signing identity.
- The attributes of an item (its service and account) are readable by any app of the
  user without a prompt, so they must not carry anything secret either.

A Secure Enclave key made with CryptoKit and kept as its `dataRepresentation` beside the
store needs none of this: an ad-hoc build makes it and loads it back without the keychain
(measured on this Mac, 2026-11-19), and its access control lives in the chip, not in the
code hash of a build. The data protection keychain can be measured again once the app is
signed with a Developer ID.
