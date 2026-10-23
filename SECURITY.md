# Security

Triwarden is a client for Vaultwarden and Bitwarden servers. It uses the same end-to-end encryption
as the official clients. The server only ever sees encrypted vault data, and your master password never
leaves your Mac.

## Reporting a vulnerability

Please **don't open a public issue**. Use **Security › Report a vulnerability** on
[the GitHub repository](https://github.com/sinhong2011/triwarden/security/advisories/new) instead, and
include steps to reproduce. You should get an answer within a week. Fixes ship as a new release, with credit
to you unless you'd rather stay anonymous.

Problems in Vaultwarden or Bitwarden themselves belong to those projects.

## Where secrets live

| Secret | Where | Protection |
|---|---|---|
| Master password | Memory only, during unlock | Never stored or sent. Only the derived *master password hash* goes to the server, at login. |
| Master key / stretched key | Memory only, during unlock | Derived with PBKDF2-SHA256 or Argon2id, using the KDF settings the server reports (bounds-checked so a hostile server can't make them trivially weak). |
| User key (vault key) | Memory while unlocked | On disk only as the server's *protected user key*: encrypted with the stretched master key (AES-256-CBC + HMAC-SHA256). |
| User key for Touch ID | `Accounts/<id>/biometric.json` | AES-GCM under a key from ECDH with a **Secure Enclave** P-256 key that requires `biometryCurrentSet`. Enrolling a new finger or removing Touch ID makes it unusable, and you then need the master password. |
| Organization keys, per-item keys | Memory while unlocked | Arrive RSA-OAEP or AES encrypted in the sync payload. |
| Vault cache | `Accounts/<id>/vault.json` | The sync payload exactly as the server sent it: every name, username, password, URI, note and field is still an EncString. Item ids, types, dates and folder/collection ids are visible. |
| Refresh token | Keychain (Keychain Sharing group `…triwarden.shared`) | `AfterFirstUnlockThisDeviceOnly`, never synced to iCloud. Shared with the AutoFill extension so it can save new passkeys. |
| Custom request headers (e.g. Cloudflare Access tokens) | Same Keychain group | Same as above. |
| Website-icon cache key | Same Keychain group | 256-bit random key. Icons are cached AES-GCM encrypted, under HMAC-SHA256 file names, so the cache doesn't reveal which sites you have. |
| Attachments | On the server; decrypted copies only while previewed | Each file has its own 512-bit key (encrypted with the item key) and is uploaded as an encrypted buffer. Quick Look gets a decrypted copy in a private (0700) folder in the sandbox's temp directory. It is deleted when the preview closes, on lock and at launch. On APFS, deleting a file doesn't scrub the disk blocks, so don't preview files you need forensically erased. |
| Send contents | On the server, encrypted | Each Send has 16 random bytes of key material. They are stored under your user key and put in the share link's `#fragment`, which browsers never send to the server. HKDF-SHA256 turns them into the key for the name, text and file. An optional password is checked by the server as PBKDF2-SHA256 of the password, salted with the key material. |
| Passkeys | Inside the login item (`login.fido2Credentials`) | Encrypted with the item's key like any other field, and synced to your server. |

Files live in the App Group container
`~/Library/Group Containers/FX3VR69P5K.io.github.sinhong2011.triwarden/`. They are written atomically
with `completeUntilFirstUserAuthentication` file protection, and both the app and the extension are sandboxed.

## What the app does to limit exposure

- **Locking** drops every account's keys, decrypted items and server connection. Auto-lock after inactivity,
  and on sleep, display sleep or a user switch, are on by default.
- **Clipboard**: copied secrets are marked `org.nspasteboard.ConcealedType`, so clipboard managers skip them.
  They are cleared after 30 seconds by default, but only if the clipboard still holds the copied value.
- **AutoFill** never fills without you there. Every request requires Touch ID or the master password inside
  the extension, and `provideCredentialWithoutUserInteraction` always refuses. Only domains, usernames and
  passkey ids are shared with the system's QuickType list, never passwords.
- **SSH agent** (off by default) listens on a `0600` socket in the App Group container. It only lists and
  signs; it never adds, removes or exports keys. A signature request names the app that owns the connecting
  process (bundle id and Team ID when the signature is readable, otherwise the executable path). The person
  allows it once, for 10 minutes, until the vault locks, or always for that app. macOS then asks for Touch ID
  or the Mac login password, which Triwarden never receives. Short grants live in memory and are cleared on
  lock. Requests appear in a standalone panel without opening the vault or menu-bar window. Its countdown
  uses the queue's monotonic 60-second decision deadline; close or Escape denies the displayed request.
  Decisions are bound to that request's ID. Device authentication is cancelled on reset or agent stop.
  Allowing once also covers the same app and key for 15 seconds. Always is an app allowlist in
  `ssh-allowlist.json`: it survives lock and quit, and while the vault is unlocked those apps sign with no
  further prompt. Every request is appended to `ssh-access-log.json` in the
  App Group container (newest 200; app, tool, path, key name, outcome; no key material and no signed payload).
  Keys are only available while their account is unlocked.
- **`tw` command line** (off by default) talks to the app over a `0600` socket in the App Group container.
  Status, generate and lock work without approval. Listing or reading anything needs the vault unlocked and
  Touch ID or the Mac password, with a prompt that names the calling program. Secrets go to stdout only,
  never into arguments or environment variables.
- **Auto-type** types a login into the app the palette was called over. It's done by a separate helper,
  *Triwarden Auto-Type* (inside the app bundle), which alone holds Accessibility, so the app itself stays
  sandboxed. The helper listens on a `0600` socket in the App Group container and answers only the Triwarden
  executable of the bundle it sits in, signed by the same team; anyone else gets no answer at all. It stores
  nothing, types only what one request carries into the app that request names (after it comes forward), and
  quits with Triwarden. Typing takes the same Touch ID / re-prompt as copying. Matching a browser tab is off
  by default. When it is on, the palette and the menu bar ask the front browser for its tab's address over
  Apple Events (macOS asks once per browser), only to put that site's logins first.
- **Browser extension** (off by default; Safari, and Chrome/Edge/Brave through `tw` as the native host)
  stores nothing and holds no keys. The page URL comes from the browser, not the page. Suggestions are names
  and usernames for that site only, and only our own bundled binaries may ask for them. Filling needs Touch ID
  and only fills a login on its own site. Saving or updating a login always asks you in the app first.
- **Shortcuts / Spotlight actions** only expose item names and usernames. Copying a password or a code works
  only while unlocked, and passwords go through the same concealed, auto-clearing clipboard.
- **Update check** is off by default. When on, it asks GitHub's public API for the latest release number once a
  day and links to the release page. It never downloads or installs anything by itself.
- **Leaked-password check** (Watchtower) uses the Have I Been Pwned k-anonymity range API with padding.
  Only the first 5 hex characters of each SHA-1 are sent.
- **Self-hosted servers**: public `http://` servers are refused, while local-network `http://` is allowed for
  home labs. You can trust a private CA inside Triwarden only, without adding it to the system keychain.
- **Edits** patch the server's own JSON and send `lastKnownRevisionDate`, so fields this app doesn't
  understand survive and concurrent edits are rejected rather than overwritten.
- **Unknown item types** remain visible as unsupported, read-only items with their original numeric type.
  Only shared metadata is shown; their payload is not interpreted as credentials or exposed as custom fields.
  The encrypted cache and raw cipher retain their data. Editing, cloning, attachments, moving, archiving,
  deleting and other item writes are blocked, including batches containing an unsupported item.

## Import and export

Formats match Bitwarden's official clients, so files move between them.

| Export | What's in it | Protection |
| --- | --- | --- |
| Password-protected JSON (recommended) | Personal items, folders, passkeys, SSH keys | AES-256-CBC + HMAC-SHA256 with a key from your file password (PBKDF2-SHA256, 600,000 rounds, random salt). Decryptable by any Bitwarden client with that password. |
| JSON | The same, in plain text | None. Anyone with the file can read everything. |
| CSV | Logins and secure notes only | None. |

- An export covers the personal vault, or one organization's vault (with its collections) for owners, admins and members
  with the import/export permission. Trash and attachments are left out, as in Bitwarden's export.
- If the selected vault contains an unsupported item type outside Trash, export stops with an explanation;
  it does not produce a partial item. Use an updated Bitwarden client to export that vault.
- Exporting asks for the master password again (checked on the Mac, offline) and warns before any unencrypted format.
- The file is written straight to the place chosen in the save panel with `0600` permissions, never to a temporary copy.
- Imports are read only from the file you choose or drop on the window. Every item is encrypted on the Mac with your account
  key (or the organization's key, `POST /api/ciphers/import-organization`), then sent in batches of at most 5,000
  (`POST /api/ciphers/import`); nothing leaves unencrypted. 1Password `.1pux` files are unzipped in memory.
- `DevServer/verify_export.py` decrypts a password-protected export with an implementation independent of the app.

## Threat model

**In scope.** These are protected against:
- A compromised or malicious server, or anyone who reads the server's database. They get ciphertext only.
  A server could still withhold or roll back data, which no Bitwarden-protocol client can prevent.
- Network attackers. TLS is required for anything not on the local network.
- Someone with your unlocked Mac while Triwarden is **locked**. They need the master password or your
  fingerprint.
- Other apps reading the vault files. The vault cache stays encrypted, and the sandbox keeps other apps out.

**Out of scope.** These are not protected against:
- Malware running as your user while the vault is **unlocked**. It can read memory, the screen or the
  clipboard.
- Someone who knows your master password.
- A weak master password. The KDF slows guessing but can't make a weak password strong.
- Swift can't guarantee secret bytes are wiped from freed memory. Locking releases them, but
  doesn't zero them.

## Cryptography

All primitives come from Apple CryptoKit / CommonCrypto, except Argon2id, which uses the reference
implementation ([P-H-C/phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2), pinned by commit).
The VaultCore test suite checks known-answer vectors for PBKDF2, Argon2id, HKDF stretching, EncString, TOTP
(RFC 6238) and passkey signatures. Integration tests run against real Vaultwarden servers (see `DevServer/`).


## Local Secrets Agent

`tw run --profile NAME` has its own one-shot socket and native authorization scope, separate from generic CLI read grants. Credential values remain ordinary Bitwarden/Vaultwarden fields. Local profile files contain references only, are written with mode 0600, and are reloaded and revision-checked before delivery. The exact revision reviewed in the native settings page is pinned separately in the App's Data Protection Keychain access group. The CLI has no entitlement for that group; external profile-file edits invalidate the pin and require another native save. Keychain failures have no legacy fallback for this pin. Profiles remain configuration, not a sandbox against compromise of the App or user-approved UI automation.

Both ends obtain `LOCAL_PEERTOKEN` from the socket, resolve the audit token with `SecCodeCopyGuestWithAttributes`, validate the running code, compare its canonical path and signing identity/code hash with the counterpart in the same bundle, and validate the sealed app bundle including nested code. Official signed peers must share the running process's Team ID. No PID-only, filename-only, or unsigned fallback is provided. Ad-hoc source builds rely on valid bundle seals and exact counterpart matching; they do not have a developer-team trust anchor.

The implementation permits up to 64 saved tools with 16 credential bindings each. Every selected account must be unlocked and successfully refresh online for every request. Every binding is validated before one atomic response; a missing/ambiguous field, reprompt policy, invalid/duplicate variable or total value size above 32 KiB prevents exec. The CLI requires exactly the approved response variables and rejects partial delivery. Native approval and device-owner authentication can authorize exactly one launch (the default), ten minutes, or until lock. Temporary grants are memory-only and bound to the exact tool name, authenticated bundled helper, kernel-observed immediate calling process (PID, start time and valid running code signature), complete profile revision, independently checked executable/directory identity, and an ephemeral-key HMAC fingerprint of all selected credentials/revisions. Names alone confer no authority; an uninspectable caller permits once only. Refreshing one tool does not evict another tool's grants. Changed credentials or targets discard that tool's previous grants on the next refreshed request. Timed reuse does not extend expiry. Lock, logout, configuration save/pause/removal, denial/cancellation, Revoke All and App exit clear grants; individual Revoke removes only that entry. No permanent Always Allow is offered for API credentials. Project scripts/plugins remain unverified even when the interpreter and calling process signatures match.

The whole catalog is pinned in the existing Data Protection Keychain record; legacy single-tool revisions remain valid until changed. Native saves validate the exact loaded snapshot before preserving other tools. The new pin comes from the intended in-memory data, never a subsequent read of writable on-disk contents. Thus saving one reviewed tool cannot bless changes to another, or pin an attacker's replacement file after a save. Explicit reset recovers to a known empty catalog and cannot import unreviewed settings. Profile references contain no resolved credentials.

Command overrides are rejected. Concurrent pending requests do not share approval; lock, logout, profile change, disconnection and expiry cancel pending requests. A fresh nonce and authenticated connection are required even during temporary access. The last lifecycle/expiry check and nonblocking socket write occur synchronously on the main actor, so lock cannot interleave between them. Delivery commits at that write; keys already sent to a program cannot be revoked by grant expiry or locking.

The authenticated CLI briefly holds the plaintext value, closes IPC, rechecks the executable and directory identity, builds a restricted environment, and replaces itself with `execve`. It does not print the value, create a temporary `.env`, or alter the parent shell. Same-user process inspection can expose environment values beyond the child process tree. The receiving tool can exfiltrate its value, and locking cannot revoke it. Triwarden does not redact arbitrary child output.

Canonical path, device/inode, permissions, high-resolution timestamps and content hashing detect target changes. Public macOS path-based exec leaves a final TOCTOU window; scripts, interpreters and project dependencies can execute arbitrary code. This feature assumes the user trusts the approved command and project, and does not isolate it from other processes running under the same user. A denylist of loader/startup variables and a restricted inherited environment reduce accidental exposure but cannot make arbitrary programs safe.

A provider-key-protecting API proxy is outside this feature's current product scope. Environment injection does not provide SSH-style private-key isolation. See [Local API credentials](docs/local-secrets.md).
