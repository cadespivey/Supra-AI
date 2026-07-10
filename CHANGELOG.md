# Changelog

All notable changes to Supra AI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Development history is tracked in detail in [`Docs/Milestones/`](Docs/Milestones/)
> (per-milestone implementation plans, work orders, and progress logs) and in the
> git history. This file summarizes user-facing changes per release.

## [Unreleased]

### Added

- **Drag and drop everywhere** — drag files onto a ScratchPad day to add them
  as billing evidence, or onto a global or matter chat to attach them to the
  conversation. This includes emails dragged straight from Mail or Outlook
  (and other drags that deliver a promised file rather than a real one), which
  previously did nothing.

### Changed

- **Documents drop follows your folder** — dropping or importing files in a
  matter's Documents tab now files them into the folder selected in the
  sidebar (All Documents still imports to the top level, as before).
- **ScratchPad week strip** — the ScratchPad header now shows the week at a
  glance: step between weeks and pick a day directly, with each date carrying
  the billable-hour total from its latest billing draft (the grey number
  appears once a draft has been run for that day and updates as you edit or
  regenerate). The screen title now matches the other module headers.

## [2.1.1] - 2026-07-09

Matter organization: sort and pin the sidebar, consistent client and
practice-area details as you type, and subfolders for each matter's documents.

### Added

- **Sidebar sorting** — sort matters by client (grouped under the client's
  name, ordered by client number), practice area, name, date created, date
  modified, or drag them into your own manual order. The choice persists.
- **Pinned matters** — right-click a matter to pin it to the top of the
  sidebar; pins hold in every sort mode.
- **Client and practice-area suggestions** — the matter form recommends known
  clients (typing the name fills the client number and vice versa) and
  existing practice-area spellings, so the same client is never entered two
  different ways.
- **Document subfolders** — create nested folders in a matter's Documents tab
  (right-click a folder for "New Subfolder"). New matters are preloaded with
  starter folders matched to their practice area (e.g. Pleadings, Discovery,
  Motions, and Exhibits for litigation).
- **Firm style profile** — Settings can now capture your firm's letterhead,
  caption, and signature-block styling for drafted documents, including
  parsing an uploaded exemplar for review before anything is saved.

### Fixed

- **Folder-scoped answers** — limiting Document Q&A or the fact chronology to
  a folder now includes documents filed in its subfolders.
- **Bluebook ordinals** — correct suffixes for reporter ordinals ending in
  1, 2, or 3 (21st, 42nd, 33rd).
- **Duplicate folders on import** — importing a directory whose name matches
  an existing folder now files into it instead of creating a duplicate.

## [2.1.0] - 2026-07-05

Faster research and chat: a rebuilt jurisdiction picker, a streamlined research
planner, and proactive model loading that cuts the wait before results.

### Added

- **Segmented jurisdiction picker** — choose Federal or State and drill to the
  court, capped at appellate levels (trial-court opinions aren't precedential).
  Replaces the free-text search and folds the court-scoping choices in beside it.
- **Speculative query generation** — the research planner drafts your CourtListener
  queries while you type, so they're ready the moment you run the plan.
- **Model pre-warming** — the app loads the model you're about to use ahead of time:
  the chat model at launch and on model switch, the embedding model at launch, and
  the drafting / Q&A / outputs / billing models when you open those screens.
- **Editable, re-runnable queries** in the research results view.
- **Recent Timings** in Diagnostics — model-load and generation latency, so you can
  see the pre-warming at work.

### Changed

- **Research planner is now two clicks, not four** — Generate + Save (return to
  Research) or Generate + Run (open the results). Query review moved into the
  results view.
- **Research searches run across all courts by default** — the jurisdiction still
  shapes the query wording; a toggle restricts the search to the jurisdiction's
  courts when you want it.
- **Faster jurisdiction search** — the court catalog is indexed once at startup,
  eliminating the typing lag.

### Fixed

- **Zero-results research sessions** — over-restrictive court filtering and
  over-quoted queries could return nothing; both are corrected.
- **Splash screen** now appears only on a true cold launch, not every time the
  window is reopened.
- **First click on a matter tab** is no longer swallowed right after opening the app.

## [2.0.1] - 2026-07-04

Public government records land in the app: SEC filings, CFPB complaints, and NLRB
case records — key-less, official-source-only, and neutrally framed.

### Added

- **Public Records** — a new sidebar destination (⌘3) searching three official
  government data sources with no API keys: SEC EDGAR company filings by CIK
  (annual/quarterly/current-report scopes, links to the official archive), the
  CFPB consumer-complaint database (company, state, and product filters), and
  NLRB case records. Every record links to its official source page, and
  complaints and filings are always presented as allegations as filed — never
  as findings.
- **CFPB company matching** — free-text company names are resolved through the
  CFPB's official name-suggestion service (its database matches exact canonical
  names), and the resolution is disclosed with the results.
- **NLRB dataset import** — official recent-filings and election-results
  exports import into a local store and search offline (party history, case
  lookup, employer/union search). When the NLRB site keeps its CSV behind an
  interactive download, the app says so honestly and accepts the
  browser-downloaded file via Import Downloaded CSV, detecting the dataset
  type from its headers.
- **Go menu** — keyboard navigation to every sidebar destination (⌘1–⌘6).

### Fixed

- SEC filing rows no longer show raw document filenames when EDGAR omits a
  description.

## [2.0.0] - 2026-07-02

Grounded answers become interactive and tiered: citations you can click, sources and
opinions that open inside the app, fast preliminary answers with explicit deeper
passes, research that starts from the matter's own authority library, a deeper
legal-data stack, and one unified visual chrome.

### Added

- **Clickable citations with an in-app source panel.** Inline `[S#]` markers in
  grounded chat answers open a right-edge preview of the cited document, jumped to
  and highlighting the exact cited passage. One shared, resizable panel serves chat,
  Q&A, and the Documents tab, and remembers its width.
