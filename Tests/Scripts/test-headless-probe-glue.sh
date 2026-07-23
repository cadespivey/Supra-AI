#!/usr/bin/env bash
set -euo pipefail

# App-target probe-glue guards (review follow-up on #115). The package tests
# gate HeadlessProbeMode's DECISION logic, but the AppEnvironment glue that
# consumes it is app-target code no package test executes — the #115 review
# showed that deleting the user-store guard from makeStore() passed the entire
# suite. These greps pin the load-bearing lines so removing one fails CI
# instead of silently reopening the user-store / silent-hang defects.
#
# Guards marked [standing] pin behavior that already existed and were green at
# introduction. The coverage-unavailability guard was the observed RED for the
# degraded-store fix: before it, a coverage probe on a fallback/recovery store
# ran nothing and reported nothing, and a headless harness hung forever.

repo_root="$(git rev-parse --show-toplevel)"
app_environment="${repo_root}/Apps/SupraAI/SupraAI/AppEnvironment.swift"
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Comment lines are stripped once up front; guards match against code only.
# (Materialized rather than piped per guard: grep -q's early exit would SIGPIPE
# an upstream grep under pipefail, making a guard's verdict race-dependent.)
code="$(grep -vE '^[[:space:]]*//' "$app_environment")"

# [standing] Store isolation: the store-opening path must consult the probe
# resolution's user-store authority.
if grep -Fq 'headlessProbeResolution.permitsUserStoreOpen' <<<"$code"; then
  printf '%s\n' 'PASS: store opening consults permitsUserStoreOpen'
else
  fail 'AppEnvironment.makeStore no longer consults headlessProbeResolution.permitsUserStoreOpen'
fi

# [standing] Exclusive dispatch: probes resolve through HeadlessProbeMode.resolve
# and a flag conflict emits a report instead of running any probe.
if grep -Fq 'HeadlessProbeMode.resolve(' <<<"$code" \
    && grep -Fq 'emitHeadlessProbeConflict' <<<"$code"; then
  printf '%s\n' 'PASS: probe dispatch resolves exclusively and reports conflicts'
else
  fail 'probe dispatch no longer resolves through HeadlessProbeMode.resolve with conflict reporting'
fi

# [standing] Termination: probes leave through the app's normal termination
# path; application code never calls exit().
if grep -Eq '(^|[^A-Za-z_.])exit\(' <<<"$code"; then
  fail 'AppEnvironment calls exit() — probes must use the normal termination path'
else
  printf '%s\n' 'PASS: AppEnvironment never calls exit()'
fi

# Observed RED before the degraded-store fix: an unavailable coverage probe
# (fallback store, recovery state, or Debug build) must consult the typed
# reason and emit it before terminating.
# The exact machine-readable envelope is load-bearing: the headless harness
# polls for these delimiters and reads both status and reason. These assertions
# are [standing] guards because the production emitter already had the correct
# shape when this review exposed that function-name greps alone did not pin it.
if grep -Fq 'coverageShadowUnavailableReason' <<<"$code" \
    && grep -Fq 'emitCoverageShadowUnavailable' <<<"$code" \
    && grep -Fq '"status": "coverage_probe_unavailable"' <<<"$code" \
    && grep -Fq '"reason": reason' <<<"$code" \
    && grep -Fq 'print("===COVERAGE_SHADOW_UNAVAILABLE_BEGIN===")' <<<"$code" \
    && grep -Fq 'print("===COVERAGE_SHADOW_UNAVAILABLE_END===")' <<<"$code"; then
  printf '%s\n' 'PASS: unavailable coverage probe reports its reason and terminates'
else
  fail 'coverage probe degraded/Debug branch does not report unavailability'
fi

if (( failures != 0 )); then
  printf 'Headless probe glue tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'All headless probe glue tests passed.'
