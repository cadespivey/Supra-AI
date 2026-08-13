# D-17 — Identity-Owned, Create-Only Artifact Publication

Status: **approved operating decision (2026-08-13); implementation gates pending**

## Context

Timestamp-derived names and replace-in-place installation do not establish file ownership.
Same-second exports can collide, and compensation can overwrite a file another process or person
changed after Supra attempted publication.

## Decision

Every exported or drafted artifact is immutable and create-only. Publication begins with a
Store-owned intent containing a stable intent ID, immutable source/work-product version, format,
destination directory authority, and a unique intended identity. The installed name is derived
from that identity (a human-readable stem plus a collision-resistant suffix), not from timestamp
uniqueness alone.

The publisher uses exclusive creation or an equivalent atomic no-replace primitive. After install,
it reads back the authoritative file identity, bytes/digest, and format before Store finalization.
Only an exact match completes the intent and normative audit.

An explicit later action is **Export new version**. It creates a new intent and a new artifact;
it never silently replaces a prior receipt.

If finalization fails, compensation may remove/restore only bytes still authenticated as owned by
the exact intent. A changed, replaced, or ambiguous file is preserved and the intent becomes
`recoveryRequired`. Relaunch reconciliation finalizes only authenticated exact files.

## Consequences

- Same-second and concurrent publication remain unique and attributable.
- Finder presence is insufficient; terminal success requires authenticated read-back plus Store
  finalization.
- Existing user files, including retired Case File Review CSV/XLSX files, are outside retirement
  authority and remain untouched.
- Native Word, Numbers, or PDF inspection supplements structural validation for applicable formats.

## Enforcement and gates

Owner: the durable file writer/publication-intent boundary plus the owning Store repository.

Required gates: `T-ART-01/02/03`, `T-OUTCOME-01`, `T-OOXML-01`, and applicable native artifact
inspection in the qualification matrix.
