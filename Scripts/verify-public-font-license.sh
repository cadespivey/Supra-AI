#!/usr/bin/env bash
set -euo pipefail

status=0

report() {
  printf 'ERROR: %s\n' "$1" >&2
  status=1
}

# Repository mode scans the tracked tree from the repository root. Staged
# artifact mode — no enclosing git repository, e.g. the release transaction's
# temporary website copy — scans the current directory tree instead; every
# file present in a staged public artifact is publication-bound.
if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  scan_mode='repository'
  cd "$repo_root"
else
  scan_mode='staged'
fi

check_path() {
  local path="$1"
  case "${scan_mode}:${path}" in
    repository:website/public/fonts/*|staged:public/fonts/*|staged:out/fonts/*)
      report "public font path is prohibited: $path"
      ;;
  esac

  local lower_path
  lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$lower_path" in
    *equity*a*.woff|*equity*a*.woff2|*equity*a*.ttf|*equity*a*.otf|*equity*a*.eot|*equity*a*.ttc)
      report "Equity font asset is prohibited: $path"
      ;;
  esac
}

if [[ "$scan_mode" == 'repository' ]]; then
  while IFS= read -r -d '' path; do
    check_path "$path"
  done < <(git ls-files -z --cached --others --exclude-standard)
else
  while IFS= read -r -d '' path; do
    check_path "${path#./}"
  done < <(
    find . -type f \
      -not -path './node_modules/*' \
      -not -path './.next/*' \
      -print0
  )
fi

is_prohibited_blob() {
  case "$1" in
    2977a86366333533d454e8362956dbc2ca273836|\
    339cc03e157d27ff9c05aa1398658156fc270a1d|\
    a534fdb77da59665064b2f3ece47d779bffde437|\
    592699d8db6504e287590d73cb202ba64bb587c1|\
    21ed50d81b3d39dc5fce11597c7949e79da7fe20|\
    a2427890de67fbc5ef37eaee8557308e08d25ec9)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r -d '' path; do
  [[ -f "$path" ]] || continue
  blob="$(git hash-object -- "$path")"
  if is_prohibited_blob "$blob"; then
    report "known prohibited Equity font binary found at: $path"
  fi
done < <(
  find . -type f \
    -not -path './.git/*' \
    -not -path './.build/*' \
    -not -path './DerivedData/*' \
    -not -path './node_modules/*' \
    -not -path './.next/*' \
    -not -path './website/node_modules/*' \
    -not -path './website/.next/*' \
    \( -size 32616c -o -size 38244c -o -size 34124c -o -size 33524c -o -size 37132c -o -size 32348c \) \
    -print0
)

if (( status != 0 )); then
  printf '%s\n' 'Equity fonts may never be committed or included in public artifacts.' >&2
  exit "$status"
fi

printf '%s\n' 'Public font license check passed.'