- **In-app opinion reader.** `[A#]` legal citations open the full court opinion
  inside the app — case header, the cited passage highlighted and scrolled into
  view, and an "Open on CourtListener" link. Saved authorities read offline.
- **Tiered document retrieval.** Document Q&A and matter-chat answers run a fast
  pass first (seconds, the most relevant passages) and label the result
  *Preliminary*, with an explicit "Search All Documents (slower)" full pass. An
  empty fast pass escalates automatically; the preliminary answer is never
  discarded.
- **Local-first legal research.** A matter with saved authorities answers research
  questions from its own library first — same ranking and citation verification as
  network results — with "Search CourtListener (network)" as the wider tier.
  Opinion text is stored when you save an authority, so this works offline.
- **Docket case-finder.** "Who has sued X?" now searches CourtListener's
  RECAP/PACER dockets by party and returns a linked case list, clearly labeled as
  filings (not authority) — instead of a false "no results."
- **Live citation resolution in `/verify`.** Every cite in a checked answer is
  resolved against CourtListener's citation-lookup: real opinions link to the case;
  unresolved cites are flagged as possibly fabricated. Only the citation strings
  ever leave the device.
- **Official statute text as citable law.** U.S. Code sections (govinfo) and CFR
  sections (eCFR) are now retrieved as full official text with derived citations —
  real primary law in the source packet, not locator stubs.
- **Deeper legal-data connectors.** Naming a Regulations.gov docket returns that
  rulemaking's timeline; naming a bill ("HB 123") returns its description, sponsors,
  and official text link; Federal Register searches honor date ranges and document
  types ("proposed rules since 2024").
- **Documents tab rework.** Select-to-act rows (preview, open & edit in your
  default app, tag, move, delete), multi-select share/export, drag-and-drop between
  folders, and double-click to open.
- **Chat model selector.** Pick a model per chat or leave it on Autoselect
  (your Models-tab preferences), plus per-chat generation settings.

### Changed

- **Chat legal research quality.** Chat questions now use the same model query
  planner as the Research tab, retrieve cited cases directly (citation-first), and
  say honestly what corpus was searched when nothing matches.
- **One visual chrome.** Every sheet, popover, menu, and confirmation shares the
  same scaffold: ghost buttons, a semantic type scale, consistent iconography, and
  uniform "Delete “Name”?" confirmations.
- **Per-provider network budgets.** Each legal-data source has its own local rate
  budget, so one provider's lookups can no longer starve the others.

### Fixed

