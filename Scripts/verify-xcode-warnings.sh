#!/usr/bin/env bash
set -euo pipefail

log_file="${1:-}"
project_root="${SUPRA_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if (( $# != 1 )) || [[ ! -f "$log_file" ]]; then
  printf 'Usage: %s xcodebuild.log\n' "$0" >&2
  exit 2
fi
project_root="$(cd "$project_root" && pwd -P)"
alternate_root="$project_root"
if [[ "$project_root" == /private/* ]]; then
  alternate_root="${project_root#/private}"
fi
count=0

while IFS= read -r line; do
  case "$line" in
    "${project_root}/Apps/"*': warning:'*|"${project_root}/Packages/"*': warning:'*|"${alternate_root}/Apps/"*': warning:'*|"${alternate_root}/Packages/"*': warning:'*|Apps/*': warning:'*|Packages/*': warning:'*)
      count=$((count + 1))
      ;;
  esac
done <"$log_file"

if (( count != 0 )); then
  printf 'Project-source warning gate failed: %d warning(s).\n' "$count" >&2
  exit 1
fi
printf '%s\n' 'Project-source warning gate passed: 0 warnings.'
