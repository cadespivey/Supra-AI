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

is_prohibited_font_blob() {
  case "$1" in
    2977a86366333533d454e8362956dbc2ca273836|\
    339cc03e157d27ff9c05aa1398658156fc270a1d|\
    a534fdb77da59665064b2f3ece47d779bffde437|\
    592699d8db6504e287590d73cb202ba64bb587c1|\
    21ed50d81b3d39dc5fce11597c7949e79da7fe20|\
    a2427890de67fbc5ef37eaee8557308e08d25ec9)
      return 0 ;;
    *) return 1 ;;
  esac
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
      public/fonts/*|fonts/*)
        report "public website font directory is prohibited in release artifact: $relative" ;;
      *equity*.woff|*equity*.woff2|*equity*.ttf|*equity*.otf|*equity*.eot|*equity*.ttc)
        report "prohibited Equity font name in release artifact: $relative" ;;
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
    elif [[ -f "$path" ]]; then
      case "$(wc -c <"$path" | tr -d ' ')" in
        32616|38244|34124|33524|37132|32348)
          blob="$(git hash-object -- "$path")"
          is_prohibited_font_blob "$blob" \
            && report "known prohibited Equity font binary in release artifact: $relative"
          ;;
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
