# Key storage

## Decision

Keys and messages live in one SQLite file under `~/Library/Application Support/Sotto/`,
directory mode 0700, file mode 0600, as in the reference client; the keychain is not used
while the app is signed ad hoc.

## Files

The same SQLite file holds the files of part 3 (section 33.7 of the protocol): an upload
with the whole encrypted blob until its message is committed, the attachment of each sent
and received file with its file key, and the bytes of a download so far. A received file
is written in readable form into the folder the caller names (`received` in the data
directory of `sotto-mac`), mode 0600 in a folder of mode 0700.

## What was observed

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

## Why the keychain is not used

- The file-based keychain binds an item's access to the code hash of the build that made
  it, not to the designated requirement. Every rebuild of an ad-hoc app loses silent
  access to its own secrets and asks the user, and `kSecUseAuthenticationUIFail` does not
  turn that prompt into an error: a background read would hang on a dialog.
- The data protection keychain, which keys access by the application identifier, refuses
  an ad-hoc app outright: it needs a keychain access group entitlement, which needs a
  real signing identity.
- The attributes of an item (its service and account) are readable by any app of the
  user without a prompt, so they must not carry anything secret either.

The question is open again once the app is signed with a Developer ID: then the data
protection keychain, or a key wrapped by it for the SQLite file, can be measured.
