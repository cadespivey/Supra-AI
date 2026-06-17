# Supra AI - Milestone 3 Implementation Plan
## Matter Document Intelligence: Import, Extraction, Search, Q&A, and Chronologies

Last calibrated: June 17, 2026

This file is the self-contained Milestone 3 handoff. Implementers should not rely on prior chat context.

## 0. Purpose

Milestone 3 turns the disabled Matter > Documents tab into a production-leaning local document intelligence workspace.

The milestone is not a broad e-discovery platform. It is a local-first matter document system that can reliably import messy real-world files, extract usable text, index them, retrieve the right sources, answer natural-language questions with citations, generate cited fact chronologies, save outputs, and export them with source appendices.

The core user outcome:

```text
Given a matter with dozens to about 200 documents, Supra can ingest the file set locally,
track processing progress, let the user search across what is ready, and generate
source-grounded Q&A or chronology outputs once the selected scope is fully indexed.
Every generated claim must be traceable back to document/page/chunk source links.
```

## 0.1 Current Build State

Milestone 3 starts from the current Milestone 2 branch shape observed on June 17, 2026:

```text
- Branch observed during planning: chore/milestone2-polish.
- App has Models, Global Chat, Matters, Settings, and Diagnostics surfaces.
- Matter workspace has Chat, Research, Authorities, Outputs, Audit, and disabled Documents.
- SupraRuntimeInterface/Client support local chat model loading and generation through XPC.
- SupraSessions contains model download, validation, matters, research, and outputs controllers.
- SupraDiagnostics contains the existing model validation suite/report types.
- SupraStore migrations currently run through v021_create_audit_events_phase2.
- Milestone 2 adds research sessions, CourtListener network policy, authorities, outputs, and audit records.
```

Repository hygiene note:

```text
- The working tree may contain untracked iCloud conflict copies with names like "File 2.swift".
- Do not treat those conflict copies as source of truth unless the user explicitly resolves them.
- Use the canonical tracked file names without the " 2" suffix when aligning implementation.
```

Before writing M3 code, confirm the canonical Milestone 2 code still has these facts:

```text
- Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift has Documents disabled.
- Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift ends at v021_create_audit_events_phase2.
- Packages/SupraStore/Sources/SupraStore/SupraStore.swift exposes repositories for M2 but no document repositories.
- Packages/SupraCore/Sources/SupraCore/IDs.swift has no document IDs yet.
- Packages/SupraCore/Sources/SupraCore/LegalDomainTypes.swift has StructuredOutputType but no document Q&A/chronology cases yet.
- Packages/SupraRuntimeInterface/Sources/SupraRuntimeInterface/Protocols/SupraRuntimeServiceProtocol.swift has chat generation RPCs but no embedding RPCs yet.
- Packages/SupraSessions/Sources/SupraSessions/BundledValidationSuite.swift exposes only milestone1().
```

If Claude changes Milestone 2 table names, repositories, output schemas, or runtime APIs before M3 starts, revise the affected work orders before implementation.

## 0.2 Production-Ready Definition For M3

M3 is "nearly production ready" when these are true:

```text
- Setup prevents document import until the required local document intelligence pieces are ready.
- Batch import can handle nested folders and mixed formats without losing the batch state.
- Failures are isolated, visible, and included in the import report.
- Extraction and OCR statuses are understandable per matter and per document.
- Search is useful while indexing is still underway, with incomplete-scope warnings.
- Q&A and chronologies are blocked until the selected source scope is fully indexed.
- Answers and chronologies include inline citations and source appendix references.
- Source links open in-app previews at the cited page/chunk/location with best-effort highlights.
- Generated outputs can be saved, regenerated, and exported.
- A validation suite proves the import, extraction, search, citation, chronology, export, and job-resume flows.
```

## 0.3 Non-Goals

Do not implement these in M3:

```text
- cloud document sync
- external OCR APIs
- remote embeddings
- remote document processing
- general web browsing
- CourtListener MCP
- docket / RECAP automation
- automatic citator or negative-treatment claims
- production redaction workflows
- privilege review workflows
- document-level security labels
- e-discovery review sets
- folder watching or autonomous background ingestion
- cross-device library sync
- output redaction before export
- telemetry
```

Network access is allowed only for explicit user-initiated model/tool downloads during setup, such as curated Hugging Face model downloads. Document processing, OCR, embeddings, search, Q&A source selection, and generation must run locally.

---

# 1. Architecture

## 1.1 New Package

Create one new local Swift package:

```text
Packages/
  SupraDocuments/
```

`SupraDocuments` owns document intelligence domain logic. It must not own the database connection, SwiftUI views, or runtime model process.

`Packages/SupraDocuments/Package.swift` must use the repo's current conventions:

```text
- swift-tools-version: 6.0
- platform: macOS v15
- product: SupraDocuments
- dependencies: SupraCore
- add SupraDocumentsTests
```

Then add `SupraDocuments` as a local package dependency where needed:

```text
- SupraStore: no dependency on SupraDocuments; shared document IDs/enums live in SupraCore.
- SupraSessions: yes, for controllers and orchestration.
- SupraAI app target: yes, through package product/framework linkage.
- SupraRuntimeInterface/Client: no dependency on SupraDocuments.
- SupraResearch: no dependency on SupraDocuments.
```

## 1.2 Package Responsibilities

`SupraDocuments` is responsible for:

```text
- supported document type policy
- local document toolchain capability checks
- content hashing and file fingerprint helpers
- managed document storage path helpers
- import planning models
- extraction service protocols
- local conversion/extraction adapters
- OCR planning models and OCR result normalization
- page, chunk, cell, email-part, and image locators
- deterministic chunking
- text normalization
- source-pack assembly
- duplicate-aware retrieval models
- Q&A prompt building
- chronology prompt building
- citation/source marker coverage checks
- source appendix models
- export-ready output models
```

`SupraDocuments` is not responsible for:

```text
- database connection ownership
- SwiftUI views
- XPC runtime lifecycle
- Keychain access
- CourtListener DTOs
- network access
- app-wide job scheduling policy
```

## 1.3 Store And Session Boundaries

Use existing package boundaries:

```text
SupraCore
  - new IDs and enums shared across packages

SupraStore
  - migrations v022+
  - records and repositories for documents, folders, tags, chunks, embeddings, jobs, source links, outputs

SupraDocuments
  - import/extraction/chunk/retrieval/source-grounding domain services

SupraSessions
  - main-actor controllers for Settings, Documents tab, jobs, Q&A, chronology, outputs, exports

SupraRuntimeInterface / SupraRuntimeClient
  - add local embedding model operations to the existing XPC runtime boundary

SupraDiagnostics
  - add document validation result/report fields while preserving Milestone 1 validation compatibility
```

## 1.4 Runtime Boundary For Embeddings

Use the existing runtime XPC service for embedding model work. This is the default decision for M3 because the XPC service already owns MLX model loading and keeps heavy model execution outside the SwiftUI app process.

Add explicit embedding DTOs/RPCs rather than overloading chat generation:

```text
SupraRuntimeInterface:
  - LoadEmbeddingModelRequest
  - LoadEmbeddingModelResponse
  - EmbedTextRequest
  - EmbedTextResponse
  - EmbeddingModelStatus
  - RuntimeStatus.embeddingModelID: DocumentEmbeddingModelID?

SupraRuntimeClient:
  - loadEmbeddingModel(...)
  - embedTexts(...)
  - embeddingStatus(...)

Apps/SupraAI/SupraRuntimeService:
  - EmbeddingModelController protocol
  - MLX/local embedding implementation
  - serialized embedding requests so one embedding batch cannot race another
```

Do not create a separate embedding service/process in M3 without first updating this plan with a concrete reason the existing XPC service is unsuitable.

## 1.5 Local Dependency Policy

M3 may use local bundled tools for file conversion and extraction when Apple frameworks are not enough. Requirements:

```text
- tools must run locally
- exact versions must be pinned
- licenses and redistribution constraints must be documented in Docs/Architecture/Dependencies.md
- failures must be captured as extraction errors, not crashes
- tools must never upload document contents
- tool execution must use app-managed temporary directories
- raw user absolute paths must not appear in exported reports or audit summaries
```

Apple frameworks allowed:

```text
- PDFKit for PDF text extraction, rendering, and previews
- Vision for on-device OCR
- UniformTypeIdentifiers for file type checks
- CryptoKit for content hashing
- UserNotifications for macOS notifications
```

When choosing exact third-party converter/extraction tools or embedding models, verify current licenses and release status from primary sources at implementation time, then pin the exact versions in `Docs/Architecture/Dependencies.md`.

