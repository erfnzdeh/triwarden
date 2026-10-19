# Accessibility

Triwarden should work fully with VoiceOver, with the keyboard alone, and for people with low vision.
If something gets in your way, please [open an issue](https://github.com/sinhong2011/triwarden/issues)
with the `accessibility` label.

## VoiceOver

- The sidebar, settings, edit sheet and login form are standard SwiftUI controls, so they read with their
  visible labels.
- Every icon-only button has a spoken label: favorite, edit, trash, restore, delete forever, lock,
  reveal/hide, copy *field*, generate password, remove field, clear search, retry Touch ID, open item.
- Vault rows, Quick Search results and AutoFill rows read as one element (name, then username or site),
  with the button trait. The selected vault row also has the selected trait.
- Watchtower and password strength never rely on colour alone. Each colour dot has a text label
  (“Weak”, “Reused in 2 items”, “Strong · unique”).
- Secrets are hidden by default and announced as secure text until you choose Reveal.

## Keyboard

| Action | Keys |
|---|---|
| Filter the vault list | ⌘F |
| Find items or run commands | ⇧⌘Space |
| Move through items | ↑ / ↓ in the item list |
| New login / secure note / folder | ⌘N / ⇧⌘N / ⌥⌘N |
| Edit item | ⌘E |
| Move to Trash | ⌘⌫ |
| Password generator | ⌘G |
| Command palette from anywhere | ⇧⌘Space by default (Settings › Shortcuts); ↑ / ↓ selects, ↵ opens, ⌘↵ copies password, ⌥↵ copies code, Esc closes. Over another app: ↵ types both fields, ⌃↵ username, ⌥↵ password, ⇧ also submits |
| AutoFill picker | type to search, ↑ / ↓, Return to fill or sign in |
| Lock | ⇧⌘L |
| Sheets and dialogs | Return confirms, Esc cancels |

With Full Keyboard Access on (System Settings › Keyboard › Keyboard navigation), Tab reaches every control.

## Contrast

The brand colour is the sky blue of the mascot's tail, #80C5EF. It is used as a **fill** (buttons, the vault mark,
selection) with navy text, and a deeper vivid sky carries blue **text** where it has to be readable on light
backgrounds (WCAG 2.2 AA, relative-luminance formula):

| Use | Light | Dark |
|---|---|---|
| White labels on primary buttons | white on flat #0F74B3: **5.04:1**; Increase Contrast uses navy on #80C5EF: **7.86:1** | same |
| Navy text on tail-blue selection | #0B2A40 on #80C5EF: **7.86:1** | same |
| Blue text / links / icons | #0F74B3 on #F2F2F7: **4.51:1** (5.04:1 on white) | #80C5EF on #1E1E1E: **8.85:1** |

All other text uses system semantic colours (`.primary`, `.secondary`), which follow macOS Increase Contrast.

## Motion

The animated dial, secret decoding, arrival effects and shared button, chip, segmented-control and copy-feedback
animations respect **Reduce Motion**. Shared controls use one animation policy; button press scaling is also disabled.

## Known gaps

- App windows, settings and the menu bar disable SwiftUI transaction animations with Reduce Motion.
  AppKit panels and system-provided animations still follow macOS behavior; a complete real-hardware walkthrough remains necessary.
- There is no automated accessibility test yet. Checks so far are code review plus snapshot review.
  A VoiceOver walkthrough on real hardware is tracked in the issues.
