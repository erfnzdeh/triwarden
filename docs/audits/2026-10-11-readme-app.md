# README and app audit follow-up

Base: `main`; branch: `codex/audit-improvements`.

## Changes

- Import requests are encrypted before delivery and sent once. A failed request stops subsequent batches and reports confirmed, uncertain and unsent item counts. The sheet retains that report while offering a read-only sync retry. Successful imports followed by failed sync remain successful imports; the UI explicitly warns against resending the file. Ambiguous requests cannot be safely resumed automatically without server idempotency support.
- Account sync failures remain visible after manual and background attempts. Authentication failures explain that sign-in is required. The existing inbox names affected accounts and offers retry; successful accounts still sync when another fails. The menu-bar green indicator requires recent successful syncs with no failed accounts, rather than any historical success. It represents recent server contact, not continuous network reachability.
- Sync payloads are decoded before replacing the encrypted disk cache.
- Local build, unit-test, UI-test, self-test and snapshot commands preserve failing exit codes. Build output is saved in `build/build.log`. Snapshot copy failures and empty output are no longer silently accepted. CI runs fault-injection checks for these commands, including the stale-binary case.
- Primary-button white labels use #0F74B3 (approximately 5.04:1); Increase Contrast retains navy on pale blue (approximately 7.86:1). The remaining system prominent prompt uses the shared accessible button style.
- Shared button, chip, segmented-control and copy-feedback animations use one Reduce Motion policy. Main windows, settings, the license window and the menu-bar surface also disable SwiftUI transaction animations under Reduce Motion.
- Installation and first-use instructions appear before the feature catalogue. README explains AutoFill, auto-type permissions, offline limitations and official-build payment/reminders. Keyboard and accessibility notes and implemented roadmap entries are aligned with current code.
- The toolbar distinguishes commands from the list filter, and shared header shadows are quieter. Existing three-column structure and native typography are preserved.
- New interface messages are translated into English, Traditional Chinese (Taiwan/Hong Kong), Simplified Chinese and Japanese.

## Validation

- `make test`: passed, including import-delivery timeout and independent-account sync regression tests.
- `make test-dev` against the configured LAN development stack: passed on both HTTPS Vaultwarden endpoints (18843 / 18844), including SSO against the separate OIDC stack. No dev-server test was skipped. The optional external breached-password lookup test remains disabled.
- Added server regression tests on both endpoints: a real import commits two batches, then an injected lost-response error stops delivery; sync confirms exactly those two batches, no duplicate and no third batch, followed by cleanup. A rejected refresh token on one client does not block a second authenticated client from syncing. The lost response is injected after a successful server write; no proxy-level packet-loss test is claimed.
- `make -o build selftest`: `SELFTEST OK`, 91 checks passed. This covers personal and organization import/export, account lifecycle, token restoration, multi-account behavior and live sync using isolated local test storage. Logs are retained in `build/audit-validation/integration.log` and `build/audit-validation/selftest.log`.
- `make build`: passed with the configured signing identity. Existing deprecation and notification-concurrency warnings remain.
- `python3 scripts/test-make-exit-codes.py`: seven commands correctly rejected deliberately failing executables, including a stale build binary.
- New translation entries parse and preserve numeric placeholders in all five locales.
- `git diff --check`: passed.
- Debug snapshot rendering completed for selected login, vault and menu-bar screens in light and dark. The PNGs are in the app container's `Data/tmp/snapshots` directory. macOS denied this tool process access to the generated images, so visual review was not completed.

## Validation still requiring the appropriate environment

- Real VoiceOver / Full Keyboard Access walkthrough, Reduce Motion and Increase Contrast interaction checks.
- A large import interrupted by an actual network/proxy failure. API integration and app end-to-end self-tests have passed; deterministic accepted-write/lost-response and expired-session regression cases are covered.
- Visual review of the generated snapshots; no visual pass is claimed by this change.

## Real desktop UI validation (2026-10-11)

Used the branch's signed Debug app through native UI automation with the disposable `usagi@chiikawarden.test` development account and the LAN HTTP endpoint (18880). This was a live account workflow, separate from demo snapshots and the isolated self-test runner.

