# Human acceptance of .env reference files

Date: 2026-10-24. Environment: the signed Debug app in the local-secrets-agent worktree.
The test used the documented disposable account and one dummy key. It did not use a provider key.

The first attempt did not complete. The diagnostic rejected the selected destination.
Do not count that attempt as a successful launch.

The second attempt exited with code 0 and no test failures.

- The native save panel saved a matching reference file.
- The file did not contain the dummy key value.
- The native approval and macOS authentication completed.
- The real signed CLI received the key and executed the canary command with exit code 37.
- The returned approval duration was tenMinutes.
- The same authenticated calling process reused this grant without another prompt.
- Explicit revocation removed the grant.
- A later request showed approval again. Denial prevented execution.
- Online refresh confirmed removal of the dummy vault item.
- The test removed its local files and Keychain record before exit.

This run verifies a ten-minute selection. It does not establish a new default.
The normal default remains Allow Once.
This run covers reference export and launch. It does not cover the new plaintext import interface.

The DEBUG-only entry point is `--selftest-secrets-env-interactive`.
It requires a desktop user for the save panel and macOS authentication.
The test checks the selected destination before writing its reference file.
It does not bypass device authentication or automate the user's approval.