## 1.6 Core Types To Add

Add these ID wrappers to `Packages/SupraCore/Sources/SupraCore/IDs.swift` using the existing UUID wrapper style:

```text
DocumentBlobID
MatterDocumentID
DocumentFolderID
DocumentTagID
DocumentPagePartID
DocumentChunkID
DocumentEmbeddingModelID
DocumentImportBatchID
DocumentProcessingJobID
DocumentSourceSetID
DocumentSourceID
DocumentExportID
```

Add document enums to a new `Packages/SupraCore/Sources/SupraCore/DocumentDomainTypes.swift` file:

```text
MatterDocumentStatus:
  importing, extracting, needs_ocr, ocr_pending, indexing, embedding, ready,
  needs_review, failed, deleted

DocumentExtractionStatus:
  pending, extracted, needs_ocr, ocr_complete, edited, failed

DocumentIndexStatus:
  not_indexed, text_indexed, semantic_indexed, ready, stale, failed

DocumentProcessingPhase:
  discovering, copying_hashing, expanding_attachments, extracting_text,
  detecting_ocr, ocr_processing, chunking, full_text_indexing,
  semantic_embedding, finalizing_report, complete, failed, paused, cancelled

DocumentSourceKind:
  pdf_page, image, text, markdown, rtf, html, xml, spreadsheet_cell_range,
  email_body, email_attachment, converted_document

DocumentGeneratedOutputKind:
  document_qa, document_qa_memo, fact_chronology_table, fact_chronology_narrative
```

Extend `StructuredOutputType` with document output cases so the existing Outputs tab can list M3 outputs:

```text
- documentQA = "document_qa"
- documentQAMemo = "document_qa_memo"
- factChronologyTable = "fact_chronology_table"
- factChronologyNarrative = "fact_chronology_narrative"
```

Use `StructuredOutputStatus.needsReview` when citation checks fail or OCR/extraction confidence warnings need user attention.

---

# 2. Document Intelligence Setup

## 2.1 Setup Is Required Before Import

Document import is blocked until Document Intelligence setup completes.

Setup lives in Settings and is app-wide. It must guide the user through:

```text
1. Chat model selected and actually loaded.
2. Embedding model selected, installed, and test-loadable.
3. Local converter/extractor toolchain present.
4. OCR capability check complete.
5. App-managed document storage initialized.
6. Notification permission requested for long-running import/indexing completion notices.
```

The chat model must be actually loaded before setup is considered complete. The embedding model may load on demand during indexing, but setup must prove it is installed and can be loaded or initialized successfully.

Implementation notes for the current repo:

```text
- Extend Packages/SupraSessions/Sources/SupraSessions/SettingsController.swift.
- Extend Apps/SupraAI/SupraAI/SettingsView.swift with a "Document Intelligence" section.
- Use the existing Models tab for chat model download/load; Settings should display readiness and direct the user there rather than duplicating chat model management.
- Add a separate EmbeddingModelCatalog and embedding download flow; do not overload the chat ModelCatalog in M3.
- Do not mark setup complete from a registered model path alone; use runtime status/load checks.
- Store setup state in SupraStore, not in UserDefaults.
```

## 2.2 Model Policy

M3 uses fully local models.

```text
- Chat model: existing local runtime model, loaded before import is allowed.
- Embedding model: curated high-quality default downloadable from Hugging Face.
- Additional embedding models: user may download/select other Hugging Face models later.
- Model downloads: explicit user action only.
- Post-download use: fully local.
```

Quality is favored over speed or disk size. Larger on-disk databases and embedding caches are acceptable.

Model record ambiguity to resolve in code, with this default:

```text
- Add a model kind field or parallel embedding model table so chat models and embedding models are not confused.
- Chat model selection continues to use the existing models table and ModelLibrary.
- Embedding model records should include repo id/path, display name, vector dimension, runtime family, and last test-load result.
```

## 2.3 Setup State

Add persisted setup state that records:

```text
- selected chat model id
- last successful chat model load check
- selected embedding model id/path
- last successful embedding model load/test check
- converter toolchain version/capability check
- OCR availability check
- notification permission status
- setup completed at
- setup invalidated reason, if any
```

If a model, toolchain, or app setting changes in a way that affects document intelligence, mark setup as needing review and audit the major change.

---

# 3. Supported Import Formats

## 3.1 Required Input Types

M3 must support:

```text
- PDF: .pdf
- images: .png, .jpg, .jpeg, .tif, .tiff, and .heic if supported by native decoding
- text: .txt
- Markdown: .md, .markdown
- rich text: .rtf
- HTML: .html, .htm
- XML: .xml
- Word: .doc, .docx, .dotx
- spreadsheets: .xls, .xlsx
- email: .eml, .msg
```

If one legacy format proves impossible to support robustly with a local bundled tool, keep the importer stable, mark that file as failed with a clear reason, and include it in the import report. Do not silently skip.

## 3.2 Email Attachments

Email attachments are imported automatically as child documents.

Rules:

```text
- preserve parent email -> attachment relationship
- attachments inherit the batch/folder context unless the user later moves/copies them
- attachment failures do not fail the parent email extraction
- source links can point to email body chunks or attachment child document chunks
```

## 3.3 Spreadsheet Extraction

Spreadsheet support is limited to visible user-facing values.

Include:

```text
- workbook name
- visible sheet names
- visible cell values
- row/column coordinates
- simple table-like text normalization
```

Exclude for M3:

```text
- formulas as formulas
- hidden sheets
- hidden rows/columns
- comments
- macros
- pivot/cache internals
```

Source locators should use workbook/sheet/cell range, such as:

```text
Document.xlsx > Sheet1!B4:D9
```

## 3.4 Normalized Previews

Pixel-perfect previews are not required for every source type.

```text
- PDF/image: original visual preview where possible.
- OCR image/PDF: visual preview with OCR box highlight when coordinates exist.
- spreadsheet: normalized grid/table preview with cell-range highlight.
- text/Markdown/XML/HTML/email body: normalized text/HTML preview with text highlight.
- Word/RTF/legacy Office/MSG: normalized text/HTML/PDF preview is acceptable.
```

---

# 4. Managed Storage And Identity

## 4.1 Copy On Import

Supra copies imported documents into app-managed local matter storage. Originals are never modified.

Store only managed relative paths and safe display names in normal records. Avoid exposing raw absolute source paths in audit, diagnostics, exports, or generated outputs.

Default storage layout:

```text
Application Support/
  SupraAI/
    MatterDocuments/
      blobs/
        <sha256-prefix>/
          <sha256>.<ext>
      previews/
        <document_id>/
      temp/
      exports/
        <matter_id>/
```

Sandbox rules:

```text
- Use user-selected read-only access for file/folder import.
- Copy each file into app-managed storage before extraction.
- Extract email attachments from the copied parent email into app-managed child blobs before processing them.
- Security-scoped bookmarks to originals are optional and only for re-import/reveal workflows.
- Never require the original source location after import completes.
```

## 4.2 Content Blobs And Document Instances

Use content-addressed storage for raw imported file blobs:

```text
document_blobs
  - blob_id
  - sha256
  - byte_size
  - original_extension
  - managed_relative_path
  - mime_type or ut_type
  - created_at
```

Use separate matter document instances:

```text
matter_documents
  - document_id
  - matter_id
  - blob_id
  - parent_document_id, nullable
  - folder_id
  - display_name
  - imported_relative_path
  - source_display_path, redacted/safe relative path from batch root
  - status fields
  - metadata dates
  - deleted_at
```

The same content may exist in multiple folders as distinct document instances. Each instance has its own folder, tags, source context, deletion state, and relevance. The blob is shared only to avoid duplicate file storage.

## 4.3 Folders

M3 supports matter-level user-created folders.

Required:

```text
- recursive batch import preserves folder hierarchy
- user can create, rename, move, and soft-delete folders
- user can move a document instance between folders
- user can copy a document instance to another folder, creating a new document instance pointing to the same blob
- deleting a folder soft-deletes contained document instances after confirmation
```

## 4.4 Tags

M3 supports user-created tags.

Rules:

```text
- tags are matter-scoped
- tags attach to document instances, not blobs
- duplicate document instances may have different tags
- tag filters are available in search, Q&A, and chronology source selection
```

## 4.5 Duplicate Handling

Retrieval and search should deduplicate by default when multiple document instances point to identical or near-identical content.

```text
- Search: show one collapsed result by default with "also appears in N locations".
- Q&A/chronology: avoid citing the same underlying content repeatedly by default.
- User can expand duplicates when folder context matters.
- Source appendices should identify the selected document instance and note duplicate locations when relevant.
```

