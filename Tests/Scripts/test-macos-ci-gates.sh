#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scripts="${repo_root}/Scripts"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
failures=0

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3
  local output_file="${temporary_dir}/output-${RANDOM}.txt"
  local status=0

  "$@" >"$output_file" 2>&1 || status=$?
  if [[ "$status" -ne "$expected_status" ]]; then
    record_failure "${name}: expected status ${expected_status}, got ${status}"
    sed 's/^/  | /' "$output_file" >&2
  elif ! grep -Fq -- "$expected_text" "$output_file"; then
    record_failure "${name}: expected output to contain: ${expected_text}"
    sed 's/^/  | /' "$output_file" >&2
  else
    printf 'PASS: %s\n' "$name"
  fi
}

package_fixture="${temporary_dir}/packages"
mkdir -p "${package_fixture}/Packages"
while IFS= read -r package; do
  mkdir -p "${package_fixture}/Packages/${package}"
  : >"${package_fixture}/Packages/${package}/Package.swift"
done <<'PACKAGES'
SupraCore
SupraDesignSystem
SupraDiagnostics
SupraDocuments
SupraDrafting
SupraDraftingCore
SupraExports
SupraNetworking
SupraResearch
SupraRuntimeClient
SupraRuntimeInterface
SupraSessions
SupraStore
SupraTestKit
PACKAGES

run_case \
  "fixed package inventory accepts the exact set" \
  0 \
  "Local package inventory passed: 14 packages." \
  env SUPRA_REPO_ROOT="$package_fixture" bash "${scripts}/list-local-packages.sh" --verify

mkdir -p "${package_fixture}/Packages/SupraUnlisted"
: >"${package_fixture}/Packages/SupraUnlisted/Package.swift"
run_case \
  "an unlisted package fails inventory" \
  1 \
  "unlisted local package: SupraUnlisted" \
  env SUPRA_REPO_ROOT="$package_fixture" bash "${scripts}/list-local-packages.sh" --verify

migration_file="${temporary_dir}/SupraMigrator.swift"
printf '%s\n' \
  'migrator.registerMigration("v001_first") { _ in }' \
  'migrator.registerMigration("v002_second") { _ in }' \
  'migrator.registerMigration("v003_third") { _ in }' >"$migration_file"
run_case \
  "contiguous migrations are derived dynamically" \
  0 \
  "Migration sequence passed: v001 through v003 (3 migrations)." \
  bash "${scripts}/verify-migration-sequence.sh" "$migration_file"

printf '%s\n' \
  'migrator.registerMigration("v001_first") { _ in }' \
  'migrator.registerMigration("v003_third") { _ in }' >"$migration_file"
run_case \
  "a migration gap fails" \
  1 \
  "migration sequence gap: expected v002, found v003" \
  bash "${scripts}/verify-migration-sequence.sh" "$migration_file"

artifact_fixture="${temporary_dir}/artifacts"
mkdir -p "${artifact_fixture}/Sources" "${artifact_fixture}/ClientData/Acme"
printf 'ordinary source\n' >"${artifact_fixture}/Sources/Feature.swift"
run_case \
  "a clean artifact tree passes" \
  0 \
  "Prohibited artifact scan passed." \
  bash "${scripts}/verify-prohibited-artifacts.sh" "$artifact_fixture"

printf 'synthetic fixture only\n' >"${artifact_fixture}/ClientData/Acme/private.txt"
run_case \
  "a prohibited synthetic path fails" \
  1 \
  "prohibited artifact path: ClientData/Acme/private.txt" \
  bash "${scripts}/verify-prohibited-artifacts.sh" "$artifact_fixture"

secret_fixture="${temporary_dir}/secrets"
mkdir -p "$secret_fixture"
printf 'SUPRA_MODEL_BACKEND=mlx\n' >"${secret_fixture}/clean.env.example"
run_case \
  "a clean secret fixture passes" \
  0 \
  "Secret scan passed." \
  bash "${scripts}/verify-secrets.sh" "$secret_fixture"

secret_canary='sk-proj-'
secret_canary+='0123456789abcdefghijklmnop'
printf 'SUPRA_API_KEY=%s\n' "$secret_canary" >"${secret_fixture}/canary.env"
secret_output="${temporary_dir}/secret-output.txt"
secret_status=0
bash "${scripts}/verify-secrets.sh" "$secret_fixture" >"$secret_output" 2>&1 || secret_status=$?
if [[ "$secret_status" -ne 1 ]] || ! grep -Fq 'possible secret in: canary.env' "$secret_output"; then
  record_failure "a secret canary must fail without exposing its value"
  sed 's/^/  | /' "$secret_output" >&2
elif grep -Fq "$secret_canary" "$secret_output"; then
  record_failure "secret scanner output exposed the canary value"
else
  printf '%s\n' 'PASS: a secret canary fails without exposing its value'
fi

app_entitlements="${temporary_dir}/SupraAI.entitlements"
service_entitlements="${temporary_dir}/SupraRuntimeService.entitlements"
plutil -create xml1 "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.files.bookmarks.app-scope bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.files.user-selected.read-write bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $(PRODUCT_BUNDLE_IDENTIFIER)-spks' "$app_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $(PRODUCT_BUNDLE_IDENTIFIER)-spki' "$app_entitlements"
plutil -create xml1 "$service_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$service_entitlements"

run_case \
  "expected entitlements pass" \
  0 \
  "Entitlement expectations passed." \
  bash "${scripts}/verify-entitlements.sh" --app "$app_entitlements" --service "$service_entitlements"

/usr/libexec/PlistBuddy -c 'Set :com.apple.security.network.client false' "$app_entitlements"
run_case \
  "entitlement drift fails" \
  1 \
  "app entitlement drift: com.apple.security.network.client" \
  bash "${scripts}/verify-entitlements.sh" --app "$app_entitlements" --service "$service_entitlements"

warning_log="${temporary_dir}/xcodebuild.log"
printf '%s\n' \
  '/tmp/DerivedData/SourcePackages/checkouts/Dependency/File.swift:1: warning: upstream warning' \
  >"$warning_log"
run_case \
  "dependency warnings do not trip the project-source gate" \
  0 \
  "Project-source warning gate passed: 0 warnings." \
  env SUPRA_PROJECT_ROOT="$repo_root" bash "${scripts}/verify-xcode-warnings.sh" "$warning_log"

printf '%s\n' \
  "${repo_root}/Apps/SupraAI/SupraAI/AppEnvironment.swift:1: warning: synthetic warning" \
  >"$warning_log"
run_case \
  "a project-source warning fails" \
  1 \
  "Project-source warning gate failed: 1 warning(s)." \
  env SUPRA_PROJECT_ROOT="$repo_root" bash "${scripts}/verify-xcode-warnings.sh" "$warning_log"

npm_stub="${temporary_dir}/npm-stub.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "$*" == "run typecheck" ]]; then exit 23; fi' \
  'exit 0' >"$npm_stub"
chmod +x "$npm_stub"
run_case \
  "a website command failure blocks the gate" \
  23 \
  "Website gate failed: typecheck" \
  env SUPRA_NPM="$npm_stub" SUPRA_FONT_GUARD=/usr/bin/true \
    bash "${scripts}/test-website.sh" "$repo_root/website"

if (( failures != 0 )); then
  printf 'macOS CI gate tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All macOS CI gate tests passed.'
