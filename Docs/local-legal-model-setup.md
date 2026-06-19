# Local Legal Model Setup

Supra AI is a Swift/macOS app with a local MLX runtime service. Model routing is
environment-driven, and CourtListener is the only external legal authority
retrieval path.

## Architecture Notes

- App/UI: `Apps/SupraAI` SwiftUI macOS app.
- Runtime: `Apps/SupraAI/SupraRuntimeService` loads local MLX model folders and
  generates through XPC.
- Core route types: `Packages/SupraCore`.
- Session orchestration: `Packages/SupraSessions`.
- CourtListener client, normalization, ranking, and verification helpers:
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
| Legal reasoning high quality | `Qwen3-30B-A3B-Thinking-2507-MLX-6bit` | Optional quality profile when memory headroom permits. |
| Drafting | `Qwen3-30B-A3B-Instruct-2507-MLX-4bit` | Used by `/draft` and ordinary non-research drafting. |
| Critique | `DeepSeek-R1-Distill-Qwen-32B-MLX-4bit` | Used by `/critique`/second-pass review. |

The defaults assume an M4 Mac with 48 GB unified memory. Use 4-bit models by
default. Do not make 8-bit or 70B-class models the default on this machine.

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
- `SUPRA_COURTLISTENER_API_KEY`
- `SUPRA_LEGAL_REQUIRE_CITATIONS=true`
- `SUPRA_LEGAL_ALLOW_UNGROUNDED_LAW=false`
- `SUPRA_LEGAL_VERIFY_CITATIONS=true`
- `SUPRA_LEGAL_JURISDICTION_REQUIRED=true`
- `SUPRA_LEGAL_LOG_QUERY_TERMS=false`

CourtListener tokens can still be saved in Settings. If
`SUPRA_COURTLISTENER_API_KEY` is set, it is used ahead of the Keychain token.
Legal-route audit events redact raw query terms by default and store stable
fingerprints instead; set `SUPRA_LEGAL_LOG_QUERY_TERMS=true` only when the audit
store is approved for privileged query content.

## Modes

The chat composer supports:

- `/draft`: drafting model, low/off thinking, no mandatory research.
- `/legal`: legal reasoning model. Jurisdiction-specific/current law requires
  CourtListener grounding unless ungrounded law is explicitly allowed.
- `/research`: legal reasoning model plus mandatory CourtListener retrieval,
  source packet prompting, and citation verification.
- `/legal-hq` and `/research-hq`: same workflows using the optional configured
  high-quality legal reasoning model.
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

## CourtListener Grounding

Legal research mode:

1. Classifies jurisdiction, court level, issue, posture, authority type, date
   sensitivity, binding authority need, adverse-authority request, and citation
   lookup.
2. Queries CourtListener REST v4 only.
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

## Memory Guidance

Storage is not the main constraint. The limiting factors are unified memory for
model weights, KV cache, Metal/MLX overhead, and the rest of the app. Defaults
therefore use:

- 4-bit quantization.
- 32K normal context.
- 64K maximum research context.
- optional 6-bit quality profile only when memory headroom permits.

If model loading fails due to likely memory pressure, the runtime surfaces a
clearer message recommending a smaller quantization/context.

## Tests

Run focused package tests:

```sh
cd Packages/SupraCore && swift test
cd ../SupraResearch && swift test
cd ../SupraSessions && swift test
```

The added tests cover routing, environment-driven defaults, CourtListener
request filters, matter research-packet persistence, `/verify` without a loaded
model, `/critique` with prior draft/source packet context, authority
normalization/ranking, fake citation handling, quotation checks, drafting
behavior, and legal research grounding.