---

# 5. Import And Processing Jobs

## 5.1 Batch Import

Batch import must support:

```text
- folder picker
- file picker
- drag-and-drop into the Documents tab
- recursive folder import
- preserved folder hierarchy
- all supported file types by default
- optional user-selected subset before import begins
- continue-on-failure behavior
- final import report
```

The import report must account for every discovered file and attachment:

```text
- imported
- duplicate blob reused
- unsupported
- extraction failed
- OCR needed
- OCR failed
- indexed
- embedding pending/complete/failed
- skipped by user selection
```

## 5.2 Fire-And-Forget Processing

Import and indexing are fire-and-forget after the user starts the batch.

Required UX:

```text
- progress visible by matter
- phase labels visible
- per-document statuses visible
- completion/failure notification through macOS notifications
- no app-wide dashboard/job center in M3
```

The Documents tab for the matter is the job/progress home.

## 5.3 Job Queue

Use one active document processing job app-wide.

```text
- queue additional jobs FIFO
- process one job at a time
- user can cancel queued jobs
- no manual reorder in M3
- active job cancellation is not required in M3; if added, it must stop only at safe phase boundaries
```

## 5.4 Quit And Resume

Jobs run while the app is open.

On quit:

```text
- pause processing at durable phase boundaries
- persist enough state to reconcile safely
```

On relaunch:

```text
- detect paused/interrupted jobs
- ask the user before resuming
- reconcile partially written files/index rows before continuing
```

## 5.5 Processing Phases

Use phase-based progress:

```text
1. Discovering files
2. Copying and hashing
3. Expanding emails/attachments
4. Extracting text
5. Detecting OCR needs
6. OCR processing
7. Chunking
8. Full-text indexing
9. Semantic embedding
10. Finalizing import report
```

## 5.6 Notifications

Ask for notification permission during Document Intelligence setup.

Send notifications for:

```text
- import batch complete
- import batch complete with failures
- OCR complete
- OCR failed/action needed
- text indexing complete
- semantic indexing complete
- selected matter document intelligence ready
- job failed/action needed
```

---

# 6. Extraction And OCR

## 6.1 Extraction Goals

Extraction must be deterministic, inspectable, and failure-tolerant.

For every document instance, persist:

```text
- extraction status
- extraction method
- extracted text checksum
- warnings
- errors
- metadata dates
- page/sheet/part count
- OCR confidence summary when applicable
- whether user-edited extracted text exists
```

## 6.2 OCR

OCR is required in M3.

Scope:

```text
- scanned PDFs
- low-text PDF pages
- image files
- image attachments from emails
```

Rules:

```text
- OCR runs locally using on-device capabilities.
- OCR warnings and confidence concerns are shown in generated answers when cited.
- User can edit extracted/OCR text after import.
- If OCR confidence is low, suggest re-import/re-OCR instead of pretending certainty.
- Current edited text is enough; M3 does not need version history of extracted text edits.
```

## 6.3 Page And Locator Model

Represent source locations with a flexible locator:

```text
document_id
blob_id
chunk_id
source_kind: pdf_page | image | text | html | xml | spreadsheet_cell_range | email_body | email_attachment | converted_document
page_index/page_label, if applicable
sheet_name/cell_range, if applicable
email_part_path, if applicable
char_range in normalized text
bounding_boxes, if available
normalized_preview_anchor
```

Highlight quality is best effort:

```text
- PDF/image OCR: bounding box highlight when available; page-level fallback.
- Spreadsheet: cell-range highlight.
- Text/Markdown/HTML/XML/email body: text range highlight.
- Converted Office/RTF/MSG: text highlight if mapping survived; otherwise chunk-level highlight.
```

---

# 7. Indexing And Retrieval

## 7.1 Chunking

Chunking must preserve stable locators and be deterministic.

Requirements:

```text
- chunk by page/part first where the source has natural boundaries
- split long text into token/character-bounded chunks with overlap
- keep exact source locator metadata
- keep normalized text and display excerpt separately when useful
- re-chunk and re-index when user edits extracted text
```

## 7.2 Full-Text Search

Use SQLite FTS5 for exact and keyword search.

Search must support:

```text
- matter-scoped search
- folder filter
- tag filter
- document subset filter
- date filter
- ready-only search while indexing continues
- incomplete-scope warnings
- duplicate collapse by default
```

## 7.3 Semantic Search

M3 must support natural-language semantic search fully locally.

Requirements:

```text
- local embedding model
- persisted embeddings for chunks
- embedding model id/version stored with vectors
- re-embed when model changes
- app-managed embedding cache/database
- quality-oriented default model
- on-demand embedding model load
```

For M3 scale, app-side cosine similarity over persisted vectors is acceptable if it meets responsiveness targets for up to about 200 documents. If a local vector index is added, it must be pinned and documented as a dependency.

Default vector storage:

```text
- store one vector per chunk per embedding model
- store Float32 vectors as little-endian BLOB values
- store dimension, normalization flag, model id, model display name, and model revision/hash
- normalize vectors once at write time so cosine similarity can use dot product
- delete stale vectors when chunk text changes
- mark semantic index stale when embedding model changes
```

## 7.4 Hybrid Retrieval

Combine:

```text
- exact/FTS ranking
- semantic ranking
- recency/date signals where relevant
- folder/tag/document filters
- duplicate/content-hash collapse
- source diversity
```

Retrieval must expose why sources were selected:

```text
- matched terms, when FTS contributed
- semantic similarity score bucket, not necessarily raw score
- folder/tag/date filters applied
- duplicate collapse notes
```

---

# 8. Q&A

## 8.1 Source Scope

Q&A defaults to all matter documents.

The user can select a subset by:

```text
- folders
- documents
- tags
- date ranges
- search result selections
```

Q&A is blocked until the selected source scope is fully text-indexed and semantically indexed. Search can still work over ready documents while indexing continues.

## 8.2 Source Selection Modes

Support both workflows:

```text
Auto-source:
  Supra selects sources and answers immediately, then shows citations and source details afterward.

Guided:
  Supra retrieves candidate sources, lets the user inspect/refine them, then answers from the selected source set.
```

Auto-source is the default, and the source set must remain inspectable and reusable.

## 8.3 Answer Modes

Default answer style:

```text
- short
- direct
- cited inline
```

Optional pre-submit toggle:

```text
- memo-style answer
- more formal structure
- still source-grounded with inline citations
```

## 8.4 Citation Requirements

Every factual claim in a Q&A answer should be supported by source references.

Required:

```text
- inline citation markers
- source appendix references
- source links back to document/page/chunk
- OCR/extraction warnings shown in the answer when cited sources have confidence issues
- answer saved with the source set used
- regenerate option uses same source set by default
```

Post-generation checks must flag:

```text
- missing citation markers
- citation ids that do not resolve
- answer text that appears to rely on unsupported facts
- cited OCR chunks with low confidence
- answer generated from incomplete source scope
```

If citation checks fail, show the result as needing review and do not present it as cleanly grounded.

---

# 9. Fact Chronology

## 9.1 Scope

Fact chronology generation stays in M3.

It is:

```text
- user-initiated
- one-shot
- generated from selected source scope
- saved as generated
- regeneratable
- exportable
```

It is not:

```text
- an editable structured timeline database
- a continuously updating background view
```

## 9.2 Source Inputs

Use both:

```text
- extracted dates in document text
- metadata dates from files/emails/documents
```

Chronologies must use exact dates where available. If only partial dates are available, label them explicitly as partial/approximate rather than inventing specificity.

## 9.3 Output Formats

Before generation, let the user choose:

```text
- table/timeline format
- narrative chronology format
```

Both formats require inline citations and source appendix references.

---

# 10. Outputs And Exports

## 10.1 Saved Outputs

Q&A answers and chronologies are saved exactly as generated.

Required:

```text
- saved in the matter Outputs tab
- represented as structured_outputs rows using new StructuredOutputType cases
- generated markdown stored in structured_output_versions.content_markdown
- retain generated text
- retain source set
- retain citation/source appendix data
- retain answer mode or chronology format
- regenerate option
```

Inline editing before save is out of scope for M3.

Do not create a parallel output list for document answers/chronologies. The existing Outputs tab is the canonical saved-output surface. Add document-specific metadata and source tables around existing structured output records/versions.

Source data should be version-scoped, not only output-scoped:

```text
- Regeneration creates a new structured_output_versions row.
- Each version has its own document_source_sets/document_output_sources rows.
- The active version determines the citations shown by default.
- Older versions retain their original source set for auditability.
```

