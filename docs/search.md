# Search

The search field above the item list (⌘F) looks through every vault you can see: your own, each shared vault, and
every open account. Each word you type has to appear in an item's name, username or website, in any order:
`git alex` finds GitHub (alexchen).

## Filters

Filters narrow the list further and **stay on between launches** until you clear them. Each one shows as a chip under
the field; its ✕ takes it off, and **Clear** takes them all off. The filter menu beside the field (its icon fills
while a filter is on) lists them all, with how to type each one.

| Filter | Type it as | Also understood |
| --- | --- | --- |
| Logins | `type:login` | `type:password` |
| Cards | `type:card` | |
| Identities | `type:identity` | `type:id` |
| Secure notes | `type:note` | |
| SSH keys | `type:ssh` | `type:key` |
| A folder (and its subfolders) | `folder:Work` or `#Work` | `folder:"Home Office"` for names with spaces |
| Favorites | `is:favorite` | `is:fav`, `is:starred` |
| Has a one-time code | `has:otp` | `has:code`, `has:2fa` |
| Has a passkey | `has:passkey` | |
| Watchtower issue (weak, reused or exposed password) | `is:weak` | `is:reused`, `is:exposed`, `has:issue` |
| One vault | `vault:personal` or `vault:Northwind` | `in:Northwind`; `vault:all` for every vault |

A filter turns into a chip when you type a space after it, or press Return. While you type one, suggestions appear
under the field: ↑ ↓ to pick, Return or Tab to take it, Esc to close them. A folder or vault name that doesn't exist
stays part of the search text, so searching for `#hashtag` still works.

## Keys

| Key | In the search field |
| --- | --- |
| ⌘F | Go to the search (from any page) |
| ⌫ | With the field empty: take off the last filter |
| Esc | Close the suggestions, then clear the text, then take the filters off |
| ↓ | Into the list (or down the suggestions) |
| ⇧⌘Space | The command palette, for searching and running commands, in Triwarden or any other app |

Every other shortcut is in **Help › Keyboard Shortcuts** (⌘/).
