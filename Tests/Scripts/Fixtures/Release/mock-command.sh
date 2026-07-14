#!/usr/bin/env bash
set -euo pipefail

name="$(basename "$0")"
log="${MOCK_RELEASE_LOG:-/dev/null}"
printf '%s' "$name" >>"$log"
printf ' %q' "$@" >>"$log"
printf '\n' >>"$log"

argument_value() {
  local wanted="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "$wanted" ]]; then
      printf '%s\n' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}

case "$name" in
  credential-gate)
    [[ "${MOCK_CREDENTIAL_FAIL:-0}" != "1" ]]
    ;;
  font-gate)
    [[ "${MOCK_FONT_FAIL:-0}" != "1" ]]
    ;;
  release-gate)
    [[ "${MOCK_RELEASE_GATE_FAIL:-0}" != "1" ]]
    ;;
  website-gate)
    [[ "${MOCK_WEBSITE_FAIL:-0}" != "1" ]]
    ;;
  signed-smoke)
    output="$(argument_value --output "$@")"
    jq -n \
      --arg sourceSha "${MOCK_SOURCE_SHA}" \
      --arg appTreeSHA256 "${MOCK_APP_TREE_SHA}" \
      --arg modelSHA256 "${MOCK_MODEL_SHA}" \
      '{schemaVersion: 1, status: "passed", sourceSha: $sourceSha, appTreeSHA256: $appTreeSHA256, modelSHA256: $modelSHA256, xpcBundleIdentifier: "ai.supra.SupraAI.SupraRuntimeService", generatedTokens: 4}' >"$output"
    ;;
  gh)
    case "${1:-} ${2:-}" in
      "auth status") exit 0 ;;
      "run view")
        jq -n \
          --arg headSha "${MOCK_CI_HEAD_SHA:-${MOCK_SOURCE_SHA:-}}" \
          --arg conclusion "${MOCK_CI_CONCLUSION:-success}" \
          '{headSha: $headSha, conclusion: $conclusion, workflowName: "Protected macOS CI", url: "https://example.invalid/actions/runs/42"}'
        ;;
      "run list")
        if [[ -n "${MOCK_DEPLOY_LIST_COUNT_FILE:-}" ]]; then
          count="$(cat "$MOCK_DEPLOY_LIST_COUNT_FILE" 2>/dev/null || printf 0)"
          count=$((count + 1))
          printf '%s' "$count" >"$MOCK_DEPLOY_LIST_COUNT_FILE"
          if (( count <= ${MOCK_DEPLOY_LIST_ABSENT_CALLS:-0} )); then
            printf '[]\n'
            exit 0
          fi
        fi
        printf '%s\n' '[{"databaseId":9001,"headSha":"'"${MOCK_APPCAST_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"'","conclusion":"success","status":"completed"}]'
        ;;
      "run watch")
        [[ "${MOCK_DEPLOY_FAIL:-0}" != "1" ]]
        ;;
      "release view")
        if [[ " $* " == *" --json "* ]]; then
          jq -n \
            --arg tagName "${MOCK_RELEASE_TAG:-v2.3.0}" \
            --arg targetCommitish "${MOCK_SOURCE_SHA:-}" \
            --arg url "https://github.com/example/supra/releases/tag/${MOCK_RELEASE_TAG:-v2.3.0}" \
            '{tagName: $tagName, targetCommitish: $targetCommitish, url: $url, isDraft: false}'
        else
          [[ "${MOCK_RELEASE_EXISTS:-0}" == "1" ]]
        fi
        ;;
      "release create")
        [[ "${MOCK_DRAFT_FAIL:-0}" != "1" ]]
        ;;
      "release upload")
        [[ "${MOCK_UPLOAD_FAIL:-0}" != "1" ]]
        ;;
      "release download")
        destination="$(argument_value --dir "$@")"
        mkdir -p "$destination"
        cp "${MOCK_ZIP_SOURCE}" "${destination}/$(basename "${MOCK_ZIP_SOURCE}")"
        ;;
      "release edit"|"release delete") exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  sign_update)
    if [[ "${1:-}" == "--verify" ]]; then
      [[ "${MOCK_SIGN_VERIFY_FAIL:-0}" != "1" ]]
      exit
    fi
    bytes="$(stat -f%z "$1")"
    bytes=$((bytes + ${MOCK_SIGN_LENGTH_DELTA:-0}))
    printf 'sparkle:edSignature="c3ludGhldGljLXNpZ25hdHVyZQ==" length="%s"\n' "$bytes"
    ;;
  codesign)
    [[ "${MOCK_CODESIGN_FAIL:-0}" != "1" ]] || exit 1
    if [[ " $* " == *" --entitlements "* ]]; then
      target="${!#}"
      if [[ "$target" == *.xpc ]]; then
        cat "${MOCK_SERVICE_ENTITLEMENTS}"
      else
        cat "${MOCK_APP_ENTITLEMENTS}"
      fi
    elif [[ " $* " == *" -d "* || " $* " == *" -dv "* ]]; then
      printf '%s\n' 'Executable=synthetic' 'flags=0x10000(runtime)' "TeamIdentifier=${MOCK_TEAM_ID:-2DP657YB3K}" >&2
    fi
    ;;
  xcrun)
    if [[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]]; then
      [[ "${MOCK_STAPLER_FAIL:-0}" != "1" ]]
    fi
    ;;
  spctl)
    [[ "${MOCK_GATEKEEPER_FAIL:-0}" != "1" ]]
    ;;
  hdiutil)
    if [[ "${1:-}" == "attach" ]]; then
      mountpoint="$(argument_value -mountpoint "$@")"
      mkdir -p "$mountpoint"
      cp -R "${MOCK_APP_SOURCE}" "${mountpoint}/SupraAI.app"
      ln -s /Applications "${mountpoint}/Applications"
    fi
    ;;
  security)
    if [[ "${1:-}" == "cms" && "${2:-}" == "-D" ]]; then
      input="$(argument_value -i "$@")"
      output="$(argument_value -o "$@")"
      [[ "${MOCK_CMS_FAIL:-0}" != "1" ]] || exit 1
      cp "$input" "$output"
    elif [[ "${1:-}" == "cms" && "${2:-}" == "-S" ]]; then
      input="$(argument_value -i "$@")"
      output="$(argument_value -o "$@")"
      cp "$input" "$output"
    fi
    ;;
  appcast-publish)
    [[ "${MOCK_APPCAST_PUBLISH_FAIL:-0}" != "1" ]] || exit 1
    output="$(argument_value --output "$@")"
    appcast="$(argument_value --appcast "$@")"
    cp "$appcast" "${MOCK_PUBLIC_APPCAST_DEST}"
    printf '%s\n' "${MOCK_APPCAST_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" >"$output"
    ;;
  appcast-rollback)
    [[ "${MOCK_ROLLBACK_FAIL:-0}" != "1" ]]
    ;;
  curl)
    output="$(argument_value --output "$@" || argument_value -o "$@")"
    url="${!#}"
    case "$url" in
      *appcast.xml)
        cp "${MOCK_PUBLIC_APPCAST_DEST}" "$output"
        ;;
      *preflight-manifest.json.cms)
        cp "${MOCK_SIGNATURE_SOURCE}" "$output"
        ;;
      *preflight-manifest.json)
        cp "${MOCK_MANIFEST_SOURCE}" "$output"
        ;;
      *.zip)
        if [[ "${MOCK_POST_DIGEST_FAIL:-0}" == "1" ]]; then
          printf '%s\n' 'corrupted-public-zip' >"$output"
        else
          cp "${MOCK_ZIP_SOURCE}" "$output"
        fi
        ;;
      *.dmg) cp "${MOCK_DMG_SOURCE}" "$output" ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    printf 'unexpected mock command: %s\n' "$name" >&2
    exit 2
    ;;
esac
