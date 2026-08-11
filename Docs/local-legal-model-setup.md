# Local Legal Model Setup

Supra AI is a Swift/macOS app with a local MLX runtime service. Model routing is
configuration-driven. Case-law and docket lookup uses CourtListener; statutory and regulatory
grounding can use GovInfo, eCFR, and Open Legal Codes; development tracking uses named public
providers; and the separate Public Records workspace covers SEC, CFPB, and NLRB sources.

## Architecture Notes

- App/UI: `Apps/SupraAI` SwiftUI macOS app.
- Runtime: `Apps/SupraAI/SupraRuntimeService` loads local MLX model folders and
  generates through XPC.
- Core route types: `Packages/SupraCore`.
- Session orchestration: `Packages/SupraSessions`.
- Named legal-data clients, normalization, ranking, and verification helpers:
  `Packages/SupraResearch`.
- Persistence: `Packages/SupraStore` with GRDB.
- Tests: Swift Package Manager/XCTest targets under each package.

## Recommended Local Models

Register or download MLX model folders in the Models tab, then set environment
variables to names that match the registered display name, repo/folder name, or
path.

| Role | Default identifier | Notes |
| --- | --- | --- |
| Legal reasoning | `Qwen3-30B-A3B-Thinking-2507-MLX-4bit` | Default route for `/legal` and `/research`. |
| Legal reasoning high quality | `DeepSeek-R1-Distill-Qwen-32B-MLX-4bit` | Optional high-quality role used by selected structured-output routes. |
| Drafting | `Qwen3-30B-A3B-Instruct-2507-MLX-4bit` | Used by `/draft` and ordinary non-research drafting. |
| Critique | `DeepSeek-R1-Distill-Qwen-32B-MLX-4bit` | Used by `/critique`/second-pass review. |

The defaults assume an M4 Mac with 48 GB unified memory. Use 4-bit models by
default. Do not make 8-bit or 70B-class models the default on this machine.

### Guided New Review hardware advisory

Guided New Review applies a narrower, advisory work-model policy to the selected
managed text model. It reads the model repository identity only from the
structured app-managed manifest and compares the curated model-weight estimate
with detected unified memory. It does not infer fit from a display name, folder
name, or catalog prose, and it does not silently add an embedding model that the
Review flow did not select.

| Detected unified-memory tier | Curated Review work model | Approximate model weight |
| --- | --- | ---: |
| 16 GB | Qwen3 8B (4-bit) | 4.7 GB |
| 32 GB | Qwen3 14B (4-bit) | 8 GB |
| 64 GB | Qwen3 32B (4-bit) | 18 GB |
| 96 GB | Qwen3 32B (4-bit) | 18 GB |
| 128 GB | Qwen3 32B (4-bit) | 18 GB |

Intermediate capacities round down conservatively, capacities above 128 GB use
the 128 GB policy, and machines below 16 GB receive no preset recommendation.
The 96 GB and 128 GB tiers deliberately retain the 32B 4-bit ceiling to leave
more headroom for context, macOS, and other apps. A caution or unknown result is
shown before Start but does not block Review creation; Start still performs the
fresh exact content verification and pin that authorizes execution. Fit is an
estimated model-weight comparison, not a promise of speed, context capacity,
successful loading, or available memory at execution time.

This advisory does not replace the role-routing defaults above. In particular,
a 48 GB Mac rounds down to the 32 GB Guided New Review policy tier even though a
user may separately configure the larger role-specific defaults.

## Environment Variables

See `.env.example` for the full list. The most important values are:

- `SUPRA_MODEL_BACKEND=mlx`
- `SUPRA_MODEL_LEGAL_REASONING`
- `SUPRA_MODEL_LEGAL_REASONING_HIGH_QUALITY`
- `SUPRA_MODEL_DRAFTING`
- `SUPRA_MODEL_CRITIQUE`
- `SUPRA_DEFAULT_CONTEXT_TOKENS=32768`
- `SUPRA_MAX_CONTEXT_TOKENS=65536`
- `SUPRA_ENABLE_COURTLISTENER=true`
- `SUPRA_LEGAL_REQUIRE_CITATIONS=true`
- `SUPRA_LEGAL_ALLOW_UNGROUNDED_LAW=false`
- `SUPRA_LEGAL_VERIFY_CITATIONS=true`
- `SUPRA_LEGAL_JURISDICTION_REQUIRED=true`
- `SUPRA_LEGAL_LOG_QUERY_TERMS=false`

