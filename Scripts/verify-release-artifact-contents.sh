#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  printf 'Usage: %s ROOT [ROOT ...]\n' "$0" >&2
  exit 2
fi

status=0
report() {
  printf 'ERROR: %s\n' "$1" >&2
  status=1
}

for scan_root in "$@"; do
  [[ -d "$scan_root" && ! -L "$scan_root" ]] || { report "artifact content root is invalid: $scan_root"; continue; }
  scan_root="$(cd "$scan_root" && pwd -P)"

  while IFS= read -r -d '' path; do
    relative="${path#${scan_root}/}"
    lower="$(printf '%s' "$relative" | tr '[:upper:]' '[:lower:]')"
    case "/${relative}/" in
      */Backup-Feature-Plan.md/*|*/ClientData/*|*/PrivateData/*)
        report "private or restricted artifact path: $relative" ;;
    esac
    case "$lower" in
      *.p8|*.p12|*.mobileprovision|*.safetensors|*.gguf|*.onnx|*.mlmodel|*.mlmodelc|*.sqlite|*.sqlite3|*.db|.env|*/.env)
        report "prohibited secret, model, or private-data path in release artifact: $relative" ;;
    esac

    if [[ -L "$path" ]]; then
      target="$(readlink "$path")"
      if [[ "$relative" == 'Applications' && "$target" == '/Applications' ]]; then
        continue
      fi
      if [[ "$target" == /* ]]; then
        resolved_target="$target"
      else
        target_dir="$(dirname "$target")"
        target_base="$(basename "$target")"
        if resolved_dir="$(cd "$(dirname "$path")" && cd "$target_dir" 2>/dev/null && pwd -P)"; then
          resolved_target="${resolved_dir}/${target_base}"
        else
          report "broken or unresolvable symlink in release artifact: $relative"
          continue
        fi
      fi
      case "$resolved_target" in
        "$scan_root"|"$scan_root"/*) ;;
        *) report "symlink escapes release artifact root: $relative" ;;
      esac
    fi
  done < <(find -s "$scan_root" \( -type f -o -type l \) -print0)

  script_root="$(cd "$(dirname "$0")/.." && pwd)"
  if ! bash "${script_root}/Scripts/verify-secrets.sh" "$scan_root" >/dev/null; then
    report "secret scan failed for release artifact root: $(basename "$scan_root")"
  fi
done

if (( status != 0 )); then
  printf '%s\n' 'Release artifact content verification failed.' >&2
  exit 1
fi
printf '%s\n' 'Release artifact content verification passed.'
