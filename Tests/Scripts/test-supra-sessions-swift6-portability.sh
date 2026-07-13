#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
backup_source="${repo_root}/Packages/SupraSessions/Sources/SupraSessions/BackupController.swift"
backup_tests="${repo_root}/Packages/SupraSessions/Tests/SupraSessionsTests/BackupControllerTests.swift"
billing_source="${repo_root}/Packages/SupraSessions/Sources/SupraSessions/BillingDraftController.swift"
failures=0

record_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Expected RED before the portability fix: the macOS 15 Swift 6 compiler rejects
# an actor-isolated async operation whose unconstrained generic result can cross
# an isolation boundary. Pin every protocol/conformance declaration to Sendable.
if rg -n -F 'func withAccess<T>' "$backup_source" "$backup_tests" >&2; then
  record_failure 'BackupDestination withAccess generic result is not constrained to Sendable'
fi

with_access_declarations="$(
  { rg -n -F 'func withAccess<T: Sendable>' "$backup_source" "$backup_tests" || true; } |
    wc -l | tr -d ' '
)"
if [[ "$with_access_declarations" != '3' ]]; then
  record_failure "expected 3 Sendable withAccess declarations, found ${with_access_declarations}"
fi

# Expected RED before the portability fix: the macOS 15 Swift 6 compiler cannot
# infer the nested optional produced by Optional.map around this inout helper.
# Require a typed local and explicit optional branching so inference is stable.
if ! rg -Fq 'let profile: MatterBillingProfileRecord?' "$billing_source"; then
  record_failure 'billing profile lookup does not declare its optional result type'
fi
if rg -n -F 'record.matterID.map { profile(for:' "$billing_source" >&2; then
  record_failure 'billing profile lookup still uses the ambiguous Optional.map expression'
fi

if (( failures != 0 )); then
  printf 'SupraSessions Swift 6 portability tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'SupraSessions Swift 6 portability tests passed.'
