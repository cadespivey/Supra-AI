# Supra AI — Adversarial Review (v1.3.2)

_Prepared alongside the chat-history + example-prompts feature work on branch
`worktree-chat-history-suggestions`. Findings are cross-checked against the
shipped 1.3.2 code and the attached 1.3.2 UI screenshots (Global Chats, Models,
Diagnostics, Settings)._

> **How to read this:** Sections 1–2 are the alignment audit (website / README /
> docs vs. the actual app). Section 3 recommends product-page screenshots.
> Section 4 is the per-view / per-tab evaluation and the feature-blocker list.
> Section 5 lists what this branch already changed. Citations use `file:line`.

---

## 0. Executive summary

The app is at **1.3.2** with three feature-bearing releases since v1.0.0, but the
public materials lag badly:

- **Versions are stale everywhere outside the README body.** The website download
  fallback is pinned to **v1.2.0**; the root docs (CHANGELOG/ROADMAP/SECURITY/
  ARCHITECTURE) are frozen at the **v1.0.0** snapshot; `.env.example` contradicted
  the shipped HQ-reasoning default.
- **The marketing site undersells the real product.** Task-model routing, the
  DeepSeek-R1 HQ tier, jurisdiction-aware citation styles, automatic document
  classification (the 1.3.2 flagship), the Matter tab set, and the Assistant
  Profile personalization are all real and shipped — and all invisible on the
  site. Meanwhile the home page overstates network isolation.
- **The product page shows zero real screenshots** — only CSS mockups, one of
  which ("Still good law ✓") implies a citator capability the product explicitly
  disavows.
- **The single biggest UX defect is structural: "create but never delete."**
  Chats, registered models, research sessions, authorities, and outputs can all be
  created (several are auto-created) but **none could be deleted from the UI**.
  This branch fixes that for chats; the rest remain.

---

## 1. Alignment: version & accuracy mismatches

### 1.1 Version numbers that disagree

| Where | Says | Reality | Status |
|---|---|---|---|
| `website/lib/constants.ts:18-19` | `v1.2.0` download fallback | App is 1.3.2 (`project.pbxproj` `MARKETING_VERSION = 1.3.2`) | **Fixed in this branch → 1.3.2** |
| `.env.example:3` HQ reasoning | `Qwen3-30B-A3B-Thinking-2507-MLX-6bit` | Code default `DeepSeek-R1-Distill-Qwen-32B-MLX-4bit` (`ModelRouting.swift:79,112`); matches the Models screenshot | **Fixed in this branch** |
| `CHANGELOG.md` | ends at `[1.0.0]` | 1.1 / 1.2 / 1.3.0 / 1.3.1 / 1.3.2 shipped | Needs entries (untracked doc) |
| `ROADMAP.md` | "forward-looking from v1.0.0"; lists drafting as "future" | `/draft` + `drafting` role shipped (`ModelRouting.swift:10,50`) | Stale (untracked doc) |
| `SECURITY.md` supported-versions | only `1.0.x` | shipping `1.3.x` absent | Stale (untracked doc) |
| `ARCHITECTURE.md` | migrations "v001…v037 as of v1.0.0" | store has migrations through ~v039 | Stale (untracked doc) |

> Note: no git tag exists past **v1.2.0**, and the live `releases/latest` fetch in
> `DownloadButtons.tsx` will resolve to whatever is actually published. **Action
> for the maintainer:** cut and publish a `v1.3.2` GitHub release with the
> `.dmg`/`.zip` assets, otherwise the corrected constant still points at a tag the
> release page doesn't serve.

### 1.2 Website claims not backed by the code

1. **Network-isolation overstatement (home Hero).** `Hero.tsx:30-33` previously
   said "optional CourtListener research is **the only feature that uses the
   network**." The app also reaches Hugging Face for model/embedding downloads
   (`HuggingFaceClient.swift`) and GitHub for opt-in update checks
   (`UpdateChecker.swift`) — both correctly carved out on the privacy pages
   (`privacy-security/page.tsx`, `privacy/page.tsx`) and in `SECURITY.md`. The Hero
   contradicted the app's own security model. **Fixed in this branch** (now lists
   model downloads, optional research, and opt-in update checks).
2. **"Still good law ✓" mock implies a citator (product page).**
   `product/page.tsx:102-125` renders a 3-item "Verify citations" checklist with a
   "Still good law" check. The app does **not** do citator / good-law validation —
   it is an explicit non-goal (`ROADMAP.md`, `SECURITY.md`). Replace this mock with
   a real screenshot of the source-grounded answer + "needs review / do not rely"
   banner, which is the accurate depiction.
