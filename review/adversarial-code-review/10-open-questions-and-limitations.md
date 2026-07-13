# Open questions and limitations

## Environment and access limitations

- No model weights were available. Real MLX load, generation quality, embedding dimensions, cancellation under compute, memory pressure, and model switching were not exercised.
- No CourtListener or optional provider credentials were used. Live authenticated token rotation/expiry, provider schema drift, pagination, rate-limit headers, and real redirect behavior remain unverified.
- Three SupraResearch live tests and one SupraTestKit CourtListener test skipped by design.
- No real client data was used; all temporary matter/document/billing content was synthetic.
- The instruction document disappeared from the original Desktop path during the review; the same file was found in the user's iCloud Trash and read there. No restoration was performed.
- GitHub hidden PR refs are server-owned. The review could verify public tree-path metadata but could not delete refs/caches or confirm Support-side garbage collection.

## Build, signing, and release limitations

- Debug and Release source builds used `CODE_SIGNING_ALLOWED=NO`. The separately inspected signed/notarized artifact was v2.2.0 from tag `4c2a8ff…`, not a newly notarized artifact from reviewed main `24a802c…`.
- Current main differs from v2.2.0 by licensing/appcast/documentation commits; source code risk was reviewed at main, but a SHA-identical signed artifact was not produced.
- Notarization submission, EdDSA signing, appcast publication, update installation, rollback, and release-script failure recovery were not executed.
- Thread/Address/Undefined Behavior sanitizers and Instruments were not run. The Release build's actor-isolation warning needs direct remediation.
- `npm audit` reflects the registry state on 2026-07-12 and may change; exploitability of the PostCSS advisory in this static site was assessed only from code shape.

## Data and migration limitations

- No real historical user databases were available. The v1.4.1 and v2.0.0 fixtures were small and synthetic.
- Intermediate release fixtures (v1.5.2, v1.8, v2.1.0, v2.1.3), large databases, historical corrupt/null/duplicate states, and actual pre-migration snapshots were not tested.
- Disk-full, read-only volume, power loss/process kill during migration/import/export, and concurrent app launch were not injected.
- FTS and orphan checks sampled current relationships and foreign keys; they were not a proof over every semantic cross-matter invariant.
- Production app-container permissions, FileVault state, backups, swap, crash reports, Spotlight, Quick Look, recent items, and clipboard retention were not measured.

## Security and network limitations

- The redirect probe used loopback/synthetic authorization. It confirmed unauthorized destination access but did not reproduce credential leakage; CFNetwork stripped the header in tested cross-host/port cases.
- DNS rebinding, TLS interception, proxy/PAC behavior, IPv6, punycode edge cases, and every connector's live redirect chain were not captured.
- Secret scanning used high-confidence regular expressions over current/reachable local Git history because no dedicated scanner was installed. Public hidden refs were not downloaded wholesale, to avoid retrieving restricted assets.
- Embedded XPC's effective client authorization was not tested from a hostile local process. An audit-token check may be defense in depth rather than required, depending on platform-enforced embedded-service scope.
- Raw-path fallback was statically reviewed under shipping sandbox entitlements but not tested with real managed/user-selected paths.

## Product and attorney-domain questions

1. What evidence threshold is required before the product may say a proposition is “verified”: verbatim excerpt, deterministic lexical support, local entailment model, or attorney confirmation?
2. Must an unavailable full opinion block a legal answer, or may the app produce a prominently quarantined preliminary answer?
3. Should prior “complete” legal/document outputs be invalidated or relabeled after the verifier is corrected?
4. Is a blocked drafting review copy a required artifact? If so, how must it be watermarked and prevented from normal share/open flows?
5. How should multi-matter ScratchPad entries be split, and may a user deliberately associate one evidence item with multiple client matters?
6. Is environment-based credential loading a supported advanced workflow or should release builds enforce Keychain-only storage?
7. Are automatic update checks an accepted privacy exception, and what exact metadata/host/interval should public policy disclose?
8. Does the threat model require application-layer encryption beyond FileVault/container protection for SQLite, blobs, exports, and backups?
9. What retention language should distinguish soft delete, managed-blob deletion, audit retention, user exports, and external backups?
10. Which release lines are actually supported for security fixes and direct upgrades?

## Areas needing additional runtime review