Enter CourtListener, GovInfo, OpenStates, and Regulations.gov credentials in
Settings. Release builds load them only from the device-bound macOS Keychain;
they do not read API credentials from `.env` or process environment variables.
DEBUG/test code can explicitly compose an environment-backed store for local
live tests.
Legal-route audit events redact raw query terms by default and store per-install
HMAC pseudonyms instead; set `SUPRA_LEGAL_LOG_QUERY_TERMS=true` only when the audit
store is approved for privileged query content.

## Modes

The chat composer supports:

- `/draft`: drafting model, low/off thinking, no mandatory research.
- `/ask` or `/general`: general assistant route without authoritative legal grounding.
- `/legal`: legal reasoning model. Jurisdiction-specific/current law requires
  a retained legal-data source packet unless ungrounded law is explicitly allowed.
- `/research`: legal reasoning model plus mandatory legal-data retrieval,
  source packet prompting, and citation verification.
- `/critique`: critique model and defect-focused review prompt. If run after a
  legal answer, it uses the prior draft plus the latest source packet.
- `/verify`: deterministic citation/source verification. Without a source
  packet it flags citations as unsupported. In matter chats it verifies against
  the latest stored CourtListener research packet and does not require a loaded
  model.

If no slash command is provided, the router infers legal vs general chat from
the prompt text. The UI asks the model library to load the configured role model
when it is registered locally; otherwise it falls back to the loaded or active
model.

## Legal-data grounding

Legal research mode:

1. Classifies jurisdiction, court level, issue, posture, authority type, date
   sensitivity, binding authority need, adverse-authority request, and citation
   lookup.
2. Routes case-law and docket questions to CourtListener, U.S. Code questions to GovInfo or Open
   Legal Codes, and federal-regulation questions to eCFR. Legislative or rulemaking developments
   remain separately labeled tracking context rather than controlling authority.
3. Stores matter-chat research packets as research sessions/results so they can
   be reviewed in the Research tab and reused by `/verify` or `/critique`.
4. Normalizes results into internal `LegalAuthority` objects.
5. Ranks by jurisdiction match, court hierarchy, recency, citation match,
   relevance, text depth, and adverse-authority clues.
6. Prompts the local legal reasoning model with only the retrieved source
   packet.
7. Runs deterministic verification for unsupported citations, missing citations,
   unsupported quotes, and jurisdiction mismatch.

The model is instructed not to cite or quote authorities outside the source
packet. If retrieval is insufficient, the answer should say so.

The Public Records workspace separately queries SEC EDGAR filings, CFPB consumer complaints, and
NLRB labor-case records. Those results retain their source labels and are not silently promoted to
adjudicated facts or legal authority.

## Memory Guidance

Storage is not the main constraint. The limiting factors are unified memory for
model weights, KV cache, Metal/MLX overhead, and the rest of the app. Defaults
therefore use:

- 4-bit quantization.
- 32K normal context.
- 64K maximum research context.
- an optional separate 4-bit high-quality reasoning role when memory headroom permits.

If model loading fails due to likely memory pressure, the runtime surfaces a
clearer message recommending a smaller quantization/context.

## Tests

Run focused package tests:

```sh
cd Packages/SupraCore && swift test
cd ../SupraResearch && swift test
cd ../SupraSessions && swift test
```

The tests cover routing, configuration defaults, named-provider request filters,
matter research-packet persistence, `/verify` without a loaded
model, `/critique` with prior draft/source packet context, authority
normalization/ranking, fake citation handling, quotation checks, drafting
behavior, and legal research grounding.
