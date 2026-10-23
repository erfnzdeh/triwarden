# Product and UX priorities

The user's explicit priority is **user experience first**. Design from the user's perspective; improving their experience is a requirement, not a final visual polish step.

- Start with the user's goal, expected entry point, and complete journey before choosing screens or technical abstractions. Check both first use and routine use.
- Organize the product around user tasks. Saving and managing credentials belongs in the vault; Settings should hold integration setup and background behavior.
- Use language users understand. Explain concepts through concrete examples and outcomes. Do not require users to understand internal terms such as `profile`, field references, or environment injection before they can begin.
- Provide sensible defaults and guided setup. Reveal technical details progressively while keeping permission scope and security consequences clear.
- Connect each step to the next: after saving a key, show how to provide it to a tool; after configuring a tool, show how to use it again.
- Treat discoverability, clarity, effort, feedback, and recovery as part of feature correctness. A working backend or attractive panel alone does not make a workflow complete. Distinguish a design walkthrough from actual user testing when reporting validation.
- Use the app's existing `.thinScroller()` for scrollable views, including native Lists, Forms and picker lists. Keep the slim hover/scroll thumb consistent with the rest of the app; do not leave the system scrollbar or introduce a separate scrollbar design.
- Use the existing `AppSegmented` for segmented tabs and choices, including Access Permissions/History. Do not substitute the system segmented Picker or create another segmented-control style.
- Keep Access history visually quiet: app/key information on the left, outcome and its monochrome icon together on the right in a compact outlined badge (10pt text, 9pt icon), with the time below and outside the badge. The outcome icon and text share the same color. The group has no background fill; do not add separate icon tiles or colored outcome fills. Use color sparingly for meaningful exceptions rather than decorating every result.

For local API keys, use the journey **save a key → provide it to a tool/project → review authorization → use it again** as the product model. Keep Bitwarden/Vaultwarden compatibility and existing security protections underneath that experience.