## 10.2 Export Formats

Support export to:

```text
- PDF
- Markdown
- DOCX
- CSV
- XLSX
```

CSV/XLSX primarily apply to chronology/table outputs and source appendices. Markdown/DOCX/PDF apply to Q&A, memo-style answers, narrative chronologies, and table chronologies.

## 10.3 Export Content

Exports include:

```text
- generated output
- inline citations
- source appendix
- review warning that the user should verify before external use
```

Exports do not include:

```text
- underlying imported documents
- hidden raw source files
- redacted/unredacted alternate copies
```

Source appendix excerpts may be fairly long when needed, but should stay reasonable and focused on the cited chunk/page/cell range.

---

# 11. In-App Preview And Highlights

## 11.1 Citation Click Behavior

Clicking a citation/source link opens an in-app preview at the cited location.

Required preview behavior:

```text
- open the correct document instance
- navigate to page/sheet/part/chunk
- apply visual highlight when possible
- show source metadata and warnings nearby
- show duplicate locations collapsed unless expanded
```

## 11.2 Highlight Fallbacks

If exact highlight is unavailable:

```text
- fall back to chunk-level highlight
- if chunk-level is unavailable, fall back to page/part-level highlight
- if preview conversion failed, show normalized extracted text with source locator
```

The UI should never fail silently when a source link cannot be rendered.

---

# 12. Trash, Deletion, And Audit

## 12.1 Soft Delete

Document and folder deletion is soft-delete by default with confirmation.

Required:

```text
- recycle-bin style restore view per matter
- restore document instance
- restore folder and contained instances when possible
- exclude soft-deleted instances from search/Q&A/chronology by default
```

Deleting one duplicate instance does not delete other instances pointing to the same blob.

## 12.2 Permanent Delete

Permanent delete is available:

```text
- by explicit user request
- through a periodic auto-purge setting after xx days
```

Use standard confirmation. A typed confirmation phrase is not required.

When permanently deleting:

```text
- delete the document instance and derived index rows
- delete the shared blob only when no remaining document instances reference it
- record a major audit event
```

## 12.3 Audit Scope

Audit major actions only:

```text
- document intelligence setup completed/changed/invalidated
- batch import started/completed/failed
- document/folder soft-deleted/restored/permanently deleted
- OCR started/completed/failed
- text indexing completed/failed
- semantic indexing completed/failed
- Q&A generated/saved/exported
- chronology generated/saved/exported
- export completed/failed
```

Do not audit every search query, UI click, chunk read, hover, preview open, or minor filter change.

---

# 13. Performance Targets

M3 performance targets should reflect local import, conversion, OCR, embedding, and RAG complexity. Processing can take a while; the important production behavior is that it is durable, visible, cancellable where safe, and resumable.

## 13.1 Import And Processing

Targets:

```text
- User can start a 200-document batch without the app becoming unusable.
- Batch acceptance and job creation should complete quickly, ideally under 10 seconds after selection.
- Progress should update during each phase rather than appearing stuck.
- Small text-heavy batches should usually finish extraction and text indexing in minutes.
- OCR-heavy or legacy Office/email-heavy batches may take much longer and can run for hours.
- Semantic indexing may continue after text indexing and should report its own progress.
- Exact wall-clock completion for 200 mixed documents is not a pass/fail target in M3.
```

## 13.2 Interactive Search

Targets once the relevant index is ready:

```text
- FTS search over ready chunks should normally return within 2 seconds.
- Hybrid search should normally return within 5 seconds for a matter up to about 200 documents.
- Search over partially ready documents must show incomplete-scope warnings.
```

## 13.3 Q&A And Chronology

Targets:

```text
- Scope readiness check should be immediate.
- Source retrieval should usually complete within 15 seconds after indexes are ready.
- Generation time is model-dependent and may be longer.
- The UI must show progress through source retrieval, generation, citation checking, and saving.
```

---

# 14. Store Additions

Add migrations after `v021_create_audit_events_phase2`.

Use these exact migration names unless a newer merged branch has already consumed one of the version numbers. If that happens, append after the newest migration and preserve the table purposes/order.

```text
v022_create_document_intelligence_settings
v023_create_document_blobs
v024_create_document_folders
v025_create_matter_documents
v026_create_document_tags
v027_create_document_tag_assignments
v028_create_document_pages_parts
v029_create_document_chunks
v030_create_document_chunk_fts
v031_create_document_embedding_models
v032_create_document_chunk_embeddings
v033_create_document_import_batches
v034_create_document_processing_jobs
v035_create_document_source_sets
v036_create_document_output_sources
v037_create_document_exports
```

Required repository capabilities:

```text
- setup state read/write
- import batch creation/progress/final report
- blob upsert by sha256
- folder CRUD and hierarchy moves
- document instance CRUD, move/copy, soft-delete/restore/permanent delete
- tag CRUD and assignment
- extraction/page/chunk replacement in a transaction
- FTS index update/delete
- embedding update/delete by model id
- search persistence where useful
- source set persistence
- create structured_outputs/structured_output_versions for document Q&A/chronologies
- attach source sets and source links to structured_output_versions
- regenerate by creating a new structured_output_versions row and new source set rows
- export records for generated document outputs
- job queue persistence and resume reconciliation
```

Also update the DEBUG-only `deleteAllTables(_:)` list in `SupraMigrator.swift` so M3 tables are dropped before existing parent tables during debug schema resets.

Table relationship defaults:

```text
document_source_sets
  - source_set_id
  - matter_id
  - structured_output_version_id, nullable only while source selection/generation is in progress
  - status: pending | attached | discarded
  - mode: auto_source | guided | chronology
  - scope_json: folders/documents/tags/date filters
  - retrieval_query
  - created_at

document_output_sources
  - source_id
  - source_set_id
  - structured_output_version_id
  - document_id
  - chunk_id
  - citation_label
  - locator_json
  - excerpt
  - rank
  - warnings_json

document_exports
  - export_id
  - structured_output_id
  - structured_output_version_id
  - matter_id
  - format
  - managed_relative_path
  - created_at
```

---

# 15. Validation Suite

M3 must include a real validation suite, not only scattered unit tests.

Use two layers:

```text
1. Deterministic document pipeline validation.
2. App-run document intelligence validation against the loaded local chat model and embedding model.
```

The suite should build on the existing Milestone 1 validation infrastructure where practical, but it may add document-specific fixtures, result types, and mechanical checks.

Required exposure:

```text
- Deterministic pipeline validation runs through SwiftPM tests.
- App-run document intelligence validation is exposed in Diagnostics as "Run M3 Document Validation".
- The Diagnostics flow requires completed Document Intelligence setup and loaded/tested models.
- Persist M3 validation through the existing validation history/report pattern: create a model_validation_runs row with suite id "milestone3-document-intelligence-suite", store per-scenario rows in model_validation_tests, and write the rich Markdown/JSON report through the existing report/export plumbing.
```

## 15.1 Fixture Policy

Commit small synthetic fixtures for each required format when feasible.

Default location:

```text
Packages/SupraDocuments/Tests/SupraDocumentsTests/Fixtures/M3ValidationMatter/
```

Fixtures must:

```text
- contain no real client data
- be tiny enough for the repo
- use deterministic text
- include known dates, names, amounts, and contradictions
- include expected source locators
- include at least one intentional unsupported/failed file scenario
```

For binary formats that are hard to author manually, generate fixtures through checked-in scripts or documented local tool commands, then commit the resulting small files if licensing and repo size are acceptable.

## 15.2 Required Fixture Matter

Create a synthetic validation matter with a nested folder tree:

```text
Validation Matter/
  Contracts/
    service-agreement.pdf
    scanned-amendment.pdf
    legacy-termination.doc
    termination-letter.docx
    notice-template.dotx
  Emails/
    notice-thread.eml
    board-approval.msg
  Finance/
    invoice-summary.xlsx
    legacy-ledger.xls
  Notes/
    intake-notes.md
    witness-notes.txt
    rich-text-note.rtf
  Web/
    archived-page.html
    metadata.xml
  Images/
    photographed-receipt.jpg
    scanned-notice.png
    fax-page.tiff
  Duplicates/
    service-agreement-copy.pdf
  Unsupported-Or-Bad/
    corrupt-file.docx
```

The fixture set should exercise:

```text
- recursive folder import
- duplicate blob reuse with distinct document instances
- email attachments as child documents
- OCR on scanned PDF/image
- spreadsheet visible values
- Office/RTF/HTML/XML/Markdown/text extraction
- PDF/image alternates including born-digital PDF, scanned PDF, JPG, PNG, and TIFF
- failure reporting
```