3. **CourtListener framed as "when enabled" / opt-in.** `enableCourtListener`
   defaults to **true** (`ModelRouting.swift:84`); it's gated by the token + the
   user pressing run, not by a disabled-by-default toggle. The framing oversells
   the default posture.

### 1.3 Real, shipped features missing from the site/README

These are demoable selling points with no marketing presence:

- **Task-model routing** — four roles (Legal reasoning, High-quality legal
  reasoning, Drafting, Critique), each independently assignable, plus a separate
  embedding model (`ModelRouting.swift:7-24`; visible in the Models screenshot).
- **DeepSeek-R1 HQ legal-reasoning tier** (`ModelRouting.swift:79,81`).
- **Jurisdiction-aware citation styles** — Bluebook / Indigo Book / MLA + per-state
  guidance (`CitationStyle.swift`; Settings → Citations).
- **Automatic document classification** — the 1.3.2 flagship, ~33 categories
  (`DocumentClassification.swift`).
- **Assistant Profile / Writing Style / Writing Samples** personalization
  (`SettingsView.swift`).
- **In-app software updater** (1.2.0) and **Diagnostics + validation suite**.

### 1.4 Stale / orphaned assets

- `website/public/screenshot.jpeg` and `website/public/images/supra-ai-hero-lockup.png`
  exist but are referenced nowhere — dead weight, and a missed opportunity given
  the product page uses CSS mockups instead of real captures.
- `website/app/layout.tsx` `metadataBase` still carries a "move to supralegal.ai"
  TODO — verify OG/canonical URLs against the live domain.

---

## 2. Legal-disclaimer & trust gaps

- The strong "not legal advice / verify every citation" disclaimer lives in the
  README, `/disclaimer`, and `/terms`, but the **home and product pages carry no
  inline disclaimer** — only a footer link. For a product that answers legal
  questions and auto-classifies legal documents, both high-traffic pages should
  carry at least a one-line "not legal advice; attorney verification required"
  notice.
- Mixed beta messaging: `DraftNotice` ("pre-launch draft") appears on the legal
  pages; the download page calls it "a public beta"; the home/product pages say
  neither. Pick one posture.

---

## 3. Recommended product-page screenshots (prioritized)

The product page currently renders hand-coded mockups and never shows real UI.
Replace/supplement with real captures, in this order.

> **Sanitize first.** Do not ship the raw 1.3.2 screenshots — they expose the
> local macOS username, full model file paths, saved-token state, and non-legal
> chat content. Capture from a demo matter with a generic user and redact paths
> before publishing.

**Tier 1 — core differentiators**
1. **Matter workspace with the tab bar visible** (Chat · Research · Authorities ·
   Outputs · Documents · Audit). _Caption:_ "Every matter keeps research,
   authorities, drafts, documents, and a full audit trail together."
2. **A source-grounded answer with citations + the "needs review" banner**
   (replaces the misleading "Still good law ✓" mock). _Caption:_ "Answers stay
   tied to the authority that supports them — anything unsupported is flagged, not
   hidden."
3. **Models tab** — registered models + task-model assignment + embedding model
   (the attached 1.3.2 screenshot is exactly this). _Caption:_ "Assign local
   models per task — legal reasoning, high-quality reasoning (DeepSeek-R1),
   drafting, critique — plus a local embedding model."

**Tier 2 — features competitors lack**
4. **Settings → Citations** (Bluebook/Indigo/MLA + state picker). _Caption:_
   "Citations follow your jurisdiction."
5. **Documents tab with auto-classified category chips.** _Caption:_ "Imports are
   automatically classified into legal categories."
6. **Settings → Assistant Profile / Writing Style / Writing Samples.** _Caption:_
   "Writes in your voice — without reusing your content."

**Tier 3 — trust & completeness**
7. **Global Chats with the new history sidebar + example prompts** (this branch).
8. **Settings → Document Intelligence checklist + Software Update + CourtListener
   token** (substantiates the corrected network-egress story).
9. **Diagnostics** (the attached screenshot) — a trust surface for a privacy app.

---

## 4. Per-view & per-tab evaluation (vs. 1.3.2 screenshots)

Severity: **BLOCKER** (stops a core task / unrecoverable) · **BUG** ·
**GAP** (missing affordance).

### 4.1 Module views

**Global Chats — `GlobalChatsView.swift`**
- _Works:_ markdown rendering, collapsible reasoning, copy-on-hover, status
  badges, robust generation lifecycle (double-send guard, interrupted fallback).
