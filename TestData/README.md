# Supra AI — Seeded Test Corpus

Realistic but synthetic test data for exercising the Milestone 3 document
intelligence pipeline (import → extraction → OCR → indexing → retrieval → Q&A →
chronology → exports) and the CourtListener research connection.

## Layout
```
TestData/
  VALIDATION-PLAN.md          ← the test plan + answer keys (start here)
  specs/<key>.json            ← authored matter specs (source of truth)
  <Matter Name>/              ← generated, import-ready document corpus
    <Folders>/...             ← pdf, scanned pdf (OCR), png (OCR), docx, xlsx, eml, msg
    Caselaw & Procedure/      ← real FL authorities + judge policies (provided)
    Notes/attorney-notes.md   ← attorney notes (Markdown)
    _answer-key.json          ← machine-readable Q&A / chronology / CourtListener key
```

Three matters: a **construction lien / collection** dispute, a **purchase & sale**
agreement, and an **insurance claim** investigation. Each contains 6–10 documents
across all supported formats, with planted "hidden" facts, OCR-only facts,
spreadsheet-only facts, a deliberate cross-document contradiction, and a
deliberately unanswerable question (to test refusal).

## Regenerating
The corpus is produced from `specs/*.json` by the `SeedCorpus` tool
(`Packages/SupraTestKit`), which also folds in the provided real case documents:

```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift run --package-path Packages/SupraTestKit SeedCorpus
```

## Automated validation
`SupraTestKit`'s tests regenerate each matter, import it with **real Vision OCR**,
index it, and assert every planted fact is extractable (including from the
OCR-only documents) and that `.msg` is reported unsupported:

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
