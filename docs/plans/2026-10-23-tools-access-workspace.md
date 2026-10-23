# Tools and Access workspace

The user approved replacing full tool cards with a searchable list/detail workspace, testing 0/1/10/64 tools and 16 bindings, and moving SSH access management out of Developer settings into a separate **Access** sidebar destination.

## Design

- **Tools:** fixed header with name, search, status filter, alphabetical sort, Add Tool and Access entry. A native selectable list shows tool name, project-folder summary, key count and availability. Wide content uses list/detail; narrow content navigates from list to detail with a visible Back action. Selection survives resizing and updates predictably after filtering/removal. Duplicate display names are distinguished by folder and stable shortcut.
- Detail shows just one tool: copy launch command, complete key/variable mappings with a View action for each key, clear locked/missing/reprompt repair information, Edit and a management menu for pause/resume/remove. Technical command details and helper setup are progressively disclosed. Adding a tool chooses a saved key within this workflow before opening the existing setup form.
- Build one indexed, reference-only presentation snapshot from profiles/items/unlocked accounts. Search covers display name, folder, key names, variables and shortcut; sorting uses display names with deterministic tie-breaks. Native List virtualizes rows. Grant timers update only small live regions rather than rebuilding the browser each second.
- **Access:** current API-key approvals, temporary SSH grants including timed grants, persistent SSH permissions, and SSH-only history, clearly separated. Search and type filters support growing lists. Revocation affects the corresponding existing controller/store; global temporary revocation cancels pending work but explicitly preserves Always Allowed apps. Permanent removal uses a separate action. History clearing never revokes access; API-key history is not fabricated.
- Developer settings retain SSH enable/socket setup, CLI/browser integration, and a navigation link to Access. The new page reuses the existing SSH access-event row, controller and bounded 200-event log.
- Keep grant scopes, device-owner authentication, raw-key delivery and SSH signing semantics unchanged. No proxy, new server cipher type or automatic trust is introduced.

## Implementation and verification

1. Implement the pure ToolBrowserIndex/status/search/sort/selection helpers and a native isolated diagnostic covering large data and missing/locked/paused/ambiguous/reprompt cases.
2. Replace ToolLaunchesPane with adaptive list/detail views and per-key navigation; use an isolated preview fixture for list/detail state, search and filters.
3. Add AccessPane, wire sidebar/palette/settings navigation, move existing SSH rows out of Developer settings, and expose filtered active SSH trust for presentation without changing authorization.
4. Add synthetic 0/1/10/64-tool and 16-binding light/dark/compact previews and Access cases with active/expired permissions and 200 history records. Inspect representative renders and record developer measurements without claiming user research or provider acceptance.
5. Run native browser/Keychain diagnostics, relevant Secrets/SSH checks, signed Debug build, strict signature verification and diff checks. Fix selection, keyboard/focus, no-results and long-label issues before committing. Keep the existing worktree and branch for review.
