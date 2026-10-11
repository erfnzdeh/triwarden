# Sidebar context actions — proposal

Status: brainstorm, not implemented. Every selectable destination should have actions specific to its purpose. Section headings (Items, Vaults, Tools, Manage) remain labels.

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
