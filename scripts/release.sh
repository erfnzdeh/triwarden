#!/usr/bin/env bash
# Build a signed, notarized Triwarden release.
#
#   scripts/release.sh 0.3.0            # archive, Developer ID export, notarize, staple, zip + dmg (+ Triwarden.dmg, a
#                                       #   stable-named copy for the website's releases/latest/download link)
#   scripts/release.sh 0.3.0 --publish  # …and create the GitHub release (draft) with the artifacts
#   scripts/release.sh 0.3.0 --skip-notarize   # local dry run
#
# Normally CI runs this when a release-please PR is merged (.github/workflows/release.yml); it uploads to the
# release that release-please created. Run it by hand only as a fallback.
#
# Signing in to Apple, either:
#   local: your Xcode account + `xcrun notarytool store-credentials triwarden-notary --apple-id … --team-id FX3VR69P5K`
#          (archive uses project.yml Automatic + Apple Development; export uses Automatic Developer ID)
#   CI:    an App Store Connect API key: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#          (imports Developer ID .p12; release.sh fetches MAC_APP_DIRECT profiles and archives with Manual
#           Developer ID so runners never mint Mac/Apple Development certificates)
# Sparkle update signature: the EdDSA private key from your keychain (`make sparkle-keys`), or SPARKLE_KEY_FILE in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [--publish] [--skip-notarize]}
shift
PUBLISH=0; NOTARIZE=1
for arg in "$@"; do
  case $arg in --publish) PUBLISH=1 ;; --skip-notarize) NOTARIZE=0 ;; *) echo "unknown option $arg"; exit 64 ;; esac
done
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3"; exit 64; }
PROFILE=${NOTARY_PROFILE:-triwarden-notary}
# App Store Connect API key (CI, Admin access): fetches Developer ID profiles and lets notarytool submit, without an Apple ID.
AUTH=(); NOTARY=(--keychain-profile "$PROFILE")
if [[ -n ${ASC_KEY_PATH:-} ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi
BUILD=$(git rev-list --count HEAD)
OUT=dist/$VERSION
ARCHIVE=$OUT/Triwarden.xcarchive
rm -rf "$OUT" && mkdir -p "$OUT"

[[ -n ${ALLOW_DIRTY:-} || -z $(git status --porcelain) ]] || { echo "working tree not clean"; exit 1; }

echo "== Generate project"
xcodegen generate -q

# Bundles embedded in Triwarden.app that must sign during archive/export.
DEVELOPER_ID_BUNDLES=(
  io.github.sinhong2011.triwarden
  io.github.sinhong2011.triwarden.autofill
  io.github.sinhong2011.triwarden.safari
  io.github.sinhong2011.triwarden.autotype
  io.github.sinhong2011.triwarden.tw
)

if [[ -n ${ASC_KEY_PATH:-} ]]; then
  # CI: prepare Developer ID profiles *before* archive, then force Manual + Developer ID
  # on the generated project. project.yml stays Automatic + Apple Development for local
  # Debug; without this, archive + -allowProvisioningUpdates mints Mac Development certs
  # on clean runners and eventually hits Apple's certificate quota.
  echo "== Prepare Developer ID profiles"
  PROFILES_TSV=$OUT/developer-id-profiles.tsv
  scripts/developer-id-profiles.py "${DEVELOPER_ID_BUNDLES[@]}" | tee "$PROFILES_TSV"
  scripts/apply-developer-id-signing.py "$PROFILES_TSV"

  PROFILES=""
  while IFS=$'\t' read -r bundle name; do
    PROFILES+="    <key>$bundle</key><string>$name</string>"$'\n'
  done < "$PROFILES_TSV"
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>FX3VR69P5K</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>
$PROFILES  </dict>
</dict></plist>
PLIST
else
  # Local: your Xcode account signs (and makes the profiles) automatically.
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>FX3VR69P5K</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
fi

echo "== Archive $VERSION ($BUILD)"
xcodebuild -project Triwarden.xcodeproj -scheme Triwarden -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates "${AUTH[@]}" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

echo "== Export with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
APP=$OUT/export/Triwarden.app

KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ -n $KEY ]] || { echo "SUPublicEDKey is empty: run 'make sparkle-keys' once and commit project.yml"; exit 1; }

