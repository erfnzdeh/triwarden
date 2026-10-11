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

- `make test`: passed, including import-delivery timeout and independent-account sync regression tests. Dev-server integration tests skip without `TRIWARDEN_DEV_HOST`.
- `make build`: passed with the configured signing identity. Existing deprecation and notification-concurrency warnings remain.
- `python3 scripts/test-make-exit-codes.py`: seven commands correctly rejected deliberately failing executables, including a stale build binary.
- New translation entries parse and preserve numeric placeholders in all five locales.
- `git diff --check`: passed.
- Debug snapshot rendering completed for selected login, vault and menu-bar screens in light and dark. The PNGs are in the app container's `Data/tmp/snapshots` directory. macOS denied this tool process access to the generated images, so visual review was not completed.

## Validation still requiring the appropriate environment

- Real VoiceOver / Full Keyboard Access walkthrough, Reduce Motion and Increase Contrast interaction checks.
- Full click-through UI tests and server-backed end-to-end tests, including interrupted large imports and expired sessions.
- Visual review of the generated snapshots; no visual pass is claimed by this change.
