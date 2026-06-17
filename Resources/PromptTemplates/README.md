# Prompt Templates

These Markdown prompt templates exist in two places by necessity:

- **This directory (`Resources/PromptTemplates/`)** is the canonical, reviewable
  source of truth for the prompt text.
- **`Packages/Supra*/Sources/.../Resources/`** holds byte-identical copies that
  are bundled into the SPM packages and loaded at runtime via `Bundle.module`
  (Swift Package Manager can only bundle resources that live inside the package).

When editing a template, update **both** copies so they stay in sync. The
runtime always reads the package copy; this directory is the documentation
mirror referenced by the Milestone plans.

Current templates:

- `default-system-prompt-v1.md` — Milestone 1 legal-assistant system prompt
- `research-query-generation-v1.md` — CourtListener query generation (WO 24)
- `StructuredOutputs/*.md` — the six structured-output generators + the
  structure-repair prompt (WO 28–29)