- Real-XPC crash/reconnect/exactly-once stream completion and cancellation races
- Real embedding generation, model identity changes, interrupted re-indexing, and cross-matter vector retrieval
- Large/malformed PDF/image/Office/EML corpora with memory/time budgets
- OCR accuracy and warning propagation across mixed native/scanned documents
- Attorney-reviewed citation, quote, jurisdiction, precedent, negative-treatment, and pinpoint corpus
- Office interoperability and formula behavior in Excel, Numbers, and LibreOffice
- VoiceOver, error announcements, non-color blocking state, full keyboard access, high contrast, Reduce Motion, large text, and multiwindow behavior
- Signed Sparkle update installation and failure/rollback paths

## Post-review remediation disposition — 2026-07-13

The source remediation changes the status of the original defects but does not erase the review limitations above. The dated execution report uses the following residual-risk boundaries:

- **GitHub-owned public refs/caches:** preventive, metadata-only guards exist in the repository, Pages deployment, CI, and release preflight. The repository owner assigned the already-existing server-side refs/caches to GitHub Support. No remediation deliverable claims those server-owned objects have been deleted or garbage-collected.
- **Attorney validation:** legal and document support now fail closed against deterministic proposition-support rules and a shared corpus. Corpus entries remain `pending_attorney_review`; no code test proves that an authority is good law, controls the jurisdiction, contains a legally sufficient pinpoint, or meets professional judgment standards.
- **Model qualification:** revision-bound manifests, containment, sizes, and hashes are enforced, but protected MLX weights were unavailable. Real model load, output quality, peak resident memory, long cancellation, and switching under production compute remain release-candidate qualifications.
- **Live providers and credentials:** deterministic redirect, credential-scope, and policy tests used synthetic transports/loopback fixtures. No production credential or live legal-data provider was exercised.
- **Migration fixtures:** permanent shipping-version fixtures and snapshot recovery are synthetic. They materially improve coverage but are not substitutes for testing representative, consented, production-scale databases.
- **Accessibility scope:** targeted UI smoke tests cover the remediated warning/recovery paths and fail closed when setup is unavailable. They are not a complete VoiceOver, keyboard, high-contrast, motion, large-text, or multiwindow certification.
- **Release infrastructure:** release scripts now enforce a SHA-bound, transactional dry run with failure injection and a repository-owned signed XPC/model smoke driver. Live GitHub rulesets/environments, the dedicated ephemeral isolated runner, private release-model resources, signing/notarization credentials, public asset publication, Sparkle installation, and rollback have not been exercised for the remediated SHA.
- **XPC deterministic qualification:** at `f24c792179137557ae61f259f18a209c9790b345`, the final app/UI/XPC smoke re-exercised the hosted selectors through the locally ad-hoc-signed embedded service; the earlier content-binding-specific run attested the exact fingerprint. It did not exercise the real MLX loader, a hostile Developer ID peer, or a forced service kill/relaunch.
- **Bookmark and model identity boundary:** app-signer stale persistent bookmarks require reauthorization. A stale cross-signer resolution is accepted only when the canonical path is actively scoped, contained, exists, and still matches the caller-supplied device/inode identity. When run, the signed-smoke implementation additionally copies and rehashes an exact revision-bound tree and attests its fingerprint through XPC. Because MLX loads by pathname and POSIX unlink is not inode-conditional, a hostile same-UID mutate/restore or cleanup race remains bounded by the mandatory isolated runner rather than claimed closed by hashing alone.
- **Sanitizers and resources:** RuntimeClient passed 4/4 under both TSan and ASan at the earlier integrated snapshot `19e06b451cd585f7b7b360ea916e992339b46845`. The hosted lifecycle also passed under TSan and ASan at that snapshot. UBSan did not run because the embedded XPC failed to link against the Xcode beta sanitizer runtime (`___ubsan_handle_*` symbols unresolved); the failed xcresult is recorded in `11-command-and-evidence-log.md`. Sanitizers were not rerun at `f24c792`; Instruments, protected real weights, long generation, peak RSS, production memory pressure, and model switching remain unqualified.
- **UI diagnostics:** the final app/UI/XPC smoke passed 5/5 at `f24c792`, including the drafting/output vertical-window origin/height stability assertions, and recorded one Xcode-internal QoS priority-inversion warning. The output test verifies that the row exists and is hittable, then uses a DEBUG-only command to enter the same production `NavigationStack` and destination; it does not directly prove Xcode 16 synthesized-click or manual pointer activation of the `NavigationLink`. This is targeted regression evidence, not broad accessibility or window-management certification.

Accordingly, `Remediated` in the findings index means the source defect and its deterministic regression gate are closed. It does not imply attorney approval, GitHub Support completion, signed-release qualification, production-provider validation, or exhaustive accessibility/security certification.
