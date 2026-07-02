#!/usr/bin/env bash
#
# Build, Developer ID-sign, notarize, staple, package, and publish a Supra AI
# release, then upload the notarized .zip as a GitHub release asset (which the
# in-app updater downloads).
#
# One-time prerequisites
#   1. "Developer ID Application" cert installed in your login Keychain
#      (team 2DP657YB3K). Check: security find-identity -v -p codesigning
#   2. A notarization credential profile in your Keychain:
#        xcrun notarytool store-credentials "supra-notary" \
#          --apple-id "you@example.com" --team-id 2DP657YB3K \
#          --password "<app-specific-password from appleid.apple.com>"
#   3. gh authenticated: gh auth status
#   4. Sparkle EdDSA signing key in your login Keychain (Sparkle's generate_keys).
#      The matching public key is embedded in the app's Info.plist (SUPublicEDKey).
#
# Usage
#   Scripts/release.sh 1.2.0
#
# What it does with versions/updates
#   - Sets MARKETING_VERSION = <version> and CURRENT_PROJECT_VERSION = git commit
#     count (a monotonic CFBundleVersion Sparkle requires) before archiving.
#   - After uploading the notarized .zip, EdDSA-signs it, prepends an <item> to
#     website/public/appcast.xml, and bumps website/lib/constants.ts. Commit those
#     to main to publish the seamless update (deploy-website workflow).
#
# Notes
#   - The first notarized build MUST be smoke-tested (load a model + generate)
#     because hardened runtime is only on for Release; if MLX fails, add the
#     needed code-signing entitlement (e.g. com.apple.security.cs.allow-jit) to
#     SupraRuntimeService.entitlements and re-run.
set -euo pipefail

VERSION="${1:?usage: Scripts/release.sh <version>  (e.g. 1.2.0)}"
TAG="v${VERSION}"
PROFILE="${NOTARY_PROFILE:-supra-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build/release"
ARCHIVE="${BUILD}/SupraAI.xcarchive"
EXPORT_DIR="${BUILD}/export"
APP="${EXPORT_DIR}/SupraAI.app"
ZIP="${BUILD}/SupraAI-${VERSION}.zip"
DMG="${BUILD}/SupraAI-${VERSION}.dmg"
SIGN_ID="${SIGN_IDENTITY:-Developer ID Application}"
PBXPROJ="${ROOT}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
APPCAST="${ROOT}/website/public/appcast.xml"
CONSTANTS="${ROOT}/website/lib/constants.ts"

echo "▶︎ Verifying catalog model IDs resolve on Hugging Face…"
"${ROOT}/Scripts/verify-model-ids.sh"

# Sparkle compares CFBundleVersion (sparkle:version). It MUST increase every
# release or updates are never offered. Derive a monotonic build number from the
# commit count and write both versions into the project before archiving.
BUILD_NUMBER="$(git -C "${ROOT}" rev-list --count HEAD)"
echo "▶︎ Setting MARKETING_VERSION=${VERSION}, CURRENT_PROJECT_VERSION=${BUILD_NUMBER}…"
PROJECT_DIR="${ROOT}/Apps/SupraAI/SupraAI.xcodeproj" \
MARKETING_VERSION="${VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" ruby <<'RUBY'
require 'xcodeproj'
proj = Xcodeproj::Project.open(ENV.fetch('PROJECT_DIR'))
proj.targets.find { |t| t.name == 'SupraAI' }.build_configurations.each do |c|
  c.build_settings['MARKETING_VERSION'] = ENV.fetch('MARKETING_VERSION')
  c.build_settings['CURRENT_PROJECT_VERSION'] = ENV.fetch('BUILD_NUMBER')
end
proj.save
RUBY

rm -rf "${BUILD}"
mkdir -p "${BUILD}"

echo "▶︎ Archiving (Release, hardened runtime, Developer ID)…"
xcodebuild archive \
  -workspace "${ROOT}/SupraAI.xcworkspace" \
  -scheme SupraAI \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE}" \
  ENABLE_HARDENED_RUNTIME=YES

echo "▶︎ Exporting…"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${ROOT}/Scripts/ExportOptions.plist"

echo "▶︎ Verifying Sparkle helpers are embedded and Developer ID-signed (hardened)…"
SPARKLE_FW="${APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
for helper in "XPCServices/Installer.xpc" "Autoupdate" "Updater.app"; do
  [ -e "${SPARKLE_FW}/${helper}" ] || { echo "✗ Sparkle helper missing: ${helper}"; exit 1; }
  codesign -dv "${SPARKLE_FW}/${helper}" >/dev/null 2>&1 || { echo "✗ Sparkle helper unsigned: ${helper}"; exit 1; }
