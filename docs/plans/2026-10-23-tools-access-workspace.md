# Tools and Access workspace

The user approved replacing full tool cards with a searchable list/detail workspace, testing 0/1/10/64 tools and 16 bindings, and moving SSH access management out of Developer settings into a separate **Access** sidebar destination.

## Design

- **Tools:** fixed header with name, search, status filter, alphabetical sort, Add Tool and Access entry. A selectable list shows tool name, project-folder summary, key count and availability. Wide content uses list/detail; narrow content navigates from list to detail with a visible Back action. Selection survives resizing and updates predictably after filtering/removal. Duplicate display names are distinguished by folder and stable shortcut.
- Detail shows just one tool: copy launch command, complete key/variable mappings with a View action for each key, clear locked/missing/reprompt repair information, Edit and a management menu for pause/resume/remove. Technical command details and helper setup are progressively disclosed. Adding a tool chooses a saved key within this workflow before opening the existing setup form.
- Build one indexed, reference-only presentation snapshot from profiles/items/unlocked accounts. Search covers display name, folder, key names, variables and shortcut; sorting uses display names with deterministic tie-breaks. Tools uses the vault's ScrollView/LazyVStack pattern; SSH history retains native List. Grant timers update only small live regions rather than rebuilding the browser each second.
- **Access:** current API-key approvals, temporary SSH grants including timed grants, persistent SSH permissions, and SSH-only history, clearly separated. Search and type filters support growing lists. Revocation affects the corresponding existing controller/store; global temporary revocation cancels pending work but explicitly preserves Always Allowed apps. Permanent removal uses a separate action. History clearing never revokes access; API-key history is not fabricated.
- Developer settings retain SSH enable/socket setup, CLI/browser integration, and a navigation link to Access. The new page reuses the existing SSH access-event row, controller and bounded 200-event log.
- Keep grant scopes, device-owner authentication, raw-key delivery and SSH signing semantics unchanged. No proxy, new server cipher type or automatic trust is introduced.

## Implementation and verification

1. Implement the pure ToolBrowserIndex/status/search/sort/selection helpers and a native isolated diagnostic covering large data and missing/locked/paused/ambiguous/reprompt cases.
2. Replace ToolLaunchesPane with adaptive list/detail views and per-key navigation; use an isolated preview fixture for list/detail state, search and filters.
3. Add AccessPane, wire sidebar/palette/settings navigation, move existing SSH rows out of Developer settings, and expose filtered active SSH trust for presentation without changing authorization.
4. Add synthetic 0/1/10/64-tool and 16-binding light/dark/compact previews and Access cases with active/expired permissions and 200 history records. Inspect representative renders and record developer measurements without claiming user research or provider acceptance.
5. Run native browser/Keychain diagnostics, relevant Secrets/SSH checks, signed Debug build, strict signature verification and diff checks. Fix selection, keyboard/focus, no-results and long-label issues before committing. Keep the existing worktree and branch for review.

## Implemented behavior

- Tools uses the same lazy selectable-row pattern as the vault, natural name sorting, search and status filters. The 780-point content breakpoint switches between list/detail and list-to-detail navigation; compact Back restores list focus. Command-F stays in the current Tools/Access workspace. Saving selects the tool just saved and clears obsolete filters; each key has its own vault destination, with the appropriate account and cleared vault filters. Locked accounts have an Unlock Account action. The Add Tool entry explains the 64-tool limit before another setup is started.
- The presentation index retains only item metadata and references, not credential values. Its readiness checks inspect the already-unlocked model; actual online refresh and authorization remain in the existing launch controller.
- Access sits beside Tools in the sidebar and command palette. Developer settings now link to it while retaining integration setup. Temporary API-key and SSH permissions, persistent SSH permissions and SSH history have distinct scopes and actions. Clearing history does not revoke permissions. Removing persistent SSH permission also removes that caller's cached temporary signing grants, leaving other apps alone. Failed permission persistence leaves the permission visible and reports the failure.
- Native previews exposed a visible segmented-picker label wrapping vertically and duplicate no-result placeholders; both were corrected. After user feedback, SSH history uses quiet text rows without colored icon tiles or outcome pills; denied requests alone use semantic red. Full record metadata remains available as a tooltip. The follow-up signed build passed and four wide/compact light/dark history renders cover all eight outcomes.

## Verification record — 2026-10-23

- Signed Debug build succeeded; strict recursive code-signature verification and `git diff --check` passed.
- The complete VaultCore run succeeded: suite summaries list 80 API, 28 crypto, 50 Secrets and 23 SSH tests; 19 server-dependent tests were explicitly skipped because no development server was configured. The new SSH regression covers removing every cached key for one caller while preserving another caller.
- 28 isolated native browser/access checks and 22 native Keychain/catalog checks passed. Persistence checks use temporary files and no real account, agent socket, SSH permission list or history file.
- The developer measurement for 100 searches across 64 synthetic tools / 1,024 bindings was approximately 56 ms on this Mac. This is a diagnostic measurement, not an end-user performance study or a benchmark over a large real vault.
- Synthetic native light/dark renders cover 28 layouts: empty, one, ten and 64 tools; compact list and 16-key detail; search misses, duplicate names, attention states and long names; Access permissions and 200-record history. Representative wide/compact, light/dark, repair, history and empty screens were inspected.
- This increment does not claim a new live Touch ID/provider test, real multi-account navigation acceptance or a manual keyboard/VoiceOver walkthrough. Those remain interactive acceptance work. No proxy or broader authorization was introduced.

## Toolbar and selection follow-up

User feedback identified mismatched toolbar heights and an opaque native-list selection. Tools and Access now share 32-point search/filter controls built from the vault's HeaderChrome and ActionMenu components. The Tools list uses Color.rowSelected, rounded row geometry and hover treatment matching the vault's ItemRow, without the system's gray selection background or list separators. It remains lazy, keeps the app's thin scroller, exposes selected/accessibility actions and scrolls keyboard selection into view. Search Down hands focus and selection into the list; arrows follow the filtered/sorted order and stop at its edges. Six additional stepping checks bring the isolated browser/access diagnostic to 34 checks. Synthetic account availability is shared between preview status and repair actions, avoiding a false Unlock action on a missing key in an unlocked fixture account.

Verification: the updated signed Debug build, 34 isolated checks, strict signature verification and diff check passed. All 28 synthetic layouts were regenerated; wide light/dark selection, compact toolbars, attention/repair states, Access history and long compact detail were inspected. The stepping checks exercise selection policy; they do not substitute for the pending manual keyboard/VoiceOver walkthrough.
