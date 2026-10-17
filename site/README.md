# Triwarden website

Astro + Tailwind CSS v4, with GSAP for motion. Static output for any host.

```bash
cd site
pnpm install
pnpm dev        # http://localhost:4321/
pnpm build      # → dist/
```

Optional deploy config:

- `SITE_URL`: canonical site origin for sitemap/canonical URLs (for example `https://example.com`)
- `SITE_BASE_PATH`: base path prefix (defaults to `/`)

GitHub Actions CI/CD (`.github/workflows/site.yml`) uses:

- Repository variables:
  - `SITE_URL` (optional)
  - `SITE_BASE_PATH` (optional)
  - `CLOUDFLARE_PAGES_PROJECT` (required for deploy)
- Repository secrets:
  - `CLOUDFLARE_API_TOKEN`
  - `CLOUDFLARE_ACCOUNT_ID`

- `src/config.ts`: one-time License price (US$19.99), download and Homebrew links, version, support email, and the live Stripe
  Payment Link (`CHECKOUT_URL`). `asset()` prefixes the deploy base.
- `src/styles/global.css`: brand tokens in `@theme` (so `text-ink`, `bg-sky`, `font-serif` … exist as utilities),
  plus the bespoke widget styles (dial, vault window, palette, terminal) under `@layer components`.
- i18n with [Paraglide JS](https://inlang.com/m/gerre34r/library-inlang-paraglideJs): messages in `messages/<locale>.json`
  (en, zh-hant, zh-hk, zh-hans, ja — the app's five languages, using the app's own terms), compiled to
  `src/paraglide/` on build. English is at `<base>/`, the rest at `<base>/<locale>/`; `src/middleware.ts` sets the
  locale per page and `src/i18n.ts` lists the languages. Add a string to every locale file, then use `m.key()`.
- `src/components/*.astro`: one per section; each loads its own script from `src/scripts/`.
- Standalone pages (each locale): `/pricing/` (purchase), `/privacy/`, `/license-terms/` — linked from the footer
  and nav. The home page still has a `#pricing` section for the landing scroll.
- `src/scripts/dial.ts`: the three-ring dial, same geometry as `Design/AppIcon/generate.py`.
- `src/scripts/shader.ts`: live WebGPU backdrops (hero, screenshot stage, closing panel) from the MIT
  [`shaders`](https://github.com/shader-effects-inc/shaders) library, as brand-blue presets per theme. Telemetry is off,
  it loads only near the viewport once the page is idle, and each element's CSS background is the fallback for
  browsers without WebGPU. `astro.config.mjs` (`SHADERS_USED`) bundles only the effects the presets use; add a name
  there when a preset starts using a new one.
- `public/media/`: the film and its poster, rendered from `promo/`.
- SEO: `layouts/Base.astro` writes the canonical URL, hreflang alternates, Open Graph and Twitter cards
  (`public/assets/og.jpg`, 1200×630, cut from the film poster) and any `jsonLd` a page passes: the home page sends
  SoftwareApplication (with the price) and FAQPage, the guide TechArticle and BreadcrumbList. `@astrojs/sitemap`
  writes `sitemap-index.xml` with the language alternates. A project site can't serve `robots.txt` (crawlers only
  read it at the domain root), so submit the sitemap in Google Search Console and Bing Webmaster Tools instead.

App UI is only ever shown as real captures, never imitated in HTML. `public/assets/shots/<name>-light|dark.webp` come from
`make build`, then `build/Build/Products/Debug/Triwarden.app/Contents/MacOS/Triwarden --demo-full --shoot -appearance
light` (and `dark`), converted with `cwebp`; `src/shots.ts` lists their sizes and `<Shot>` shows the one matching the
page's light/dark mode. Honours `prefers-reduced-motion`.
Brand rule: the tail sky `#80C5EF` is a fill only; text and icons stay navy ink.