- **BLOCKER/GAP (FIXED in this branch):** history was reachable only via a tiny
  clock-icon dropdown — no search, no delete, no rename, no move-to-matter — and
  **every chat was titled "New Chat"** because nothing auto-titled them. The
  dropdown became a wall of identical entries. → This branch adds a searchable
  history sidebar with rename / delete / move-to-matter, plus first-message
  auto-titling.
- **BUG (FIXED):** auto-scroll only observed `messages.last?.content`, so it
  missed new turns with duplicate content and chat switches. → Now also observes
  `messages.count`.
- **GAP (remaining):** the attachment picker allows `.pdf`/`.data` but declines
  heavy docs only via a tooltip + transient error; either drop those UTTypes or
  show the limit inline.

**Models — `ModelsView.swift`**
- _Works:_ clear Registered / Task / Embedding 1-2-3 layout; "Load" always offered
  for a not-loaded startup model after relaunch; recommended-model one-tap assign.
- **BLOCKER:** no way to delete / unregister a model. `ModelLibrary` has
  `addModel` but no `removeModel`. A wrong/huge (~18 GB) download is permanent and
  leaves "Missing model" ghosts in the assignment pickers.
- **BUG/risk:** selecting an entry in the step-1 download picker starts a
  multi-GB download immediately on `onChange` — no confirm button.
- **BUG:** `addModelFolder` swallows bookmark/add failures (`try?`) with no
  feedback.

**Diagnostics — `DiagnosticsView.swift`**
- _Works:_ clean read-only status with a per-state "Next Step" hint (matches the
  attached screenshot) and Refresh.
- **BUG (confusing labels):** the screenshot shows "Runtime service unavailable"
  / "Model unloaded" while also listing a loaded model name — reads as
  contradictory. Distinguish "last-configured / registered model" from "currently
  loaded runtime model," and show the connection-state timestamp.
- **GAP:** it's a dead-end for action — "Next Step" tells you to go to Models or
  relaunch but offers no button to jump there, retry the connection, or restart
  the runtime. Recorded diagnostic events are never surfaced here.

**Settings — `SettingsView.swift`**
- _Works:_ composed-prompt preview; Document Intelligence checklist with gated
  "Mark Setup Complete"; source-aware footers (matches the attached screenshot).
- **BUG/UX:** profile fields bind live but persist only on "Save Profile";
  switching tabs without saving silently discards edits (no dirty indicator),
  while Generation Defaults and the embedding picker persist immediately —
  inconsistent.
- **BUG/surprise:** changing the embedding model silently invalidates a completed
  Document Intelligence setup (`DocumentIntelligenceSetupController.swift`); the
  cause isn't called out at the point of action.
- **BUG:** writing-sample import failures are fire-and-forget and may show nothing.

### 4.2 Matter tabs

**Chat (inline)** — reuses `GlobalChatsView` with `.inline`. Inherits the chat
issues; chips were all "New Chat" (now auto-titled by this branch). Attachments
and the jurisdiction/generation popovers are intentionally hidden inline.

**Research — `MatterResearchView` / planner / detail**
- _Works:_ strong empty-state CTA; manual-query entry without a model; run gated on
  a CourtListener token with blocking banners; per-query failures continue.
- **BLOCKER/GAP:** research sessions can't be deleted — and **global/matter legal
  chats silently auto-create "Chat research:" sessions** (`GlobalChatController.swift`
  `createAutomaticResearchSession`), so the tab fills with sessions the user never
  asked for and can't remove.
- **BUG:** the token banner doesn't re-check on `onAppear`, so adding a token in
  Settings may leave "Research Blocked" until something else republishes.

**Authorities — `MatterAuthoritiesView` / detail**
- _Works:_ good empty state; the use-status transition graph is enforced.
- **BLOCKER/GAP:** authorities can't be deleted/removed; a mistaken "Save as
  Authority" is permanent.
- **BUG:** citation/notes fields seed in a bare `.onAppear` not keyed to the
  authority id — reusing the detail view for another authority can show/overwrite
  the wrong record's text.
- **GAP:** no search/filter/sort on the list.

**Outputs — `MatterOutputsView` / detail**
- _Works:_ thorough new-output sheet (type, document grounding, indexed-readiness,
  route-model status); multi-format export; version picker + Repair Structure.
- **BLOCKER/GAP:** outputs can't be deleted — and **Document Q&A answers and
  chronologies auto-save here** (`DocumentQAController.swift`), so every question
  permanently adds an un-removable row.
