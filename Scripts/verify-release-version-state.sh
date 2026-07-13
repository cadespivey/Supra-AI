#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
project="${repo_root}/Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj"
appcast="${repo_root}/website/public/appcast.xml"
constants="${repo_root}/website/lib/constants.ts"

usage() {
  printf '%s\n' \
    'Usage: verify-release-version-state.sh [--project FILE --appcast FILE --constants FILE]' >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --project) project="${2:-}"; shift 2 ;;
    --appcast) appcast="${2:-}"; shift 2 ;;
    --constants) constants="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

for required in "$project" "$appcast" "$constants"; do
  [[ -f "$required" ]] || fail "release version input is missing: ${required}"
done
command -v xmllint >/dev/null 2>&1 || fail 'xmllint is required to validate the appcast'
xmllint --noout "$appcast" >/dev/null 2>&1 || fail 'appcast is not well-formed XML'

marketing_values="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$project")"
build_values="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$project")"
marketing_count="$(printf '%s\n' "$marketing_values" | sed '/^$/d' | wc -l | tr -d ' ')"
build_count="$(printf '%s\n' "$build_values" | sed '/^$/d' | wc -l | tr -d ' ')"
unique_marketing="$(printf '%s\n' "$marketing_values" | sed '/^$/d' | LC_ALL=C sort -u)"
unique_build="$(printf '%s\n' "$build_values" | sed '/^$/d' | LC_ALL=C sort -u)"
unique_marketing_count="$(printf '%s\n' "$unique_marketing" | sed '/^$/d' | wc -l | tr -d ' ')"
unique_build_count="$(printf '%s\n' "$unique_build" | sed '/^$/d' | wc -l | tr -d ' ')"

[[ "$marketing_count" == 4 && "$unique_marketing_count" == 1 ]] \
  || fail 'app and XPC marketing versions must be one reviewed value'
[[ "$build_count" == 4 && "$unique_build_count" == 1 ]] \
  || fail 'app and XPC build numbers must be one reviewed value'

candidate_version="$unique_marketing"
candidate_build="$unique_build"
newest_item="$(awk '
  /<item([[:space:]>])/ && !inside { inside = 1 }
  inside { print }
  inside && /<\/item>/ { exit }
' "$appcast")"
published_versions="$(printf '%s\n' "$newest_item" | sed -nE 's|.*<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>.*|\1|p')"
published_builds="$(printf '%s\n' "$newest_item" | sed -nE 's|.*<sparkle:version>([^<]+)</sparkle:version>.*|\1|p')"
published_version_count="$(printf '%s\n' "$published_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
published_build_count="$(printf '%s\n' "$published_builds" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$published_version_count" == 1 && "$published_build_count" == 1 ]] \
  || fail 'newest appcast item must contain exactly one marketing version and build'
published_version="$published_versions"
published_build="$published_builds"

fallback_tag_versions="$(sed -nE 's/.*FALLBACK_RELEASE_TAG = "v([^"]+)".*/\1/p' "$constants")"
fallback_versions="$(sed -nE 's/.*FALLBACK_RELEASE_VERSION = "([^"]+)".*/\1/p' "$constants")"
fallback_tag_count="$(printf '%s\n' "$fallback_tag_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
fallback_version_count="$(printf '%s\n' "$fallback_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$fallback_tag_count" == 1 && "$fallback_version_count" == 1 ]] \
  || fail 'website fallback release metadata must contain one tag and version'
fallback_tag_version="$fallback_tag_versions"
fallback_version="$fallback_versions"

semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$candidate_version" =~ $semver_pattern ]] \
  || fail "candidate marketing version is not semantic: ${candidate_version}"
[[ "$published_version" =~ $semver_pattern ]] \
  || fail "newest appcast marketing version is not semantic: ${published_version}"
[[ "$candidate_build" =~ ^[1-9][0-9]*$ ]] \
  || fail "candidate build is not a positive integer: ${candidate_build}"
[[ "$published_build" =~ ^[1-9][0-9]*$ ]] \
  || fail "newest appcast build is not a positive integer: ${published_build}"

if [[ "$fallback_tag_version" != "$published_version" \
    || "$fallback_version" != "$published_version" ]]; then
  fail 'website fallback release metadata must match the newest appcast item'
fi

semver_is_greater() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"
  if (( 10#$left_major != 10#$right_major )); then
    (( 10#$left_major > 10#$right_major ))
  elif (( 10#$left_minor != 10#$right_minor )); then
    (( 10#$left_minor > 10#$right_minor ))
  else
    (( 10#$left_patch > 10#$right_patch ))
  fi
}

if [[ "$candidate_version" == "$published_version" ]]; then
  [[ "$candidate_build" == "$published_build" ]] \
    || fail 'candidate build must match the published appcast when the marketing version is unchanged'
else
  semver_is_greater "$candidate_version" "$published_version" \
    || fail 'candidate marketing version must be newer than the published appcast'
  (( candidate_build > published_build )) \
    || fail 'candidate marketing version requires a build newer than the published appcast'
fi

printf 'Release version state passed: candidate %s (%s), published %s (%s).\n' \
  "$candidate_version" "$candidate_build" "$published_version" "$published_build"
