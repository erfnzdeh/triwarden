# Easier copying in item details

Approved direction: give usernames a labeled row with a visible Copy action; expose separate Copy and Open actions for websites; enlarge field copy targets and show a checkmark with Copied feedback. Keep long values selectable and preserve guarded copying and clipboard expiry for sensitive values.

Keep the existing card hierarchy. Move the username out of the combined header subtitle into its own row in the hero card. Keep the host as context below the item name. Use a shared copy button for username, item fields, websites, and notes. Website copying must preserve the complete original address; browser opening remains a separate action. Masked fields remain masked and use the existing master-password guard.

Validation: compile the macOS app, run focused copy UI tests where available, and inspect light/dark snapshots for readable controls and long values.

## Visual refinement — 2026-10-16

User feedback: the filled Copy button is visually heavy and the username row has too much empty space. Use a persistent, secondary copy icon with a 32-point hit area and a subtle hover background. Keep the field-specific accessibility label, tooltip, and checkmark confirmation. Align the action to the center of the complete label/value group and reduce their spacing. Apply the same icon treatment to the website Open action.