- **Research misrouting.** Legal-concept phrasings ("cases against piercing the
  veil") no longer route to the docket finder; statute questions containing
  "lawsuit against…" stay statutory; one failed search no longer abandons the
  remaining queries.
- **Statute text fidelity.** HTML entities decode (§ instead of `&#167;`), page
  chrome is stripped from fetched sections, and empty fetches can never be marked
  citable.
- **Esc closes the source panel** no matter where keyboard focus sits, and
  footer-less sheets close on Return again.

## [1.8.0] - 2026-06-28

Legal research gets a source-grounded authority stack, stricter guardrails, and safer
credential handling.

### Added

- **Primary-law-first legal research.** Federal and state legal questions now plan
  source retrieval around the governing authority hierarchy before asking the model to
  answer. Statutory/regulatory questions fetch primary law first, then layer controlling
  and persuasive cases behind it.
- **Federal statutory and regulatory sources.** Legal research can retrieve U.S. Code
  and C.F.R. material from Open Legal Codes, eCFR, and govinfo, with provider metadata,
  currency notes, and citable source packets.
- **Legal-development tracking.** Research answers can include a separate, non-citable
  tracking section for recent or pending legislation and regulations from Federal
  Register, Regulations.gov, OpenStates, and LegiScan providers.
- **API-key readiness checks.** Settings and diagnostics now verify legal-data provider
  keys and surface missing, invalid, and unreachable states without leaking secrets.

### Changed

- **Global and matter chats share the same legal-research structure.** Both chat types
  use the same source-planning, primary-law gating, authority ranking, source-packet
  persistence, and citation-verification behavior; only the target source scope differs.
- **Legal answers are more conservative when authority is missing.** If a limitations,
  deadline, filing, statutory, or regulatory question requires primary law and no citable
  provision is available, the app now blocks the answer instead of letting case snippets
  or package-level locator hits stand in for the governing text.
- **Federal-court authority routing uses the jurisdiction catalog.** Court IDs are no
  longer recognized through a small hand-written allowlist, so district and appellate
  federal issues follow the federal authority hierarchy consistently.
- **Network logging redacts sensitive query parameters.** Provider keys and other
  credentials are stripped from diagnostic output before logging.

### Fixed

- **Locator-only govinfo hits no longer satisfy the primary-law gate.** govinfo package
  results are retained as notes until section text is retrieved, but they are excluded
  from citable `[A#]` packets.
- **Statutory citation verification recognizes equivalent source labels.** Citations
  like `33 U.S.C. § 913` now match provider labels such as `United States Code, Title 33
  § 913`, avoiding false unsupported-citation warnings when the retrieved text is
  actually the cited provision.
- **Recent-development results are relevance-filtered.** Off-topic Federal Register and
  Regulations.gov items no longer appear just because they share generic words like
  "base" or "federal"; acronym queries such as "DBA" still match "Defense Base Act."

## [1.7.0] - 2026-06-26

A broad app overhaul: draft a Notice of Appearance from within a matter's chat and
download it as a Word document, discover chat commands from a slash palette, record
bar admissions across multiple jurisdictions and have the right one printed to match
the filing's court, attach documents inline to ScratchPad notes with `#Note`
non-billable exclusion, search chats and notes by tag or content, and a redesigned
Models tab with custom-repo and parallel/resumable downloads. First launch now offers
a guided model-download flow, and Diagnostics keeps itself current.

### Added

- **Draft a Notice of Appearance from a matter's chat.** A new **Draft** button in a
  matter's chat toolbar opens a sheet where you enter the caption parties, the client
  you represent, and the service recipients (opposing counsel), then generates a
  downloadable `.docx` Notice of Appearance with Reveal in Finder / Open / Save-a-copy
  actions and any review-flag notes. Before anything renders, every required slot is
  validated — a caption with two or more complete parties and a court header, the party
  represented, a full firm signature block, and service recipients with valid e-mail
  addresses — and missing items are reported as a specific list (e.g. "still needed:
  service recipients, caption party 1 designation") so blanks never leak into a filing.
- **Notice of Appearance drafting is refused outside Florida.** Generating one for a
  non-Florida matter now fails with a clear message ("wired for Florida filings
  only…") rather than producing a filing with the wrong service rules.
- **A discoverable slash-command palette in the chat composer.** Typing `/` at the
  start of a message pops up a menu of every available command — `/legal`, `/research`,
  `/draft`, `/critique`, `/verify`, `/ask` — each with a one-line description; pick one
  to fill the composer. The menu filters as you type the command token and dismisses on
  a space. The placeholder now reads "Message — type / for commands".
- **Record bar admissions across jurisdictions.** The firm profile replaces the single
  "Florida Bar number" field with a **Bar admissions** list: add multiple jurisdiction +
  bar-number rows (the 50 states plus D.C.), mark one as primary with a star, and remove
  rows.
- **The correct bar admission is printed to match the filing's court.** When you draft a
  court filing, the app prints the admission whose jurisdiction matches the court (a
  Texas court prints your Texas Bar No.), falling back to your primary admission, and
  the signature-block label is now jurisdiction-specific ("Florida Bar No.", "D.C. Bar
  No.", …) instead of always "Florida Bar No."
- **`#Note` marks a ScratchPad entry non-billable.** Tagging an entry `#Note`
  (case-insensitive) excludes it — and any files attached to it — from the billing/time
  draft. The exclusion is deterministic: `#Note` entries are filtered out before the
  prompt is built, so their text and attached filenames never reach the billing model
  and the time math stays exact. A day of only `#Note` entries yields the same "nothing
  to bill" result as a blank day.
- **`#Note` is visible while you write and after.** Composing a `#Note` tag raises a
  near-composer alert ("Tagged #Note — this won't be counted toward billing or time…");
  saved entries carry a "Non-billable" badge, and the `#Note` tag is tinted orange (vs.
  gold for ordinary `#tags`). The billing-draft review banner reports what was left out
  ("1 note tagged #Note excluded; 1 attached file tied to excluded notes excluded from
  billing.").
- **Search chats and ScratchPad notes by tag or content.** The chat search box (now
  "Search chats or #tags") matches chats by message body as well as title; a leading `#`
  is an exact tag match (`#urgent` does not match `#urgentish`). A `#tag` query surfaces
  a grouped **Tag matches** discovery section spanning ScratchPad notes and cross-matter
  chats, with snippets centered on the match. In a matter scope, search is bounded to
  that matter's chats and `@`-mentioning notes; globally it spans every matter for
  cross-matter discovery. In-scope chats open in place; cross-matter chats and notes
  appear as discovery-only.
- **First-run onboarding for downloading models.** On a fresh launch with no models
  installed, a skippable Welcome screen lets you pick and start downloading a reasoning
  model, a drafting model, and an embedding model; downloads continue in the background
  after you enter the app, and the screen never reappears once completed or skipped.
- **Custom Hugging Face repo IDs.** Both task (text) and embedding model setup now
  accept a pasted custom repo ID alongside the curated catalog. A custom embedding
  model's dimension is discovered automatically when it verifies, so semantic search and
  the dimension guard work on later loads.

### Changed

- **ScratchPad files are recorded inline with their note.** A file attached in the
  composer is now saved with the note on submit and renders as a chip directly beneath
  that entry, inheriting the note's own `@matter` instead of landing in a detached
  day-level attachment bar. Dropping a file on a note attaches it there; dropping a file
  on the timeline creates a minimal note that carries it (e.g. "Attached evidence.txt")
  so a document is never orphaned. The old standalone attachment bar now shows only
  legacy/unfiled attachments from older days.
- **Settings consolidated.** The separate "Assistant Profile" and "Firm identity for
  drafting" sections are now one **Profile & Firm Identity** section, so who-you-are
  details and the signature-block/letterhead fields live together. Single-line fields
  show a caption label above a clearly bordered, left-aligned box (instead of
  right-aligned, value-like form rows), and multi-line prose fields (global billing
  instructions, secondary e-mails, other instructions, writing style) start around three
  lines and grow as you type.
- **Legacy single bar numbers migrate automatically.** A saved profile with the old
  single bar number becomes a structured admission on load (jurisdiction inferred from
  your office state), so it appears in the new editor and resolves a proper signature
  label; the hidden legacy field is then cleared.
- **Document Intelligence moved to the Models tab.** Its setup/readiness panel no longer
  lives in Settings; it now sits at the bottom of the Models tab, directly under the
  model sections it depends on.
- **The Models tab was redesigned.** It is now a scroll of whitespace-separated sections
  with larger headers and body fonts and muted gray step numbers (instead of bold accent
  badges). Per-model rows use a play icon to load and a hover-revealed trash icon to
  delete (replacing swipe-to-delete and the bordered "Load" label). Task-model setup
  folds load-and-verify into a single "Load Runtime Model" action that loads the
  recommended startup model — assigned models load automatically when a task runs — and
  embedding models now auto-verify on download and on selection (the manual "Test Load"
  step is gone), showing verifying/ready/failed status inline.
- **Downloads run in parallel and resume.** Model downloads now fetch a repo's files
  concurrently (up to four at a time) and skip files already on disk, so multi-file
  models land faster and an interrupted download resumes where it left off; cancelling or
  failing no longer deletes partial progress. Progress now shows how many of a model's
  files have finished downloading.
- **Diagnostics refreshes itself.** The tab now updates runtime status automatically
  every 10 seconds while open; the manual header and its Refresh button are gone.
- **Stricter pre-file gate for court filings.** Filing is now blocked not just on missing
  sections but on incomplete ones: a caption needs a court header, two or more complete
  parties, and a case number; the signature block needs firm, attorney, attorneys, and a
  primary e-mail; and the certificate of service needs at least one complete recipient
  (name, role, e-mail).

### Removed

- **The `-hq` slash variants are gone.** `/legal-hq`, `/research-hq`, and their
  `-high-quality` aliases are no longer recognized. Each route now always runs on the
  model assigned to that task — there is no per-message quality tier to pick.
- **The Models-tab download toolbar buttons are gone.** "Download Model" and "Add Local
  Folder" no longer appear in the top bar; downloading is done inline within the
  task-model and embedding sections (including the new custom-repo field).

### Fixed

- **Deleting a ScratchPad note removes its inline attachments.** The files attached to a
  note are now deleted with it, instead of being detached and left behind as orphaned
  attachment records.

## [1.6.0] - 2026-06-25

Document drafting comes to chat, plus model-setup quality-of-life: a one-model
install is ready to use immediately, picking a model loads it, and the embedding
model catalog gains stronger multilingual and instruction-tuned options.

### Added

- **Generate court filings and demand letters from a matter.** The on-device
  drafting engine (shipped in 1.5.2) is now wired into the app: it resolves a
  matter's caption and your firm identity into a Word document — a Notice of
  Appearance, Motion to Dismiss, or Demand Letter — rendered locally to the
  firm's formatting, with no cloud and no Word/Office dependency. Every citation
  is verified or left as a visible `[cite]` placeholder, and every recited fact
  traces back to the matter; the draft never invents authority or identity.
- **Firm identity for drafting in Settings.** A new Assistant Profile section
  collects the signature-block and letterhead fields (bar number, office
  address, service e-mails) used to populate filings. If they're blank, drafting
  asks you to complete them rather than guessing.
- **More embedding models.** Document Intelligence now offers Qwen3-Embedding
  0.6B and 8B (instruction-tuned, strong multilingual + code retrieval) and
  BGE-M3 (multilingual, long-context) alongside the existing BGE and Nomic
  options.

### Changed

- **One model is ready to use immediately.** When exactly one model is
  installed, it's automatically the default for every role — legal reasoning,
  high-quality reasoning, drafting, and critique — so a single-model setup works
  without assigning each role by hand.
- **Selecting a model loads it.** Choosing a model for a role in Settings now
  loads it into the runtime automatically, so there's no separate trip to the
  Models tab to press Load (an already-loaded model is never swapped out
  mid-use).

## [1.5.2] - 2026-06-25

Foundational document-drafting engine — the local, fidelity-locked layer that
generates court filings and demand letters as Word documents. No user-facing UI
yet; this release lands and verifies the engine the drafting features build on.

### Added

- **On-device document drafting engine.** Three new packages — `SupraDraftingCore`
  (shared drafting types), `SupraExports` (the Word/OOXML renderer), and
  `SupraDrafting` (the slot/generation/verification pipeline) — implement the first
  drafting vertical slice end to end: resolve a matter's facts and the firm's
  identity into a document, verify it, and render a `.docx`. Everything runs
  locally — no cloud, no Word/Office dependency.
- **Three drafting kinds.** A Notice of Appearance (deterministic slot-fill, no
  model needed), a Motion to Dismiss (section-by-section argument with the Florida
  house motion structure), and a Demand Letter (firm-letterhead business letter).
- **Court-fidelity Word output.** The renderer reproduces the firm's locked
  formatting — the two-column caption, hanging-indent point headings, the `/s/`
  signature block, the certificate of service, and page-1 number suppression —
  validated against round-tripped Word goldens.

### Security

- **Authority firewall — the model never invents a citation.** Every citation in a
  generated draft is either backed by a real retrieved authority (CourtListener) or
  is left as a visible `[cite]` placeholder; an unverified citation is stripped, not
  guessed.
- **Fact firewall — every recited fact traces to the matter.** Asserted facts must
  carry matter provenance; an untraced fact is replaced with a visible `[fact?]`
  flag rather than passed through. Firm-identity (name, bar number, address, e-mail)
  is slot-only and never baked into a template, so one firm's details can't leak
  into another's draft.
- **Court formatting floor enforced.** Sub-12-point fonts or sub-1-inch margins are
  rejected before render (Fla. R. Jud. Admin. 2.520(a)).

## [1.5.1] - 2026-06-23

Matter-chat grounding so the assistant answers from your actual documents,
billing-narrative and export refinements, and Settings quality-of-life fixes.

### Added

- **Matter chat answers from your documents.** Asking a matter's Chat about its
  own files — "list the cases in the Research folder," "what do my documents say
  about indemnification" — now answers from the matter's actual document library:
  a deterministic folder/document inventory for "what's in folder X" (including
  sub-folders), and cited, retrieval-grounded answers for content questions.
  General legal questions still use the existing research routes.
- **Choose how billing narratives end.** A firm-wide narrative-punctuation setting
  (as written / no terminal period / end with a semicolon), plus a per-matter
  override on the matter's Billing tab, applied deterministically at export.
- **Copy weekly billing table.** A new export that copies a ready-to-paste,
  five-column table — Date · Client / Matter · Matter No. · Narrative · Time.
- **Starter billing instructions.** Fresh installs begin with a sensible default
  set of billing-narrative guidelines, editable in Settings.

### Changed

- **Opens on your best reasoning model.** The app now loads the strongest available
  reasoning model on launch instead of the lighter drafting/instruct model.
- **Settings autosave.** The Assistant Profile now saves as you type — the "Save
  Profile" button is gone, so guidance can't be lost by forgetting to save.
- **Multi-line Settings fields accept line breaks.** Style notes, citation notes,
  additional instructions, and the global billing instructions now take the Return
  key as a newline, and the profile preview is shown at a readable size.

### Fixed

- **No more invented document lists or fabricated actions.** Matter chat no longer
  answers questions about your files from the model's memory (it reads the real
  library), and the assistant won't claim to have searched, reviewed a folder, or
  taken any other action it cannot actually perform.

## [1.5.0] - 2026-06-22

Milestone 4 — **ScratchPad**: turn a day's running notes into defensible, e-billable
time entries, entirely on-device. Plus chat-input refinements across the app.

### Added

- **ScratchPad daily notes → billing drafts.** A new top-level section keeps one
  timestamped daily note per date. Tag work with `@matter` and `#issue`, attach
  work product / email / filings as evidence, then generate a reviewable billing
  draft — a grouped, editable table of Client · Matter · Narrative · Time with
  UTBMS task/activity codes and per-day reconciliation (totals, gaps, low-confidence
  flags). Nothing is billed automatically; every suggested time cites its evidence.
- **Export to LEDES 1998B, CSV, and clipboard.** Fee lines export to the 24-field
  LEDES 1998B e-billing format, a review CSV, or tab-separated text. A pre-export
  validator blocks a LEDES file with missing required fields (timekeeper rate,
  client ID, firm matter ID, or an unresolved task code) and explains what to fix.
- **ScratchPad / Billing settings.** Global billing instructions, an auto-timestamp
  toggle, a time-inference sensitivity slider, a rounding increment, a UTBMS
  auto-coding toggle, and the timekeeper + firm identity that populate fee lines.
- **Per-matter Billing tab.** A matter-specific override and UTBMS code set, plus
  client billing-guideline document uploads — all layered on top of the global
  instructions when a draft is generated. The matter's LEDES e-billing identifiers
  (Client ID, Client matter ID, Firm matter ID) are now editable in the matter
  details and shown here, so LEDES export can actually be unblocked.
- **Reviewable, fixable billing lines.** Each draft line can be edited, **reassigned
  to a different matter**, or **deleted**, and task/activity codes are chosen from a
  real **UTBMS code picker** — so every validator blocker has a fix in the UI.
- **Calendar history in ScratchPad.** Jump to any past day from a calendar
  (defaulting to today); browsing never creates empty days.
- **Attachments in matter chats.** The chat composer's attach button now works in a
  matter's Chat tab too. Attachments are read into that conversation only — never
  saved to the matter's document library.

### Changed

- **Refined chat composer.** A single rounded input with a leading attach button and
  a circular send control that floats over the conversation (no bracketing dividers),
  shared by the global Chats screen and in-matter chats. The model, jurisdiction, and
  precision controls remain just beneath it.

### Security

- ScratchPad and billing run fully on-device: extraction, classification, and
  generation are local (no network egress in any ScratchPad path); attachment and
  note content never leave the machine.
- **CSV/clipboard exports are hardened against spreadsheet formula injection** —
  a cell beginning with `= + - @` is neutralized so it imports as literal text.
- **Locked days are enforced at the data layer**, not just the UI: a finalized day
  rejects entry/attachment edits and new billing drafts even via a stale view.

### Fixed

- **UTBMS codes and work dates are validated** before a draft is saved: an
  out-of-set task/activity code is dropped (and flagged for a manual pick) and an
  impossible or future work date falls back to the day's date — so a malformed code
  or date can't reach a LEDES file.
- **Billing audit trail**: draft generation and export are recorded in the relevant
  matters' audit logs, day lock/reopen is audited, and an exported draft is marked
  exported.

## [1.4.1] - 2026-06-22

### Fixed

- **Model-picker downloads no longer fail (HTTP 401) for the higher-precision options.**
  The 6/8-bit repo IDs added in 1.4.0 didn't exist under those names. Corrected against
  the current Hugging Face listings: the Qwen3-30B Thinking 6/8-bit MLX quants live at
  `lmstudio-community/Qwen3-30B-A3B-Thinking-2507-MLX-6bit` / `-MLX-8bit`, and the
  DeepSeek-R1-Distill-Qwen-32B 8-bit is `mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit`.
  (Every other catalog entry — the 4-bit role models, the DeepSeek 6-bit, and the
  general models — was verified against the live site and is unchanged.)

## [1.4.0] - 2026-06-22

A legal-quality and safety-hardening release: the local models are tuned and scaffolded
for legal research, document analysis, and drafting, and an adversarial audit of every
model-call path hardened the citation/grounding guarantees.

### Changed

- **Your assistant profile now shapes authoritative legal answers.** The composed
  "soul document" (citation style, jurisdiction, voice) was silently dropped on
  legal chat routes, structured outputs, and document Q&A — it only reached generic
  chat. It is now layered *over* each task's system prompt (the grounding/structure
  contract still leads), so legal answers honor your configured citation form and
  jurisdiction. The machine-parsed research query-planner and fact chronology stay
  profile-free so their required structure isn't perturbed.
- **Verification and grounded document Q&A/chronology now decode deterministically**
  (greedy: temperature 0, no nucleus/top-k truncation), mirroring the classifier.
  Citation-checking and document extraction are now reproducible run-to-run and lose
  the marginal-sampling fabrication risk; the creative sampling stays on the case-law
  research-memo path only.
- **The legal source packet is capped and length-budgeted** (top-ranked authorities,
  per-authority text budget) so a large CourtListener result set can't overflow the
  context window and silently evict the binding authorities or the "answer only from
  the packet" instructions. Dropped authorities are noted in the packet.
- **Context-window budget guard.** The runtime caps its KV cache at the context
  window, so an oversized prompt previously rotated the *front* (system grounding +
  top sources) out silently mid-generation. The runtime now measures the assembled
  prompt and drops the oldest conversation turns until it fits — protecting the
  system prompt, the current question, and the evidence — and surfaces a note when it
  had to (instead of quietly losing context).
- **Citations now use an explicit `[A#]` contract.** Free-form legal answers are
  instructed to end each proposition with its source-packet label (e.g. `[A1]`), use
  only labels that exist, and write `[NEEDS AUTHORITY]` otherwise. The citation
  verifier recognizes in-range `[A#]` labels as citations and flags fabricated/out-of-
  range ones — closing the "unrecognized citation format slips through" gap.
- **Repetition penalty for long-form generation** (drafting / legal research /
  critique presets) curbs the loop/restate degeneration 4-bit local models show on
  multi-thousand-token drafts. Greedy extraction/verification stays penalty-free.
- **Better semantic recall on the default embedding model.** Retrieval queries now
  carry the BGE/mxbai instruction prefix these models were trained with (passages are
  embedded raw, matching the existing index — no re-indexing needed). Models without
  an asymmetric prompt are unchanged.
- **Structured outputs auto-complete their sections.** A generated issue-spotting /
  rule-synthesis / argument-outline / drafting-skeleton output now runs up to two
  automatic structure-repair passes when required sections are missing (a pass that
  doesn't reduce the missing set is discarded, so it never pollutes the version
  history), and multi-section outputs get a larger output-token budget so a long memo
  isn't truncated mid-structure. "Complete in one action" is now the common case
  instead of a manual repair step.
- **Multi-turn legal follow-ups.** The one-shot legal answer/research and critique
  flows previously sent no conversation history, so a follow-up like "now narrow that
  to the 9th Circuit" or "apply that rule to my facts" lost context. They now replay
  the prior turns (token-budgeted; the runtime's context guard trims them if the
  packet + question leave no room). (Document Q&A remains single-shot by design — it
  has no conversation thread.)
- **Legal answers self-repair before quarantine.** When automated citation
  verification finds a hard failure (a fabricated/unsupported citation or quote, or a
  jurisdiction mismatch), the model now gets one corrective pass — re-prompted with the
  specific issues and a packet-only-citation rule — and the answer is re-verified
  before falling back to the UNVERIFIED-DRAFT banner. Only runs on failure, so clean
  answers keep their single round-trip; the revision is kept only if it's at least as
  clean. The verifier also now counts a valid `[A#]` packet label as a supported
  citation, so a correctly label-cited answer is no longer over-flagged.
- **Full opinion text for the top authorities.** CourtListener search returns only a
  short snippet, so the model previously reasoned and quoted from a sentence or two.
  The top 4 ranked authorities are now hydrated with their full opinion body (best-
  effort — a fetch failure keeps the snippet and never blocks the answer), so the
  model gets real opinion prose and the citation verifier checks quotes against the
  full text instead of false-flagging a genuine quote absent from the snippet.
- **Specialized legal prompts.** `/legal` (direct IRAC answer, bottom-line-first) and
  `/research` (exhaustive memo) no longer share one prompt. Both now carry a
  jurisdiction-binding directive (only controlling authority for the stated
  jurisdiction is binding; never call an out-of-jurisdiction case controlling), the
  `[A#]` citation contract, and holding-vs-dictum / date-qualification discipline; the
  memo prompt adds citator-treatment flagging. The base system prompt (structured
  outputs, document Q&A, general chat) gains the same uncertainty-calibration and
  good-law/citator discipline. The legal-answer prompt now includes a short worked
  exemplar so local models follow the citation + hedging form reliably.
- **LLM reranking for document Q&A.** Auto-source retrieval now pulls a wider
  candidate pool (30) and asks the loaded model to rank it, packing the most relevant
  ~10 passages (re-labeled in the new order) into the answer. Best-effort: if the
  model errors or returns too few labels, it falls back to the retrieval order, so a
  rerank failure never blocks an answer. Hand-picked (guided) sources are left in the
  user's order.
- **Sharper document retrieval.** Hybrid search now fuses keyword (FTS) and semantic
  candidates with Reciprocal Rank Fusion instead of a length-sensitive linear blend —
  scale-robust ranking that rewards chunks strong in both lists. Each selected chunk
  is also expanded with its immediate same-part neighbors before grounding, so an
  answer that straddles a chunk boundary (a clause split mid-section) stays
  citable instead of triggering a "sources do not support" refusal. Each source
  header now also carries the document's type (from the classifier) and date, so the
  model can prefer the operative/executed document over a draft and weigh recency
  when sources conflict.
- **Chat attachments are labeled, citable sources.** Files dragged into chat are now
  given `[S1]`/`[S2]` labels with an instruction to cite attachment-backed statements
  to them (previously unlabeled fenced text with no citation expectation), extending
  the cite-your-source discipline to the inline-document workflow.
- **Matter Chat is now a real chat store.** The Chat tab inside a matter gets the
  same searchable history sidebar as Global Chats — start new chats and reopen old
  ones (rename / delete too), instead of the cramped inline strip. A blank matter
  chat shows the same rotating example-prompt starters, and the conversation now
  fills the pane (the redundant header bar is gone; the sidebar owns New Chat).
- **Documents tab updates live during processing.** Each document's status badge
  and classifier category chips now appear as it finishes, without leaving and
  re-entering the tab (the controller reloads on each processing phase and polls
  while a job for the matter is active).

### Added

- **Higher-precision model options for citation-critical roles.** The catalog now
  offers 6-bit and 8-bit builds of the legal-reasoning (Qwen3-30B Thinking) and
  critique (DeepSeek-R1-Distill-32B) models. 4-bit quantization disproportionately
  degrades the long-tail factual recall that citations / holdings / dates depend on;
  the higher-precision builds cut those errors for users with RAM headroom (each
  download notes its RAM needs; assign them to the role in the Models tab).
- **Documents: move a document between folders** — each document row has a folder
  menu to move it into any folder, between folders, or back to All Documents
  (the data layer already supported this; it just wasn't surfaced).
- **Imported research is filed into a "Research" folder** (auto-created per matter)
  instead of being dropped into All Documents.
- **Models: delete a registered model** (swipe / context menu in the Models tab,
  with confirmation). App-downloaded models have their files removed from disk to
  reclaim space; user-registered folders are only unregistered (the folder is left
  in place). Deleting unloads the model if it's loaded and clears any task-role
  assignments so no "Missing model" entry is left behind.

### Fixed

- **The chat generation controls now affect routed sends.** The Precise/temperature/
  max-output picker was silently ignored for `/legal`, `/research`, and `/draft` (they
  used the route preset and dropped the user's selection). Non-legal routes (drafting,
  general chat) now honor the user's temperature; the legal authority routes keep their
  tuned conservative temperature so a looser global default can't loosen a
  citation-bound answer. The output budget is extend-only so the general default can't
  truncate a research memo's tuned budget.
- **Launch splash no longer lets the window behind it show through.** The shell's
  `NavigationSplitView` sidebar is backed by an AppKit vibrancy view that ignores
  SwiftUI layer opacity, so the old "overlay the shell at opacity 0" approach let
  the sidebar/chrome bleed through the splash. The shell is now swapped in only
  after the splash dismisses (the cross-fade is preserved), so there's no vibrancy
  to leak; the launch window size is pinned so the swap doesn't resize the window.

### Security

- **Citation verification hardened against fabricated cites (adversarial audit).** The
  verifier now validates `[A#]` labels against *exactly* the source packet the model was
  shown (not the larger retrieved/reconstructed set), so a label pointing at an authority
  the model never saw is flagged; and a labeled proposition is content-grounded against
  the cited opinion's full text, so a fabricated paraphrased holding under a valid label
  is caught — neither can read as verified law. Structured-output repair is monotonic
  (a repair can't strip the unverified-citation banner) and preserve-or-improve (a worse
  pass can't replace a good version).
- **Grounded answers refuse instead of silently ungrounding.** When the sources + the
  question exceed the model's context window, document Q&A / research / chronology /
  structured-output flows now refuse (asking you to narrow scope or use a larger-context
  model) rather than return a confident answer whose "answer only from the sources"
  contract was evicted from the context.
- **The CourtListener API token is gated to the API hosts in code** (never the public
  storage CDN used for opinion PDFs) — defense-in-depth for the existing token-handling
  invariant, with the request failing loudly if ever misdirected.

## [1.3.4] - 2026-06-21

### Added

- **Authorities: delete a saved authority** (swipe / context menu / detail button),
  and **import your own research** (PDF/Word/RTF/text) through the matter document
  pipeline so the model can RAG over it via Ask Documents.
- **Opinion text + HTML/PDF in the Authority and Research detail.** A longer
  50–100-word excerpt (windowed on the search snippet), an in-app **opinion HTML
  viewer** (JavaScript off; remote subresources blocked) with HTML download, and a
  **Download PDF** action with an in-app **PDF preview** between Status and Notes.

### Changed

- Research results/citations are sanitized of CourtListener highlight markup
  (`<mark>`) and HTML entities; the preferred citation is reporter-ranked (official
  U.S. Reports / S. Ct. / L. Ed. over regional/specialty reporters).
- The research query-planner prompt asks for diverse, operator-aware queries.
- Authority **use status** displays human-readable labels (e.g. "Retrieved from
  CourtListener") instead of raw `snake_case` tokens.

### Fixed

- Document completion notifications now carry the app's logo (the app icon is
  attached to the local notification).
- "Download HTML…" on the opinion viewer now works (it used an app-modal save panel
  that never appeared from within a sheet; now uses `.fileExporter`).

### Security

- Opinion PDF downloads use CourtListener's public storage CDN
  (`storage.courtlistener.com`) only, token-free, on explicit user action; the
  allow-list and SECURITY.md are updated accordingly.

## [1.3.3] - 2026-06-21

### Added

- **Global Chat history sidebar** — an interior, title-searchable chat list with
  rename, delete (confirmed), and move-to-matter actions for chats that turn out to
  be matter-specific. Chats are auto-titled from their first message.
- **Example prompts** — a blank Global Chat opens to four randomized legal prompt
  starters (drawn from a 36-prompt set) that fill the composer for editing; the app
  opens to a fresh chat on launch.
- A 1.3.2 adversarial review ([`Docs/Review-1.3.2.md`](Docs/Review-1.3.2.md)) with
  module findings, feature blockers, and product-page screenshot recommendations.

### Changed

- Website now serves from the apex custom domain **https://supralegal.ai/**.
- Product-page copy reflects the current app flow (local model role assignment,
  global-chat history); download fallback points at v1.3.3.

### Fixed

- Static-export `basePath` left over from project-site hosting baked `/Supra-AI/`
  into every asset URL, so the site rendered unstyled at the apex root. Removed the
  basePath and added `website/public/CNAME` so the custom domain persists across
  deploys.
- Chat delete/move are blocked while a chat is still generating and surface store
  errors instead of swallowing them; the move audit event is recorded only after the
  store confirms the move.

## [1.3.2] - 2026-06-20

### Added

- **Automatic document classification** — imported documents are classified into
  legal categories (metadata-only suggestions).

## [1.3.1] - 2026-06-20

### Changed

- Chat rendering overhaul — assistant answers render as Markdown.
- Configurable **citation styles** (Bluebook, Indigo Book, MLA, and per-state
  guidance) in Settings.
- Guided model setup in the Models tab.

### Fixed

- Document import fix.

## [1.3.0] - 2026-06-20

### Added

- **Conversation context** — prior turns are replayed so the model can answer
  follow-ups in context.
- **Jurisdiction-bound research** in Global Chat (auto-detected or explicitly
  selected, with optional related-federal courts).
- Marketing **website** and the GitHub Pages deploy workflow.

### Changed

- High-quality legal reasoning now defaults to DeepSeek-R1-Distill-Qwen-32B.
- Deterministic per-route model selection; chat UI polish.

## [1.2.0] - 2026-06-19

### Added

- **In-app software update check** (opt-in; queries GitHub Releases only).
- Developer ID signing + a notarized release pipeline ([`Scripts/release.sh`](Scripts/release.sh));
  the updater prefers the notarized `.dmg` over the `.zip`.

## [1.1.0] - 2026-06-19

### Added

- Downloadable model catalog (the plan's role models) and per-chat-route model
  recommendations based on what's already downloaded.

## [1.0.0] - 2026-06-19

First public release. Supra AI is a local, MLX-powered macOS research and drafting
assistant for legal work — on-device generation, source-grounded legal research, and
matter document intelligence, with citation verification built in.

v1.0.0 is the sum of three planned milestones (M1 → M2 → M3). Each was specified
up front in [`Docs/Milestones/`](Docs/Milestones/) and delivered against explicit
acceptance criteria and a validation suite.

### Added — Milestone 1: Local MLX runtime vertical slice

- Sandboxed XPC runtime service (`SupraRuntimeService`) that loads and runs local
  MLX models, with single-active-generation enforcement, streamed generation events,
  cancellation, and metrics.
- Cross-process model-file access via security-scoped bookmarks minted by the app and
  resolved inside the sandboxed service (see
  [`Docs/Architecture/RuntimeFileAccess.md`](Docs/Architecture/RuntimeFileAccess.md)).
- Local Swift package graph: `SupraCore`, `SupraStore` (GRDB persistence + migrations),
  `SupraRuntimeInterface`, `SupraRuntimeClient`, `SupraSessions`, `SupraDiagnostics`.
- Global chat with persisted send/stream/cancel/fail flow.
- Model library: register local MLX model folders and load the active model.
- Bundled default system prompt wired into every generation.
- Diagnostics + a deterministic validation suite with persisted run history.

### Added — Milestone 2: Legal utility layer

- **Matter workspaces** — organize chat, research, authorities, outputs, and an audit
  trail per matter, with jurisdiction and party-perspective metadata.
- **Source-grounded legal research** via CourtListener REST API v4: research-session
  planning, locally generated and user-approved search queries, review-before-save
  results, and a per-matter authority library with enforced use-status transitions.
- **Default-deny network policy** — only CourtListener is allowlisted; every request
  (approved or blocked) is logged; local rate-limit tracking; CourtListener token stored
  only in the Keychain.
- **Structured legal outputs** — issue spotting, research plan, case-result summary,
  rule synthesis, argument outline, drafting skeleton — with deterministic
  missing-section detection and version-preserving structure repair.
- New packages: `SupraNetworking` (Keychain, network policy, authorized HTTP client,
  rate limiting) and `SupraResearch` (CourtListener client, DTOs, citation handling).
- UI polish pass: sidebar restructure, status badges, empty states, right-side
  inspectors, and a three-level warning hierarchy that blocks unsafe actions.

### Added — Milestone 3: Matter document intelligence

- **Document import** — batch import of nested folders and mixed formats (PDF, DOCX/DOC,
  XLSX, RTF, HTML, XML, Markdown, text, EML with attachments as child documents), with
  content-addressed managed storage, sha256 dedup, continue-on-failure, and a full
  per-file import report.
- **On-device OCR** (Vision) for scanned PDFs and images, with confidence summaries that
  surface in cited answers, and editable extracted text that triggers re-indexing.
- **Hybrid retrieval** — deterministic chunking, SQLite FTS5 full-text search, and local
  semantic search via on-device embeddings (`MLXEmbedders`, default `BAAI/bge-base-en-v1.5`),
  with folder/tag/date filters, duplicate collapse, and scope-readiness gating.
- **Source-grounded Q&A** (auto-source and guided) and **fact chronologies**
  (table/narrative) — every factual claim carries inline citations and a source appendix;
  post-generation citation checks flag unresolved or unsupported claims as needing review.
- **In-app source preview** — citation links open the cited document at the page/cell/chunk
  with best-effort highlighting and a text fallback that never fails silently.
- **Exports** to PDF, Markdown, DOCX, CSV, and XLSX with inline citations and a source
  appendix (raw source documents are never embedded).
- **Trash / restore / auto-purge** with instance-scoped soft delete and safe blob GC.
- New package: `SupraDocuments` (import, extraction, OCR, chunking, retrieval, grounding,
  export). Document processing runs as a single-active, FIFO, resumable job queue with
  pause-on-quit and ask-before-resume.
- M3 validation suite: a deterministic SwiftPM pipeline suite plus an app-run document
  intelligence suite exposed in Diagnostics.

### Added — Pre-publish hardening (v1.0.0)

- Assistant Profile ("soul document") settings.
- Global-chat file/image attachments (OCR-to-text).
- Collapsible reasoning view in chat (assistant answers rendered as Markdown).
- Chat status bar with model/processing state and generation settings.
- App icon, launch splash, and "See Supra" brand banner.
- CourtListener API-token status surfaced in Settings.
- Automatic load of the selected default model into the runtime on startup.

### Security & privacy

- Generation is fully on-device; only CourtListener research makes network calls, through
  an allow-listed, rate-limited, Keychain-authenticated client.
- Privileged query terms are redacted to stable fingerprints in logs and diagnostics by
  default.
- No telemetry. See [SECURITY.md](SECURITY.md) for the full model.

[Unreleased]: https://github.com/cadespivey/Supra-AI/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/cadespivey/Supra-AI/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/cadespivey/Supra-AI/compare/v1.3.4...v1.4.0
[1.3.4]: https://github.com/cadespivey/Supra-AI/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/cadespivey/Supra-AI/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/cadespivey/Supra-AI/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/cadespivey/Supra-AI/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/cadespivey/Supra-AI/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/cadespivey/Supra-AI/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/cadespivey/Supra-AI/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/cadespivey/Supra-AI/releases/tag/v1.0.0