| Workflow | Observed result |
| --- | --- |
| Add existing development account and sign in | Successful; initial All Items count 12 |
| Search and filter | `type:card` committed to a Cards chip and showed only Travel Visa; clearing filters restored the list |
| Create login | Empty editor disabled Save; synthetic login saved with username, password, URI and notes; count 13 |
| Edit login | Updated name and notes persisted in detail while other fields remained intact |
| Command palette | Search found the synthetic item and opened its detail |
| Manual sync | Sync Now showed a successful checkmark |
| Lock and unlock | Development account unlocked again and retained the created item |
| Import JSON | Native picker, preview of one login, Import and success summary completed; count 14 |
| Trash and restore | Confirmation named the synthetic item; Trash count 1; Restore returned All Items to 14 and emptied Trash |
| Cleanup and logout | Both synthetic items moved to recoverable Trash; normal list returned to 12; development account logged out and app returned to its original locked account screen |

### Findings

- **P2: Item toolbar accessibility labels inherit the first action's name.** With a login selected, Archive, Favorite, Edit and Move to Trash all expose Description `Reveal`, despite distinct Help text. With an identity selected, the same buttons expose `Archive`. In Trash, Delete Forever exposes `Restore`, with Help `Delete Forever`. Reproduced across three toolbar states; relevant construction is `HeroCard.actions` / `toolbarButton` in `App/Sources/VaultView.swift`. This can misidentify destructive actions to accessibility clients. Tooltips and click behavior were correct. No actual VoiceOver speech walkthrough is claimed, and this finding was subsequently corrected (see follow-up below).
- **Unconfirmed observation:** the sign-in server preflight briefly showed “Can't reach this server”, but the same endpoint then signed in successfully. A repeatable preflight failure has not been established.

The two synthetic records (`UI audit 20261011 edited` and `UI audit import 20261011`) remain recoverable in the development account's Trash. No existing account was unlocked or logged out. This smoke test does not cover all settings, SSO/TOTP login UI, AutoFill/auto-type, a real interrupted-network import, or every visual/accessibility mode.

## UI polish and password-fill follow-up

- Item actions now contain separately labeled buttons rather than allowing the toolbar to inherit its first action label. Verified with the live development account: Reveal, Archive, Favorite, Edit, Move to Trash, Restore and Delete Forever expose distinct names and retain button roles.
- Palette separators are inset and subtle. The initial opaque background adjustment was reverted after visual feedback; the palette now uses a native behind-window HUD material without an opaque tint, following further transparency feedback. The results scrollbar is hidden while scrolling and keyboard selection remain available. Item hints now use a primary-action row and a secondary-shortcut row, with a vertical fallback for longer translations. The light palette was visually reviewed through native UI capture.
- The panel now sizes itself to its card rather than keeping a 660-point transparent canvas. The hosting layer clips to the card corners and uses the native window shadow. This targets the large rectangular AppKit sheet-dimming backdrop shown in the reported screenshot.
- Password-fill focus handling checks an attached sheet before deciding to dismiss, allows time for the system service to appear, and restores focus when a canceled sheet returns to the original foreground application. Monitoring tasks are canceled when the palette closes. The actual right-click → AutoFill → Cancel flow still needs successful end-to-end verification; native UI automation was interrupted repeatedly and no pass is claimed for that path.
- `make build` and `git diff --check` passed. Added a targeted UI regression checking that five toolbar actions remain individually named buttons. The targeted XCTest run was interrupted by Codex/desktop windows and stopped; it is not recorded as passing. The manual live-account label checks above passed independently.
- Sidebar context-menu ideas were initially recorded in `docs/design/sidebar-context-actions.md`; the implementation is documented in the follow-up below.

## Sidebar context-target styling

