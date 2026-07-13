#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: publish-release-transaction.sh --repo-root PATH --repository OWNER/REPO --source-sha SHA --version X.Y.Z --build N --zip ZIP --dmg DMG --manifest JSON --manifest-signature CMS --appcast-in XML --constants-in TS --sign-update EXE' >&2
  exit 2
}

repo_root=''; repository=''; source_sha=''; version=''; build=''; zip=''; dmg=''
manifest=''; manifest_signature=''; appcast_in=''; constants_in=''; sign_update=''
while (( $# > 0 )); do
  case "$1" in
    --repo-root) repo_root="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --zip) zip="${2:-}"; shift 2 ;;
    --dmg) dmg="${2:-}"; shift 2 ;;
    --manifest) manifest="${2:-}"; shift 2 ;;
    --manifest-signature) manifest_signature="${2:-}"; shift 2 ;;
    --appcast-in) appcast_in="${2:-}"; shift 2 ;;
    --constants-in) constants_in="${2:-}"; shift 2 ;;
    --sign-update) sign_update="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$repo_root" && -f "$zip" && -f "$dmg" && -f "$manifest" \
  && -f "$manifest_signature" && -f "$appcast_in" && -f "$constants_in" && -x "$sign_update" ]] || usage
repo_root="$(cd "$repo_root" && pwd -P)"
release_validate_repository "$repository"
release_validate_sha "$source_sha"
release_validate_version "$version"
release_validate_build "$build"
release_require_protected_environment
for command in jq shasum security xmllint; do release_require_command "$command"; done

gh_command="$(release_resolve_command_override SUPRA_GH_COMMAND gh)"
curl_command="$(release_resolve_command_override SUPRA_CURL_COMMAND curl)"
website_gate="$(release_resolve_command_override SUPRA_WEBSITE_GATE_COMMAND "${root}/Scripts/test-website.sh")"
appcast_publish="$(release_resolve_command_override SUPRA_APPCAST_PUBLISH_COMMAND "${root}/Scripts/publish-release-appcast.sh")"
appcast_rollback="$(release_resolve_command_override SUPRA_APPCAST_ROLLBACK_COMMAND "${root}/Scripts/rollback-release-appcast.sh")"
for command_path in "$gh_command" "$curl_command" "$website_gate" "$appcast_publish" "$appcast_rollback"; do
  [[ -x "$command_path" ]] || release_die "release transaction command is unavailable: $command_path"
done

tag="v${version}"
temporary_dir="$(mktemp -d)"
draft_created=0
release_public=0
appcast_commit=''

record_incident() {
  local failure_status="$1"
  local rollback_status="$2"
  local incident_dir="${repo_root}/build/release/incidents"
  mkdir -p "$incident_dir" 2>/dev/null || return 0
  local incident="${incident_dir}/${tag}-$(date -u +'%Y%m%dT%H%M%SZ').json"
  jq -n \
    --arg at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg tag "$tag" --arg source "$source_sha" --arg appcastCommit "$appcast_commit" \
    --argjson status "$failure_status" --argjson rollbackStatus "$rollback_status" \
    --argjson releaseWasPublic "$release_public" \
    '{schemaVersion: 1, recordedAt: $at, tag: $tag, sourceSha: $source,
      exitStatus: $status, rollbackStatus: $rollbackStatus,
      rollbackCompleted: ($rollbackStatus == 0), releaseWasPublic: ($releaseWasPublic == 1),
      appcastCommit: (if $appcastCommit == "" then null else $appcastCommit end),
      privilegedContentRecorded: false}' >"$incident" 2>/dev/null || true
}

