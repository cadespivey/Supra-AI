#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"
base_sha="${1:-}"
head_sha="${2:-HEAD}"

git -C "$repo_root" rev-parse --verify "${head_sha}^{commit}" >/dev/null
if [[ -z "$base_sha" ]]; then
  base_sha="$(git -C "$repo_root" rev-parse "${head_sha}^" 2>/dev/null || true)"
fi

all_packages=0
if [[ -z "$base_sha" ]] || ! git -C "$repo_root" cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
  all_packages=1
  changed_paths="$(git -C "$repo_root" ls-tree -r --name-only "$head_sha")"
else
  changed_paths="$(git -C "$repo_root" diff --name-only "$base_sha" "$head_sha")"
fi

matches() {
  grep -Eq "$1" <<<"$changed_paths"
}

if matches '(^|/)(Package\.swift|Package\.resolved)$|^Scripts/(list-local-packages|test-all-packages)\.sh$'; then
  all_packages=1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
selected_file="${temporary_dir}/packages"
: >"$selected_file"
add_package() {
  grep -Fxq "$1" "$selected_file" 2>/dev/null || printf '%s\n' "$1" >>"$selected_file"
}
if (( all_packages == 1 )); then
  while IFS= read -r package; do add_package "$package"; done \
    < <(bash "$repo_root/Scripts/list-local-packages.sh")
else
  while IFS= read -r path; do
    [[ "$path" == Packages/*/* ]] || continue
    package="${path#Packages/}"
    add_package "${package%%/*}"
  done <<<"$changed_paths"

  changed=1
  while (( changed == 1 )); do
    changed=0
    for manifest in "$repo_root"/Packages/*/Package.swift; do
      consumer="$(basename "$(dirname "$manifest")")"
      grep -Fxq "$consumer" "$selected_file" && continue
      while IFS= read -r dependency; do
        if grep -Eq "(\.\./|package:[[:space:]]*\")${dependency}(\"|/|$)" "$manifest"; then
          add_package "$consumer"
          changed=1
          break
        fi
      done <"$selected_file"
    done
  done
fi

packages_json="$(LC_ALL=C sort -u "$selected_file" | jq -Rsc 'split("\n") | map(select(length > 0))')"

app=false
ui=false
migrations=false
website=false
benchmarks=false
release=false
governance=false
claims=false
entitlements=false
publication_metadata=false

matches '^Apps/|^SupraAI\.xcworkspace/|^Config/' && app=true
matches '^Apps/SupraAI/.*(AppEnvironment|MainShellView|SupraAIApp|RuntimeXPC|UITests/(Launch|Navigation|Runtime))|^Scripts/(run-app-smoke-tests|run-hosted-xpc-lifecycle)\.sh$' && ui=true
matches 'SupraMigration|ShippingMigrations|Database.*Schema|^Scripts/(verify-migration-sequence|run-shipping-migration-fixtures)\.sh$' && migrations=true
matches '^website/|^Scripts/(test-website|verify-public-font-license)\.sh$|^Docs/Website-Asset-Licensing\.md$|^\.github/workflows/deploy-website\.yml$' && website=true
matches '(Indexer|Retriever|Chunk|Batch|Performance|Benchmark)|^Scripts/run-benchmarks\.sh$|^TestData/Synthetic Document Intelligence Benchmark/' && benchmarks=true
matches '^Scripts/.*release.*\.sh$|^Tests/Scripts/test-.*release.*\.sh$|^\.github/workflows/(release|release-rehearsal|emergency-release-rollback)\.yml$|^Apps/SupraAI/.*entitlements$' && release=true
matches '^\.github/workflows/|^Scripts/(ci-change-plan|verify-repo-facts|verify-product-claims|verify-entitlements|verify-release-protection|verify-changed-files)\.sh$|^Tests/Scripts/test-(ci-change-plan|macos-ci-gates|verify-product-claims|headless-probe-glue|verify-changed-files)\.sh$' && governance=true
matches '^Docs/Verified-Product-Claims\.yml$|^(README|ARCHITECTURE|SECURITY|CONTRIBUTING)\.md$|^\.env\.example$|^Apps/SupraAI/SupraAI/(SettingsView\.swift|SupraAI\.entitlements)$|^website/(app|components)/|^Apps/SupraAI/SupraAI\.xcodeproj/project\.pbxproj$|^Packages/.*/Package\.swift$|SupraMigration|ShippingMigrations' && claims=true
matches 'entitlements$|project\.pbxproj$|^\.github/workflows/release|^Scripts/.*release.*\.sh$' && entitlements=true

changed_count="$(printf '%s\n' "$changed_paths" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$changed_count" == 2 ]] \
    && grep -Fxq 'website/public/appcast.xml' <<<"$changed_paths" \
    && grep -Fxq 'website/lib/constants.ts' <<<"$changed_paths"; then
  publication_metadata=true
fi

jq -n \
  --argjson packages "$packages_json" \
  --argjson app "$app" --argjson ui "$ui" --argjson migrations "$migrations" \
  --argjson website "$website" --argjson benchmarks "$benchmarks" --argjson release "$release" \
  --argjson governance "$governance" --argjson claims "$claims" --argjson entitlements "$entitlements" \
  --argjson publicationMetadata "$publication_metadata" \
  '{packages:$packages,app:$app,ui:$ui,migrations:$migrations,website:$website,benchmarks:$benchmarks,release:$release,governance:$governance,claims:$claims,entitlements:$entitlements,publicationMetadata:$publicationMetadata}'
