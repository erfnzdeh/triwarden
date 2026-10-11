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
- Full click-through UI tests and a large import interrupted by an actual network/proxy failure. API integration and app end-to-end self-tests have now passed; deterministic accepted-write/lost-response and expired-session regression cases are covered.
- Visual review of the generated snapshots; no visual pass is claimed by this change.
