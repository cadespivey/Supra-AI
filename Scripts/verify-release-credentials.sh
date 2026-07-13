#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

release_require_protected_environment
release_require_command security
release_require_command xcrun
release_require_command git

team_id="${SUPRA_RELEASE_TEAM_ID:-2DP657YB3K}"
sign_identity="${SIGN_IDENTITY:-Developer ID Application}"
manifest_identity="${MANIFEST_SIGNING_IDENTITY:-$sign_identity}"
notary_profile="${NOTARY_PROFILE:-supra-notary}"
sparkle_bin="${SPARKLE_BIN:-}"

[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || release_die 'release Team ID is invalid'
[[ -n "$notary_profile" ]] || release_die 'notarization profile is not configured'
[[ -n "$sparkle_bin" && -x "${sparkle_bin}/sign_update" ]] \
  || release_die 'Sparkle sign_update is not configured in the protected environment'

identity_output="$(security find-identity -v -p codesigning 2>/dev/null)" \
  || release_die 'unable to inspect release signing identities'
printf '%s\n' "$identity_output" | grep -Fq "$sign_identity" \
  || release_die 'Developer ID signing identity is unavailable'
printf '%s\n' "$identity_output" | grep -Fq "$team_id" \
  || release_die 'Developer ID identity does not match the expected Team ID'
printf '%s\n' "$identity_output" | grep -Fq "$manifest_identity" \
  || release_die 'manifest signing identity is unavailable'

# `history` validates that notarytool can resolve and authenticate the named
# Keychain profile without printing credential material.
xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null \
  || release_die 'notarization Keychain profile is unavailable or invalid'
release_load_git_signing_identity "$root"

printf '%s\n' 'Release credentials are available in the protected environment.'
