# Executive summary

## Post-review remediation notice — 2026-07-13

This executive summary is the historical assessment of `main` at `24a802cb0ab763a225982813a7b1c374864bbdeb`; the original findings and release decision below are intentionally unchanged. A remediation program was subsequently implemented on `remediation/acr-program`. The implementation replaces label-presence checks with fail-closed proposition support, blocks unsafe drafts before rendering, enforces redirect policy on every hop, confines billing to an evidence-derived matter graph, hardens document/model/export persistence, adds shipping-migration and macOS CI gates, binds release transactions to an exact source SHA, and makes product claims executable.

The remediation does not establish that GitHub's server-owned hidden refs/caches are clean; the repository owner assigned that work to GitHub Support. It also does not substitute for attorney approval of the legal-support corpus, a signed/notarized release-candidate rehearsal, live protected GitHub rulesets/environments, or real-weight MLX qualification. The dated execution record, conservative finding dispositions, exact commit ledger, verification evidence, and remaining release gates are in `12-remediation-execution-report.md`.

Final verification ran against source snapshot `fce83ebf462c76b60203eb9ccb5db4ed00c7a0de`, the 2.2.1 build 387 candidate. The vertical-window regression selectors passed 2/2, the content-bound hosted XPC lifecycle passed, all 14 package suites passed, Debug and universal Release app/XPC builds passed, and the deterministic CI, claims, release-transaction, migration, website, and XPC-boundary gates passed. Release qualification now requires repository-owned signed-smoke code, exact model/app/source evidence, and a dedicated ephemeral isolated runner. RuntimeClient and the hosted lifecycle sanitizer results remain recorded at the earlier integrated snapshot; they were not relabeled as rerun at this later SHA. These source-level results do not change the external signed-release qualifications above.

## Overall assessment

The reviewed commit builds and its broad automated suite is healthy: clean Debug and Release builds passed, all 14 packages passed 990 tests with four intentional live-test skips, and all three app UI tests passed. The signed v2.2.0 release artifacts inspected were valid, notarized, stapled, and byte-identical to the public GitHub assets.

Those positives do not establish the core legal-safety and network guarantees. Five confirmed issues are release blockers. Two independent citation paths can accept an unsupported proposition merely because it carries a valid packet label. The demand-letter path writes model prose containing an unverified case reference or `[fact?]` into a downloadable `.docx` and returns success even while describing the artifact as blocked. The authorized HTTP layer validates only the first URL and allows `URLSession` to follow a redirect outside policy. Separately, the repository's still-public hidden PR refs 39 through 50 expose all six prohibited Equity font paths.

Production readiness: **not ready for release** until SA-ACR-001 through SA-ACR-005 are remediated and their proposed merge gates pass.

## Findings at a glance

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 5 |
| Medium | 9 |
| Low | 1 |
| Informational | 0 |
| **Total** | **15** |

| Confidence classification | Count |
|---|---:|
| Confirmed defect | 8 |
| Probable defect | 2 |
| Design risk | 2 |
| Incomplete implementation | 1 |
| Verification gap | 1 |
| Code-quality issue | 1 |

## Release blockers

- **SA-ACR-001:** GitHub hidden PR refs 39–50 continue to expose the six prohibited Equity font files.
- **SA-ACR-002:** short or unhydrated legal authorities automatically pass proposition-support checking.
- **SA-ACR-003:** document Q&A verifies label existence, not factual support, and source text is not fenced as untrusted instructions.
- **SA-ACR-004:** demand-letter blocking findings do not sanitize or prevent creation/open/share of the `.docx`.
- **SA-ACR-005:** redirects can leave the default-deny allow-list without a second policy decision.

## Material risks

### Confidentiality

No broad cross-matter retrieval leak was reproduced. A targeted document-Q&A test confirmed that its prompt packet and persisted source set stayed in the selected matter. However, billing generation sends every live matter's client identity and billing rules to the local model, even for a day whose evidence mentions one matter, and accepts a model line assigning that evidence to a different matter (SA-ACR-007). Redirects also create an unauthorized egress path for request targets and query context (SA-ACR-005). SQLite and managed blobs are plaintext and rely on the user account/container and FileVault rather than application-layer encryption.

