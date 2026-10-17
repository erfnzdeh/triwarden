# Website copy audit — 2026-10-10

## Scope and result

Reviewed all 370 message keys in English, Traditional Chinese (Taiwan), Traditional Chinese (Hong Kong), Simplified Chinese and Japanese, covering the homepage, pricing, license terms, privacy and SSH agent guide. Implemented revisions locally; no deployment or checkout transaction performed.

Compared with the start-of-audit snapshot, changed 103 English, 104 Taiwan Traditional Chinese, 175 Hong Kong Traditional Chinese, 114 Simplified Chinese and 103 Japanese entries, including two new privacy entries per locale. Unchanged entries were retained after review.

## Findings and implemented recommendations

| Finding | Implemented change |
| --- | --- |
| “Worth keeping” wording left the payment trigger unclear. | State personal use is free, with an optional one-time purchase to support development; state work/commercial licensing separately and visibly. |
| “From” pricing implied multiple prices. | Display US$19.99 consistently, with no subscription or premium-feature implication. |
| Free use sounded like a time-limited trial. | Explain unlimited personal use and reminders after 30 days, at most weekly. |
| Device and company-use wording could conflict. | One person, unlimited Macs including company Macs; each user needs their own license for work/commercial use. No sharing, resale or transfer. |
| Checkout copy listed unconfirmed payment methods. | Say available methods and applicable taxes appear at checkout. |
| “Never phones home” and “connects once” omitted actual requests. | Explain activation per Mac or re-registration, locally cached successful activation, and no periodic revalidation. Add Watchtower, 2FA Directory and website-icon requests. |
| Security copy promised hardware protection too broadly. | Qualify hardware/Touch ID support and describe available authentication alternatives. |
| Auto-Type, autofill, history and offline claims were too absolute. | Describe permissions, supported contexts, retained/recent history and cached offline items; distinguish server-dependent operations. |
| SSH guide implied that keys could never leave the app. | Describe the agent returning signatures without transmitting the private key, and configurable approval behavior. |
| Update and copy-error text did not match behavior. | Describe opt-in update checks/Homebrew upgrades; show an honest copy failure message. |
| Hong Kong copy mixed registers and terminology. | Use consistent written Traditional Chinese with Hong Kong vocabulary. |

## Evidence and validation

Checked claims against License.swift, AccountStore.swift, CLIBridge.swift, SSHAgentService.swift, CipherEditor.swift, Watchtower.swift, PwnedPasswords.swift and Icons.swift, plus site scripts/components. Updated docs/PRIVACY.md to match network behavior. License policy and macOS 26 minimum remain as previously agreed.

- Production site build passed: 25 static pages.
- All five locale files parse, contain the same 370 keys and have matching interpolation parameters.
- Rendered text in all 25 pages contains no unresolved copy variables or `undefined` values.
- `git diff --check` passed.
- Visually checked the updated Traditional Chinese pricing page in the local browser.

## Before launch

The existing checkout configuration is explicitly marked TEST MODE. Replace/verify the production checkout before accepting real purchases. This audit does not establish which payment methods are enabled or introduce a refund window. The build also reports an existing large JavaScript chunk warning; it does not block generation of the pages.

## Payment update — 2026-10-17

The test Lemon Squeezy checkout was replaced by the live Stripe Managed Payments link. Komori now validates paid
Checkout Sessions, signs Triwarden licenses and sends them through Resend. The app verifies signed keys locally and
no longer sends license or installation data to a license provider.
