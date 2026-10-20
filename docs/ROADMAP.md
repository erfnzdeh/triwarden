# Triwarden roadmap

Owner: product. Updated 2026-10-11. Status: ✅ done · 🟡 in progress · ⬜ planned

> **Work is tracked in [GitHub Issues](https://github.com/sinhong2011/triwarden/issues)** by milestone
> ([v0.2](https://github.com/sinhong2011/triwarden/milestone/1), [v0.3](https://github.com/sinhong2011/triwarden/milestone/2), [v1.0](https://github.com/sinhong2011/triwarden/milestone/3)).
> This page keeps the product intent, exit criteria and decisions.

## North star

A Mac-native password manager for Vaultwarden (and Bitwarden) people *prefer* over the official
app: instant to open, beautiful in light and dark, and woven into macOS (AutoFill, Touch ID,
Quick Search, menu bar, SSH agent).

## v0.1 — "usable every day" (exit criteria)

You can replace the official desktop app for **reading** your vault:

| # | Capability | Why it blocks daily use | Status |
|---|---|---|---|
| 1 | Log in: PBKDF2, TOTP 2FA, new-device email code | Can't get in otherwise | ✅ |
| 2 | Log in: **Argon2id** accounts | Many vaults (and Bitwarden's newer default) use it | ✅ |
| 3 | **Organization items** (RSA-wrapped org keys, per-item keys) | Shared/family items were invisible | ✅ |
| 4 | Every item type renders: login, card, identity, note, SSH key | Half the vault looked empty | ✅ |
| 5 | **Stay signed in**: unlock with master password offline; Touch ID unlock (Secure Enclave) | Logging in with the network every time is a non-starter | ✅ |
| 6 | Encrypted offline cache, background sync, live updates (SignalR WebSocket, proxy-safe) | Must work on a plane; must reflect other devices | ✅ |
| 7 | Copy, reveal, live TOTP, open website | Core jobs | ✅ |
| 8 | Search + filters + sidebar categories | Core jobs | ✅ |
| 9 | Settings: appearance, auto-lock, lock on sleep, clipboard, custom CA, extra headers | Self-hosters and security defaults | ✅ |
| 10 | Command palette (⇧⌘Space, global) + menu bar extra (codes, favorites, lock) | The reason to go native | ✅ |
| 11 | Localized: en, zh-Hant, zh-HK, zh-Hans, ja, ko, fr, es, th | Day-one requirement | ✅ (kept current per change) |

## v0.2 — "use it instead of the browser extension"

- ✅ **Multiple accounts** (e.g. personal Vaultwarden + work Bitwarden): merged list with per-account colour and filter, per-account lock/unlock and Touch ID (one touch opens all), AutoFill across accounts
- ✅ AutoFill credential provider extension (passwords, one-time codes) — system-wide; QuickType suggestions; unlock required for every fill
- ✅ Passkey provider
- ✅ Create / edit logins & notes (lossless patching: item key, passkeys, history kept; conflict-safe), Trash (restore / delete forever), password generator (unbiased CSPRNG), hold ⌥ to reveal, Item menu shortcuts
- ✅ Edit cards / identities / SSH keys, custom fields, attachments
- ✅ Website icons from your own server, encrypted cache with keyed-hash names, placeholder detection; Watchtower (breached via HIBP k-anonymity on demand, reused, weak, unsecured http) with score

### Adopted from reviewing prizm (ideas only — its license is MIT + Commons Clause, so no code)

- Inline Touch ID prompt on the unlock screen (`LAAuthenticationView`)
- Hold ⌥ to reveal all masked fields; Edit-menu copy commands (⇧⌘C username, ⌥⌘C password)
- Search-match highlighting; drag items onto folders; nested folders via `/` names
- Trash (restore / delete forever)
- Editing must preserve `key`, `fido2Credentials`, `passwordHistory` and send `lastKnownRevisionDate`
- Favicons must not leak the domain list or sit in a plaintext cache
- `SECURITY.md` (where every key lives) and `ACCESSIBILITY.md`

## v0.3 — "power users"

The following capabilities are implemented; continued work focuses on reliability and validation.

- SSH agent with Touch ID per signature; git commit signing
- App Intents / Shortcuts, Services menu, `tw` CLI over XPC
- Send, attachments, collections management, emergency access (Vaultwarden)
- Safari Web Extension + Chromium native messaging (save prompts, inline fill)

## Reliability priorities

- Unknown server item types stay discoverable and read-only; preserve encrypted payloads and reject unsafe
  writes, mixed batches and partial exports. Verify with `make selftest-compatibility` and VaultCore compatibility tests.
- Import delivery distinguishes confirmed writes, uncertain requests and batches not sent; failed reads never invite resending successful imports.
- Every account syncs independently; failures stay visible with a retry action and the encrypted cache remains available.
- Local build and test commands preserve failure exit codes.
- Keep this document, README, keyboard shortcuts and accessibility notes aligned with shipped behavior.

## Quality bar (every change)

- Unit tests + dev-server integration tests pass (`DevServer/dev.sh test`)
- In-app lifecycle self-test passes (`Triwarden --selftest <server> <email> <password>`)
- Light **and** dark snapshots reviewed (`Triwarden --snapshot`)
- All new strings translated in all nine locales
- No secrets in logs, UserDefaults or the repo; secrets in Keychain or memory only

## Decisions log

- 2026-10-05 Native Swift/SwiftUI, macOS 26+, self-distributed. The earlier MIT decision was superseded by GPL-3.0; see LICENSE.
- 2026-10-05 Vaultwarden-first; official Bitwarden cloud also supported.
- 2026-10-05 UI follows the canvas "Vault window (static spec)"; **no Liquid Glass on custom components**, system sidebar only.
- 2026-10-05 Keyguard is reference-only (All Rights Reserved) — never port its code.
- 2026-10-05 prizm (b0x42/prizm) is reference-only (MIT + Commons Clause) — never port its code.
- 2026-10-05 Swift app replaces the earlier Tauri prototype on `main`; the prototype is kept on branch `tauri-legacy`.
