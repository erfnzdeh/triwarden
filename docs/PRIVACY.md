# Privacy

The canonical privacy policy for users is on the website: `/privacy/` (and each locale prefix).

Summary (aligned with the app and site code):

- Vault data stays on **your** Vaultwarden / Bitwarden server; Triwarden decrypts on the Mac.
- On the Mac: encrypted local cache, Keychain (unlock, sessions, license if registered), and standard preferences —
  not for analytics.
- Stripe processes checkout and sends the customer name, email and order/payment details to Triwarden’s Komori
  license service. Komori stores the order, signed license and delivery record, then Resend emails the key. Neither
  Komori nor Triwarden receives card details. See [Stripe Privacy](https://stripe.com/privacy) and
  [Resend Privacy](https://resend.com/legal/privacy-policy).
- The app verifies the signed license key locally. It never sends the key or an installation identifier to Stripe,
  Komori or another license server.
- Sparkle may check GitHub for updates when enabled. See
  [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
- Watchtower queries Pwned Passwords with five characters of a SHA-1 password hash, never the password or
  complete hash. It can download 2FA Directory data and query saved sites for change-password pages.
- Enabled website icons send domain names to the account’s configured Vaultwarden or Bitwarden icon service.
- The marketing site is static; it may fetch public GitHub release/star metadata, loads Google Fonts
  ([Google Privacy Policy](https://policies.google.com/privacy)), and stores light/dark theme in `localStorage` only.
- For privacy questions, email [triwarden@protonmail.com](mailto:triwarden@protonmail.com).