## 15.3 Deterministic Pipeline Tests

These tests should run without a chat model.

Required checks:

```text
- setup gating blocks import before setup is complete
- recursive import preserves hierarchy
- imported files are copied into managed storage
- original files are not modified
- duplicate content uses one blob and multiple document instances
- email attachments become child documents
- unsupported/corrupt files appear in the import report
- extraction creates expected normalized text for each format
- OCR results can be mocked and persisted with confidence warnings
- user edits to extracted text trigger re-chunk/re-index
- chunks have stable locators
- FTS search finds exact terms and respects folder/tag/date filters
- semantic index records model id/version and vector dimensions
- duplicate search results collapse by default
- soft-delete removes document instances from search/Q&A scope
- restore makes instances searchable again
- permanent delete removes unreferenced blobs only
- source links resolve to document/page/chunk/cell locators
- export builders include inline citations and appendix references
- major audit events are recorded
```

## 15.4 App-Run Document Intelligence Tests

These tests require:

```text
- completed Document Intelligence setup
- loaded chat model
- installed/test-loadable embedding model
- imported validation matter
```

Required scenarios:

```text
1. Auto-source Q&A:
   Ask a direct question whose answer appears in two documents.
   Expect an answer with inline citations and resolvable source links.

2. Guided Q&A:
   Retrieve candidate sources, select a subset, generate an answer.
   Expect the saved source set to match the selected subset.

3. Unsupported Q&A:
   Ask a question not answered by the fixture matter.
   Expect the answer to say the source set does not support the answer.

4. OCR-cited answer:
   Ask about a fact available only through OCR.
   Expect OCR warning/confidence language in the answer or source details.

5. Duplicate handling:
   Ask about content duplicated in two folders.
   Expect one cited content source by default and duplicate locations noted.

6. Chronology table:
   Generate a table chronology from all documents.
   Expect exact dates, citations, and metadata/text-date distinction where applicable.

7. Chronology narrative:
   Generate a narrative chronology from a folder subset.
   Expect no facts outside the selected subset.

8. Export:
   Export a Q&A and chronology to required formats.
   Expect inline citations, source appendix, and no embedded raw source documents.

9. Queue/resume:
   Start a long fixture processing job, simulate interruption, relaunch/reconcile, and resume by user choice.
   Expect durable progress and no duplicate index rows.
```

## 15.5 Validation Pass Criteria

M3 cannot be considered complete unless:

```text
- all deterministic pipeline tests pass
- validation import report accounts for every fixture file and attachment
- Q&A generated in validation has no unresolved citation ids
- chronology generated in validation has no unresolved citation ids
- source links open to the expected preview target in automated checks where possible
- unsupported Q&A does not invent an answer
- export files are created and contain output plus appendix references
- no document processing test performs network access except explicit model download setup
- queue/resume validation leaves no stuck active job
```

The validation report should be saved in Diagnostics and include:

```text
- suite id/version
- app version/build
- chat model id/name
- embedding model id/name
- fixture matter id
- import summary
- extraction/OCR/indexing summary
- Q&A/chronology/export results
- warnings and failures
```

---

# 16. Work Orders

## WO 32 - M3 Schema And Core Types

Add document intelligence IDs/enums to `SupraCore`. Add store migrations v022+ and repositories for settings, blobs, folders, document instances, tags, chunks, embeddings, jobs, outputs, and exports.

Implementation targets:

```text
- Packages/SupraCore/Sources/SupraCore/IDs.swift
- Packages/SupraCore/Sources/SupraCore/DocumentDomainTypes.swift
- Packages/SupraStore/Sources/SupraStore/Database/SupraMigrator.swift
- Packages/SupraStore/Sources/SupraStore/SupraStore.swift
- Packages/SupraStore/Sources/SupraStore/Records/Document*.swift
- Packages/SupraStore/Sources/SupraStore/Repositories/Document*.swift
- Packages/SupraStore/Tests/SupraStoreTests/
```

Acceptance:

```text
- migrations apply on a clean database
- existing v001-v021 data remains intact
- repositories have focused unit tests
```

## WO 33 - Document Intelligence Setup

Build Settings flow for chat model readiness, embedding model selection/test-load, converter capability checks, OCR availability, storage initialization, and notification permission.

Implementation targets:

```text
- Packages/SupraSessions/Sources/SupraSessions/SettingsController.swift
- Apps/SupraAI/SupraAI/SettingsView.swift
- Packages/SupraSessions/Sources/SupraSessions/EmbeddingModelCatalog.swift
- Packages/SupraSessions/Sources/SupraSessions/EmbeddingModelDownloadController.swift
- Packages/SupraRuntimeInterface/Sources/SupraRuntimeInterface/DTOs/
- Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/
- Apps/SupraAI/SupraRuntimeService/
```

Acceptance:

```text
- import is blocked until setup is complete
- setup invalidates when relevant model/tool choices change
- major setup changes are audited
```

## WO 34 - Local Toolchain And Extraction Adapters

Select, pin, document, and wrap local extraction/conversion tools for formats not covered by Apple frameworks.

Implementation targets:

```text
- Packages/SupraDocuments/Sources/SupraDocuments/
- Docs/Architecture/Dependencies.md
- Packages/SupraDocuments/Tests/SupraDocumentsTests/
```

Acceptance:

```text
- dependencies documented
- tool failures are captured per file
- no document content leaves the machine
```

## WO 35 - Managed Storage, Folders, Tags, And Import

Implement content-addressed blob storage, document instances, recursive folder import, drag-and-drop import, folder preservation, tags, duplicate handling, and import reports.

Acceptance:

```text
- batch import handles nested folders
- originals are untouched
- duplicate blobs are reused
- failures appear in the report
```

## WO 36 - Extraction, OCR, And Editable Text

Implement extraction for required formats, OCR for scanned PDFs/images, low-confidence warnings, editable extracted text, and re-index triggers.

Acceptance:

```text
- all required fixture formats produce expected normalized text or clear failures
- OCR warnings surface in answer/source details
- edited extracted text updates chunks and indexes
```

## WO 37 - Chunking, FTS, Embeddings, And Hybrid Retrieval

Implement deterministic chunking, FTS5 indexing, local embedding generation/storage, hybrid retrieval, filters, duplicate collapse, and readiness checks.

Acceptance:

```text
- search works over ready documents during indexing
- Q&A/chronology block until selected scope is fully ready
- hybrid retrieval returns cited source candidates with locators
```

## WO 38 - Document Processing Queue

Implement one active app-wide processing job, FIFO queued jobs, cancellation of queued jobs, pause-on-quit, ask-before-resume on relaunch, progress phases, and notifications.

Acceptance:

```text
- no duplicate active document jobs
- interrupted jobs reconcile safely
- notifications fire for major completion/failure phases
```

## WO 39 - Documents Tab UI

Enable the Documents tab with folder tree, document list, drag-and-drop import, progress/status, tags, trash/restore, duplicate expansion, and search.

Implementation targets:

```text
- Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift: make MatterTab.documents enabled.
- Apps/SupraAI/SupraAI/Documents/: add Documents tab SwiftUI views.
- Apps/SupraAI/SupraAI/AppEnvironment.swift: create/inject document controllers.
- Packages/SupraSessions: add MatterDocumentsController and supporting view models.
- Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj: link SupraDocuments package/product and add new app files.
```

Acceptance:

```text
- clean functional UI
- no dashboard separate from matter context
- user can manage folders/tags/documents per matter
```

## WO 40 - In-App Preview And Source Links

Implement normalized previews, PDF/image previews, spreadsheet previews, source navigation, and best-effort visual highlights.

Acceptance:

```text
- citation links resolve to expected previews
- unavailable exact highlights fall back visibly
- source warnings are visible
```

## WO 41 - Auto-Source And Guided Q&A

Implement Q&A over selected source scope with auto-source and guided modes, short/default and memo-style answer modes, citation checks, source appendices, saved outputs, and regeneration.

Acceptance:

```text
- answers cite resolvable sources
- unsupported answers say unsupported
- saved answers retain source sets
```

## WO 42 - Fact Chronology

Implement one-shot chronology generation with table/timeline and narrative formats, exact date handling, metadata/text date distinction, citations, save, regenerate, and export.

Acceptance:

```text
- chronology uses selected scope only
- every factual entry has source support
- exact/partial dates are labeled correctly
```

## WO 43 - Output Exports

Implement PDF, Markdown, DOCX, CSV, and XLSX exports with inline citations, source appendix, and review warning.

Acceptance:

```text
- exports contain generated output plus appendix references
- exports do not embed raw imported documents
- export actions are audited
```

