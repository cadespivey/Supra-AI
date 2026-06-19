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
#
# Usage
#   Scripts/release.sh 1.2.0
#
# Notes
#   - Bump MARKETING_VERSION in the project to match before tagging.
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

echo "▶︎ Notarizing (this can take a few minutes)…"
ditto -c -k --keepParent "${APP}" "${BUILD}/notarize.zip"
xcrun notarytool submit "${BUILD}/notarize.zip" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

echo "▶︎ Packaging ${ZIP}…"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "▶︎ Publishing release ${TAG}…"
if ! gh release view "${TAG}" >/dev/null 2>&1; then
  gh release create "${TAG}" --title "Supra AI ${VERSION}" --generate-notes
fi
gh release upload "${TAG}" "${ZIP}" --clobber

echo "✓ Released ${TAG} — notarized, stapled, uploaded: ${ZIP}"