done

echo "▶︎ Notarizing app (this can take a few minutes)…"
ditto -c -k --keepParent "${APP}" "${BUILD}/notarize.zip"
xcrun notarytool submit "${BUILD}/notarize.zip" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

echo "▶︎ Building DMG (drag-to-Applications)…"
STAGE="${BUILD}/dmg"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "Supra AI ${VERSION}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
codesign --force --timestamp --sign "${SIGN_ID}" "${DMG}"

echo "▶︎ Notarizing DMG…"
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

echo "▶︎ Packaging app zip…"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "▶︎ Publishing release ${TAG}…"
if ! gh release view "${TAG}" >/dev/null 2>&1; then
  gh release create "${TAG}" --title "Supra AI ${VERSION}" --generate-notes
fi
gh release upload "${TAG}" "${DMG}" "${ZIP}" --clobber

echo "▶︎ Signing the update (EdDSA) and updating the appcast…"
# Sparkle's sign_update ships in the resolved SPM artifact bundle. Sign the EXACT
# .zip that was just uploaded — never re-zip after this.
# Honor a releaser-provided SPARKLE_BIN (custom DerivedData, CI, multiple Xcode
# builds) before falling back to the DerivedData search — the escape hatch the
# failure message below promises.
SPARKLE_BIN="${SPARKLE_BIN:-$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)}"
[ -x "${SPARKLE_BIN}/sign_update" ] || { echo "✗ Sparkle sign_update not found (build SupraAI once, or set SPARKLE_BIN)"; exit 1; }
SIG_FRAGMENT="$("${SPARKLE_BIN}/sign_update" "${ZIP}")"   # -> sparkle:edSignature="…" length="…"
case "${SIG_FRAGMENT}" in *edSignature=*length=*) ;; *) echo "✗ unexpected sign_update output: ${SIG_FRAGMENT}"; exit 1;; esac
DISK_LEN="$(stat -f%z "${ZIP}")"
case "${SIG_FRAGMENT}" in *length=\"${DISK_LEN}\"*) ;; *) echo "✗ appcast length != on-disk zip size (${DISK_LEN})"; exit 1;; esac
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${APP}/Contents/Info.plist")"
PUB_DATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"

# Prepend a new <item> (newest first) at the marker, unless this version is already there.
if grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "${APPCAST}"; then
  echo "  appcast already contains ${VERSION}; leaving it unchanged"
else
  ITEM="    <item>
      <title>Supra AI ${VERSION}</title>
      <sparkle:releaseNotesLink>https://github.com/cadespivey/Supra-AI/releases/tag/${TAG}</sparkle:releaseNotesLink>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url=\"https://github.com/cadespivey/Supra-AI/releases/download/${TAG}/SupraAI-${VERSION}.zip\" type=\"application/octet-stream\" ${SIG_FRAGMENT} />
    </item>"
  # Insert ITEM immediately after the marker line.
  MARKER='<!-- APPCAST_ITEMS:'
  python3 - "${APPCAST}" "${MARKER}" <<PY
import sys
path, marker = sys.argv[1], sys.argv[2]
item = """${ITEM}"""
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
out = []
for ln in lines:
    out.append(ln)
    if marker in ln:
        out.append(item + "\n")
open(path, "w", encoding="utf-8").write("".join(out))
PY
  echo "  appcast updated with ${VERSION} (build ${BUNDLE_VERSION})"
fi

# Bump the website's pinned download fallback.
sed -i '' "s|FALLBACK_RELEASE_TAG = \"v[0-9.]*\"|FALLBACK_RELEASE_TAG = \"${TAG}\"|" "${CONSTANTS}"
sed -i '' "s|FALLBACK_RELEASE_VERSION = \"[0-9.]*\"|FALLBACK_RELEASE_VERSION = \"${VERSION}\"|" "${CONSTANTS}"

echo "✓ Released ${TAG} — DMG + zip, notarized + stapled: ${DMG}"
echo ""
echo "  NEXT (publishes the seamless update to existing users):"
echo "    1. Review:  git diff -- Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj website/public/appcast.xml website/lib/constants.ts"
echo "    2. Commit the version bump + appcast + constants and merge to 'main'"
echo "       (the deploy-website workflow publishes https://supralegal.ai/appcast.xml)."
echo "    The GitHub asset is already live, so the appcast can safely reference it."