echo "== Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier"

ZIP=$OUT/Triwarden-$VERSION.zip
DMG=$OUT/Triwarden-$VERSION.dmg
if [[ $NOTARIZE == 1 ]]; then
  echo "== Notarize (profile $PROFILE)"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY[@]}" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

echo "== Package"
ditto -c -k --keepParent "$APP" "$ZIP"
# Styled window: background, icon positions and volume icon from scripts/dmg-settings.py (Design/DMG/generate.py).
command -v dmgbuild >/dev/null || { echo "dmgbuild not found: pipx install dmgbuild (or uv tool install dmgbuild)"; exit 1; }
dmgbuild -s scripts/dmg-settings.py -D app="$APP" "Triwarden $VERSION" "$DMG" 2>&1 | grep -v "is deprecated" || true
[[ -f $DMG ]] || { echo "dmgbuild failed"; exit 1; }
if [[ $NOTARIZE == 1 ]]; then
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
  xcrun stapler staple "$DMG"
fi
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
# The same DMG under a name that never changes, so the website can link
# https://github.com/sinhong2011/triwarden/releases/latest/download/Triwarden.dmg for "the newest version".
LATEST_DMG=$OUT/Triwarden.dmg
cp "$DMG" "$LATEST_DMG"

echo "== Homebrew cask"
cat > "$OUT/triwarden.rb" <<CASK
cask "triwarden" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/sinhong2011/triwarden/releases/download/v#{version}/Triwarden-#{version}.dmg"
  name "Triwarden"
  desc "Native macOS client for Vaultwarden and Bitwarden"
  homepage "https://github.com/sinhong2011/triwarden"

  depends_on macos: :tahoe

  app "Triwarden.app"
  binary "#{appdir}/Triwarden.app/Contents/MacOS/tw"

  zap trash: [
    "~/Library/Group Containers/FX3VR69P5K.io.github.sinhong2011.triwarden",
    "~/Library/Containers/io.github.sinhong2011.triwarden",
  ]
end
CASK

echo "== Sparkle appcast"
# Signs the zip with the EdDSA key and writes appcast.xml pointing at this release's download.
SPARKLE_BIN=${SPARKLE_BIN:-$(find build/SourcePackages/artifacts ~/Library/Developer/Xcode/DerivedData -path "*sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)}
[[ -x $SPARKLE_BIN/generate_appcast ]] || { echo "Sparkle tools not found; build once (make build) or set SPARKLE_BIN"; exit 1; }
FEED=$OUT/feed && mkdir -p "$FEED" && cp "$ZIP" "$FEED/"
# What's new, shown in the update window: this version's CHANGELOG section as HTML, named like the zip so
# generate_appcast embeds it in the appcast item.
python3 scripts/release-notes.py "$VERSION" CHANGELOG.md > "$FEED/Triwarden-$VERSION.html"
KEY_ARGS=(); [[ -n ${SPARKLE_KEY_FILE:-} ]] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/sinhong2011/triwarden/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/sinhong2011/triwarden/releases/tag/v$VERSION" \
  --link "https://github.com/sinhong2011/triwarden" "$FEED"
cp "$FEED/appcast.xml" "$OUT/appcast.xml"
grep -q 'sparkle:edSignature' "$OUT/appcast.xml" || { echo "appcast is not signed"; exit 1; }

if [[ $PUBLISH == 1 ]]; then
  [[ $NOTARIZE == 1 ]] || { echo "refusing to publish an un-notarized build"; exit 1; }
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "== Upload to release v$VERSION"   # created by release-please
  else
    echo "== GitHub release v$VERSION"
    gh release create "v$VERSION" --title "Triwarden $VERSION" --generate-notes
  fi
  gh release upload "v$VERSION" "$DMG" "$LATEST_DMG" "$ZIP" "$OUT/appcast.xml" "$OUT/triwarden.rb" --clobber
fi

echo
echo "Done: $OUT"
ls -lh "$OUT" | grep -E "\.(dmg|zip|rb|xml)$"
echo "sha256 $SHA"
