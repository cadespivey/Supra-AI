#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/release-common.sh
source "${root}/Scripts/lib/release-common.sh"

release_require_protected_environment

bash "${root}/Scripts/verify-repo-facts.sh"
bash "${root}/Scripts/verify-secrets.sh"
bash "${root}/Scripts/verify-entitlements.sh"
bash "${root}/Scripts/verify-prohibited-artifacts.sh"
bash "${root}/Scripts/verify-public-font-license.sh"
bash "${root}/Scripts/verify-release-protection.sh"
bash "${root}/Scripts/verify-public-repository-assets.sh" "${SUPRA_RELEASE_REPOSITORY:?SUPRA_RELEASE_REPOSITORY is required}"
bash "${root}/Scripts/verify-model-ids.sh"

claims_gate="${root}/Scripts/verify-product-claims.sh"
[[ -x "$claims_gate" ]] || release_die 'verified product-claims gate is missing'
bash "$claims_gate"

printf '%s\n' 'Release-specific repository, security, live metadata, and claims gates passed.'
