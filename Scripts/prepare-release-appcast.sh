#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: prepare-release-appcast.sh --appcast-in FILE --constants-in FILE --appcast-out FILE --constants-out FILE --zip ZIP --version X.Y.Z --build N --repository OWNER/REPO --sign-update EXE' >&2
  exit 2
}

appcast_in=''; constants_in=''; appcast_out=''; constants_out=''; zip=''
version=''; build=''; repository=''; sign_update=''
while (( $# > 0 )); do
  case "$1" in
    --appcast-in) appcast_in="${2:-}"; shift 2 ;;
    --constants-in) constants_in="${2:-}"; shift 2 ;;
    --appcast-out) appcast_out="${2:-}"; shift 2 ;;
    --constants-out) constants_out="${2:-}"; shift 2 ;;
    --zip) zip="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --sign-update) sign_update="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$appcast_in" && -f "$constants_in" && -f "$zip" && -n "$appcast_out" \
  && -n "$constants_out" && -x "$sign_update" ]] || usage
release_validate_version "$version"
release_validate_build "$build"
release_validate_repository "$repository"
release_require_command xmllint

[[ "$appcast_in" != "$appcast_out" && "$constants_in" != "$constants_out" ]] \
  || release_die 'appcast preparation outputs must not overwrite source files'
[[ "$(basename "$zip")" == "SupraAI-${version}.zip" ]] \
  || release_die 'Sparkle ZIP name does not match release version'
[[ "$(grep -c '<!-- APPCAST_ITEMS:' "$appcast_in")" == '1' ]] \
  || release_die 'appcast must contain exactly one insertion marker'
if grep -Fq "<sparkle:shortVersionString>${version}</sparkle:shortVersionString>" "$appcast_in"; then
  release_die 'appcast already contains the release version'
fi
if grep -Fq "<sparkle:version>${build}</sparkle:version>" "$appcast_in"; then
  release_die 'appcast already contains the release build number'
fi

signature_fragment="$("$sign_update" "$zip")" \
  || release_die 'Sparkle signing failed'
if [[ "$signature_fragment" =~ ^sparkle:edSignature=\"([A-Za-z0-9+/=]+)\"[[:space:]]+length=\"([0-9]+)\"$ ]]; then
  signature="${BASH_REMATCH[1]}"
  signed_length="${BASH_REMATCH[2]}"
else
  release_die 'unexpected Sparkle signing output'
fi

zip_length="$(release_file_size "$zip")"
[[ "$signed_length" == "$zip_length" ]] \
  || release_die 'Sparkle length does not match ZIP bytes'
"$sign_update" --verify "$zip" "$signature" >/dev/null 2>&1 \
  || release_die 'Sparkle signature verification failed'

pub_date="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
tag="v${version}"
release_url="https://github.com/${repository}/releases/tag/${tag}"
download_url="https://github.com/${repository}/releases/download/${tag}/SupraAI-${version}.zip"
item_file="$(mktemp)"
temporary_appcast="$(mktemp)"
temporary_constants="$(mktemp)"
trap 'rm -f "$item_file" "$temporary_appcast" "$temporary_constants"' EXIT

printf '%s\n' \
  '    <item>' \
  "      <title>Supra AI ${version}</title>" \
  "      <sparkle:releaseNotesLink>${release_url}</sparkle:releaseNotesLink>" \
  "      <pubDate>${pub_date}</pubDate>" \
  "      <sparkle:version>${build}</sparkle:version>" \
  "      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>" \
  '      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>' \
  "      <enclosure url=\"${download_url}\" type=\"application/octet-stream\" sparkle:edSignature=\"${signature}\" length=\"${signed_length}\" />" \
  '    </item>' >"$item_file"

while IFS= read -r line || [[ -n "$line" ]]; do
  printf '%s\n' "$line" >>"$temporary_appcast"
  if [[ "$line" == *'<!-- APPCAST_ITEMS:'* ]]; then
    sed -n 'p' "$item_file" >>"$temporary_appcast"
  fi
done <"$appcast_in"

sed -E \
  -e "s|(FALLBACK_RELEASE_TAG[[:space:]]*=[[:space:]]*\")[^\"]*(\")|\1${tag}\2|" \
  -e "s|(FALLBACK_RELEASE_VERSION[[:space:]]*=[[:space:]]*\")[^\"]*(\")|\1${version}\2|" \
  "$constants_in" >"$temporary_constants"

xmllint --noout "$temporary_appcast" >/dev/null 2>&1 \
  || release_die 'prepared appcast is not valid XML'
grep -Fq "<sparkle:version>${build}</sparkle:version>" "$temporary_appcast" \
  || release_die 'prepared appcast is missing exact build number'
grep -Fq "sparkle:edSignature=\"${signature}\" length=\"${signed_length}\"" "$temporary_appcast" \
  || release_die 'prepared appcast is missing exact signature or length'
grep -Fq "FALLBACK_RELEASE_TAG = \"${tag}\"" "$temporary_constants" \
  || release_die 'website fallback tag was not updated'
grep -Fq "FALLBACK_RELEASE_VERSION = \"${version}\"" "$temporary_constants" \
  || release_die 'website fallback version was not updated'

mkdir -p "$(dirname "$appcast_out")" "$(dirname "$constants_out")"
mv -f "$temporary_appcast" "$appcast_out"
mv -f "$temporary_constants" "$constants_out"
rm -f "$item_file"
trap - EXIT
printf 'Prepared validated appcast for v%s (%s) from exact ZIP bytes.\n' "$version" "$build"
