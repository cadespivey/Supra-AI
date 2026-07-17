# Security Policy

Supra AI handles privileged legal work product. Security and privacy are core design
constraints, not afterthoughts. This document describes the security model and how to
report a vulnerability.

## Reporting a vulnerability

**Please do not report security issues in public GitHub issues.**

Report privately through **[GitHub Security Advisories](https://github.com/cadespivey/Supra-AI/security/advisories/new)**
("Report a vulnerability"). If that is unavailable to you, open a public issue that contains
**no details** asking the maintainer (@cadespivey) to open a private channel.

Please include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Affected version/commit and your environment (macOS / chip / Xcode).
- Whether any user data, secrets, or privileged content could be exposed.

You can expect an acknowledgment and an initial assessment. Please allow a reasonable period
for a fix before any public disclosure, and avoid accessing or modifying data that isn't
yours while investigating.

## Supported versions

This is an early project. Security fixes target the latest release and `main`.

The currently supported release line is 2.3.x.

| Version | Supported |
|---------|-----------|
| 2.3.x   | ✅        |
| < 2.3   | ❌        |

## Security & privacy model

These properties are guarantees the project intends to preserve. Changes that weaken them
need an explicit, documented justification.

### On-device by default

- Model **generation**, document **processing/OCR/embeddings**, **search**, and **source
  selection** run locally. No prompt, document, or query leaves the device for generation.
- Network egress is limited to user-initiated legal-data searches, opinion downloads, and model metadata or artifact downloads, plus Sparkle update checks and signed update downloads when enabled.
- User-initiated product-data paths are:
  - **Legal research / legal-data lookups** against a fixed allow-list — CourtListener,
    plus free government sources (eCFR, Federal Register, Open Legal Codes) and key'd APIs
    (GovInfo, OpenStates, Regulations.gov); see the allow-list below.
  - **Opinion PDF downloads** from CourtListener's public storage CDN
    (`storage.courtlistener.com`), only when you click Download PDF on an authority.
    The API token is **never** sent to the CDN.
  - **Model / embedding downloads** during setup (explicit user action; local thereafter).
- Sparkle separately checks `https://supralegal.ai/appcast.xml` for signed app
  updates once per day when automatic checks are enabled. It may download the
  signed update asset named by that feed; this path carries no API credential,
  prompt, document, legal query, or usage telemetry.
- The document-intelligence pipeline performs no network I/O; its imported bytes and extracted
  content are not inputs to the separate research, model-download, or update clients.
- Application network paths do not attach matter documents, prompts, generated work, or usage telemetry to outbound requests.
- The application contains no analytics or telemetry client. Local runtime metrics and diagnostic
  records remain on the Mac unless the user deliberately exports a file.

### Default-deny networking

- Every request passes through a network policy that **denies by default**. The
  allow-list is limited to explicit, user-initiated legal-data sources:
  - `courtlistener.com` / `www.courtlistener.com` — CourtListener API (token-authenticated) —
    and `storage.courtlistener.com` — its public asset CDN (token-free opinion PDF downloads).
  - Free, key-less official sources: `openlegalcodes.org` (statutes), `ecfr.gov`
    (Code of Federal Regulations), `federalregister.gov` (regulatory developments),
    and `www.govinfo.gov` (govinfo's key-less U.S. Code citation link service and
    the official section HTML it redirects to — always token-free).
  - Key'd legal-data APIs (the key is read from the Keychain): `api.govinfo.gov`
    (U.S. Code), `v3.openstates.org` (bills), `api.regulations.gov`
    (federal rulemaking dockets).
  - Government-records connectors, public and key-less: `data.sec.gov`
    (SEC EDGAR APIs), `www.consumerfinance.gov` (CFPB consumer-complaint
    database), `www.nlrb.gov` (NLRB official CSV exports). Always token-free.
  - The CourtListener token is gated to the CourtListener hosts and is **never** sent to
    any other allow-listed host.
- Plain `http`, embedded credentials, and non-allow-listed hosts are rejected.
- Every request — approved or blocked — is logged (path only, never the `Authorization`
  header or token). Local rolling rate-limit counters block requests at CourtListener's
  documented limits.

### Secrets handling

- CourtListener, GovInfo, OpenStates, and Regulations.gov credentials are stored
  **only in the macOS Keychain** under distinct accounts, bound to the device.
- Release composition reads API credentials only from the Keychain. Environment
  credential injection is compiled for DEBUG/test workflows and must be composed
  explicitly; `.env.example` contains no API-key fields.
- Credentials are not written to SQLite, diagnostics, validation reports, crash
  logs, exported files, or app settings, and are shown in the UI only masked.
- Nonsecret runtime configuration may live in `.env` / the process environment;
  `.env` is gitignored.

### Named egress policies

- **Legal data:** `NetworkPolicyService` is HTTPS-only, default-deny, and names
  each legal provider origin. Provider keys are scoped to their own origin;
  CourtListener credentials may remain only on same-owner, same-origin hops.
- **Hugging Face:** `RedirectPolicy.huggingFace` is token-free and permits only
  the Hub origin plus explicitly tested CDN transitions. Model downloads are
  initiated by the user.
- **Sparkle:** the signed feed origin is fixed in `Info.plist`; Sparkle validates
  the EdDSA signature before installation. No legal-data credential is supplied
  to the updater.
- Legal-data redirects remain HTTPS and provider-scoped; CourtListener credentials stay on same-owner API hops, and Hugging Face downloads remain token-free on named Hub or CDN origins.

### Privilege-aware logging

- Raw legal query terms are omitted from local request logs by default and replaced with per-install keyed pseudonyms; users may opt in to raw local logging and may delete stored markers.
  The pseudonyms support local grouping but are not anonymous or portable across installations.
- Exports, audit summaries, and diagnostics avoid raw absolute source paths; documents are
  referenced by safe display names / managed relative paths.

### Source grounding & verification

- Legal answers are constrained to retrieved authority; document answers and chronologies are
  constrained to the selected source set.
- A citation verifier flags fabricated/unsupported citations, unresolved citation labels, and
  jurisdiction mismatches, and marks such output as **needs review** rather than presenting it
  as clean. The app makes **no** automatic citator / "good law" claims.

### Sandboxing & process isolation

- MLX model execution runs in a **sandboxed XPC service**, isolated from the UI process.
- The app and embedded runtime authenticate one another with Foundation's supported
  code-signing-requirement APIs. Release requirements bind both exact bundle identifiers
  to Team ID `2DP657YB3K`; Debug permits ad-hoc signatures but still binds identifiers.
- Runtime model access requires an activatable transferable bookmark. Nil, invalid,
  moved/stale, mismatched, missing, and managed-root-escaping targets fail before model
  parsing; raw paths are not authority. A signer-stale cross-process bookmark is usable
  only when its canonical target still matches exactly and every containment check passes.
- Imported originals are opened read-only and are not modified; managed copies are written inside the sandbox, while exports use destinations selected by the user.
  External file access uses security-scoped URLs chosen through the
  system picker; import paths are treated as read-only. A top-level import
  bookmark is retained only while its source is unfinished and is cleared in the
  same transaction that records a terminal source state; child sources never
  retain bookmarks.
- The app retains `com.apple.security.files.user-selected.read-write` because
  user-selected export destinations must be created or replaced and selected
  imports may require coordinated reads. The entitlement grants no ambient path:
  access is limited to URLs the user chooses through the system picker. App-managed
  copies remain inside the sandbox container.
- The app sandbox has network-client, app-scoped bookmark, user-selected read-write, and required MLX mach-lookup entitlements; the runtime service has only the app-sandbox entitlement.

### Data at rest and supported upgrades

- Supra AI does not add application-level encryption to the SQLite database, managed document copies, model files, or exports; protection at rest depends on macOS account controls, destination permissions, and FileVault when enabled.
  Keychain protects provider credentials separately. Exported files inherit the controls of the
  destination selected by the user.
- Upgrade tests cover v1.4.1, v1.5.2, v1.8.0, v2.0.0, v2.1.0, v2.1.3, v2.2.0, and the latest-minus-one schema fixture.
  A verified pre-migration snapshot is required before a supported upgrade mutates the database.

## Scope notes

Supra AI is a drafting and research **aid**. It does not replace attorney review. Its safety
properties reduce — but do not eliminate — the risk of incorrect or unsupported output; every
citation, quotation, and proposition must be independently verified before any reliance.
