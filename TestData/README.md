# Supra AI — Seeded Test Corpus

Realistic but synthetic test data for exercising the Milestone 3 document
intelligence pipeline (import → extraction → OCR → indexing → retrieval → Q&A →
chronology → exports) and the CourtListener research connection.

## Layout
```
TestData/
  VALIDATION-PLAN.md          ← the test plan + answer keys (start here)
  benchmark-manifest.json     ← frozen SHA-256 + disposition manifest
  specs/<key>.json            ← authored matter specs (source of truth)
  <Matter Name>/              ← generated, import-ready document corpus
    <Folders>/...             ← pdf, scanned pdf (OCR), png (OCR), docx, xlsx, eml, msg
    Caselaw & Procedure/      ← real FL authorities + judge policies (provided)
    Notes/attorney-notes.md   ← attorney notes (Markdown)
    _answer-key.json          ← machine-readable Q&A, task, chronology, and research keys
```

Four matters include a **construction lien / collection** dispute, a **purchase &
sale** agreement, an **insurance claim** investigation, and the **Synthetic
Document Intelligence Benchmark**. The benchmark adds real OOXML/MIME/PDF
structures for numbering, tables, notes, comments, tracked changes,
headers/footers, formulas and cached values, hidden rows/sheets, threaded email,
contract versions, discovery pairs, deposition Q/A, mixed OCR, encryption,
duplicates, omissions, cross-matter lookalikes, and untrusted prompt-like text.

Every benchmark artifact is synthetic, fictional, and nonprivileged. Its path,
kind, expected policy disposition (where applicable), and SHA-256 digest are
frozen in `benchmark-manifest.json`. Each matter spec also carries stable task
answer keys for lists, chronology, comparisons, contradictions, negative
conclusions, structures, and versions; every evidence locator resolves to a
declared document.

## Regenerating
The corpus is produced from `specs/*.json` by the `SeedCorpus` tool
(`Packages/SupraTestKit`), which also folds in the provided real case documents:

```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift run --package-path Packages/SupraTestKit SeedCorpus
```

Regeneration replaces only the generated benchmark matter before writing it,
then rewrites `benchmark-manifest.json` from the resulting bytes. Digest changes
therefore require an intentional fixture review.

## Automated validation
`SupraTestKit` verifies the frozen manifest and answer-key references, then
regenerates each matter, imports it with **real Vision OCR**, indexes it, and
asserts every planted fact is extractable (including from OCR-only documents)
and that `.msg` is reported unsupported:

```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/SupraTestKit
```

`SupraTestKit` is intentionally **not** part of `SupraAI.xcworkspace`, so it never
affects the app build.

## Manual / model validation
See `VALIDATION-PLAN.md` for the per-matter Q&A, chronology, and CourtListener
scenarios with expected answers — run these in the app once a chat + embedding
model are loaded and (for research) a CourtListener token is set.
