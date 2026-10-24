# Import API keys from an .env file

## User task

Move existing keys into a Bitwarden vault. Then select a saved command that receives these keys after approval.

1. Open Tools and select Import .env File.
2. Select one local file. Review variable names with masked values.
3. Select the keys and the destination account. Save ordinary API-key Secure Notes.
4. Confirm the imported values through an online vault refresh.
5. Set up a tool with these keys and the source project folder.
6. Test the saved launch. Remove old plaintext assignments in the user's editor after this test succeeds.

The first slice keeps the source file unchanged. It does not create a plaintext backup or a temporary plaintext file.
Automatic source cleanup needs a separate design for atomic replacement and concurrent edits. It is not part of this slice.
The completion view must state that plaintext remains. It must explain that an empty assignment can override a supplied key.

## Input rules

- Read one regular UTF-8 file, at most 256 KiB, with at most 256 assignments.
- Support single-line literal assignments, an optional export prefix, quotes, and comments.
- Reject duplicate variable names and malformed assignments. Never include rejected values in errors.
- Do not evaluate shell text, substitutions, or variable expansion.
- Disable unsupported values and program-control variables. Do not select public variables or ordinary settings by default.
- Accept 1 to 16 selected values, at most 32 KiB in total.
- Do not scan other files or directories.

## Delivery rules

Use the existing encrypted import batch. Do not retry an uncertain write.
Give this batch a random identifier in a custom field. Match each returned item by this identifier and variable name.
Compare the returned value with the selected value. Do not match items by their names.
If delivery or refresh fails, offer a refresh check. Keep the source file and block another send from this sheet.
If the account locks, clear the loaded values and require the user to open the file again.
Tool setup and key delivery retain the existing command, caller, revision, and macOS authentication checks.
The approval default remains Allow Once.

## Validation

Add parser and import-payload tests before implementation. Test duplicate names, shell syntax, limits, public settings, and non-regular files.
Run the package suite, signed app build, native self-tests, and masked light/dark previews.
Use only dummy keys and the documented disposable account for online checks.
Record human authentication separately from simulated authorization tests.

## Results

- The complete package suite reports no failures. Development-server suites without server configuration skip their online tests.
- The signed Debug app builds. Strict signature verification succeeds.
- The native Secrets checks report no failures. The stale text assertion now checks that unconfirmed settings cannot create a socket.
- The online importer saves two dummy keys through the normal encrypted batch and confirms both exact values.
- This check also covers unchanged source bytes, compatible items, tool setup references, repeated-send prevention, and clearing pending values.
- The test removes its dummy vault items and confirms removal through online sync.
- Synthetic light and dark renders cover the masked import review. They are not human usability acceptance.
- Human reference-file acceptance completed separately. See the [record](2026-10-24-env-reference-acceptance.md).
