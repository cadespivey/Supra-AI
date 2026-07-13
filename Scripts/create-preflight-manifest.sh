#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

usage() {
  printf '%s\n' \
    'Usage: create-preflight-manifest.sh --source-manifest FILE --app APP --zip ZIP --dmg DMG --team-id TEAM --output FILE [--smoke-result FILE]' >&2
  exit 2
}

source_manifest=''
app=''
zip=''
dmg=''
team_id=''
output=''
smoke_result=''
while (( $# > 0 )); do
  case "$1" in
    --source-manifest) source_manifest="${2:-}"; shift 2 ;;
    --app) app="${2:-}"; shift 2 ;;
    --zip) zip="${2:-}"; shift 2 ;;
    --dmg) dmg="${2:-}"; shift 2 ;;
    --team-id) team_id="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --smoke-result) smoke_result="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$source_manifest" && -d "$app" && -f "$zip" && -f "$dmg" && -n "$output" ]] || usage
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || release_die 'invalid release Team ID'
for command in jq shasum; do release_require_command "$command"; done

jq -e '
  .schemaVersion == 1 and
  .manifestKind == "supra-release-source-preflight" and
  (.source.sha | test("^[0-9a-f]{40}$")) and
  (.source.sha == .source.originMain) and
  (.release.version | type == "string") and
  (.release.build | test("^[1-9][0-9]*$")) and
  .reviewedBuildMetadata.marketingVersion == .release.version and
  .reviewedBuildMetadata.currentProjectVersion == .release.build and
  (.ciRuns | length >= 1) and
  (.ciRuns | all(.[]; .headSha == $sha and .conclusion == "success"))
' --arg sha "$(jq -r '.source.sha // empty' "$source_manifest")" "$source_manifest" >/dev/null \
  || release_die 'source preflight manifest is invalid or not SHA-bound'

version="$(jq -r '.release.version' "$source_manifest")"
build="$(jq -r '.release.build' "$source_manifest")"
source_sha="$(jq -r '.source.sha' "$source_manifest")"
release_validate_version "$version"
release_validate_build "$build"
release_validate_sha "$source_sha"

[[ "$(basename "$app")" == 'SupraAI.app' ]] || release_die 'release app must be named SupraAI.app'
[[ "$(basename "$zip")" == "SupraAI-${version}.zip" ]] || release_die 'ZIP name does not match release version'
[[ "$(basename "$dmg")" == "SupraAI-${version}.dmg" ]] || release_die 'DMG name does not match release version'
[[ -d "${app}/Contents/XPCServices/SupraRuntimeService.xpc" ]] \
  || release_die 'signed app is missing the embedded runtime service'

app_sha="$(release_directory_digest "$app")"
app_size="$(release_directory_size "$app")"
zip_sha="$(release_sha256 "$zip")"
zip_size="$(release_file_size "$zip")"
dmg_sha="$(release_sha256 "$dmg")"
dmg_size="$(release_file_size "$dmg")"
source_manifest_sha="$(release_sha256 "$source_manifest")"
generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

smoke_json='null'
if [[ -n "$smoke_result" ]]; then
  [[ -f "$smoke_result" ]] || release_die 'signed runtime smoke result is missing'
  smoke_json="$(jq -c \
    --arg sha256 "$(release_sha256 "$smoke_result")" \
    '{
      status: .status,
      sourceSha: .sourceSha,
      appTreeSHA256: .appTreeSHA256,
      modelSHA256: .modelSHA256,
      xpcBundleIdentifier: .xpcBundleIdentifier,
      generatedTokens: .generatedTokens,
      resultSHA256: $sha256
    }' "$smoke_result")"
  jq -e --arg source "$source_sha" --arg appSHA "$app_sha" '
    .status == "passed" and .sourceSha == $source and .appTreeSHA256 == $appSHA and
    (.modelSHA256 | test("^[0-9a-f]{64}$")) and
    .xpcBundleIdentifier == "ai.supra.SupraAI.SupraRuntimeService" and
    (.generatedTokens | type == "number" and . > 0)
  ' <<<"$smoke_json" >/dev/null || release_die 'signed runtime smoke result does not match release bytes'
fi

mkdir -p "$(dirname "$output")"
temporary_output="$(mktemp "$(dirname "$output")/.preflight-manifest.XXXXXX")"
trap 'rm -f "$temporary_output"' EXIT
jq -n \
  --slurpfile sourcePreflight "$source_manifest" \
  --arg generatedAt "$generated_at" \
  --arg sourceManifestSHA256 "$source_manifest_sha" \
  --arg teamID "$team_id" \
  --arg appName "$(basename "$app")" --arg appSHA "$app_sha" --argjson appSize "$app_size" \
  --arg zipName "$(basename "$zip")" --arg zipSHA "$zip_sha" --argjson zipSize "$zip_size" \
  --arg dmgName "$(basename "$dmg")" --arg dmgSHA "$dmg_sha" --argjson dmgSize "$dmg_size" \
  --argjson smoke "$smoke_json" \
  '{
    schemaVersion: 1,
    manifestKind: "supra-release-preflight",
    generatedAt: $generatedAt,
    sourceManifestSHA256: $sourceManifestSHA256,
    repository: $sourcePreflight[0].repository,
    source: $sourcePreflight[0].source,
    release: $sourcePreflight[0].release,
    reviewedBuildMetadata: $sourcePreflight[0].reviewedBuildMetadata,
    toolchain: $sourcePreflight[0].toolchain,
    dependencyLocks: $sourcePreflight[0].dependencyLocks,
    ciRuns: $sourcePreflight[0].ciRuns,
    gates: $sourcePreflight[0].gates,
    signing: {
      teamID: $teamID,
      appBundleIdentifier: "ai.supra.SupraAI",
      xpcBundleIdentifier: "ai.supra.SupraAI.SupraRuntimeService",
      hardenedRuntimeRequired: true,
      notarizationRequired: true
    },
    artifacts: [
      {kind: "app", name: $appName, digestType: "supra-directory-sha256-v1", sha256: $appSHA, sizeBytes: $appSize},
      {kind: "zip", name: $zipName, digestType: "sha256", sha256: $zipSHA, sizeBytes: $zipSize},
      {kind: "dmg", name: $dmgName, digestType: "sha256", sha256: $dmgSHA, sizeBytes: $dmgSize}
    ],
    signedRuntimeSmoke: $smoke
  }' >"$temporary_output"

jq -e '
  .schemaVersion == 1 and .manifestKind == "supra-release-preflight" and
  (.artifacts | length == 3) and
  (.artifacts | map(.kind) | sort == ["app", "dmg", "zip"]) and
  (.artifacts | all(.[]; (.sha256 | test("^[0-9a-f]{64}$")) and .sizeBytes >= 0))
' "$temporary_output" >/dev/null || release_die 'generated preflight manifest is invalid'

mv -f "$temporary_output" "$output"
trap - EXIT
printf 'Preflight manifest created for v%s (%s) at %s.\n' "$version" "$build" "$source_sha"
