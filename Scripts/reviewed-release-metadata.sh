#!/usr/bin/env bash
# Print the single reviewed release value (marketing version or build number)
# recorded in an Xcode project file. The reviewed commit is the sole statement
# of release version intent: every target and configuration must agree on one
# value, and the value must be release-shaped. Used by the protected release
# workflows and Scripts/release-dispatch.sh; fails closed on any ambiguity.
set -euo pipefail

usage() {
  printf 'Usage: reviewed-release-metadata.sh PROJECT_PBXPROJ version|build\n' >&2
  exit 2
}

(( $# == 2 )) || usage
project="$1"
key="$2"

case "$key" in
  version)
    label='MARKETING_VERSION'
    shape='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    ;;
  build)
    label='CURRENT_PROJECT_VERSION'
    shape='^[1-9][0-9]*$'
    ;;
  *)
    usage
    ;;
esac

if [[ ! -f "$project" ]]; then
  printf 'ERROR: reviewed project metadata is missing: %s\n' "$project" >&2
  exit 1
fi

values="$(sed -nE "s/^[[:space:]]*${label} = ([^;]+);.*$/\1/p" "$project" | LC_ALL=C sort -u)"
if [[ -z "$values" ]]; then
  printf 'ERROR: %s not found in %s\n' "$label" "$project" >&2
  exit 1
fi
if [[ "$values" == *$'\n'* ]]; then
  printf 'ERROR: %s values disagree across targets in %s:\n%s\n' "$label" "$project" "$values" >&2
  exit 1
fi
if [[ ! "$values" =~ $shape ]]; then
  printf 'ERROR: %s is not release-shaped: %s\n' "$label" "$values" >&2
  exit 1
fi
printf '%s\n' "$values"
