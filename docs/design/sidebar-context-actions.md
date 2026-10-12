# Sidebar context actions — proposal

Status: implemented on `codex/audit-improvements` (2026-10-11). Every selectable destination should have actions specific to its purpose. Section headings (Items, Vaults, Tools, Manage) remain labels.

| Destination | Suggested actions |
| --- | --- |
| All Items | New Item submenu; Search Here; Sync active account scope |
| Favorites | New Favorite submenu; Search Favorites |
| Logins | New Login; Search Logins |
| Passkeys | Search Passkeys; AutoFill Settings; explain that a passkey is created from its website/app registration flow |
| Cards | New Card; Search Cards |
| Identities | New Identity; Search Identities |
| Secure Notes | New Secure Note; Search Notes |
| SSH Keys | New SSH Key; Import SSH Key; SSH Agent Settings |
| My vault | New Item Here; Import Here; Sync owning account |
| Organization | Search Here; Sync owning account; Copy Name; Open Organization Web Vault when a verified destination is available |
| Collection, e.g. Shared | New Item Here when writable; Search Here; Copy Name; management only when permitted |
| Send | New Text Send; New File Send; Show Expired Sends |
| One-Time Codes | New Login with TOTP; Search Codes |
| Generator | Generate Password; Generate Passphrase; Generator Settings |
| Watchtower | Run Checks; View Weak Passwords; View Reused Passwords; View Breached Passwords |
| My Folders | New Folder; Search Folders |
| Individual folder | New Item Here; New Subfolder; Search Here; Rename; Delete Folder with explicit explanation of item handling |
| Archive | Search Archive; Restore Scoped Items… |
| Trash | Search Trash; Restore Scoped Items…; Empty Scoped Trash… |

## Interaction rules

- Right-click targets the clicked destination without navigating away. Bind its immutable scope to the menu action; never infer the target from the previously selected row.
- Keep creation first, search/navigation second, management last. Separate destructive actions visually and use the destructive role.
- Creation inherits type, folder, favorite, vault and collection where appropriate. If the scope contains several accounts, choose a destination explicitly before saving.
- Search Here opens that scope with the search field focused; it must not silently reset the account scope.
- Organization/collection permissions determine available actions. Explain unavailable creation; avoid implying that organizational settings are editable by ordinary members.
- Bulk restore or purge resolves the selected scope to a snapshot of item IDs. Show account, vault and item count in confirmation, and do not expand the action to another account if the filter changes.
- Never put bulk secret copy, reveal, or unencrypted export in a convenience menu. Export stays in its established flow.
- Empty Trash requires explicit irreversible confirmation. Empty scopes disable bulk actions.
- Support keyboard context-menu invocation, native menu accessibility labels, and localized labels. Keep menus short; avoid a generic Settings entry on every row.

## Suggested rollout

1. Type-specific creation and scoped search on Items, Vaults and collections; Send and Generator creation shortcuts. These reuse existing flows.
2. Tool-specific settings and Watchtower filters; folder parity.
3. Scoped bulk Restore and Empty Trash, after preview/count/permissions and partial-failure handling are implemented.

## Verification scenarios

Right-click a row different from the current selection; multiple accounts with the same folder or collection name; read-only collection; empty scope; locked account; long translated labels; keyboard menu access; server failure during a bulk action; scope changes while a confirmation is open. Confirm irreversible actions only against explicitly disposable test data.

## Implementation notes

- `SidebarActions.swift` captures account IDs, vault filters, and the clicked destination when a menu opens. Search opens the captured destination; ordinary navigation or changing the account/vault filter releases that temporary scope.
- Native `NSMenu` supplies menus and submenus. Context targets use a subtle fill; normal outline keyboard focus remains available. Shift-F10 and the Menu key invoke the selected row's menu, and VoiceOver exposes each enabled action.
- Creation uses the existing editor. Multiple accounts require an explicit account choice; filtered shared vaults require a writable collection. Folder and Favorite defaults are inherited. SSH import parses an unencrypted private key into the editor without saving it automatically.
- Collection write/manage flags come from sync, with owner/admin fallback for older servers. Creation is also checked against the session's current permissions before the request is sent. Organization creation encrypts with the organization key and submits the selected collection IDs to `/ciphers/create`.
- Send shortcuts open the appropriate composer; its account choice remains explicit in a multi-account scope. Expired Sends can toggle back to all Sends. Creation shortcuts stay disabled while a Send draft is open so they cannot replace unsaved input. Generator Settings opens the full generator page containing its options. Passkey creation stays in the website/app registration flow.
- Restore and Empty Trash freeze only item IDs and account associations before confirmation. Confirmation lists account email, vault names, and count. Execution rechecks eligibility, skips changed or locked targets, continues other accounts, and presents persistent partial-failure details. Failed writes are not automatically replayed.
- English, Traditional Chinese, Hong Kong Chinese, Simplified Chinese, and Japanese labels are included.

## Validation

- Debug app build passed.
- VaultCore development-server tests passed, including collection creation and decryption on both latest and older Vaultwarden servers.
- The in-app self-test covers stale account focus after unlock, collection permissions, collection creation, multi-account creation defaults, and frozen bulk restore scope with a locked account. Final results and live UI observations are recorded in the audit report.
