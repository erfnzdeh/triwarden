# SSH approval: who is asking, and a local record

## Goal

When a program asks the Triwarden SSH agent to sign, the person sees which app is asking, chooses how long that app may sign, and can look the request up later. The macOS password dialog still appears after they allow it. A card shown first explains that the password is the Mac login password, confirmed by macOS, and never read by Triwarden.

## What stays

`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` still proves the device owner. macOS draws that dialog, including the words “Triwarden is trying to …” and the Mac account password field. Triwarden sets the reason and the cancel title (`Deny`) only. The first allow for an app and a key always reaches this dialog. A remembered grant skips it until that grant ends.

The `tw` command keeps its own prompt. This design covers the SSH agent.

## Who is asking

The socket peer is usually `ssh` or `git`. Walk that process’s parents, at most eight steps, stopping at pid 0 or 1. The first executable that lives inside a `.app` bundle is the app on the card (Cursor, Terminal, VS Code). The peer’s own name stays on the card as the tool that connected (`via git`, `via ssh`), with its path in small type.

The trust identity is the app’s bundle identifier plus its Team ID when Security.framework can read the signature. Otherwise it is the `.app` path, or the peer’s executable path when no app bundle is found. A display name alone never matches a grant.

## One decision, three ways to reach it

1. **Approval card.** A floating panel in the menu-bar visual language (icon, app name, tool, key name, path). Buttons: Deny, Allow Once, Allow for 10 Minutes, Trust Until Lock. A short note says the next system dialog asks for Touch ID or the Mac login password, and that this password stays with macOS. Closing the card leaves the request waiting. About 60 seconds with no choice denies that signature.
2. **Menu bar.** While a request is waiting, the template glyph gains a small corner mark, and the SSH row becomes that request with the same four actions. The row is the card again, for someone who closed the panel.
3. **Notification.** A prompt to come back, posted about two seconds after the card appears if the request is still waiting. Tapping it brings the card forward. The notification has no Allow action. Permission is requested when the SSH agent is turned on. With permission denied, the card and the menu bar still work.

The card is shown as Triwarden comes forward, so Touch ID attaches to it. After the system dialog finishes, focus returns to the app that was in front.

Requests for the same app and the same key share one card, including a burst from a single `git push`. Other pairs wait in a queue, one card at a time. Allow Once also covers the same app and key for the next 15 seconds, so the burst does not ask again. Each signature is still recorded.

## Apps that ask all the time

Cursor, and other editors, start many `ssh` and `git` processes while you work, often several at once. The agent today asks on every signature (`sshApprovalSeconds` defaults to 0). Overlapping calls all pass the grant check before any grant is saved, so each one presents the system password dialog. The peer name on that dialog is `ssh`, so every one of them looks the same.

The card absorbs that pattern:

- Signatures already waiting for the same app and key join the prompt that is already up. One system dialog covers the whole burst. The card shows how many signatures are in it.
- The first ask from an app leads with Allow Once.
- When that app asks again after the short grant has ended, the card leads with Trust Until Lock and says this app has asked before. Allow Once stays available. A person who uses Cursor for the afternoon can stop the Mac password dialog for the rest of the unlock without a setting buried elsewhere.

## Trust

The Settings picker “Ask before signing” (every time / 1 minute / 10 minutes) goes away. Each card carries the choice:

| Choice | Effect |
| --- | --- |
| Deny | This signature fails. |
| Allow Once | Touch ID, then the same app and key may sign for 15 seconds. |
| Allow for 10 Minutes | Touch ID, then that pair may sign for 10 minutes. |
| Trust Until Lock | Touch ID, then that pair may sign until the vault locks. |

Grants live in memory. Locking clears them, the same moment parsed keys are dropped. Settings lists only “Trust Until Lock” entries: icon, app name, key name, Remove. Ten-minute grants stay out of that list and expire on their own.

Touch ID runs after the choice and before the grant is stored. A failed or cancelled system dialog stores nothing.

## Access log

Every signature request is appended to a local log on this Mac: a new ask, a grant reused during its window, a denial, a timeout, and a refusal because the vault is locked. The log survives lock and quit. It is not synced and it is not an organization event.

Each entry has the time, the app name, the tool (`git` or `ssh`), the executable path, the key’s name, and the outcome. It has no private key and no signed payload. The file lives in the App Group container, holds the newest 200 entries, and can be cleared from Settings. The menu bar keeps showing only the latest one.

## Verification

Pure tests cover parent walking, trust-key formatting, grant expiry, shared prompts for one app and key, the 15-second burst, the 200-entry cap, lock clearing grants while keeping the log, and the second ask from an app leading with Trust Until Lock. The existing SSH self-test keeps approving through its hook, with no card and no Touch ID. `SECURITY.md` describes the card, the grants, and the local log.
