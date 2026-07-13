# Security and privacy report

## Network allow-list and redirect results

The initial URL policy correctly requires HTTPS, exact lowercased hosts, no userinfo, and rejects lookalike/non-allow-listed hosts. CourtListener authentication is separately restricted to its API hosts; an authenticated initial request to the storage CDN fails. API-key headers/query parameters are redacted from logs in tests.

The central failure is redirect scope (SA-ACR-005). The default session follows redirects after the only policy decision. A controlled probe reached a disallowed second host. CFNetwork stripped the synthetic authorization header in this environment, so the review did **not** reproduce token leakage, but unauthorized egress is confirmed. No approved-port restriction exists. Hugging Face uses its own initial-host check and default session. Sparkle is a third reviewed exception and performs scheduled automatic checks.

Production network-capable surfaces found:

- `AuthorizedHTTPClient` for legal/government connectors
- `HuggingFaceClient` for model/embedding metadata and files
- Sparkle appcast/update framework
- `WKWebView` authority reader; content JavaScript and subresources are deliberately blocked in its coordinator

No document-processing `URLSession` use was found.

## Credential handling

Positive findings:

- Keychain implementation uses device-bound `AfterFirstUnlockThisDeviceOnly` semantics.
- Authorization is omitted from request metadata, and common API-key headers/parameters are redacted.
- No high-confidence secret format, private key, certificate, tracked `.env`, or actual token was found in the current tree or reachable local branch/tag history scan.
- The inspected release binary contains only environment-variable names, not secret values.

Claim gap:

- `EnvironmentBackedTokenStore` loads environment values before Keychain values for CourtListener and optional providers.
- `.env.example` includes those key fields, and setup documentation supports `.env` use.
- Therefore “Keychain only/never files” is false as written (SA-ACR-014).

The history scan was pattern-based because no dedicated `gitleaks`/`trufflehog` binary was installed; hidden GitHub PR refs were inspected for prohibited font paths, not exhaustively downloaded/scanned for secrets.

## Entitlements, sandbox, and XPC

The signed v2.2.0 app and XPC service both carry `com.apple.security.app-sandbox=true`. The app has network client, app-scoped bookmarks, user-selected read-write file access, and Sparkle mach-lookup exceptions. The XPC has only app sandbox. Hardened runtime flags, Developer ID signature, notarization ticket, and stapling were verified.

`RuntimeServiceDelegate` accepts every connection delivered to its listener without an explicit audit-token/team/bundle check. Embedded XPC service lookup may provide platform scoping, but the review did not prove the effective connection authorization under a hostile local process. Treat this as a defense-in-depth verification item, not a confirmed vulnerability.

The XPC model controller uses a raw path if bookmark data is absent. In the shipping sandbox this should not grant capabilities by itself, but real signed-app access to managed and user-selected model paths was not exercised. Documentation should not describe the raw path as an access bypass.

The security document's “read-only grant” claim is inaccurate because the shipping app entitlement is read-write. The import implementation was not found writing originals, but the capability is broader than claimed.

## File access and parser security

Originals are hashed/copied and source paths are stored as display-relative paths, a positive design. Risks remain:

- non-atomic/unverified managed copy and extraction from mutable original (SA-ACR-006)
- recursive symlink/alias containment and visited-node controls absent (SA-ACR-011)
- file type selected by extension instead of a general content signature check
- inconsistent global decoded-byte/nesting/resource budgets, especially EML
- temporary/final export replacement not atomic (SA-ACR-009)
- document CSV formula injection (SA-ACR-008)

Office extraction has a 256 MB per-entry limit and attachment filenames are reduced to a safe last path component; these are useful controls.

## Logging and redaction

Default raw query logging is off and unit tests confirm the transport receives real terms while logs receive fingerprints. Sensitive headers and key-like query parameters are always redacted. Diagnostics tests cover local path redaction.

The fingerprint is unsalted FNV-1a (SA-ACR-015), so it is pseudonymous and dictionary-recoverable. Numerous audit writes use `try?`, meaning audit completeness is not guaranteed when the business operation succeeds. No default raw privileged content leak was observed in the tested logs.

## Data at rest

No SQLCipher, `PRAGMA key`, application-layer file encryption, or explicit data-protection class was found. SQLite, FTS text, embeddings, managed documents, exports, and backups are plaintext. Synthetic `/tmp` databases were mode 0644 under the review umask; the real app container parent is expected to restrict other users/processes, but production container modes were not tested.

The precise posture is: protection relies on the macOS account, sandbox/TCC boundaries, destination permissions, and FileVault if enabled. This is not end-to-end/application encryption. Public documentation should say so and users handling privileged data should be advised to use FileVault and secure backup destinations.

## Deletion semantics

- Matters, chats, documents, and authorities use soft-delete/recycle-bin flows in multiple repositories.
- Chats/documents can be purged after retention maintenance; matters require manual permanent deletion.
- Permanent document/matter deletion returns unreferenced managed blob paths for filesystem deletion; shared blob repository tests pass.
- FTS/chunk/embedding cascades have focused Store tests.
- Audit history and user-created exports/backups/clipboard/system recent items are not necessarily erased with the originating record.

UI language should consistently say “move to Recycle Bin,” “permanently delete local managed copy,” and separately explain exports/backups/audit retention. Full backup/Quick Look/Spotlight/recent-items deletion testing was not performed.

## Release artifacts and public surfaces

Inspected v2.2.0 results:

- App bundle: valid Developer ID signature, hardened runtime, notarized, stapled, accepted by Gatekeeper.
- DMG: checksum verified, notarized/stapled, Gatekeeper accepted.
- Public GitHub DMG/ZIP digests exactly matched local inspected files.
- Bundle/ZIP/DMG contained no Equity/font files, `.env`, SQLite DB, keys/certs, dSYM, or obvious private paths; one harmless AppleDouble `._AppIcon.icns` entry was present.
- Website lint/typecheck/static build and pre/post font guard passed; generated `out` contained no Equity markers.
- All 26 curated model IDs resolved.
- `npm audit` reported two moderate entries: PostCSS `<8.5.10` XSS advisory through Next 16.2.6. The static site does not accept runtime user CSS in the reviewed code, reducing exploitability, but dependency owners should track a non-breaking patched resolution.

The artifact is from tag `v2.2.0` (`4c2a8ff…`), not reviewed main. Main's later commits are licensing/docs/appcast changes, but no notarized artifact was produced from `24a802c` during this review.

Public hidden PR refs remain contaminated with prohibited assets (SA-ACR-001). Release automation gaps are in SA-ACR-012.

## Public-claim contradictions

The most consequential contradictions are collected in SA-ACR-014 and `03-claim-verification-matrix.md`: default-deny “every request,” user-initiated-only egress, Keychain-only secrets, read-only grants, verified citations/facts, supported version, package count, and migration level.
