#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"
base_sha="${1:-}"
head_sha="${2:-HEAD}"
[[ -n "$base_sha" ]] || base_sha="$(git -C "$repo_root" rev-parse "${head_sha}^" 2>/dev/null || true)"
git -C "$repo_root" cat-file -e "${base_sha}^{commit}" 2>/dev/null \
  || { printf '%s\n' 'ERROR: changed-file safety needs an available base commit' >&2; exit 1; }
git -C "$repo_root" cat-file -e "${head_sha}^{commit}" 2>/dev/null \
  || { printf '%s\n' 'ERROR: changed-file safety needs an available head commit' >&2; exit 1; }

status=0
secret_pattern='(-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|A(KIA|SIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(proj-|live-)?[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})'

git -C "$repo_root" diff --check "$base_sha" "$head_sha" || status=1
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$path" in
    Backup-Feature-Plan.md|*/Backup-Feature-Plan.md|ClientData/*|*/ClientData/*|PrivateData/*|*/PrivateData/*)
      printf 'ERROR: prohibited artifact path: %s\n' "$path" >&2; status=1 ;;
  esac
  case "$lower" in
    *.dmg|*.pkg|*.xcarchive|*.app|*.xpc|*.p8|*.p12|*.pem|*.mobileprovision|*.safetensors|*.gguf|*.onnx|*.mlmodel|*.mlmodelc|*.sqlite|*.sqlite3|*.db|.env|*/.env)
      printf 'ERROR: prohibited artifact path: %s\n' "$path" >&2; status=1 ;;
  esac
  if git -C "$repo_root" diff --unified=0 "$base_sha" "$head_sha" -- "$path" \
      | sed -n '/^+++/d; s/^+//p' | LC_ALL=C grep -Eq "$secret_pattern"; then
    [[ "$path" == 'Scripts/verify-secrets.sh' || "$path" == 'Scripts/verify-changed-files.sh' ]] \
      || { printf 'ERROR: possible secret in changed file: %s\n' "$path" >&2; status=1; }
  fi
done < <(git -C "$repo_root" diff --name-only --diff-filter=ACMR "$base_sha" "$head_sha")

(( status == 0 )) || { printf '%s\n' 'Changed-file safety failed; findings report paths only.' >&2; exit 1; }
printf '%s\n' 'Changed-file safety passed.'