rollback_transaction() {
  local failure_status="$1"
  trap - ERR INT TERM
  set +e
  local rollback_status=0
  if (( release_public != 0 )); then
    "$gh_command" release edit "$tag" --repo "$repository" --draft >/dev/null 2>&1 \
      || rollback_status=1
    if [[ -n "$appcast_commit" ]]; then
      "$appcast_rollback" \
        --repo-root "$repo_root" --repository "$repository" --commit "$appcast_commit" \
        --source-sha "$source_sha" --version "$version" --reason 'automated release transaction rollback' \
        >/dev/null 2>&1 || rollback_status=1
    fi
  elif (( draft_created != 0 )); then
    "$gh_command" release delete "$tag" --repo "$repository" --yes --cleanup-tag >/dev/null 2>&1 \
      || rollback_status=1
  fi
  record_incident "$failure_status" "$rollback_status"
  rm -rf "$temporary_dir"
  if (( rollback_status == 0 )); then
    printf 'ERROR: release transaction failed; public state was rolled back or retained as draft (%s).\n' "$tag" >&2
  else
    printf 'CRITICAL: release transaction and automated rollback both failed for %s; invoke the protected emergency rollback immediately.\n' "$tag" >&2
  fi
  exit "$failure_status"
}

on_error() {
  local failure_status=$?
  (( failure_status != 0 )) || failure_status=1
  rollback_transaction "$failure_status"
}
trap on_error ERR INT TERM

decoded_manifest="${temporary_dir}/decoded-manifest.json"
manifest_team_id="$(jq -r '.signing.teamID // empty' "$manifest")"
[[ "$manifest_team_id" =~ ^[A-Z0-9]{10}$ ]] || release_die 'preflight manifest Team ID is invalid'
expected_team_id="${SUPRA_RELEASE_TEAM_ID:-2DP657YB3K}"
[[ "$manifest_team_id" == "$expected_team_id" ]] \
  || release_die 'preflight manifest Team ID does not match protected release configuration'
release_verify_cms_manifest "$manifest_signature" "$manifest" "$manifest_team_id" "$decoded_manifest"
jq -e --arg repository "$repository" --arg source "$source_sha" --arg version "$version" --arg build "$build" '
  .schemaVersion == 1 and .manifestKind == "supra-release-preflight" and
  .repository == $repository and .source.sha == $source and .source.originMain == $source and
  .release.version == $version and .release.build == $build and .release.tag == ("v" + $version) and
  .reviewedBuildMetadata.marketingVersion == $version and
  .reviewedBuildMetadata.currentProjectVersion == $build and
  (.ciRuns | length >= 1) and
  (.ciRuns | all(.[]; .headSha == $source and .conclusion == "success")) and
  (.artifacts | map(.kind) | sort == ["app", "dmg", "zip"])
' "$manifest" >/dev/null || release_die 'release transaction inputs do not match preflight manifest'

manifest_artifact() {
  local kind="$1" key="$2"
  jq -r --arg kind "$kind" --arg key "$key" '.artifacts[] | select(.kind == $kind) | .[$key]' "$manifest"
}
manifest_app_sha="$(manifest_artifact app sha256)"
release_validate_digest "$manifest_app_sha"
release_verify_embedded_smoke_attestation \
  "$manifest" "$source_sha" "$manifest_app_sha" "$version" "$build"

for pair in "zip:$zip" "dmg:$dmg"; do
  kind="${pair%%:*}"
  path="${pair#*:}"
  [[ "$(basename "$path")" == "$(manifest_artifact "$kind" name)" \
    && "$(release_sha256 "$path")" == "$(manifest_artifact "$kind" sha256)" \
    && "$(release_file_size "$path")" == "$(manifest_artifact "$kind" sizeBytes)" ]] \
    || release_die 'publication artifact does not match signed preflight manifest'
done

release_notes="${temporary_dir}/release-notes.md"
printf 'Supra AI %s\n\nSource: `%s`\nBuild: `%s`\nChecksums: signed `preflight-manifest.json`\n' \
  "$version" "$source_sha" "$build" >"$release_notes"
"$gh_command" release create "$tag" --repo "$repository" --target "$source_sha" --draft \
  --title "Supra AI ${version}" --notes-file "$release_notes"
