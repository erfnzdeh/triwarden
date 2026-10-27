# Releasing

Releases are automatic once the one-time setup is done:

1. Commits on `main` use [Conventional Commits](https://www.conventionalcommits.org): `feat: …`, `fix: …`,
   `perf: …`, `security: …`, `ui: …` show up in the changelog; `docs:`, `chore:`, `test:` don't. `feat!:` or a
   `BREAKING CHANGE:` footer marks a breaking change (before 1.0 that bumps the minor version).
2. [release-please](https://github.com/googleapis/release-please) keeps a **release PR** open with the next version
   (in `project.yml`) and `CHANGELOG.md`. With `include-commit-authors` in `release-please-config.json`, each
   entry ends with `(@username)` when GitHub knows the author (otherwise the author name).
3. Merging the release PR tags `vX.Y.Z` and creates the GitHub release. The `build` job in
   `.github/workflows/release.yml` then runs `scripts/release.sh X.Y.Z --publish`:
   - archive a Release build (build number = commit count);
   - Developer ID export, signature check, notarize and staple the app and the DMG (built with
     [dmgbuild](https://github.com/dmgbuild/dmgbuild) from `scripts/dmg-settings.py`; the window background comes
     from `python3 Design/DMG/generate.py`; by hand you need `pipx install dmgbuild`);
   - sign the zip for Sparkle and write `appcast.xml`, with this version's `CHANGELOG.md` section embedded as the
     release notes the update window shows (`scripts/release-notes.py`);
   - upload the DMG, the zip, `appcast.xml` and the Homebrew cask (`triwarden.rb`) to the release;
   - push the cask to `Casks/triwarden.rb` in `sinhong2011/homebrew-tap`.
4. Installed copies with automatic checks on find the update through
   `https://github.com/sinhong2011/triwarden/releases/latest/download/appcast.xml`. They verify the EdDSA
   signature and the notarization, install, and relaunch. Everyone else gets it from **Check for Updates…**.

## One-time setup (maintainer)

These are your credentials, so run each step yourself. Nothing secret goes into the repository.

### 1. Update-signing key (Sparkle)

```bash
make sparkle-keys
```

This creates an EdDSA key pair in your login keychain and writes the **public** key to `project.yml`
(`SPARKLE_PUBLIC_KEY`). Commit that change. Back up the private key; without it, installed copies can't verify
any future update:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

### 2. GitHub secrets for the `release` environment

Create an environment named `release` (Settings › Environments) and add the secrets:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_P12` | Your *Developer ID Application* certificate and key, exported as .p12, base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12 export password |
| `ASC_KEY_P8` | An App Store Connect API key (Users and Access › Integrations; role *Admin* — creating Developer ID provisioning profiles needs it), the .p8 contents |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | That key's ID and the issuer ID |
| `SPARKLE_PRIVATE_KEY` | The contents of `sparkle-private-key.txt` from step 1 (then delete that file) |
| `HOMEBREW_TAP_DEPLOY_KEY` | The private half of a write deploy key on `sinhong2011/homebrew-tap` (see [Homebrew](#homebrew)) |

For example:

```bash
gh secret set DEVELOPER_ID_P12 --env release < <(base64 -i DeveloperID.p12)
gh secret set SPARKLE_PRIVATE_KEY --env release < sparkle-private-key.txt
```

The API key lets CI create the Developer ID provisioning profiles (App Group, AutoFill, Safari extension) and
notarize, without an Apple ID or password.

### 3. Licenses (Fork-style: paid, never locked)

Every feature works unregistered and there's no time limit. An unregistered official build asks at launch, no
more than once a week and never in the first week, whether the user wants to buy a license. Debug builds, and
any build without `TW_STORE_URL`, never ask.

Every purchased key is an Ed25519-signed payload. Triwarden verifies it on the Mac and makes no activation request.
Stripe handles checkout; Komori validates the paid Checkout Session, signs one product-scoped key and sends it through
Resend. Refunds are recorded by Komori, but an already-issued offline key cannot be revoked remotely.

1. Keep the one-time Stripe product at **US$19.99**, quantity one. The live Managed Payments link is set as
   `TW_STORE_URL` in `project.yml` and `CHECKOUT_URL` in `site/src/config.ts`. Keep both values identical.
2. Keep Komori’s live `triwarden` product, Stripe price mapping and `triwarden-live` signing identity enabled. The
   private seed belongs only in Komori’s fulfillment secret. `TW_LICENSE_PUBLIC_KEY` must match that identity.
3. In Stripe, keep the Komori snapshot webhook enabled for Checkout completion, delayed payment, expiry and refund
   events. Komori must run its API and fulfillment worker; the worker needs both private and egress networks.
4. Before release, complete one real checkout. Confirm Stripe reports payment, Komori shows one paid order and issued
   license, Resend accepts the email, and the emailed key activates in the release build without a network request.

A key is for **one person** on all their Macs. It is not for resale or team sharing — see
[LICENSE-TERMS.md](LICENSE-TERMS.md).

## Releasing by hand (fallback)

On your Mac, with an Xcode account for team `FX3VR69P5K` and notary credentials in your keychain:

```bash
xcrun notarytool store-credentials triwarden-notary --apple-id <you@example.com> --team-id FX3VR69P5K
scripts/release.sh 0.3.0 --publish
```

This uploads to the release `v0.3.0` if release-please made it, and creates the release otherwise. To try a local
build without notarizing or publishing: `ALLOW_DIRTY=1 scripts/release.sh 0.3.0 --skip-notarize`.

## Homebrew

Each release pushes its cask to `Casks/triwarden.rb` in
[sinhong2011/homebrew-tap](https://github.com/sinhong2011/homebrew-tap), using the `HOMEBREW_TAP_DEPLOY_KEY` secret
in the `release` environment: the private half of a deploy key that can write to that repository only. To replace
it, make a new key pair, add the public key to the tap under Settings › Deploy keys with write access, and store the
private key as that secret. Users run `brew install sinhong2011/tap/triwarden`. The cask also links `tw` onto the PATH. Homebrew users can update
with `brew upgrade` or in the app; both work.

## CI and release gates

`CI` runs for every PR and main push so required checks also finish on site-only changes. It runs VaultCore
unit tests, HTTPS integration tests against disposable native Vaultwarden 1.35.0 and 1.30.5 servers, the app
build, an offline compatibility self-test and two UI smoke tests. No development server or signing secrets
are used. `Build app` fails if either the unit or server tests fail, even if its own build could succeed.
The server source revisions and Rust toolchains are pinned in `.github/workflows/ci.yml`; update them
explicitly when adding a new compatibility baseline. UI smoke tests cover demo launch/lock and edit/cancel;
they do not replace the broader manual UI, browser interoperability or physical Touch ID checks.

Release automation starts only after successful **push CI on main**. A stale success from an older main
commit is ignored. Manually rerunning a version tag first validates that the tag belongs to main, then runs
the same CI against its exact commit before the release environment can be used. Historical tags predating
the compatibility entry point skip that check; UI smoke tests must exist for the tag to be re-released with
this workflow (backport them or use the documented local fallback for historical releases).

The Main ruleset requires a pull request and successful `VaultCore tests` and `Build app` checks with an
up-to-date branch, and prevents branch deletion and force pushes. Site deployment has its own build dependency.

GitHub requires a maintainer to approve workflow runs on release PRs created or updated using `GITHUB_TOKEN`.
An `action_required` run with no jobs is this approval gate, not a failed build. Review the release PR and use
**Approve workflows to run** before merging it. This repository retains that approval instead of weakening
workflow security or introducing a long-lived personal token.