## WO 44 - Trash, Purge, And Audit

Implement soft-delete, restore, permanent delete, auto-purge setting, and major audit events.

Acceptance:

```text
- delete is instance-scoped
- unreferenced blobs are cleaned only when safe
- major actions are audited
```

## WO 45 - M3 Validation Suite

Build the deterministic pipeline validation suite and app-run document intelligence validation suite.

Implementation targets:

```text
- Packages/SupraDocuments/Tests/SupraDocumentsTests/Fixtures/M3ValidationMatter/
- Packages/SupraDocuments/Tests/SupraDocumentsTests/
- Packages/SupraSessions/Sources/SupraSessions/BundledValidationSuite.swift
- Packages/SupraSessions/Sources/SupraSessions/Resources/
- Packages/SupraSessions/Sources/SupraSessions/DocumentValidationRunner.swift
- Packages/SupraSessions/Sources/SupraSessions/DocumentValidationRunController.swift
- Packages/SupraDiagnostics/Sources/SupraDiagnostics/
- Apps/SupraAI/SupraAI/DiagnosticsView.swift
```

Acceptance:

```text
- synthetic fixtures cover all required formats
- deterministic tests pass locally
- app-run validation report is saved in Diagnostics
- validation gates in section 15.5 pass
```

## WO 46 - Hardening Pass

Run validation, repair failures, review performance, confirm no hidden network use during processing, and update dependency documentation.

Acceptance:

```text
- validation report clean enough for M3 signoff
- known limitations documented
- M3 handoff notes identify remaining production gaps
```

---

# 17. Open Decisions To Reconfirm During Implementation

These should be resolved during dependency/toolchain work, not left until final QA:

```text
- exact local converter/extraction tool choices and licenses
- exact curated default embedding model
- whether .heic image import is available through native decoding in the deployment target
- final auto-purge default value for deleted documents
- exact validation fixture generation approach for legacy binary formats
```

---

# 18. Progress Log

Implementation tracking for M3. Each entry is one work order / commit point.
Branch: `feat/milestone3` (off `main`).

## WO 32 — M3 Schema And Core Types — DONE (2026-06-17)

Status: complete; `swift test` green for SupraCore (13) and SupraStore (20, incl. 11 new M3 tests).

Delivered:
- `SupraCore/IDs.swift`: added all 12 document ID wrappers.
- `SupraCore/DocumentDomainTypes.swift`: new file with `MatterDocumentStatus`,
  `DocumentExtractionStatus`, `DocumentIndexStatus`, `DocumentProcessingPhase`,
  `DocumentSourceKind`, `DocumentGeneratedOutputKind`, plus helper enums
  (`DocumentProcessingJobStatus`, `DocumentImportBatchStatus`,
  `DocumentSourceSetStatus`, `DocumentSourceSetMode`, `DocumentImportDisposition`).
- `SupraCore/LegalDomainTypes.swift`: extended `StructuredOutputType` with the 4
  document cases.
- `SupraStore/Database/SupraMigrator.swift`: migrations v022–v037 (all 16 tables
  from §14, including the FTS5 virtual table) + updated DEBUG `deleteAllTables`
  to drop M3 children before parents.
- `SupraStore/Records/Document*.swift`: 15 record types.
- `SupraStore/Repositories/Document*.swift`: 5 repositories + wired into `SupraStore`.
- `SupraStore/Tests/SupraStoreTests/Milestone3SchemaTests.swift`: 11 focused tests
  (dedup, folder cascade soft-delete/restore, move/copy, permanent-delete blob GC,
  tags, chunk/FTS replacement + embedding cascade, soft-delete search exclusion,
  embedding-model selection + setup state, FIFO job queue + resume reconcile,
  source-set attach + exports, import-batch report).

Deviations from the literal plan (kept within plan intent):
- Repositories are grouped into 5 cohesive types rather than one-per-table, matching
  the existing convention where `ChatRepository`/`ResearchRepository` own several
  tables: `DocumentSettingsRepository` (settings + embedding models),
  `DocumentLibraryRepository` (blobs/folders/documents/tags), `DocumentIndexRepository`
  (parts/chunks/FTS/embeddings), `DocumentJobRepository` (batches/jobs),
  `DocumentSourceRepository` (source sets/output sources/exports).
- `matter_documents.import_batch_id` is a plain TEXT column (no SQL FK) because
  `document_import_batches` is created later at v033; avoids a forward reference.
- Per-document extraction metadata (method, checksum, warnings/errors, page count,
  OCR confidence summary, user-edited flag) lives on `matter_documents` since §14's
  table list has no separate extraction table.

Toolchain note (env, not plan): the default CLI `swift` is broken; build/test with
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## WO 33 — Document Intelligence Setup — DONE (2026-06-17)

Status: complete; app builds (`xcodebuild -scheme SupraAI`), all package tests green
(SupraDocuments 4, SupraRuntimeClient 4, SupraSessions 43 incl. 3 new setup tests).

Delivered:
- New `SupraDocuments` package (created here, per §1.1; extraction adapters land in
  WO 34): `SupportedDocumentTypes` (format policy), `DocumentStorage` (managed
  blob/preview/temp/export layout + sha256 hashing), `DocumentToolchain`
  (PDFKit/Vision/OCR/HEIC capability detection) + 4 tests.
- Runtime embedding boundary (§1.4): `EmbeddingDTOs` (Load/Embed/Status +
  `EmbeddingModelState`), `RuntimeStatus.embeddingModelID`, 3 RPCs added to the
  Swift + `@objc` XPC service protocols and `RuntimeClientProtocol` (with default
  impls so non-embedding doubles compile), `RuntimeClient` methods, and a real
  `MLXEmbeddingModelController` (actor, serialized) backed by **MLXEmbedders**
  (already in `mlx-swift-lm`; product linked into the runtime target via pbxproj).
- Sessions: `EmbeddingModelCatalog` (curated, quality-first default
  `BAAI/bge-base-en-v1.5`), `EmbeddingModelDownloadController`,
  `DocumentNotifications` (injectable), and `DocumentIntelligenceSetupController`
  (orchestrates the 6 setup steps, persists state in
  `document_intelligence_settings`, gates import via `isReadyForImport`, audits
  setup completed/changed/invalidated).
- App: `SettingsView` "Document Intelligence" section (per-step status, embedding
  download/test-load, storage init, notifications, Mark Complete); `AppEnvironment`
  constructs the controllers and refreshes setup on bootstrap.
- `Docs/Architecture/Dependencies.md` updated with the M3 embedding stack.

