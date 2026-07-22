#!/usr/bin/env bash
set -euo pipefail

repo_root="${SUPRA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
base_ref="${1:-}"
head_ref="${2:-HEAD}"

audit_control_inputs=(
  website/
  Scripts/test-website.sh
  Scripts/verify-public-font-license.sh
  Scripts/website-dependency-audit-required.sh
  .github/workflows/macos-ci.yml
  .github/workflows/deploy-website.yml
  .github/workflows/security-scheduled.yml
)

# An unresolved comparison is not evidence that the audit may be skipped. Emit the
# literal consumed by the workflow and succeed so the downstream gate runs fail-closed.
if [[ -z "$base_ref" ]] \
    || ! git -C "$repo_root" cat-file -e "${base_ref}^{commit}" 2>/dev/null \
    || ! git -C "$repo_root" cat-file -e "${head_ref}^{commit}" 2>/dev/null; then
  printf '%s\n' 'Website audit comparison unavailable; dependency audit required.' >&2
  printf '%s\n' 'true'
  exit 0
fi

status=0
git -C "$repo_root" diff --quiet "$base_ref" "$head_ref" -- "${audit_control_inputs[@]}" \
  || status=$?
case "$status" in
  0) printf '%s\n' 'false' ;;
  1) printf '%s\n' 'true' ;;
  *)
    printf '%s\n' 'Website audit comparison failed; dependency audit required.' >&2
    printf '%s\n' 'true'
    ;;
esac