### Legal accuracy

Legal accuracy is the most serious product risk. Both `[A#]` research citations and `[S#]` document citations can look verified without proposition support (SA-ACR-002/003). Demand-letter prose is not structurally traced back to facts or authorities, and an artifact with blocking content is still downloadable (SA-ACR-004). Existing tests explicitly encode several of these unsafe outcomes as passing behavior.

### Billing integrity

`#Note` text and attachments were positively verified as filtered before prompt construction, and nothing is automatically billed. The remaining risk is cross-matter contamination and unvalidated model-supplied `sourceEntryIDs`/matter assignment (SA-ACR-007). Attorney review reduces severity but does not make the generated draft evidentially sound.

### Data loss and integrity

Ad hoc v1.4.1→v054 and v2.0.0→v054 migrations preserved synthetic records, passed `PRAGMA integrity_check`, had no foreign-key violations, and passed FTS integrity. Risks remain in document import: managed blobs are copied non-atomically without post-copy verification, existing paths are trusted, and extraction runs from the mutable original rather than the managed copy (SA-ACR-006). Exporters also replace destinations non-atomically (SA-ACR-009).

## Most affected components

1. `SupraSessions`: controller orchestration, billing scope, document Q&A, drafting, model download.
2. `SupraResearch`: proposition-support verifier and partially hydrated legal packets.
3. `SupraDocuments`: citation coverage, import/extraction policy, CSV and Office output.
4. `SupraNetworking`: redirect enforcement and fingerprinting.
5. Release/security documentation and scripts.

## Documentation contradictions with highest impact

- “Unsupported” legal citations/claims are not always quarantined; valid labels can pass unsupported propositions.
- “Every request” does not pass through the policy: redirects, model downloads, and Sparkle are separate paths; Sparkle performs scheduled background checks.
- “Keychain only” is contradicted by environment-variable fallbacks and `.env.example` key fields.
- “Read-only grants” is contradicted by the shipping `user-selected.read-write` entitlement.
- `SECURITY.md` supports 1.4.x while the current release line is 2.2.x.
- Documentation says 11 packages and migrations through v049; the tree has 14 packages and v054.

## Do existing tests provide meaningful confidence?

They provide meaningful confidence in deterministic formatting, repositories, fresh-schema behavior, basic connector request construction, `#Note` exclusion, and many UI/controller happy paths. They do **not** justify confidence in proposition support, redirect containment, hostile import boundaries, shipping-version migrations, or release gating. No GitHub workflow compiles the Swift app or runs package/UI tests. One UI helper silently returns if setup fails, and several safety tests assert the current unsafe behavior.

## First three remediation actions

1. Stop public font exposure through GitHub Support and block release until refs/caches are confirmed purged; retain the current repository and artifact guard.
2. Replace label-presence verification with sentence-to-source proposition verification in research and document Q&A; treat retrieved text as untrusted data and quarantine unsupported output in every surface.
3. Make redirect policy enforcement part of the transport and make drafting gates fail closed before rendering/persistence/open/share.

## Direct answers

1. **Should the current build be released?** No.
2. **Is privileged user data exposed to material risk?** Yes, through unauthorized redirect egress and billing cross-matter context; broad matter-document leakage was not reproduced.
3. **Can legal outputs be presented without adequate verification?** Yes.
4. **Can matter data cross boundaries?** Yes in the billing pipeline; the targeted document-Q&A boundary test passed.
5. **Can billing outputs contain excluded or unsupported content?** `#Note` content was correctly excluded, but unsupported or cross-matter assignments can still be generated and persisted for review.
6. **Do the current tests justify confidence in the core guarantees?** No.

Review limitations are detailed in `10-open-questions-and-limitations.md`.
