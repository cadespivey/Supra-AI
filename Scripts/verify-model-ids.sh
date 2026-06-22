#!/usr/bin/env bash
#
# Verify that every curated model repoID in the catalogs resolves on Hugging Face.
#
# Why: the catalog repoIDs are downloaded by the in-app model picker. A typo'd or
# nonexistent repo returns HTTP 401 from HF (it returns 401, not 404, for a repo that
# does not exist), which the user only discovers as a failed download. This catches it
# before release (release.sh runs it as a pre-flight) and in CI (.github/workflows/
# verify-model-ids.yml runs it on catalog changes + weekly to catch upstream removals).
#
# Usage: Scripts/verify-model-ids.sh
# Exit:  0 = all resolve (HTTP 200); 1 = one or more do not, or extraction failed.
#
# Note: a gated repo can return 401 even though it exists; the curated set is all
# public (mlx-community / lmstudio-community / BAAI / nomic-ai / mixedbread-ai).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES=(
  "${ROOT}/Packages/SupraSessions/Sources/SupraSessions/ModelCatalog.swift"
  "${ROOT}/Packages/SupraSessions/Sources/SupraSessions/EmbeddingModelCatalog.swift"
)

# Extract repoID string literals that look like "<org>/<name>" (the actual catalog
# entries — the `repoID: String` property/param/func declarations have no slashed value).
ids="$(grep -hoE 'repoID: "[^"]+/[^"]+"' "${FILES[@]}" | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)"

if [[ -z "${ids}" ]]; then
  echo "✗ No model repoIDs extracted from the catalogs — check the grep pattern." >&2
  exit 1
fi

fail=0
count=0
while IFS= read -r id; do
  [[ -z "${id}" ]] && continue
  count=$((count + 1))
  code="$(curl -sS -o /dev/null -w '%{http_code}' --retry 2 --max-time 30 "https://huggingface.co/api/models/${id}" 2>/dev/null || echo "000")"
  if [[ "${code}" == "200" ]]; then
    printf '  ✓ %s\n' "${id}"
  else
    printf '  ✗ %s  (HTTP %s)\n' "${id}" "${code}"
    fail=1
  fi
done <<< "${ids}"

echo "Checked ${count} catalog model repo IDs against Hugging Face."
if [[ "${fail}" -ne 0 ]]; then
  cat >&2 <<'MSG'
✗ One or more catalog model IDs do not resolve on Hugging Face (HTTP != 200).
  A 401 usually means the repo does not exist under that name. Find the current ID at:
    https://huggingface.co/api/models?author=<org>&search=<name>
  and fix it in ModelCatalog.swift / EmbeddingModelCatalog.swift.
MSG
  exit 1
fi
echo "✓ All catalog model IDs resolve on Hugging Face."