draft_created=1
"$gh_command" release upload "$tag" --repo "$repository" \
  "$zip" "$dmg" "$manifest" "$manifest_signature" --clobber

uploaded_dir="${temporary_dir}/uploaded"
mkdir -p "$uploaded_dir"
"$gh_command" release download "$tag" --repo "$repository" \
  --pattern "$(basename "$zip")" --dir "$uploaded_dir" --clobber
uploaded_zip="${uploaded_dir}/$(basename "$zip")"
[[ -f "$uploaded_zip" \
  && "$(release_sha256 "$uploaded_zip")" == "$(manifest_artifact zip sha256)" \
  && "$(release_file_size "$uploaded_zip")" == "$(manifest_artifact zip sizeBytes)" ]] \
  || release_die 'uploaded ZIP digest differs from signed preflight manifest'

prepared_appcast="${temporary_dir}/appcast.xml"
prepared_constants="${temporary_dir}/constants.ts"
bash "${root}/Scripts/prepare-release-appcast.sh" \
  --appcast-in "$appcast_in" --constants-in "$constants_in" \
  --appcast-out "$prepared_appcast" --constants-out "$prepared_constants" \
  --zip "$uploaded_zip" --version "$version" --build "$build" \
  --repository "$repository" --sign-update "$sign_update"

website_stage="${temporary_dir}/website"
mkdir -p "$website_stage"
cp -R "${repo_root}/website/." "$website_stage/"
cp "$prepared_appcast" "${website_stage}/public/appcast.xml"
cp "$prepared_constants" "${website_stage}/lib/constants.ts"
bash "${root}/Scripts/verify-release-artifact-contents.sh" "$website_stage" >/dev/null \
  || release_die 'staged website artifact policy failed'
"$website_gate" "$website_stage" >/dev/null || release_die 'staged website release gate failed'
built_website="${website_stage}/out"
if [[ ! -d "$built_website" ]]; then
  if [[ "${SUPRA_RELEASE_TESTING:-0}" == '1' ]]; then
    built_website="$website_stage"
  else
    release_die 'staged website gate did not produce a static Pages artifact'
  fi
fi
bash "${root}/Scripts/verify-release-artifact-contents.sh" "$built_website" >/dev/null \
  || release_die 'built Pages artifact policy failed'

"$gh_command" release edit "$tag" --repo "$repository" --draft=false --latest
release_public=1

appcast_commit_file="${temporary_dir}/appcast-commit.txt"
"$appcast_publish" \
  --repo-root "$repo_root" --repository "$repository" --source-sha "$source_sha" \
  --version "$version" --appcast "$prepared_appcast" --constants "$prepared_constants" \
  --output "$appcast_commit_file"
appcast_commit="$(tr -d '[:space:]' <"$appcast_commit_file")"
release_validate_sha "$appcast_commit"

deploy_json="$("$gh_command" run list --repo "$repository" --workflow deploy-website.yml \
  --commit "$appcast_commit" --json databaseId,headSha,conclusion,status --limit 10)"
deploy_run_id="$(jq -r --arg sha "$appcast_commit" '[.[] | select(.headSha == $sha)][0].databaseId // empty' <<<"$deploy_json")"
[[ "$deploy_run_id" =~ ^[1-9][0-9]*$ ]] || release_die 'website deployment run was not created for appcast commit'
"$gh_command" run watch "$deploy_run_id" --repo "$repository" --exit-status

public_release_json="$("$gh_command" release view "$tag" --repo "$repository" \
  --json tagName,targetCommitish,url,isDraft)"
jq -e --arg tag "$tag" --arg source "$source_sha" \
  --arg url "https://github.com/${repository}/releases/tag/${tag}" '
  .tagName == $tag and .targetCommitish == $source and .isDraft == false and
  .url == $url
