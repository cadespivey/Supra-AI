#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scope_script="${repo_root}/Scripts/website-dependency-audit-required.sh"
macos_workflow="${repo_root}/.github/workflows/macos-ci.yml"
deploy_workflow="${repo_root}/.github/workflows/deploy-website.yml"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

required_inputs=(
  website/
  Scripts/test-website.sh
  Scripts/verify-public-font-license.sh
  Scripts/website-dependency-audit-required.sh
  .github/workflows/macos-ci.yml
  .github/workflows/deploy-website.yml
  .github/workflows/security-scheduled.yml
)

if [[ ! -x "$scope_script" ]]; then
  fail 'website dependency-audit scope script is missing or not executable'
else
  for input in "${required_inputs[@]}"; do
    grep -Fq -- "$input" "$scope_script" \
      || fail "audit scope script omits control input: $input"
  done

  fixture="${temporary_dir}/fixture"
  mkdir -p "${fixture}/website" "${fixture}/Scripts" "${fixture}/.github/workflows" "${fixture}/Docs"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Supra CI Test'
  git -C "$fixture" config user.email 'ci-test@example.invalid'
  for input in "${required_inputs[@]}"; do
    path="${input%/}"
    if [[ "$input" == */ ]]; then path="${path}/index.txt"; fi
    mkdir -p "${fixture}/$(dirname "$path")"
    printf 'initial\n' >"${fixture}/${path}"
  done
  printf 'initial\n' >"${fixture}/Docs/unrelated.md"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm initial

  previous="$(git -C "$fixture" rev-parse HEAD)"
  for input in "${required_inputs[@]}"; do
    path="${input%/}"
    if [[ "$input" == */ ]]; then path="${path}/index.txt"; fi
    printf 'changed\n' >>"${fixture}/${path}"
    git -C "$fixture" add "$path"
    git -C "$fixture" commit -qm "change ${path}"
    actual="$(SUPRA_REPO_ROOT="$fixture" bash "$scope_script" "$previous" HEAD)"
    [[ "$actual" == 'true' ]] || fail "control input did not require audit: $input"
    previous="$(git -C "$fixture" rev-parse HEAD)"
  done

  printf 'changed\n' >>"${fixture}/Docs/unrelated.md"
  git -C "$fixture" add Docs/unrelated.md
  git -C "$fixture" commit -qm 'change unrelated docs'
  actual="$(SUPRA_REPO_ROOT="$fixture" bash "$scope_script" "$previous" HEAD)"
  [[ "$actual" == 'false' ]] || fail 'unrelated change unexpectedly required dependency audit'

  actual="$(SUPRA_REPO_ROOT="$fixture" bash "$scope_script" deadbeef HEAD 2>/dev/null)"
  [[ "$actual" == 'true' ]] || fail 'invalid base commit did not fail closed to audit'
fi

grep -Fq 'Scripts/website-dependency-audit-required.sh' "$macos_workflow" \
  || fail 'Protected macOS CI does not use the shared website audit scope'

deploy_paths="$(sed -n '/^[[:space:]]*paths:/,/^[[:space:]]*workflow_dispatch:/p' "$deploy_workflow")"
for input in "${required_inputs[@]}"; do
  expected="$input"
  if [[ "$input" == */ ]]; then expected="${input}**"; fi
  grep -Fq -- "- \"${expected}\"" <<<"$deploy_paths" \
    || fail "deploy workflow path filter omits audit control input: $expected"
done

grep -Fq 'Tests/Scripts/test-website-audit-governance.sh' "$macos_workflow" \
  || fail 'Protected macOS CI does not execute the website audit governance test'

if (( failures != 0 )); then
  printf 'Website audit governance tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'Website audit governance tests passed.'