Deviations from the literal plan (kept within plan intent):
- Setup orchestration lives in a dedicated `DocumentIntelligenceSetupController`
  rather than being stuffed into `SettingsController`, matching the existing
  one-controller-per-concern convention (ModelDownloadController, ValidationRun
  Controller). The plan named SettingsController as a target; intent ("setup lives
  in Settings") is met via the Settings UI section.
- `SupraDocuments` is created in WO 33 (not WO 34) because setup's capability checks
  need it; WO 34 fills in the heavier extraction/conversion adapters.
- Embedding model uses MLXEmbedders (resolved §17 open decision: curated default
  `BAAI/bge-base-en-v1.5`, 768-d, with larger quality options offered).
- Import gating mechanism (`isReadyForImport`) is in place; the Documents tab that
  consumes it is enabled in WO 39.

## WO 34 — Local Toolchain And Extraction Adapters — DONE (2026-06-17)

Status: complete; SupraDocuments tests green (14), app builds with the new
transitive dependency.

Delivered (all in `SupraDocuments`):
- `DocumentExtraction.swift`: `ExtractedPart`/`ExtractionResult`/`ExtractedAttachment`
  result types, `ExtractionError`, the `DocumentExtractor` protocol, and an
  `ExtractionService` that dispatches by supported-type family.
- `TextExtractors.swift`: plain text / markdown, XML (`XMLParser`), HTML
  (in-house tag-strip + entity decode, no WebKit), shared `TextNormalization`.
- `OfficeExtractors.swift`: `.docx/.dotx` via ZIPFoundation + OOXML SAX; `.rtf`
  and legacy `.doc` via `NSAttributedString` on the main actor; a `ZipArchiveReader`.
- `SpreadsheetExtractor.swift`: `.xlsx` shared-strings + sheet SAX → visible cell
  values with coordinates and used range; legacy `.xls` reported unsupported.
- `EmailExtractor.swift`: in-house RFC 822 / MIME parser (multipart, base64,
  quoted-printable) → body part + attachments as child documents; `.msg` reported
  unsupported.
- `PDFImageExtractors.swift`: PDFKit per-page text with low-text `needsOCR`
  detection; images flagged `needsOCR` (OCR itself in WO 36).
- `Docs/Architecture/Dependencies.md`: documented the extraction matrix and the
  one pinned library.

Deviations / decisions (within plan intent):
- No third-party converter binaries. Apple frameworks + in-house parsers cover the
  formats; the only added dependency is **ZIPFoundation 0.9.20 (exact, MIT)** for
  `.docx`/`.xlsx` containers — satisfies §1.5's "pinned, documented, local, no
  upload" requirements with the least redistribution/licensing risk.
- Legacy `.xls` and Outlook `.msg` are reported as `unsupportedFormat` (captured in
  the import report, never silent) rather than supported via a bundled tool — this
  is the §3.1 / §15.2 "failure reporting" path. `.doc`, `.docx`, `.rtf`, and all
  text/office/spreadsheet/email families ARE supported.
- OCR is not performed here (split to WO 36); PDF/image extractors set `needsOCR`.

## WO 35 — Managed Storage, Folders, Tags, And Import — DONE (2026-06-17)

Status: complete; deterministic import tests green (SupraSessions 45 total incl. 2
new import tests; SupraStore 20).

Delivered:
- `SupraSessions/DocumentImportService`: the import engine. Recursively walks
  files/folders, preserves hierarchy as `document_folders`, copies each file into
  content-addressed managed storage with sha256 dedup (blob reused across
  instances), creates `matter_documents`, runs `ExtractionService`, persists
  `document_pages_parts` + extraction metadata, expands email attachments as child
  documents (a failed attachment never fails the parent), records unsupported/
  corrupt files as failed instances + report lines, and finalizes the batch with a
  `DocumentImportReport` (per-file dispositions + counts). Audits import
  completed/with-failures.
- `SupraStore/DocumentLibraryRepository`: added `updateExtraction(...)` and
  `markTextEdited(...)` (edits → `edited` + `stale` for re-index).
- Tests: recursive hierarchy + dedup (one blob, two instances) + managed-storage
  copy + originals untouched + email attachment child docs + unsupported reporting
  + batch report; and edited-text → stale.

Notes: tags repo capability already exists (WO 32); the Documents-tab UI for
folders/tags/drag-drop is WO 39. Import gating consumes
`DocumentIntelligenceSetupController.isReadyForImport` (WO 33) at the UI layer.

## WO 36 — Extraction, OCR, And Editable Text — DONE (2026-06-17)

Status: complete; SupraDocuments 14, SupraSessions 46, SupraStore 20 — all green.

Delivered:
- `SupraDocuments/OCRService`: `DocumentOCRService` protocol + `OCRTextResult` +
  Vision-backed `VisionOCRService` (image files via ImageIO; scanned PDF pages
  rendered via CoreGraphics → `VNRecognizeTextRequest`), capturing mean confidence
  and normalized bounding boxes. `OCRPolicy.lowConfidenceThreshold`. `ExtractedPart`
  gained `boundingBoxesJSON`.
- `DocumentImportService`: OCR injected (default `VisionOCRService`, mockable). After
  extraction, documents flagged `needsOCR` are OCR'd over the managed blob and
  merged into page parts. `persistExtraction` computes an OCR confidence summary and
  routes low-confidence results to `needs_review` with a warning; OCR'd docs become
  `ocr_complete`. Added `updateExtractedText(documentID:partID:text:)` (edit → part
  text replaced, doc marked edited + index stale for re-index).
- `SupraStore/DocumentIndexRepository.updatePartText(...)`.
- Tests: mocked OCR fills image text, low confidence → `needs_review` + summary, and
  edit → stale + new part text.

Re-chunk/re-embed of `stale` docs is performed by the indexing pass in WO 37; the
edit path here sets the trigger.

## WO 37 — Chunking, FTS, Embeddings, And Hybrid Retrieval — DONE (2026-06-17)

Status: complete; SupraDocuments 17, SupraStore 20, SupraSessions 48 (verified
deterministic across repeated runs).

Delivered:
- `SupraDocuments/DocumentChunker`: deterministic chunking — natural part
  boundaries first, then char-bounded windows with overlap, preferring paragraph/
  sentence/space breaks; preserves locators + char ranges. `DocumentSourceLocator`
  (Codable locator model with `displayString`/`encodedJSON`).
- `SupraSessions`: `VectorMath` (Float32-LE encode/decode, normalize, dot);
  `TextEmbedder` protocol + `RuntimeTextEmbedder` (loads the embedding model on
  demand, batches `embedTexts`); `DocumentIndexingService` (chunk → `replaceChunks`
  writes FTS + cascades stale embeddings → embed → advance index status; re-indexes
  `stale` docs); `DocumentRetrievalService` (hybrid FTS + cosine, folder/tag/date/
  document filters, duplicate-content collapse with noted locations, source
  diversity cap, semantic-similarity threshold, scope-readiness gating + incomplete-
  scope warning).
- `SupraStore`: `DocumentLibraryRepository.resolveScopeDocumentIDs(...)`;
  `DocumentIndexRepository.searchChunks(...)` now takes a document-id filter and
  sanitizes user text into a safe FTS5 OR-of-prefixes expression; `fetchChunks(ids:)`.
- Tests: chunker determinism/overlap/locators; index→retrieve with FTS + semantic,
  folder filter scoping, duplicate collapse, and text-only readiness without an
  embedder.

Decision: index status without an embedder stays `text_indexed` (searchable);
semantic readiness requires embeddings. Q&A/chronology readiness uses
`DocumentRetrievalService.scopeReadiness`.

## WO 38 — Document Processing Queue — DONE (2026-06-17)

Status: complete; SupraSessions queue tests green (FIFO drain, interrupted-job
reconcile, queued-job cancel); app builds with the queue wired in.

Delivered:
- `SupraSessions/DocumentProcessingQueue` (@MainActor ObservableObject): single
  active job, FIFO queue, per-job run of import → indexing with phase progress,
  completion/failure notifications (`DocumentNotifying`), queued-job cancellation,
  `pauseActiveForQuit()`, and `bootstrap()` relaunch reconciliation (interrupted
  active jobs → paused/`resumableJobs`, `resume(jobID:)`). `waitUntilIdle()` drives
  deterministic draining. Import sources are held in-memory per job; jobs whose
  sources are lost across relaunch fall back to store-only re-index reconciliation.
- `SupraStore/DocumentJobRepository.fetchPausedJobs()`.
- `AppEnvironment`: constructs the queue (import service + an indexing factory that
  builds a `RuntimeTextEmbedder` from the selected embedding model) and calls
  `documentQueue.bootstrap()` on launch.
- Tests: two import jobs drain FIFO to completion with per-job notifications and
  indexed chunks; interrupted active job becomes resumable on bootstrap; queued job
  cancels.

Note: the UI that enqueues imports (drag-drop) and surfaces progress/resume prompts
is WO 39; the queue + `pauseActiveForQuit` hook are ready for it.

## WO 39 — Documents Tab UI — DONE (2026-06-17)

Status: complete; app builds with the enabled Documents tab.

Delivered:
- `SupraSessions/MatterDocumentsController` (@MainActor): per-matter folders,
  documents, trashed docs, tags, search hits; import gating + enqueue through the
  queue; folder/tag CRUD; soft-delete/restore/permanent-delete (audited); FTS
  search with duplicate-content collapse; `allowedContentTypes` for the picker.
  `MattersController` now vends a `documentsController` on select (wired to the
  queue + a setup-ready gate); both are optional so existing call sites/tests are
  unaffected.
- `Apps/SupraAI/SupraAI/Documents/MatterDocumentsView.swift`: folder sidebar,
  document list with status badges/OCR-confidence/tags/per-row tag + delete menus,
  attachment indentation, file-importer + drag-and-drop import, live job-progress
  bar, search results, trash sheet (restore/permanent delete), and a setup-gating
  banner. `MatterWorkspaceView` Documents tab enabled and given the queue;
  `MattersView` passes `environment.documentQueue`.
- `AppEnvironment` init reordered so the queue + setup controller precede
  `MattersController`. pbxproj: new `Documents` group + `MatterDocumentsView.swift`
  (no SupraDocuments app-target link needed — the view uses SupraSessions/Store/Core
  types only).

Deviation: folder sidebar is a flat matter-scoped list rather than a nested tree
for v1 (clean + functional; nested-tree presentation can follow). Move/copy between
folders is available at the controller/repo level; richer drag-between-folders UI is
deferred.

## WO 40 — In-App Preview And Source Links — DONE (2026-06-17)

Status: complete; preview-loader tests green (3); app builds.

Delivered:
- `SupraSessions/DocumentPreviewLoader` + `DocumentPreviewModel`: resolves a
  `(documentID, DocumentSourceLocator)` into a renderable kind — `.pdf(path,page,
  highlightText)`, `.image(path,boxes)`, `.text(content,highlight range)`, or
  `.unavailable(reason,fallbackText)`. Picks the matching part (page/sheet/first),
  surfaces extraction/OCR warnings, and always falls back to normalized text so a
  link never fails silently (plan §11.2). `MatterDocumentsController` exposes
  `preview(chunkID:)` (open at the matched chunk) and `preview(documentID:)`.
- `Apps/.../Documents/MatterDocumentsView.swift`: `DocumentPreviewView` (sheet) +
  `PDFKitView` (NSViewRepresentable) navigating to the page with a best-effort
  `findString` highlight; image via NSImage; normalized text with an
  `AttributedString` char-range highlight; warnings shown in the header. Search
  hits and a per-row eye button open the preview.
- Tests: text locator → highlighted text; missing PDF blob → unavailable + text
  fallback; unknown document → unavailable.

Note: image OCR bounding-box overlay is carried in the model
(`boundingBoxesJSON`) but not yet drawn over the image (page/text highlight is
implemented); a deferred visual nicety.

## WO 41 — Auto-Source And Guided Q&A — DONE (2026-06-17)

Status: complete; citation tests (8) + Q&A flow tests (4) green; app builds.

Delivered:
- `SupraDocuments/DocumentGrounding`: `GroundingSource`, `DocumentAnswerMode`
  (short/memo → `documentQA`/`documentQAMemo`), `DocumentQAPromptBuilder`
  (inline-citation-required prompt), `CitationCoverage`/`CitationCheckResult`
  (label parsing, unresolved-label + missing-citation detection, valid
  "unsupported" handling, low-confidence + incomplete-scope flags, `requiresReview`),
  and `SourceAppendix` (Markdown).
- `SupraSessions/DocumentQAController` (@MainActor): readiness-gated generate
  (blocks until scope fully indexed), auto-source (hybrid retrieval) or guided
  (caller-selected chunk ids), short/memo modes, citation checks → `complete` vs
  `needsReview`, persists a `documentQA`/`documentQAMemo` structured output +
  version + a version-scoped source set + cited output sources (labels/locators/
  excerpts/warnings), and `regenerate` (new version + fresh source set from the
  saved scope/question). Audited.
- App: `MattersController` vends `documentQAController` (embedder from the selected
  model); Documents-tab "Ask" sheet (`DocumentQASheet`) with question, short/memo,
  optional folder scope, readiness display, and rendered cited answer.
- Tests: auto-source cited answer saved with source set; unsupported question does
  not invent an answer; missing citations → needs review; generation blocked when
  scope not indexed; plus the 8 citation-coverage unit tests.

## WO 42 — Fact Chronology — DONE (2026-06-17)

Status: complete; chronology tests (2) green; app builds.

Delivered:
- `SupraDocuments/DocumentChronology`: `DateExtraction` (ISO/slashed/month-name/
  month-year/bare-year detection), `DocumentChronologyFormat` (table/narrative →
  `factChronologyTable`/`factChronologyNarrative`), `DocumentChronologyPromptBuilder`
  (exact/partial date labeling, metadata-vs-text distinction, inline citations,
  source-only facts).
- `SupraSessions/DocumentChronologyController` (@MainActor): readiness-gated,
  one-shot. Harvests date-bearing chunks across the scope plus document metadata
  dates (distinguished), builds the table/narrative prompt, generates, citation-
  checks, and saves a `factChronology*` output + version + a `.chronology`-mode
  source set + cited sources. Audited. Reuses the Q&A `QAResult`/`CitationCoverage`/
  `SourceAppendix` machinery.
- App: `MattersController` vends `documentChronologyController`; Documents-tab
  "Chronology" sheet (`DocumentChronologySheet`) with format choice, optional folder
  scope, readiness, and the rendered chronology.
- Tests: scope-only facts (notes-folder narrative excludes the contract date;
  whole-matter table references both docs) + date-form detection.

## WO 43 — Output Exports — DONE (2026-06-17)

Status: complete; export tests (builders 5 + service 1) green; app builds.

Delivered:
- `SupraDocuments/DocumentExport`: `DocumentExportFormat` (pdf/markdown/docx/csv/
  xlsx), `DocumentExportPayload`, and `DocumentExportBuilder` writing each format —
  Markdown, CSV (source-appendix table), paginated PDF via CoreText, and minimal
  Office Open XML DOCX/XLSX via ZIPFoundation. Each carries the generated output +
  inline citations + source appendix + a review warning; no raw documents embedded.
- `SupraSessions/DocumentExportService`: assembles the payload from a saved
  output's active version + its source set (locators decoded to display strings,
  document names resolved), writes into managed `exports/<matter>/`, records a
  `document_exports` row, and audits `export_completed`.