' <<<"$public_release_json" >/dev/null || release_die 'public release tag/source metadata mismatch'
public_release_url="$(jq -r '.url' <<<"$public_release_json")"

public_dir="${temporary_dir}/public"
mkdir -p "$public_dir"
public_zip="${public_dir}/$(basename "$zip")"
public_dmg="${public_dir}/$(basename "$dmg")"
public_appcast="${public_dir}/appcast.xml"
public_manifest="${public_dir}/$(basename "$manifest")"
public_manifest_signature="${public_dir}/$(basename "$manifest_signature")"
"$curl_command" --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$public_zip" "https://github.com/${repository}/releases/download/${tag}/$(basename "$zip")"
"$curl_command" --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$public_dmg" "https://github.com/${repository}/releases/download/${tag}/$(basename "$dmg")"
"$curl_command" --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$public_appcast" 'https://supralegal.ai/appcast.xml'
"$curl_command" --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$public_manifest" "https://github.com/${repository}/releases/download/${tag}/$(basename "$manifest")"
"$curl_command" --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$public_manifest_signature" "https://github.com/${repository}/releases/download/${tag}/$(basename "$manifest_signature")"

[[ "$(release_sha256 "$public_zip")" == "$(manifest_artifact zip sha256)" \
  && "$(release_file_size "$public_zip")" == "$(manifest_artifact zip sizeBytes)" \
  && "$(release_sha256 "$public_dmg")" == "$(manifest_artifact dmg sha256)" \
  && "$(release_file_size "$public_dmg")" == "$(manifest_artifact dmg sizeBytes)" ]] \
  || release_die 'post-publication artifact digest mismatch'
[[ "$(release_sha256 "$public_manifest")" == "$(release_sha256 "$manifest")" \
  && "$(release_sha256 "$public_manifest_signature")" == "$(release_sha256 "$manifest_signature")" ]] \
  || release_die 'post-publication manifest digest mismatch'
release_verify_cms_manifest "$public_manifest_signature" "$public_manifest" \
  "$manifest_team_id" "${temporary_dir}/public-manifest-decoded.json"
xmllint --noout "$public_appcast" >/dev/null 2>&1 || release_die 'public appcast is invalid XML'
cmp -s "$public_appcast" "$prepared_appcast" || release_die 'public appcast differs from validated appcast bytes'
grep -Fq "<sparkle:version>${build}</sparkle:version>" "$public_appcast" \
  || release_die 'public appcast build mismatch'
grep -Fq "releases/download/${tag}/$(basename "$zip")" "$public_appcast" \
  || release_die 'public appcast URL mismatch'

result_dir="${repo_root}/build/release"
mkdir -p "$result_dir"
result_file="${result_dir}/release-result-${tag}.json"
jq -n \
  --arg completedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg repository "$repository" --arg tag "$tag" --arg source "$source_sha" \
  --arg version "$version" --arg build "$build" --arg appcastCommit "$appcast_commit" \
  --arg releaseURL "$public_release_url" \
  --arg appcastURL 'https://supralegal.ai/appcast.xml' \
  --arg zipSHA "$(manifest_artifact zip sha256)" --arg dmgSHA "$(manifest_artifact dmg sha256)" \
  --arg manifestSHA "$(release_sha256 "$manifest")" \
  '{schemaVersion: 1, status: "published-and-verified", completedAt: $completedAt,
    repository: $repository, tag: $tag, sourceSha: $source, version: $version, build: $build,
    releaseURL: $releaseURL, appcastURL: $appcastURL, appcastCommit: $appcastCommit,
    publicDigests: {zipSHA256: $zipSHA, dmgSHA256: $dmgSHA, manifestSHA256: $manifestSHA}}' >"$result_file"

trap - ERR INT TERM
rm -rf "$temporary_dir"
printf 'Release transaction completed for %s at %s; appcast commit %s.\n' "$tag" "$source_sha" "$appcast_commit"
