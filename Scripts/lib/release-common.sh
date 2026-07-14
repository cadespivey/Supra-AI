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

# GitHub takes several seconds to spawn a new pull request's check runs, and
# `gh pr checks` errors with "no checks reported" instead of waiting when
# queried inside that window. Poll until checks exist, then defer to --watch.
# Returns 0 when all required checks pass, the watch status when they exist
# but fail, and 2 when no checks ever appear within the bounded wait.
release_wait_for_required_checks() {
  local pr_url="$1"
  local repository="$2"
  local poll_seconds=15
  if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_CHECK_POLL_SECONDS:-}" ]]; then
    poll_seconds="$SUPRA_RELEASE_CHECK_POLL_SECONDS"
  fi
  local attempt output status
  for (( attempt = 0; attempt < 40; attempt++ )); do
    status=0
    output="$(gh pr checks "$pr_url" --repo "$repository" --required 2>&1)" || status=$?
    if (( status == 0 )); then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ "$output" != *'no checks reported'* ]]; then
      gh pr checks "$pr_url" --repo "$repository" --required --watch --interval 10
      return $?
    fi
    sleep "$poll_seconds"
  done
  printf 'ERROR: required checks never appeared for %s\n' "$pr_url" >&2
  return 2
}

# GitHub spawns push-triggered workflow runs asynchronously too: listing runs
# immediately after a merge can miss the deployment run entirely (observed
# live: v2.2.1's transaction died at the deploy lookup and rolled the release
# back to draft). Poll until the workflow run for the exact commit exists and
# print its id. Returns 0 with the run id on stdout, 2 when no run ever
# appears within the bounded wait.
release_wait_for_deploy_run() {
  local gh_command="$1"
  local repository="$2"
  local workflow="$3"
  local commit="$4"
  local poll_seconds=15
  if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' && -n "${SUPRA_RELEASE_CHECK_POLL_SECONDS:-}" ]]; then
    poll_seconds="$SUPRA_RELEASE_CHECK_POLL_SECONDS"
  fi
  local attempt run_json run_id
  for (( attempt = 0; attempt < 40; attempt++ )); do
    run_json="$("$gh_command" run list --repo "$repository" --workflow "$workflow" \
      --commit "$commit" --json databaseId,headSha,conclusion,status --limit 10 2>/dev/null)" \
      || run_json='[]'
    run_id="$(jq -r --arg sha "$commit" '[.[] | select(.headSha == $sha)][0].databaseId // empty' <<<"$run_json")"
    if [[ "$run_id" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep "$poll_seconds"
  done
  printf 'ERROR: %s run never appeared for commit %s\n' "$workflow" "$commit" >&2
  return 2
}

# Validate a configured command exactly as it will later be executed: bare
# names resolve through PATH, path-qualified commands must be executable files.
release_require_resolvable_command() {
  local command_path="$1"
  local context="$2"
  if [[ "$command_path" == */* ]]; then
    [[ -x "$command_path" ]] || release_die "${context} command is unavailable: $command_path"
  else
    command -v -- "$command_path" >/dev/null 2>&1 \
      || release_die "${context} command is unavailable: $command_path"
  fi
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

# Validate the content-free signed runtime smoke evidence embedded in a final
# preflight manifest. Exact key sets mirror additionalProperties: false in the
# reviewed schema and prevent generated text, prompts, model paths, or errors
# from crossing the release-evidence boundary.
release_verify_embedded_smoke_attestation() {
  local manifest="$1"
  local expected_source="$2"
  local expected_app_sha="$3"
  local expected_version="$4"
  local expected_build="$5"
  local recorded_result_sha
  local reproduced_result_sha

  jq -e \
    --arg source "$expected_source" \
    --arg appSHA "$expected_app_sha" \
    --arg version "$expected_version" \
    --arg build "$expected_build" '
    def exact_keys($expected):
      type == "object" and ((keys | sort) == ($expected | sort));
    def git_sha:
      type == "string" and test("^[0-9a-f]{40}$");
    def sha256:
      type == "string" and test("^[0-9a-f]{64}$");
    def semantic_version:
      type == "string" and
      test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$");
    def positive_build:
      type == "string" and test("^[1-9][0-9]*$");
    def nonnegative_integer:
      type == "number" and floor == . and . >= 0;
    def positive_number:
      type == "number" and . > 0;

    .signedRuntimeSmoke as $smoke |
    ($smoke | exact_keys([
      "schemaVersion", "status", "nonce", "sourceSha", "appTreeSHA256",
      "modelSHA256", "appBundleIdentifier", "xpcBundleIdentifier",
      "appVersion", "appBuild", "modelRepositoryID", "modelRevision",
      "verification", "eventCounts", "generatedTokenCount", "timings",
      "resultSHA256"
    ])) and
    $smoke.schemaVersion == 1 and
    $smoke.status == "passed" and
    ($smoke.nonce | sha256) and
    ($smoke.sourceSha | git_sha) and
    ($smoke.appTreeSHA256 | sha256) and
    ($smoke.modelSHA256 | sha256) and
    ($smoke.resultSHA256 | sha256) and
    $smoke.appBundleIdentifier == "ai.supra.SupraAI" and
    $smoke.xpcBundleIdentifier == "ai.supra.SupraAI.SupraRuntimeService" and
    ($smoke.appVersion | semantic_version) and
    ($smoke.appBuild | positive_build) and
    ($smoke.modelRepositoryID | type == "string" and
      test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    ($smoke.modelRevision | git_sha) and
    ($smoke.verification | exact_keys([
      "xpcConnected", "modelLoaded", "generationStarted",
      "generationCompleted", "modelUnloaded", "modelReverified"
    ])) and
    ($smoke.verification | all(.[]; . == true)) and
    ($smoke.eventCounts | exact_keys([
      "total", "generationStarted", "token", "metrics",
      "generationCompleted", "generationFailed", "generationCancelled",
      "reserved"
    ])) and
    ($smoke.eventCounts | all(.[];
      type == "number" and floor == . and . >= 0)) and
    $smoke.eventCounts.generationStarted == 1 and
    $smoke.eventCounts.token > 0 and
    $smoke.eventCounts.metrics == 1 and
    $smoke.eventCounts.generationCompleted == 1 and
    $smoke.eventCounts.generationFailed == 0 and
    $smoke.eventCounts.generationCancelled == 0 and
    $smoke.eventCounts.reserved == 0 and
    $smoke.eventCounts.total == (
      $smoke.eventCounts.generationStarted + $smoke.eventCounts.token +
      $smoke.eventCounts.metrics + $smoke.eventCounts.generationCompleted +
      $smoke.eventCounts.generationFailed +
      $smoke.eventCounts.generationCancelled + $smoke.eventCounts.reserved
    ) and
    ($smoke.generatedTokenCount |
      type == "number" and floor == . and . > 0) and
    ($smoke.timings | exact_keys([
      "loadTimeMs", "firstTokenLatencyMs", "tokensPerSecond"
    ])) and
    ($smoke.timings.loadTimeMs | nonnegative_integer) and
    ($smoke.timings.firstTokenLatencyMs | nonnegative_integer) and
    ($smoke.timings.tokensPerSecond | positive_number) and
    $smoke.sourceSha == $source and
    $smoke.appTreeSHA256 == $appSHA and
    $smoke.appVersion == $version and
    $smoke.appBuild == $build
  ' "$manifest" >/dev/null \
    || release_die 'signed runtime smoke evidence is missing, malformed, or does not match the release'

  recorded_result_sha="$(jq -r '.signedRuntimeSmoke.resultSHA256' "$manifest")"
  reproduced_result_sha="$(
    jq -S -c '.signedRuntimeSmoke | del(.resultSHA256)' "$manifest" \
      | shasum -a 256
  )"
  reproduced_result_sha="${reproduced_result_sha%% *}"
  [[ "$reproduced_result_sha" == "$recorded_result_sha" ]] \
    || release_die 'signed runtime smoke evidence digest is not reproducible'
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
