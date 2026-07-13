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

| Version | Supported |
|---------|-----------|
| 1.4.x   | ✅        |
| < 1.4   | ❌        |

## Security & privacy model

These properties are guarantees the project intends to preserve. Changes that weaken them
need an explicit, documented justification.

### On-device by default

- Model **generation**, document **processing/OCR/embeddings**, **search**, and **source
  selection** run locally. No prompt, document, or query leaves the device for generation.
- Product-data network egress is explicit and user-initiated:
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
- The document-intelligence pipeline performs **no** network I/O at all.
- **No telemetry or analytics.**

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

### Privilege-aware logging

- Privileged query terms are redacted to **per-install keyed pseudonyms** in request logs and
  diagnostics by default. These markers support local grouping but are not anonymous or
  portable across installations; Diagnostics can remove stored query markers. Storing raw
  query terms is strictly opt-in (`SUPRA_LEGAL_LOG_QUERY_TERMS`, off by default).
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
- Imported documents are **copied** into app-managed storage; originals are read-only and
  never modified. External file access uses security-scoped URLs chosen through the
  system picker; import paths are treated as read-only.
- The app retains `com.apple.security.files.user-selected.read-write` because
  user-selected export destinations must be created or replaced and selected
  imports may require coordinated reads. The entitlement grants no ambient path:
  access is limited to URLs the user chooses through the system picker. App-managed
  copies remain inside the sandbox container.

## Scope notes

Supra AI is a drafting and research **aid**. It does not replace attorney review. Its safety
properties reduce — but do not eliminate — the risk of incorrect or unsupported output; every
citation, quotation, and proposition must be independently verified before any reliance.
