#!/usr/bin/env bash
set -euo pipefail

# Synthetic stand-in for SupraAI.app's Release-only smoke entrypoint. The
# repository-owned driver contract test installs this at Contents/MacOS/SupraAI.
# Its behavior is selected by the first character of the required nonce so the
# driver can keep using an otherwise sanitized environment.

contents_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
printf '%s\n' "$@" >"${contents_dir}/fixture-argv.txt"
/usr/bin/env | LC_ALL=C /usr/bin/sort >"${contents_dir}/fixture-environment.txt"

if (( $# != 1 )) || [[ "$1" != '--supra-signed-release-smoke-v1' ]]; then
  exit 64
fi

source_sha="${SUPRA_RELEASE_SMOKE_SOURCE_SHA:-}"
app_sha="${SUPRA_RELEASE_SMOKE_APP_TREE_SHA256:-}"
model_sha="${SUPRA_RELEASE_SMOKE_MODEL_SHA256:-}"
nonce="${SUPRA_RELEASE_SMOKE_NONCE:-}"
model_directory="${SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY:-}"

[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 78
[[ "$app_sha" =~ ^[0-9a-f]{64}$ ]] || exit 78
[[ "$model_sha" =~ ^[0-9a-f]{64}$ ]] || exit 78
[[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || exit 78
[[ -n "$model_directory" ]] || exit 78

if ! { : >&3; } 2>/dev/null; then
  exit 74
fi

payload="$(printf '%s' \
  '{"schemaVersion":1,"status":"passed","nonce":"'"$nonce"'","sourceSha":"'"$source_sha"'","appTreeSHA256":"'"$app_sha"'","modelSHA256":"'"$model_sha"'","appBundleIdentifier":"ai.supra.SupraAI","xpcBundleIdentifier":"ai.supra.SupraAI.SupraRuntimeService","appVersion":"2.2.1","appBuild":"387","modelRepositoryID":"mlx-community/Release-Smoke-4bit","modelRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verification":{"xpcConnected":true,"modelLoaded":true,"generationStarted":true,"generationCompleted":true,"modelUnloaded":true,"modelReverified":true},"eventCounts":{"total":4,"generationStarted":1,"token":1,"metrics":1,"generationCompleted":1,"generationFailed":0,"generationCancelled":0,"reserved":0},"generatedTokenCount":7,"timings":{"loadTimeMs":123,"firstTokenLatencyMs":45,"tokensPerSecond":12.5}}')"

case "${nonce:0:1}" in
  0)
    exit 71
    ;;
  8)
    sleep 20
    ;;
  9)
    exit 0
    ;;
  b)
    printf -v padding '%*s' 17000 ''
    padding="${padding// /x}"
    payload="${payload%?},\"padding\":\"${padding}\"}"
    ;;
  c)
    printf '%s\n%s\n' "$payload" "$payload" >&3
    exit 0
    ;;
  d)
    payload="${payload%?},\"unexpected\":true}"
    ;;
  e)
    payload="${payload%?},\"tokenText\":\"PRIVATE-GENERATED-TOKEN-CANARY\"}"
    ;;
  f)
    printf '%s\n' 'fixture-stdout-canary'
    ;;
esac

printf '%s\n' "$payload" >&3