- Existing My Folders, folder and shared-vault context menus now use a native menu surface with a subtle rounded target fill, replacing SwiftUI's thick context-preview outline. Opening the menu does not select or navigate to its target.
- Left clicks, scrolling, disclosure and drag/drop pass through to the existing sidebar. The same actions are exposed as accessibility custom actions; this change does not remove a keyboard focus ring. Destructive entries retain their confirmation flows and are colored red in the menu.
- The macOS-owned password-provider popup (Triwarden… / Passwords…) retains system styling.
- `make build` and `git diff --check` passed. Interactive verification was limited by changes to the active app during automation; no visual or keyboard-navigation pass is claimed for this final sidebar patch.

## Account unlock and complete sidebar actions (2026-10-11)

- Successful password or PIN unlock now selects the account actually unlocked. Touch ID retains an unlocked focus or chooses an unlocked displayed target. Startup's unlock chooser follows a valid saved account focus. A generation token supersedes old gate animations, preventing a delayed close from replacing a newly opened vault.
- All selectable sidebar destinations now have purpose-specific context actions described in `docs/design/sidebar-context-actions.md`. Shared collection creation encrypts with the organization key and includes the selected collection IDs. New editors inherit type, folder, Favorite state, and collection; several accounts require a destination choice before saving.
- Bulk operations capture item/account associations and show the account, vault and count before confirmation. Eligibility is checked again at execution; locked or changed targets are reported, and other accounts continue. Persistent partial-failure alerts advise syncing and inspecting before retrying. Restore uses a normal confirmation button; permanent deletion uses a destructive button.
- `make test-dev` passed: 70 VaultwardenAPI tests, 28 TriCrypto tests and 19 SSHAgent tests. New organization-creation integration coverage passed against ports 18843 and 18844 and verified organization-key decryption and collection membership. Only synthetic test records were deleted.
- The isolated in-app test passed all 101 checks, including startup account selection. Added regressions cover stale locked account focus, collection permissions, collection creation, explicit multi-account creation scope, restore with one account locked, and exclusion of items arriving after confirmation. The final Debug build also succeeded.
- Live native UI: the disposable development account unlocked and remained selected across subsequent interactions. Right-clicking Passkeys left the existing selection alone; Search Here selected Passkeys and focused search. Cards → New Card opened an unsaved card editor. Shared → New Secure Note opened an unsaved editor labeled Chiikawa Family / Shared. Both drafts were canceled. Trash → Restore Scoped Items showed exactly `usagi@chiikawarden.test — My vault: 2`; it was canceled without restoring or purging the preexisting synthetic trash items.
- Native UI capture showed the menus, but the desktop capture was distorted/scaled; no claim of a full visual/accessibility matrix is made. An initial Shift-F10 attempt exposed an overly strict outline-first-responder check; the implementation now uses the sidebar's selected destination and excludes text editing and modal sheets. Final live verification passed for SSH Keys: Shift-F10 exposed New SSH Key, Import SSH Key…, Search Here and SSH Agent Settings…, and Escape dismissed the menu. The reopened development account remained selected and unlocked.

## AutoFill material follow-up

- The extension now uses native behind-window HUD glass without a solid tint. Its light-mode content card uses a lighter translucent fill.
- SwiftUI and the credential provider now agree on a 440 × 480 content size, reducing excess vertical space.
- End-to-end system AutoFill presentation still needs live verification; building the extension does not confirm which registered app copy macOS will host.

## Toolbar menus and Settings visual consistency

- Palette results use `.scrollIndicators(.never)` so the system's Always preference cannot force a wide scrollbar; `.hidden` had still allowed it. Settings grouped Forms hide their opaque scroll backgrounds, use the app's pastel backdrop, and opt into the existing thin scroller.
- New Item, Filters and Sort share a custom toolbar popover with fixed symbol and checkmark columns, soft brand-tint hover, disabled actions, and keyboard navigation. Folder/vault choices use nested pages with Back; keyboard selection scrolls into view.
- Live development-account checks: Filters opened and keyboard Down/Return applied Cards; the temporary filter was cleared. New Item opened and keyboard Down/Return launched an unsaved Secure Note editor, which was canceled. Sort displayed Title and A to Z as selected. Native capture remained distorted, so a complete visual pass and live Settings background confirmation are not claimed.
- Debug build passed; no existing vault records were written during these checks.
