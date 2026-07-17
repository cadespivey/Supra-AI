#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_root="$(cd "$repo_root" && pwd -P)"

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--verify-baseline" ]]; }; then
  printf '%s\n' 'usage: bash Scripts/run-benchmarks.sh [--verify-baseline]' >&2
  exit 2
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
current_report="${temporary_dir}/current.json"
current_normalized="${temporary_dir}/current-normalized.json"
baseline_normalized="${temporary_dir}/baseline-normalized.json"
proposal_manifest="${repo_root}/TestData/Benchmarks/threshold-proposals.json"
baseline_path="$(jq -er '.baselinePath' "$proposal_manifest")"
baseline_report="${repo_root}/${baseline_path}"

(
  cd "${repo_root}/Packages/SupraTestKit"
  swift run SupraBench --deterministic --output "$current_report"
  swift test --filter BenchmarkBaselineContractTests
)

jq -S 'del(.run.generatedAt, .run.repositorySHA)' "$current_report" >"$current_normalized"
jq -S 'del(.run.generatedAt, .run.repositorySHA)' "$baseline_report" >"$baseline_normalized"
if ! cmp -s "$baseline_normalized" "$current_normalized"; then
  printf '%s\n' 'ERROR: deterministic benchmark drifted from the frozen baseline' >&2
  diff -u "$baseline_normalized" "$current_normalized" >&2 || true
  exit 1
fi

jq '{
  schemaVersion,
  sourceSHA: .run.repositorySHA,
  fixtureSHA256: .run.corpusManifestSHA256,
  measured: [.metrics[] | .measurements[] | select(.status == "measured") | {name, value}],
  notApplicableCount: ([.metrics[] | select(all(.measurements[]; .status == "not_applicable"))] | length)
}' "$current_report"
printf '%s\n' 'Deterministic document benchmark matches the frozen baseline.'
