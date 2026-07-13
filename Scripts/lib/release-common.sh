#!/usr/bin/env bash

# Shared, side-effect-free helpers for the protected release scripts. This file is
# sourced by scripts that already enable `set -euo pipefail`.

release_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

release_die() {
  release_error "$*"
  return 1
}

release_require_command() {
  command -v "$1" >/dev/null 2>&1 || release_die "required command is unavailable: $1"
}

release_validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || release_die "invalid full source SHA: $1"
}

release_validate_digest() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || release_die "invalid SHA-256 digest: $1"
}

release_validate_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$ ]] \
    || release_die "invalid semantic release version: $1"
}

release_validate_build() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || release_die "invalid positive build number: $1"
}

release_validate_repository() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || release_die "invalid owner/repository value: $1"
}

release_sha256() {
  shasum -a 256 -- "$1" | awk '{print $1}'
}

release_file_size() {
  if stat -f '%z' -- "$1" >/dev/null 2>&1; then
    stat -f '%z' -- "$1"
  else
    stat -c '%s' -- "$1"
  fi
}

release_file_mode() {
  if stat -f '%Lp' -- "$1" >/dev/null 2>&1; then
    stat -f '%Lp' -- "$1"
  else
    stat -c '%a' -- "$1"
  fi
}

# Hash paths, types, modes, symlink targets, sizes, and file bytes in a stable
# order. The digest therefore identifies the signed app tree rather than only
# its executable. Release bundles may not contain device nodes or sockets.
release_directory_digest() {
  local root="$1"
  [[ -d "$root" && ! -L "$root" ]] || release_die "directory digest root is invalid: $root"
  local parent base
  parent="$(cd "$(dirname "$root")" && pwd -P)"
  base="$(basename "$root")"

  (
    cd "$parent"
    find -s "$base" -print0 | while IFS= read -r -d '' relative; do
      if [[ -L "$relative" ]]; then
        printf 'L\0%s\0%s\0' "$relative" "$(readlink "$relative")"
      elif [[ -d "$relative" ]]; then
        printf 'D\0%s\0%s\0' "$relative" "$(release_file_mode "$relative")"
      elif [[ -f "$relative" ]]; then
        printf 'F\0%s\0%s\0%s\0%s\0' \
          "$relative" \
          "$(release_file_mode "$relative")" \
          "$(release_file_size "$relative")" \
          "$(release_sha256 "$relative")"
      else
        release_die "unsupported filesystem object in release bundle: $relative"
      fi
    done
  ) | shasum -a 256 | awk '{print $1}'
}

release_directory_size() {
  local root="$1"
  [[ -d "$root" && ! -L "$root" ]] || release_die "directory size root is invalid: $root"
  local total=0 size
  while IFS= read -r -d '' path; do
    if [[ -f "$path" && ! -L "$path" ]]; then
      size="$(release_file_size "$path")"
      total=$((total + size))
    fi
  done < <(find -s "$root" -type f -print0)
  printf '%s\n' "$total"
}

release_resolve_command_override() {
  local variable_name="$1"
  local production_value="$2"
  local override_value
  override_value="$(printenv "$variable_name" 2>/dev/null || true)"
  if [[ "${SUPRA_RELEASE_TESTING:-0}" == "1" && -n "$override_value" ]]; then
    printf '%s\n' "$override_value"
  else
    printf '%s\n' "$production_value"
  fi
}

release_require_protected_environment() {
  if [[ "${SUPRA_RELEASE_TESTING:-0}" == "1" ]]; then
    return 0
  fi
  [[ "${SUPRA_PROTECTED_RELEASE_ENVIRONMENT:-0}" == "1" ]] \
    || release_die 'release action is restricted to the protected release environment'
}

release_verify_cms_manifest() {
  local signature="$1"
  local manifest="$2"
  local expected_team_id="$3"
  local decoded="$4"
  security cms -D -i "$signature" -o "$decoded" >/dev/null 2>&1 \
    || release_die 'preflight manifest CMS signature verification failed'
  cmp -s "$decoded" "$manifest" \
    || release_die 'signed preflight manifest payload differs from supplied manifest'

  if [[ "${SUPRA_RELEASE_TESTING:-0}" != '1' ]]; then
    release_require_command openssl
    local openssl_decoded="${decoded}.openssl"
    local signer_certificate="${decoded}.signer.pem"
    openssl cms -verify -inform DER -in "$signature" -noverify \
      -out "$openssl_decoded" -signer "$signer_certificate" >/dev/null 2>&1 \
      || release_die 'unable to extract verified preflight manifest signer'
    cmp -s "$openssl_decoded" "$manifest" \
      || release_die 'OpenSSL-verified manifest payload differs from supplied manifest'
    local signer_subject signer_details
    signer_subject="$(openssl x509 -in "$signer_certificate" -noout -subject -nameopt RFC2253 2>/dev/null)" \
      || release_die 'unable to inspect preflight manifest signing certificate'
    printf '%s\n' "$signer_subject" | grep -Eq "(^|,)OU=${expected_team_id}(,|$)" \
      || release_die 'preflight manifest signer Team ID mismatch'
    signer_details="$(openssl x509 -in "$signer_certificate" -noout -text 2>/dev/null)" \
      || release_die 'unable to inspect preflight manifest certificate usage'
    printf '%s\n' "$signer_details" | grep -Fq 'Code Signing' \
      || release_die 'preflight manifest signer is not a code-signing identity'
  fi
}

release_load_git_signing_identity() {
  local repository_root="$1"
  RELEASE_GIT_NAME="${SUPRA_RELEASE_GIT_NAME:-$(git -C "$repository_root" config --get user.name 2>/dev/null || true)}"
  RELEASE_GIT_EMAIL="${SUPRA_RELEASE_GIT_EMAIL:-$(git -C "$repository_root" config --get user.email 2>/dev/null || true)}"
  RELEASE_GIT_SIGNING_KEY="${SUPRA_RELEASE_GIT_SIGNING_KEY:-$(git -C "$repository_root" config --get user.signingkey 2>/dev/null || true)}"
  RELEASE_GIT_SIGNING_FORMAT="${SUPRA_RELEASE_GIT_SIGNING_FORMAT:-$(git -C "$repository_root" config --get gpg.format 2>/dev/null || true)}"
  [[ -n "$RELEASE_GIT_SIGNING_FORMAT" ]] || RELEASE_GIT_SIGNING_FORMAT='openpgp'
  [[ -n "$RELEASE_GIT_NAME" && -n "$RELEASE_GIT_EMAIL" && -n "$RELEASE_GIT_SIGNING_KEY" ]] \
    || release_die 'protected Git commit signing identity is incomplete'
  case "$RELEASE_GIT_SIGNING_FORMAT" in
    openpgp|x509|ssh) ;;
    *) release_die 'unsupported protected Git signing format' ;;
  esac
  if [[ "$RELEASE_GIT_SIGNING_FORMAT" == 'ssh' && "$RELEASE_GIT_SIGNING_KEY" == /* ]]; then
    [[ -f "$RELEASE_GIT_SIGNING_KEY" ]] || release_die 'protected SSH commit signing key is unavailable'
  fi
}