- **BUG-ish:** "Generate" is disabled only on `routeModel == nil`, not on grounding
  readiness; you can press Generate on a not-fully-indexed selection and get a
  silent message instead of a disabled button.

**Documents — `MatterDocumentsView`**
- _Works:_ the richest tab — folders, import (picker + drag/drop), live job
  progress, classification chips, tags, search, trash with restore, in-app
  preview; import correctly gated on Document Intelligence setup.
- **BLOCKER/BUG:** on an empty matter, Q&A/Chronology report "still indexing
  (0/0 ready)" forever (`DocumentRetrievalService.swift` `isFullyReady` is false
  with zero docs). The Ask/Chronology buttons are enabled even when setup is
  incomplete. → Should special-case zero documents ("Import documents first") and
  disable the buttons until there are ready documents.
- **BUG/risk:** "Delete Folder" (context menu) is immediate with no confirmation,
  unlike matter deletion; permanent-delete in Trash also has no confirmation.
- **BUG:** typing a new search query without submitting leaves stale results shown
  against the new text.
- **GAP:** no folder rename, no move-document-between-folders.

**Audit (inline)**
- _Works:_ humanized event labels + timestamps; good empty state. (This branch adds
  a `chat_moved_to_matter` label.)
- **BUG:** the list is fetched inline in the view body with no `onAppear`, so it
  doesn't refresh while open when another tab records an event.
- **GAP:** no export, no date filter, recorded metadata JSON is never shown.

### 4.3 Cross-cutting

1. **"Create but never delete"** across models, chats, research, authorities,
   outputs — compounded by silent auto-creation. The biggest structural defect.
2. **Pervasive silent `try?`** on store writes — failures are invisible.
3. **State that doesn't refresh on `onAppear`** (Audit, research token banner,
   document search results).
4. **Inconsistent status-string presentation** (raw vs. prettified vs. capitalized)
   across Research / Authorities / Outputs.

---

## 5. What this branch changes

**Task 1 — global chat history sidebar**
- Interior, searchable chat-history sidebar in the global chat
  (`GlobalChatsView.swift`): search by title, select, **rename**, **delete** (with
  confirmation), and **move a chat into a matter** (records a `chat_moved_to_matter`
  audit event).
- New controller APIs (`GlobalChatController`): `renameChat`, `deleteChat`,
  `moveChat(chatID:toMatter:)`, `startNewChat`, plus first-message auto-titling
  (`derivedTitle`) so history is actually navigable.
- New store APIs (`ChatRepository`): `renameChat`, `softDeleteChat`,
  `moveChatToMatter`.

**Task 2 — example prompts on a blank global chat**
- `ChatSuggestions` (`SupraSessions`): 36 curated legal prompts (research,
  drafting, analysis, documents, litigation, transactional) with a random sampler.
- The global chat opens **blank with four rotating example cards** each launch and
  on every new/blank/empty window; tapping one sends it via the normal path.

**Task 3 — alignment fixes applied here (surgical, high-confidence)**
- `website/lib/constants.ts`: download fallback `v1.2.0 → v1.3.2`.
- `.env.example`: HQ reasoning default corrected to the shipped DeepSeek-R1 model.
- `website/components/Hero.tsx`: network-isolation claim corrected to match the
  privacy pages and `SECURITY.md`.

**Verification:** `SupraSessions` + `SupraStore` build clean; the full app scheme
builds (`** BUILD SUCCEEDED **`); 9 targeted unit tests cover auto-title,
rename/delete/move, blank-new-chat, and the suggestion sampler.

---

## 6. Prioritized recommendations (beyond this branch)

1. **Cut & publish the v1.3.2 GitHub release** with `.dmg`/`.zip` assets (the
   download buttons depend on it).
2. **Add delete (and ideally rename) for models, research sessions, authorities,
   and outputs** — the "create but never delete" pattern is the top structural fix.
3. **Fix the empty-matter Q&A/Chronology dead-end** and disable those buttons until
   documents are indexed.
4. **Refresh the root docs to 1.3.x** (CHANGELOG entries for 1.1–1.3.2; ROADMAP
   re-baseline; SECURITY supported-versions; ARCHITECTURE migration count).
5. **Add real product-page screenshots** (Section 3) and a one-line "not legal
   advice" disclaimer to the home + product pages.
6. **Surface model routing, citation styles, and document classification on the
   website** — they're shipped differentiators that are currently invisible.
7. **Confirm large downloads** before starting them, and **confirm "Delete
   Folder" / permanent-delete**.
