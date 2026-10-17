/** Site-wide facts in one place. Paths from `asset()` respect the deploy base (GitHub Pages: /triwarden/). */
const repo = "https://github.com/sinhong2011/triwarden";

// Live Stripe Managed Payments checkout. Komori fulfills signed keys after verified payment.
export const CHECKOUT_URL = "https://buy.stripe.com/8x2dRaaSJ1fS4y27r183C00";

export const SITE = {
  name: "Triwarden",
  repo,
  version: "0.1.1",
  /** One-time License price shown on the site. Must match Stripe and Komori before going live. */
  price: "US$19.99",
  // Fallback when the latest DMG can't be looked up (see release.ts).
  download: `${repo}/releases/latest`,
  api: "https://api.github.com/repos/sinhong2011/triwarden",
  // Always the newest DMG, once releases carry the stable-named copy (scripts/release.sh).
  latestDmg: `${repo}/releases/latest/download/Triwarden.dmg`,
  brew: "brew install --cask sinhong2011/tap/triwarden",
  security: `${repo}/blob/main/SECURITY.md`,
  /** Path under each locale; use `localeHref(locale, "pricing/")` in components. */
  pricingPath: "pricing/",
  privacyPath: "privacy/",
  licenseTermsPath: "license-terms/",
  checkout: CHECKOUT_URL,
  supportEmail: "triwarden@protonmail.com",
  support: "mailto:triwarden@protonmail.com",
  stripePrivacy: "https://stripe.com/privacy",
  resendPrivacy: "https://resend.com/legal/privacy-policy",
  googleFontsPrivacy: "https://policies.google.com/privacy",
  githubPrivacy: "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement",
  filmLength: "1:00",
};

export const asset = (path: string) => `${import.meta.env.BASE_URL.replace(/\/$/, "")}/${path.replace(/^\//, "")}`;