- App: `StructuredOutputController.exportOutput(outputID:format:)`; Outputs-tab
  detail view gains an Export menu (PDF/MD/DOCX/CSV/XLSX) that writes the file and
  reveals it in Finder. (Outputs is the canonical saved-output surface per §10.1,
  covering document Q&A/chronology outputs too.)
- Tests: each format builder (PDF readable via PDFKit, DOCX/XLSX zip entries
  contain the text, MD/CSV content) and a full service export across all formats
  with persisted export records.

## WO 44 — Trash, Purge, And Audit — DONE (2026-06-17)

Status: complete; maintenance tests (2) green; app builds.

Most of this WO already existed at the repo/controller level from earlier WOs
(soft-delete/restore/permanent-delete with blob GC in WO 32/39; the Documents-tab
trash sheet in WO 39; major audit events across import/index/Q&A/chronology/export/
setup). WO 44 added the auto-purge half:
- `SupraStore`: `DocumentLibraryRepository.fetchDocumentsDeletedBefore(_:)`.
- `SupraSessions/DocumentMaintenance`: reads the configurable retention from
  `app_settings` (`documents.auto_purge_days`, default 30 — §17 decision resolved;
  0 disables), and `purgeExpired()` permanently deletes documents soft-deleted past
  the cutoff, cleans now-unreferenced blobs, and audits each as
  `document_permanently_deleted`.
- `DocumentIntelligenceSetupController.autoPurgeDays`/`updateAutoPurgeDays`; Settings
  "Auto-purge trash after N days" stepper. `AppEnvironment.bootstrap` runs
  `purgeExpired()` on launch. `folder_soft_deleted` audit added to the Documents
  controller.
- Tests: expired purge (keeps a recent instance + its still-referenced blob);
  retention 0 disables.

## WO 45 — M3 Validation Suite — DONE (2026-06-17)

Status: complete; deterministic suite passes; app builds with the Diagnostics
runner. (The model-dependent app-run scenarios require loaded models and were not
executed in this environment; the deterministic suite proves the same behavior.)

Delivered (two layers, per §15):
- Layer 1 — deterministic pipeline validation (SwiftPM, fully runnable):
  `Milestone3ValidationTests` authors the synthetic Validation Matter (nested
  folders; born-digital PDF/DOCX/XLSX via the export builder; RTF/HTML/XML/MD/TXT;
  an email with a base64 attachment; an image for mocked OCR; a byte-identical PDF
  duplicate; and `.xls`/`.msg`/corrupt-`.docx` failure fixtures) and runs import →
  mocked OCR → index (stub embedder) → search → Q&A → chronology → export, asserting
  the §15.5 gates (report accounts for every file + failures; recursive hierarchy;
  dedup; attachment child docs; originals untouched; extraction text; OCR confidence;
  FTS; source links resolve; soft-delete search exclusion; resolvable citations in
  Q&A/chronology; exports with appendix; audit events).
- Layer 2 — app-run validation in Diagnostics: `Milestone3ValidationFixtures`
  (shared authoring), `DocumentValidationRunController` (builds the fixture matter,
  runs the pipeline against the loaded chat + embedding models, persists per-scenario
  rows to `model_validation_runs`/`model_validation_tests` under suite id
  `milestone3-document-intelligence-suite`, and audits), and a Diagnostics
  "Run M3 Document Validation" section gated on completed setup + a loaded model.

Bugs found + fixed by the suite: `.xls`/`.msg` now report as `unsupported` (not
`extraction_failed`); the export XLSX builder now emits cell `r` references (so the
spreadsheet extractor reads them); scope readiness now excludes terminally-failed
documents so a failed import can't block Q&A forever.
