#!/usr/bin/env bash
# Provision the dedicated release-runner user account defined in
# Docs/Release-Protection.md. Run this AS the release user (default: suprarelease)
# from a login session. Idempotent: safe to re-run until every check passes.
#
# Expects a staging directory (default /Users/Shared/supra-release-staging) prepared
# by the developer account, containing:
#   actions-runner-osx-arm64.tar.gz   GitHub Actions runner release tarball
#   Sparkle/bin/sign_update           reviewed Sparkle tools (from the SPM artifact)
#   Models/<org>__<name>/             smoke model tree incl. .supra-model-manifest.json
#   smoke-model-tool.swift            copy of Scripts/smoke-model-tool.swift
#
# Usage:
#   bash provision-release-runner.sh [--staging DIR] [--registration-token TOKEN] \
#        [--repository OWNER/REPO]
set -euo pipefail

staging='/Users/Shared/supra-release-staging'
registration_token=''
repository='cadespivey/Supra-AI'
while (( $# > 0 )); do
  case "$1" in
    --staging) staging="${2:?}"; shift 2 ;;
    --registration-token) registration_token="${2:?}"; shift 2 ;;
    --repository) repository="${2:?}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

expected_user='suprarelease'
failures=0
note() { printf '%s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
todo() { printf 'TODO %s\n' "$*"; failures=$((failures + 1)); }

[[ "$(whoami)" == "$expected_user" ]] \
  || { printf 'run this script as the %s user (currently %s)\n' "$expected_user" "$(whoami)" >&2; exit 2; }
[[ "$(uname -m)" == 'arm64' ]] || { printf 'release runner requires Apple Silicon\n' >&2; exit 2; }
[[ -d "$staging" ]] || { printf 'staging directory missing: %s\n' "$staging" >&2; exit 2; }

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
runner_home="${HOME}/actions-runner"
tools_dir="${HOME}/Tools/Sparkle"
container_models="${HOME}/Library/Containers/ai.supra.SupraAI/Data/Library/Application Support/ai.supra.SupraAI/Models"

# --- toolchain -----------------------------------------------------------------
if [[ -d "$developer_dir" ]]; then ok "Xcode toolchain at ${developer_dir}"; else todo "install Xcode at ${developer_dir} (or set DEVELOPER_DIR)"; fi
for tool in git jq xmllint openssl curl shasum ditto hdiutil plutil; do
  command -v "$tool" >/dev/null 2>&1 && ok "tool: ${tool}" || todo "missing tool: ${tool}"
done
for tool in node npm gh; do
  command -v "$tool" >/dev/null 2>&1 && ok "tool: ${tool}" \
    || todo "missing tool: ${tool} (expected via /opt/homebrew/bin; check PATH for this user)"
done

# --- runner install -------------------------------------------------------------
if [[ -x "${runner_home}/run.sh" ]]; then
  ok "actions runner installed at ${runner_home}"
else
  tarball="${staging}/actions-runner-osx-arm64.tar.gz"
  if [[ -f "$tarball" ]]; then
    mkdir -p "$runner_home"
    tar -xzf "$tarball" -C "$runner_home"
    ok "actions runner extracted to ${runner_home}"
  else
    todo "stage the runner tarball at ${tarball}"
  fi
fi

if [[ -x "${runner_home}/config.sh" && ! -f "${runner_home}/.runner" ]]; then
  if [[ -n "$registration_token" ]]; then
    (cd "$runner_home" && ./config.sh --unattended \
      --url "https://github.com/${repository}" \
      --token "$registration_token" \
      --name 'supra-release-local' \
      --labels 'supra-release,supra-release-isolated' \
      --replace)
    ok 'runner registered with labels supra-release, supra-release-isolated'
  else
    todo 'runner not yet registered; re-run with --registration-token (gh api repos/OWNER/REPO/actions/runners/registration-token)'
  fi
elif [[ -f "${runner_home}/.runner" ]]; then
  ok 'runner already registered'
fi

if [[ -d "$runner_home" ]]; then
  printf '%s\n' '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' > "${runner_home}/.path"
  printf 'DEVELOPER_DIR=%s\n' "$developer_dir" > "${runner_home}/.env"
  ok 'runner .path and .env written (clean environment; no override variables)'
fi

# --- Sparkle tools ---------------------------------------------------------------
if [[ -x "${tools_dir}/bin/sign_update" ]]; then
  ok "Sparkle tools at ${tools_dir}/bin"
elif [[ -x "${staging}/Sparkle/bin/sign_update" ]]; then
  mkdir -p "$tools_dir"
  cp -R "${staging}/Sparkle/bin" "$tools_dir/"
  ok "Sparkle tools installed to ${tools_dir}/bin"
else
  todo "stage Sparkle tools at ${staging}/Sparkle/bin (sign_update required)"
fi

# --- smoke model -----------------------------------------------------------------
staged_model="$(find "${staging}/Models" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
if [[ -n "$staged_model" ]]; then
  model_name="$(basename "$staged_model")"
  target="${container_models}/${model_name}"
  if [[ ! -d "$target" ]]; then
    mkdir -p "$container_models"
    cp -R "$staged_model" "$target"
    ok "smoke model copied to ${target}"
  else
    ok "smoke model present at ${target}"
  fi
  if [[ -f "${staging}/smoke-model-tool.swift" && -d "$developer_dir" ]]; then
    fingerprint="$(DEVELOPER_DIR="$developer_dir" swift "${staging}/smoke-model-tool.swift" fingerprint --model-dir "$target")"
    ok "smoke model verified; SUPRA_RELEASE_SMOKE_MODEL_SHA256=${fingerprint}"
    ok "SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY=${target}"
  else
    todo 'cannot verify model fingerprint (need smoke-model-tool.swift in staging and Xcode)'
  fi
else
  todo "stage the smoke model under ${staging}/Models/<org>__<name>"
fi

# --- git signing key ---------------------------------------------------------------
signing_key="${HOME}/.ssh/supra-release-signing"
if [[ -f "$signing_key" ]]; then
  ok "git signing key at ${signing_key}"
else
  mkdir -p "${HOME}/.ssh"
  ssh-keygen -t ed25519 -f "$signing_key" -N '' -C 'supra-release-signing' >/dev/null
  ok "generated git signing key ${signing_key}"
fi
note "  public key (add as a SIGNING key on the GitHub account): $(cat "${signing_key}.pub")"

# --- credentials (manual imports; verified only) -----------------------------------
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -qF 'Developer ID Application' <<<"$identities"; then
  ok 'Developer ID Application identity present in this user Keychain'
else
  todo 'import the Developer ID Application .p12 into this user login Keychain (Keychain Access, as suprarelease)'
fi
if xcrun notarytool history --keychain-profile supra-notary >/dev/null 2>&1; then
  ok 'notarytool profile supra-notary authenticates'
else
  todo 'create the notary profile as this user: xcrun notarytool store-credentials supra-notary (App Store Connect credentials)'
fi
if security find-generic-password -s 'https://sparkle-project.org' >/dev/null 2>&1; then
  ok 'Sparkle EdDSA private key present in this user Keychain'
else
  todo 'import the Sparkle key as this user: <Sparkle>/bin/generate_keys -f <exported-key-file> (must match the app SUPublicEDKey)'
fi

printf '\n'
if (( failures > 0 )); then
  printf 'provisioning incomplete: %d item(s) above marked TODO\n' "$failures"
  exit 1
fi
printf 'provisioning complete. Start the runner on demand with: cd %s && ./run.sh\n' "$runner_home"
