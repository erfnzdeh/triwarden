# Saved tool first-use implementation plan

> Use the executing-plans skill to implement this plan in the existing local-secrets-agent worktree.

**Goal:** Help users configure, select, and repair a saved tool without an internal tool ID.

**Architecture:** Keep the existing saved-command and approval model. Add a terminal selection step before the existing launch path. Add tool recipes and repair actions to the app.

**Tech stack:** Swift, SwiftUI, SecretsAgent, Swift Testing, and native signed-app diagnostics.

## Design decision

The user approved the guided setup, saved-tool selection, and direct repair approach on 2026-10-24.
The alternatives were arbitrary command wrapping and a virtual environment file.
Arbitrary command wrapping needs a different authorization design.
A virtual environment file needs a separate file access design.
Neither alternative belongs in this change.

### Guided setup

- Keep npm projects, Node.js scripts, Python scripts, and custom programs.
- Add a Claude Code recipe with an explicit API billing explanation.
- Suggest the expected variable name when the user selects a recipe that specifies one.
- Show the detected executable and allow a different selection.
- Search fixed install locations only. Do not evaluate shell configuration or execute a detected program during discovery.
- Never infer a key's validity or provider from its contents.
- Preserve edited names and variable choices until the user explicitly changes the recipe.
- Load existing saved tools without changing their bindings or executable paths.

### Terminal selection

- With no arguments, `tw run` lists saved tools by name and project folder.
- Require a terminal on stdin and stderr. Refuse non-interactive selection with an exact launch instruction.
- Require an explicit number. Blank input, q, or EOF cancels without a launch.
- Show paused tools but refuse to launch them.
- Distinguish duplicate names. Use stable IDs internally.
- Read one input byte at a time to preserve input for the launched program.
- Recheck the selected saved settings before the normal launch checks.
- Print no key values, binding fields, saved arguments, or account details in the menu.

### Repair

- Show helper status in Tools and link directly to Terminal Helper Setup.
- Keep the install destination visible before the user copies a command.
- Offer Resume for a paused tool.
- Offer Unlock Account or Add Account when required.
- Offer a key selection action for a broken primary binding.
- Open the existing setup editor for additional binding repairs.
- Do not infer a provider failure from a launch error.

## Implementation tasks

1. Add failing package tests for selection, cancellation, duplicate names, paused tools, and safe menu output.
2. Add the selection model and wire the terminal reader into CLI/main.swift.
3. Add failing recipe tests for arguments, variable suggestions, and fixed discovery locations.
4. Add the recipe model and wire it into App/Sources/ToolLaunchSetup.swift.
5. Add typed repair reasons to ToolBrowserIndex and direct repair actions to ToolLaunchesPane.
6. Extend ToolsBrowserSelfTest with recipe, repair, non-interactive CLI, and terminal selection checks.
7. Build the signed app. Run package tests and isolated native checks.
8. Render synthetic light and dark layouts, including long names and repair states.
9. Update docs/local-secrets-dx.md and commit only this change.

Package tests: `swift test --package-path Packages/VaultCore`.
App build: `make build`.
Native checks: Run the built app with `--selftest-tools-browser`.
Signature check: `codesign --verify --deep --strict build/Build/Products/Debug/Triwarden.app`.

The Claude Code recipe follows the provider's documented `ANTHROPIC_API_KEY` behavior.
API key authentication can override subscription authentication and incur API charges.
Reference: [Anthropic documentation](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code).

## Limits and later work

Once remains the initial approval choice.
Keep signature verification, full catalog verification, account refresh, exact bindings, and the restricted target environment.
Add no API proxy, permanent API-key permission, API-key history, or shell startup changes.
Add no external code or 1Password assets.
This work does not include a patent clearance opinion.

The user also asked about environment files.
Plan a later reference-only `.env` mode for saved tools.
Define parsing, explicit variable binding, revision coverage, and failure handling before implementation.
Do not write actual key values into an environment file.
Do not claim that a raw-key environment or readable virtual file protects a key from its receiving program.

Synthetic tests verify behavior and layout. They do not establish first-use acceptance by an independent user.
