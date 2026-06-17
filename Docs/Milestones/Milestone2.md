# Supra AI — Milestone 2 Explicit Implementation Plan  
## Legal Utility Layer: Matters, CourtListener, Structured Outputs, and UI Polish

## 0. Milestone 2 Purpose

Milestone 2 converts Supra AI from a working local runtime shell into a useful legal research and drafting workstation.

Milestone 2 must deliver exactly these capabilities:

```text
1. Matter workspaces.
2. CourtListener API token storage in Keychain.
3. Default-deny network policy with explicit CourtListener allowlist.
4. CourtListener REST API v4 search.
5. Research session planning.
6. User-approved legal research queries.
7. Review-before-save research results.
8. Matter authority library.
9. Structured legal output templates.
10. Missing-section detection.
11. Structure repair preserving variants.
12. Matter outputs tab.
13. Audit and network request logging.
14. UI polish pass across the Milestone 2 surfaces.
```

Milestone 2 must not implement:

```text
- full document ingestion
- OCR
- local document RAG
- vector search
- CourtListener MCP
- general web browsing
- dockets / RECAP automation
- automatic citator
- automatic legal drafting without review states
- background autonomous research
- cloud sync
- telemetry
```

## 0.1 Current Build Alignment Notes

The current build already contains a Milestone 1 matter/chat foundation:

```text
- SupraStore already has v012_create_matters.
- matters currently has id, name, created_at, updated_at, deleted_at.
- chats already has matter_id and scope = "matter" for matter-scoped chats.
- SupraStore already has MatterRecord and MattersRepository.
- SupraSessions already has MattersController and matter-scoped GlobalChatController reuse.
- Apps/SupraAI already has MattersView.
```

Therefore Milestone 2 must evolve those existing surfaces rather than duplicate or replace them.

Adjusted implementation rules:

```text
- Do not add a second v012_create_matters migration.
- Do not create a matter_chats table in Milestone 2; keep chats.matter_id as the canonical matter-chat association.
- Keep the existing deleted_at soft-delete column for matters; do not add a second soft_deleted_at column.
- Create research_sessions before network_requests because the current store enables SQLite foreign-key enforcement at migration time.
- Refactor the existing MatterRecord, MattersRepository, MattersController, and MattersView into the richer matter workspace.
- Add the two new packages to both the local package graph and the Xcode app target package dependencies.
- Execute first in this order: Work Order 19, adjusted Work Order 20 schema/repository foundation, networking/client, then UI workflows.
```

---

# 1. Mandatory Architecture Decisions

## 1.1 New Packages

Create exactly two new local Swift packages:

```text
Packages/
  ├─ SupraNetworking/
  └─ SupraResearch/
```

Do not put network or CourtListener code directly into the app target.

## 1.2 Package Responsibilities

### `SupraNetworking`

Responsible for:

```text
- Keychain token storage abstraction.
- Network allowlist policy.
- URLRequest construction.
- Auth header injection.
- Network request audit metadata.
- Rate limit tracking.
- CourtListener domain enforcement.
```

Not responsible for:

```text
- CourtListener DTO semantics.
- Research sessions.
- Authority models.
- UI.
- GRDB migrations.
```

### `SupraResearch`

Responsible for:

```text
- CourtListener API client.
- CourtListener request/response DTOs.
- Research session domain models.
- Research query planner prompts.
- Research result review models.
- Authority domain models.
- Structured legal output templates.
- Missing section detection.
- Structure repair prompt building.
```

Not responsible for:

```text
- direct Keychain access.
- raw URLSession policy decisions.
- SwiftUI views.
- database connection ownership.
```

## 1.3 Existing Package Changes

Modify existing packages as follows:

```text
SupraCore
  ├─ add MatterID
  ├─ add ResearchSessionID
  ├─ add ResearchQueryID
  ├─ add ResearchResultID
  ├─ add AuthorityID
  ├─ add StructuredOutputID
  └─ add NetworkRequestID

SupraStore
  ├─ add Milestone 2 migrations
  ├─ enrich existing MatterRecord and MattersRepository
  ├─ add ResearchRepository
  ├─ add AuthorityRepository
  ├─ add StructuredOutputRepository
  └─ add NetworkRequestRepository

SupraDiagnostics
  ├─ add research/network diagnostic categories
  └─ add export-safe network audit summaries

SupraDesignSystem
  ├─ add inspector panels
  ├─ add research status badges
  ├─ add authority status badges
  ├─ add section completeness indicators
  └─ add empty-state components
```

---

# 2. CourtListener API Contract

## 2.1 Base URL

Use exactly:

```text
https://www.courtlistener.com
```

## 2.2 Search endpoint

Use exactly:

```text
GET https://www.courtlistener.com/api/rest/v4/search/
```

## 2.3 Authentication

Use exactly this HTTP header:

```http
Authorization: Token <token>
```

Also set:

```http
Accept: application/json
```

Do not use:

```text
- Basic authentication
- Cookie authentication
- OAuth
- environment variables
- token in URL query string
- token in SQLite
```

## 2.4 Token storage

Store the CourtListener API token only in Keychain.

Keychain service:

```text
com.supraai.courtlistener
```

Keychain account:

```text
api-token
```

Never store the token in:

```text
- SQLite
- diagnostics
- validation reports
- crash logs
- exported files
- app settings JSON
```

## 2.5 Required search query parameters

For Milestone 2, every case-law search request must include:

```text
q=<query text>
type=o
```

Use `type=o` because Milestone 2 searches case law opinions only.

Optional parameters permitted in Milestone 2:

```text
order_by=<value copied from CourtListener-compatible search URL>
highlight=on
cursor=<pagination cursor from next URL>
```

Do not implement semantic search in Milestone 2.

Do not implement PACER, dockets, federal filings, judges, or oral argument search in Milestone 2.

## 2.6 Search result fields to decode

Decode these root fields from the search response:

```text
count
next
previous
results
```

Decode these result fields when present:

```text
absolute_url
caseName
caseNameFull
citation
citeCount
cluster_id
court
court_citation_string
court_id
dateFiled
docketNumber
docket_id
judge
lexisCite
neutralCite
opinions
posture
procedural_history
source
status
suitNature
syllabus
meta
```

Decode these opinion fields when present:

```text
id
type
snippet
download_url
local_path
author_id
per_curiam
sha1
```

All unknown JSON must be preserved in `raw_result_json`.

## 2.7 URL construction rule

CourtListener result display URL must be:

```text
https://www.courtlistener.com + absolute_url
```

If `absolute_url` is missing, no display URL is shown.

Do not infer or synthesize a URL from `cluster_id` or `opinion_id`.

---

# 3. Network Policy

## 3.1 Default behavior

Network policy is default-deny.

The only allowlisted Milestone 2 domains are:

```text
www.courtlistener.com
courtlistener.com
```

Every network request must pass through `NetworkPolicyService`.

## 3.2 Blocked request behavior

If any code attempts to request a non-allowlisted domain:

```text
1. Do not send the request.
2. Create a network_requests row with approved = false.
3. Create a diagnostic warning.
4. Show user-facing error:
   "Network request blocked by Supra AI network policy."
```

## 3.3 Approved request behavior

Before sending an approved CourtListener request:

```text
1. Create network_requests row with approved = true and status_code = null.
2. Execute request.
3. Update status_code or error_message.
4. Link request to research_session_id if applicable.
```

## 3.4 Rate limit tracking

Implement local rolling counters for CourtListener requests.

Track:

```text
requests_last_minute
requests_last_hour
requests_last_day
```

When local counters reach known default authenticated limits:

```text
5 per minute
50 per hour
125 per day
```

Do not send the request. Show:

```text
"CourtListener request limit reached for the current window. Try again later or increase your CourtListener API limits."
```

Still log the blocked-by-local-rate-limit attempt in `network_requests`.

---

# 4. Milestone 2 Database Migrations

Add migrations in this exact order after the existing `v012_create_matters` migration.

```text
v013_enrich_matters
v014_create_research_sessions
v015_create_network_requests
v016_create_research_queries
v017_create_research_results
v018_create_authorities
v019_create_structured_outputs
v020_create_output_versions
v021_create_audit_events_phase2
```

## 4.1 `matters`

`matters` already exists from Milestone 1. Add the Milestone 2 fields with `ALTER TABLE`, using safe defaults for existing rows:

```sql
ALTER TABLE matters ADD COLUMN jurisdiction TEXT NOT NULL DEFAULT 'Unspecified';
ALTER TABLE matters ADD COLUMN party_perspective TEXT NOT NULL DEFAULT 'neutral';
ALTER TABLE matters ADD COLUMN court TEXT;
ALTER TABLE matters ADD COLUMN judge TEXT;
ALTER TABLE matters ADD COLUMN docket_number TEXT;
ALTER TABLE matters ADD COLUMN practice_area TEXT;
ALTER TABLE matters ADD COLUMN notes TEXT;
```

Validation:

```text
name: required, trimmed length >= 1
jurisdiction: required, trimmed length >= 1
party_perspective: required, one of plaintiff | defendant | petitioner | respondent | appellant | appellee | movant | nonparty | neutral | other
```

Soft deletion continues to use the existing `deleted_at` column.

## 4.2 Matter chats

Milestone 2 uses the existing direct chat association:

```text
chats.scope = "matter"
chats.matter_id = matters.id
```

Default matter chat behavior:

```text
- Creating a matter creates a chat with scope = "matter".
- Default chat title is "General — <Matter Name>".
- Research and structured output rows link to matter_id and, when needed, chat_id directly.
```

## 4.3 `network_requests`

```sql
CREATE TABLE network_requests (
    id TEXT PRIMARY KEY NOT NULL,
    timestamp TEXT NOT NULL,
    domain TEXT NOT NULL,
    method TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    approved INTEGER NOT NULL,
    status_code INTEGER,
    related_research_session_id TEXT REFERENCES research_sessions(id),
    blocked_reason TEXT,
    error_message TEXT,
    request_metadata_json TEXT,
    response_metadata_json TEXT
);
```

Rules:

```text
- endpoint stores path only, not full token-bearing URL.
- request_metadata_json must not include Authorization header.
- response_metadata_json must not include token.
```

## 4.4 `research_sessions`

```sql
CREATE TABLE research_sessions (
    id TEXT PRIMARY KEY NOT NULL,
    matter_id TEXT NOT NULL REFERENCES matters(id),
    title TEXT NOT NULL,
    issue_text TEXT NOT NULL,
    jurisdiction TEXT NOT NULL,
    preferred_courts_json TEXT NOT NULL,
    excluded_courts_json TEXT NOT NULL,
    date_range_start TEXT,
    date_range_end TEXT,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT
);
```

Allowed `status` values:

```text
draft
planned
approved
running
results_ready
review_incomplete
complete
cancelled
failed
```

## 4.5 `research_queries`

```sql
CREATE TABLE research_queries (
    id TEXT PRIMARY KEY NOT NULL,
    research_session_id TEXT NOT NULL REFERENCES research_sessions(id),
    query_text TEXT NOT NULL,
    query_index INTEGER NOT NULL,
    court_filter TEXT,
    date_filed_after TEXT,
    date_filed_before TEXT,
    status TEXT NOT NULL,
    result_count INTEGER,
    next_url TEXT,
    executed_at TEXT,
    request_metadata_json TEXT,
    response_metadata_json TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

Allowed `status` values:

```text
draft
approved
running
completed
failed
cancelled
```

## 4.6 `research_results`

```sql
CREATE TABLE research_results (
    id TEXT PRIMARY KEY NOT NULL,
    research_query_id TEXT NOT NULL REFERENCES research_queries(id),
    courtlistener_id TEXT,
    cluster_id TEXT,
    opinion_id TEXT,
    case_name TEXT NOT NULL,
    case_name_full TEXT,
    citation_json TEXT NOT NULL,
    preferred_citation TEXT,
    court TEXT,
    court_id TEXT,
    date_filed TEXT,
    docket_number TEXT,
    snippet TEXT,
    absolute_url TEXT,
    review_state TEXT NOT NULL,
    raw_result_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

Allowed `review_state` values:

```text
unreviewed
saved
skipped
potentially_adverse
not_adverse
needs_later_review
```

## 4.7 `authorities`

```sql
CREATE TABLE authorities (
    id TEXT PRIMARY KEY NOT NULL,
    matter_id TEXT NOT NULL REFERENCES matters(id),
    research_session_id TEXT NOT NULL REFERENCES research_sessions(id),
    research_result_id TEXT NOT NULL REFERENCES research_results(id),
    courtlistener_id TEXT,
    cluster_id TEXT,
    opinion_id TEXT,
    case_name TEXT NOT NULL,
    case_name_full TEXT,
    citation_json TEXT NOT NULL,
    preferred_citation TEXT,
    court TEXT,
    court_id TEXT,
    date_filed TEXT,
    docket_number TEXT,
    absolute_url TEXT,
    precedential_status TEXT,
    review_state TEXT NOT NULL,
    use_status TEXT NOT NULL,
    user_notes TEXT,
    raw_metadata_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(matter_id, research_result_id)
);
```

Allowed `review_state` values:

```text
saved
potentially_adverse
not_adverse
needs_later_review
```

Allowed `use_status` values:

```text
unverified
retrieved_from_courtlistener
needs_citator_check
user_marked_verified
do_not_use
```

Default when saved:

```text
review_state = saved
use_status = retrieved_from_courtlistener
```

## 4.8 `structured_outputs`

```sql
CREATE TABLE structured_outputs (
    id TEXT PRIMARY KEY NOT NULL,
    matter_id TEXT NOT NULL REFERENCES matters(id),
    chat_id TEXT REFERENCES chats(id),
    research_session_id TEXT REFERENCES research_sessions(id),
    title TEXT NOT NULL,
    output_type TEXT NOT NULL,
    active_version_id TEXT,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    soft_deleted_at TEXT
);
```

Allowed `output_type` values:

```text
legal_issue_spotting
research_plan
case_result_summary
rule_synthesis
argument_outline
drafting_skeleton
```

Allowed `status` values:

```text
draft
needs_review
complete
superseded
```

## 4.9 `structured_output_versions`

```sql
CREATE TABLE structured_output_versions (
    id TEXT PRIMARY KEY NOT NULL,
    structured_output_id TEXT NOT NULL REFERENCES structured_outputs(id),
    version_index INTEGER NOT NULL,
    parent_version_id TEXT REFERENCES structured_output_versions(id),
    content_markdown TEXT NOT NULL,
    required_sections_json TEXT NOT NULL,
    present_sections_json TEXT NOT NULL,
    missing_sections_json TEXT NOT NULL,
    repair_reason TEXT,
    generation_session_id TEXT REFERENCES generation_sessions(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(structured_output_id, version_index)
);
```

## 4.10 `audit_events`

If no audit table exists yet, create it:

```sql
CREATE TABLE audit_events (
    id TEXT PRIMARY KEY NOT NULL,
    matter_id TEXT REFERENCES matters(id),
    timestamp TEXT NOT NULL,
    event_type TEXT NOT NULL,
    actor TEXT NOT NULL,
    summary TEXT NOT NULL,
    related_table TEXT,
    related_id TEXT,
    metadata_json TEXT
);
```

Allowed `actor` values:

```text
user
system
runtime
network
```

Required Milestone 2 `event_type` values:

```text
matter_created
matter_updated
research_session_created
research_plan_generated
research_queries_approved
courtlistener_search_started
courtlistener_search_completed
courtlistener_search_failed
research_result_reviewed
authority_saved
authority_status_changed
structured_output_created
structured_output_repaired
network_request_blocked
network_request_sent
```

---

# 5. Domain Types

Add these exact domain enums.

## 5.1 Matter

```swift
public enum PartyPerspective: String, Codable, CaseIterable, Sendable {
    case plaintiff
    case defendant
    case petitioner
    case respondent
    case appellant
    case appellee
    case movant
    case nonparty
    case neutral
    case other
}
```

## 5.2 Research

```swift
public enum ResearchSessionStatus: String, Codable, Sendable {
    case draft
    case planned
    case approved
    case running
    case resultsReady = "results_ready"
    case reviewIncomplete = "review_incomplete"
    case complete
    case cancelled
    case failed
}

public enum ResearchQueryStatus: String, Codable, Sendable {
    case draft
    case approved
    case running
    case completed
    case failed
    case cancelled
}

public enum ResearchResultReviewState: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case saved
    case skipped
    case potentiallyAdverse = "potentially_adverse"
    case notAdverse = "not_adverse"
    case needsLaterReview = "needs_later_review"
}

public enum AuthorityUseStatus: String, Codable, CaseIterable, Sendable {
    case unverified
    case retrievedFromCourtListener = "retrieved_from_courtlistener"
    case needsCitatorCheck = "needs_citator_check"
    case userMarkedVerified = "user_marked_verified"
    case doNotUse = "do_not_use"
}
```

## 5.3 Structured Outputs

```swift
public enum StructuredOutputType: String, Codable, CaseIterable, Sendable {
    case legalIssueSpotting = "legal_issue_spotting"
    case researchPlan = "research_plan"
    case caseResultSummary = "case_result_summary"
    case ruleSynthesis = "rule_synthesis"
    case argumentOutline = "argument_outline"
    case draftingSkeleton = "drafting_skeleton"
}

public enum StructuredOutputStatus: String, Codable, Sendable {
    case draft
    case needsReview = "needs_review"
    case complete
    case superseded
}
```

---

# 6. CourtListener Client

## 6.1 Files

Create:

```text
Packages/SupraResearch/Sources/SupraResearch/CourtListener/
  ├─ CourtListenerClient.swift
  ├─ CourtListenerEndpoint.swift
  ├─ CourtListenerSearchRequest.swift
  ├─ CourtListenerSearchResponse.swift
  ├─ CourtListenerSearchResultDTO.swift
  ├─ CourtListenerOpinionDTO.swift
  ├─ CourtListenerMapper.swift
  └─ CourtListenerError.swift
```

## 6.2 Client protocol

```swift
public protocol CourtListenerClientProtocol: Sendable {
    func searchOpinions(_ request: CourtListenerSearchRequest) async throws -> CourtListenerSearchResponse
}
```

## 6.3 Request type

```swift
public struct CourtListenerSearchRequest: Codable, Sendable {
    public let query: String
    public let orderBy: String?
    public let highlight: Bool
    public let cursorURL: URL?

    public init(
        query: String,
        orderBy: String? = nil,
        highlight: Bool = true,
        cursorURL: URL? = nil
    ) {
        self.query = query
        self.orderBy = orderBy
        self.highlight = highlight
        self.cursorURL = cursorURL
    }
}
```

Rules:

```text
- If cursorURL is nil, construct URL from base endpoint.
- If cursorURL is not nil, use cursorURL only after validating host is www.courtlistener.com.
- Always include type=o for non-cursor requests.
- Always include q for non-cursor requests.
- Include highlight=on when highlight is true.
```

## 6.4 Response DTO

```swift
public struct CourtListenerSearchResponse: Codable, Sendable {
    public let count: Int
    public let next: String?
    public let previous: String?
    public let results: [CourtListenerSearchResultDTO]
}
```

## 6.5 Result DTO

```swift
public struct CourtListenerSearchResultDTO: Codable, Sendable {
    public let absoluteURL: String?
    public let caseName: String?
    public let caseNameFull: String?
    public let citation: [String]
    public let citeCount: Int?
    public let clusterID: Int?
    public let court: String?
    public let courtCitationString: String?
    public let courtID: String?
    public let dateFiled: String?
    public let docketNumber: String?
    public let docketID: Int?
    public let judge: String?
    public let lexisCite: String?
    public let neutralCite: String?
    public let opinions: [CourtListenerOpinionDTO]
    public let posture: String?
    public let proceduralHistory: String?
    public let source: String?
    public let status: String?
    public let suitNature: String?
    public let syllabus: String?
}
```

Implement custom CodingKeys for camelCase JSON fields.

## 6.6 Opinion DTO

```swift
public struct CourtListenerOpinionDTO: Codable, Sendable {
    public let id: Int?
    public let type: String?
    public let snippet: String?
    public let downloadURL: String?
    public let localPath: String?
    public let authorID: Int?
    public let perCuriam: Bool?
    public let sha1: String?
}
```

## 6.7 Error types

```swift
public enum CourtListenerError: Error, Equatable {
    case missingToken
    case blockedByNetworkPolicy
    case localRateLimitExceeded
    case invalidCursorHost
    case invalidResponse
    case authenticationFailed
    case throttled
    case serverError(statusCode: Int)
    case decodingFailed
    case transportFailed(String)
}
```

HTTP mapping:

```text
401 or 403 -> authenticationFailed
429 -> throttled
500...599 -> serverError
non-HTTP response -> invalidResponse
decode failure -> decodingFailed
URLSession error -> transportFailed
```

---

# 7. Networking Layer

## 7.1 Files

Create:

```text
Packages/SupraNetworking/Sources/SupraNetworking/
  ├─ KeychainTokenStore.swift
  ├─ NetworkPolicyService.swift
  ├─ NetworkRequestLogger.swift
  ├─ AuthorizedHTTPClient.swift
  ├─ RateLimitTracker.swift
  └─ NetworkPolicyError.swift
```

## 7.2 Keychain API

```swift
public protocol APIKeyStoreProtocol: Sendable {
    func saveCourtListenerToken(_ token: String) throws
    func loadCourtListenerToken() throws -> String?
    func deleteCourtListenerToken() throws
    func hasCourtListenerToken() throws -> Bool
}
```

Validation:

```text
- Empty token is rejected.
- Token is trimmed before storage.
- Stored token is never returned to UI except as masked "••••••".
```

## 7.3 Network policy API

```swift
public protocol NetworkPolicyServiceProtocol: Sendable {
    func isAllowed(_ url: URL) -> Bool
    func validate(_ url: URL) throws
}
```

Allowed hosts:

```swift
private let allowedHosts: Set<String> = [
    "www.courtlistener.com",
    "courtlistener.com"
]
```

Reject:

```text
- any http URL
- any non-CourtListener host
- any URL with embedded username/password
```

## 7.4 Authorized HTTP client API

```swift
public protocol AuthorizedHTTPClientProtocol: Sendable {
    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse)
}
```

Required behavior:

```text
1. Validate URL through NetworkPolicyService.
2. Check RateLimitTracker.
3. Add Accept: application/json.
4. Add Authorization: Token <token>.
5. Log network request before sending.
6. Send request.
7. Update network log after response/failure.
```

---

# 8. Matter Workspace

## 8.1 UI Files

Create:

```text
Apps/SupraAI/SupraAI/Matters/
  ├─ MattersListView.swift
  ├─ MatterWorkspaceView.swift
  ├─ MatterDetailHeader.swift
  ├─ MatterEditorSheet.swift
  ├─ MatterEmptyStateView.swift
  ├─ MatterChatView.swift
  ├─ MatterResearchView.swift
  ├─ MatterAuthoritiesView.swift
  ├─ MatterOutputsView.swift
  └─ MatterAuditView.swift
```

## 8.2 Matter workspace tabs

Use exactly these tabs in this order:

```text
1. Chat
2. Research
3. Authorities
4. Outputs
5. Audit
6. Documents
```

Documents tab behavior:

```text
- visible
- disabled
- label: "Documents — coming in next phase"
```

## 8.3 Matter creation flow

When user clicks New Matter:

```text
1. Present MatterEditorSheet.
2. Require name.
3. Require jurisdiction.
4. Require party perspective.
5. Save matter.
6. Create default matter chat.
7. Write audit event: matter_created.
8. Open MatterWorkspaceView.
```

Default chat title:

```text
General — <Matter Name>
```

## 8.4 Matter validation

Do not allow save if:

```text
- name empty after trimming
- jurisdiction empty after trimming
- party perspective missing
```

Show inline validation messages.

---

# 9. Research Session Workflow

## 9.1 UI Files

Create:

```text
Apps/SupraAI/SupraAI/Research/
  ├─ ResearchSessionListView.swift
  ├─ ResearchSessionDetailView.swift
  ├─ ResearchPlannerView.swift
  ├─ ResearchQueryEditorView.swift
  ├─ ResearchRunView.swift
  ├─ ResearchResultsReviewView.swift
  ├─ ResearchResultRow.swift
  ├─ ResearchResultDetailView.swift
  └─ ResearchSessionCompletionView.swift
```

## 9.2 Research session creation flow

When user clicks New Research Session:

```text
1. Present ResearchPlannerView.
2. User enters issue_text.
3. Pre-fill jurisdiction from matter.
4. User optionally enters preferred courts.
5. User optionally enters excluded courts.
6. User optionally enters date range.
7. User clicks Generate Search Plan.
8. Local LLM generates proposed queries.
9. User edits queries.
10. User approves selected queries.
11. App stores approved research_queries.
12. App writes audit event: research_queries_approved.
```

## 9.3 Required research planner fields

Required:

```text
- title
- issue_text
- jurisdiction
```

Optional:

```text
- preferred_courts
- excluded_courts
- date_range_start
- date_range_end
```

## 9.4 Query generation count

The local LLM must generate exactly 5 proposed queries.

The UI must allow the user to:

```text
- edit each query
- delete a query
- add a query
- approve or unapprove each query
```

At least one query must be approved before running research.

## 9.5 Running research

When user clicks Run Approved Searches:

```text
1. Confirm CourtListener token exists.
2. Confirm CourtListener domain allowed.
3. Confirm at least one approved query exists.
4. Set session status = running.
5. For each approved query in query_index order:
   a. Set query status = running.
   b. Send GET /api/rest/v4/search/?q=<query>&type=o&highlight=on.
   c. Store result_count, next_url, response metadata.
   d. Insert research_results.
   e. Set query status = completed.
6. Set session status = results_ready.
7. Write audit events for start and completion.
```

If any query fails:

```text
- set that query status = failed
- store error_message
- continue to next approved query
- if all queries fail, set session status = failed
- if at least one query succeeds, set session status = results_ready
```

## 9.6 Pagination

Milestone 2 supports one page of results by default.

Add a Load More button for a query if `next_url` is not nil.

Load More behavior:

```text
1. Validate next_url host is www.courtlistener.com.
2. Send request.
3. Append new results.
4. Update next_url.
5. Log network request.
```

Do not auto-fetch additional pages.

---

# 10. Research Result Review

## 10.1 Result row display

Each result row must show:

```text
- case name
- preferred citation or first citation
- court
- date filed
- status if available
- snippet preview
- review state badge
```

## 10.2 Result detail display

Detail view must show:

```text
- case name full
- citations
- court
- date filed
- docket number
- judge
- snippet
- opinions snippets
- CourtListener link
- raw metadata disclosure section
- review actions
```

## 10.3 Review actions

Each result must support exactly these actions:

```text
Save as Authority
Skip
Mark Potentially Adverse
Mark Not Adverse
Needs Later Review
```

Action behavior:

### Save as Authority

```text
1. Set research_results.review_state = saved.
2. Insert authorities row if not already inserted.
3. Set authorities.use_status = retrieved_from_courtlistener.
4. Write audit event: authority_saved.
```

### Skip

```text
1. Set review_state = skipped.
2. Do not create authority.
3. Write audit event: research_result_reviewed.
```

### Mark Potentially Adverse

```text
1. Set review_state = potentially_adverse.
2. Insert authority row.
3. Set authority.review_state = potentially_adverse.
4. Set authority.use_status = needs_citator_check.
5. Write audit event.
```

### Mark Not Adverse

```text
1. Set review_state = not_adverse.
2. If authority exists, set authority.review_state = not_adverse.
3. Write audit event.
```

### Needs Later Review

```text
1. Set review_state = needs_later_review.
2. Insert authority row.
3. Set authority.review_state = needs_later_review.
4. Set authority.use_status = unverified.
5. Write audit event.
```

## 10.4 Session completion rule

A research session can be marked complete only if every research result is one of:

```text
saved
skipped
potentially_adverse
not_adverse
needs_later_review
```

If any result is `unreviewed`, completion is blocked.

The UI must show:

```text
"Review incomplete: <N> result(s) still unreviewed."
```

---

# 11. Authority Library

## 11.1 UI Files

Create:

```text
Apps/SupraAI/SupraAI/Authorities/
  ├─ AuthoritiesListView.swift
  ├─ AuthorityDetailView.swift
  ├─ AuthorityStatusEditor.swift
  ├─ AuthorityCitationEditor.swift
  └─ AuthorityNotesEditor.swift
```

## 11.2 List columns

Authority list must show:

```text
- case name
- preferred citation
- court
- date filed
- review state
- use status
```

## 11.3 Detail view

Authority detail must show:

```text
- case name
- case name full
- citation list
- preferred citation editable field
- court
- date filed
- docket number
- CourtListener URL
- review state
- use status
- user notes
- raw metadata disclosure
```

## 11.4 Allowed use-status transitions

Permitted:

```text
retrieved_from_courtlistener -> needs_citator_check
retrieved_from_courtlistener -> user_marked_verified
retrieved_from_courtlistener -> do_not_use

needs_citator_check -> user_marked_verified
needs_citator_check -> do_not_use

unverified -> needs_citator_check
unverified -> user_marked_verified
unverified -> do_not_use

user_marked_verified -> needs_citator_check
user_marked_verified -> do_not_use

do_not_use -> needs_citator_check
```

Every status change writes audit event:

```text
authority_status_changed
```

---

# 12. Structured Outputs

## 12.1 Template files

Create:

```text
Resources/PromptTemplates/StructuredOutputs/
  ├─ legal-issue-spotting-v1.md
  ├─ research-plan-v1.md
  ├─ case-result-summary-v1.md
  ├─ rule-synthesis-v1.md
  ├─ argument-outline-v1.md
  ├─ drafting-skeleton-v1.md
  └─ repair-structure-v1.md
```

## 12.2 Section contracts

### Legal Issue Spotting

Required sections:

```text
# Legal Issue Spotting

## Issues Identified
## Factual Questions
## Legal Questions
## Missing Evidence
## Potentially Adverse Facts
## Research Needed
## Drafting Paths
```

### Research Plan

Required sections:

```text
# Research Plan

## Issue
## Search Strategy
## Proposed Queries
## Court Filters
## Date Filters
## Likely Controlling Authority
## Likely Persuasive Authority
## Risks / Adverse Authority to Watch
## Notes
```

### Case Result Summary

Required sections:

```text
# Case Result Summary

## Citation
## Court / Date
## Procedural Posture
## Issue
## Holding
## Reasoning
## Useful Rule Language
## Limitations / Negative Treatment
## Drafting Use
## Verification Needed
```

### Rule Synthesis

Required sections:

```text
# Rule Synthesis

## Rule Statement
## Controlling Authorities
## Persuasive Authorities
## Distinctions
## Counterarguments
## Missing Authority
## Drafting Notes
```

### Argument Outline

Required sections:

```text
# Argument Outline

## Proposed Argument
## Elements / Legal Standard
## Supporting Authorities
## Supporting Facts
## Counterarguments
## Weaknesses
## Missing Support
## Next Drafting Steps
```

### Drafting Skeleton

Required sections:

```text
# Drafting Skeleton

## Caption / Context
## Introduction
## Facts Needed
## Legal Standard
## Argument Sections
## Authorities Needed
## Record Support Needed
## Open Questions
```

## 12.3 Missing-section detection

Implement deterministic Markdown heading detection.

Rules:

```text
- A required section is present only if its heading appears exactly.
- Heading level must match exactly.
- Extra whitespace before/after heading text is allowed.
- Case-insensitive comparison is allowed.
- Synonyms do not count.
- Missing sections are stored in missing_sections_json.
```

## 12.4 Structured output creation

When creating a structured output:

```text
1. User selects output type.
2. App loads section contract.
3. App builds prompt.
4. Runtime generates Markdown.
5. App detects present/missing sections.
6. App creates structured_outputs row.
7. App creates structured_output_versions row version_index = 1.
8. If missing_sections_json is empty, status = complete.
9. If missing_sections_json is not empty, status = needs_review.
10. App writes audit event structured_output_created.
```

## 12.5 Structure repair

Repair action prompt must use:

```text
You are repairing the structure of a Markdown legal output.

Do not add new legal analysis.
Do not invent facts.
Do not invent citations.
Do not change the substance unless needed to move existing text under the required headings.

Original output:
{{original_output}}

Required exact heading structure:
{{required_sections}}

Return a repaired Markdown document using the required headings.
If content is missing for a required heading, insert:
[NEEDS CONTENT]
```

Repair behavior:

```text
1. Create new structured_output_versions row.
2. parent_version_id = previous active version.
3. version_index increments by 1.
4. repair_reason = "missing_required_sections".
5. Preserve original version.
6. Make repaired version active.
7. Re-run missing-section detection.
8. Write audit event structured_output_repaired.
```

---

# 13. Outputs Tab

## 13.1 UI Files

Create:

```text
Apps/SupraAI/SupraAI/Outputs/
  ├─ OutputsListView.swift
  ├─ OutputDetailView.swift
  ├─ OutputVersionPicker.swift
  ├─ OutputSectionCompletenessView.swift
  └─ OutputActionsBar.swift
```

## 13.2 Outputs list

Display:

```text
- title
- output type
- status
- created date
- updated date
- missing section count
```

## 13.3 Output detail

Display:

```text
- title
- output type
- version picker
- Markdown rendered preview
- raw Markdown toggle
- missing sections
- linked research session if any
- repair structure action
```

---

# 14. UI Polish Requirements

Apply these exact UI changes.

## 14.1 Sidebar

Sidebar order:

```text
Global Chats
Matters
Models
Tasks
Diagnostics
Settings
```

Matter section behavior:

```text
- Show recent matters under Matters.
- Show New Matter button.
- Active matter highlighted.
```

## 14.2 Status badges

Use these exact badge labels:

```text
Local
Runtime Ready
Generating
Research Network Active
Limited Mode
Runtime Failed
Research Blocked
```

## 14.3 Empty states

Implement empty states for:

```text
No Matters
No Research Sessions
No Authorities
No Outputs
No Diagnostics
No CourtListener Token
Network Blocked
```

Each empty state must include:

```text
- title
- one-sentence explanation
- primary action if available
```

Example:

```text
Title: No Authorities Saved
Explanation: Save reviewed CourtListener results to build this matter’s authority library.
Action: New Research Session
```

## 14.4 Inspector panels

Use a consistent right-side inspector pattern for:

```text
Research Result Detail
Authority Detail
Structured Output Detail
Diagnostics Detail
```

Inspector width:

```text
minimum 320
ideal 420
maximum 560
```

## 14.5 Warning hierarchy

Use three warning levels:

```text
Info
Warning
Blocking
```

Blocking warnings must prevent the relevant action.

Examples:

```text
No CourtListener token -> blocks research run.
Unreviewed results -> blocks research session completion.
Missing required sections -> blocks marking structured output complete.
```

---

# 15. Prompt Templates

## 15.1 Research query generation prompt

File:

```text
Resources/PromptTemplates/research-query-generation-v1.md
```

Prompt:

```text
You are helping generate CourtListener case-law search queries.

The searches will be sent to CourtListener REST API v4 using type=o for case law opinions.

Generate exactly 5 search queries.

Do not include citations unless they were provided by the user.
Do not invent case names.
Prefer concise legal search terms.
Include jurisdiction-relevant terms where useful.
Do not include commentary outside the required Markdown.

Matter:
- Jurisdiction: {{jurisdiction}}
- Party perspective: {{party_perspective}}
- Preferred courts: {{preferred_courts}}
- Excluded courts: {{excluded_courts}}
- Date range: {{date_range}}

Issue:
{{issue_text}}

Return Markdown with exactly this structure:

# Research Queries

## Query 1
{{query}}

## Query 2
{{query}}

## Query 3
{{query}}

## Query 4
{{query}}

## Query 5
{{query}}
```

Parser rule:

```text
Extract text under Query 1 through Query 5.
If fewer than 5 queries are extracted, show "Query generation incomplete" and allow manual query entry.
Do not auto-run any query.
```

## 15.2 Rule synthesis prompt

File:

```text
Resources/PromptTemplates/StructuredOutputs/rule-synthesis-v1.md
```

Prompt:

```text
Using only the saved authorities provided below, synthesize the rule relevant to the issue.

Do not invent authorities.
Do not invent citations.
Do not claim citator status.
If support is missing, use [NEEDS AUTHORITY].
If negative treatment must be checked, use [VERIFY CITATOR TREATMENT].

Issue:
{{issue_text}}

Saved Authorities:
{{authorities}}

Return Markdown with exactly these sections:

# Rule Synthesis

## Rule Statement
## Controlling Authorities
## Persuasive Authorities
## Distinctions
## Counterarguments
## Missing Authority
## Drafting Notes
```

---

# 16. Codex Work Orders

Use these Codex work orders as adjusted for the current build.

## Work Order 19 — Add Milestone 2 packages and core IDs

```text
Create SupraNetworking and SupraResearch local Swift packages. Add Milestone 2 ID types to SupraCore: MatterID, ResearchSessionID, ResearchQueryID, ResearchResultID, AuthorityID, StructuredOutputID, and NetworkRequestID. Add PartyPerspective, ResearchSessionStatus, ResearchQueryStatus, ResearchResultReviewState, AuthorityUseStatus, StructuredOutputType, and StructuredOutputStatus enums. Ensure all new types are Codable, Hashable where appropriate, and Sendable.
```

Acceptance:

```text
- Packages build independently.
- App target can import both packages.
- No UI code exists in SupraNetworking or SupraResearch.
```

## Work Order 20 — Add Milestone 2 migrations

```text
Add GRDB migrations v013 through v021 after the existing v012_create_matters. Enrich the existing matters table, keep chats.matter_id as the matter-chat association, create research_sessions before network_requests for foreign-key safety, and add research_queries, research_results, authorities, structured_outputs, structured_output_versions, and audit_events. Add or enrich records and repositories for each table.
```

Acceptance:

```text
- Fresh database runs all migrations.
- Existing Milestone 1 database migrates without data loss.
- Records round-trip through GRDB.
```

## Work Order 21 — Implement Keychain and network policy

```text
Implement KeychainTokenStore, NetworkPolicyService, RateLimitTracker, NetworkRequestLogger, and AuthorizedHTTPClient. Enforce default-deny network behavior, allow only courtlistener.com and www.courtlistener.com, reject http URLs, and log every approved or blocked request.
```

Acceptance:

```text
- CourtListener token stores only in Keychain.
- Blocked requests are never sent.
- Approved requests are logged before and after execution.
- Authorization header is never logged.
```

## Work Order 22 — Implement CourtListener client

```text
Implement CourtListenerClient for GET https://www.courtlistener.com/api/rest/v4/search/ with q and type=o. Add highlight=on by default. Decode search response and result DTOs. Preserve raw JSON for every result. Map HTTP and decoding errors to CourtListenerError.
```

Acceptance:

```text
- Test token can execute q=contract&type=o search.
- Results decode without crashing when optional fields are missing.
- Raw JSON is preserved.
- 401/403/429/5xx errors map correctly.
```

## Work Order 23 — Implement matter workspace

```text
Refactor existing MatterRecord, MattersRepository, MattersController, and MattersView to support matter creation, editing, soft deletion, and MatterWorkspaceView with tabs Chat, Research, Authorities, Outputs, Audit, and disabled Documents. Creating a matter also creates a default matter chat through the existing ChatRepository matter scope and writes a matter_created audit event.
```

Acceptance:

```text
- User can create matter.
- Required validation works.
- Matter appears in sidebar.
- Matter workspace opens.
- Default matter chat exists.
```

## Work Order 24 — Implement research planner

```text
Implement ResearchPlannerView. User enters title, issue, jurisdiction, preferred courts, excluded courts, and date range. Generate exactly 5 proposed CourtListener queries using the local runtime and research-query-generation-v1.md. User can edit, delete, add, approve, or unapprove queries. No network call occurs during planning.
```

Acceptance:

```text
- Query generation uses local model only.
- User approval is required before research run.
- At least one approved query is required to run.
- Approved queries persist.
```

## Work Order 25 — Implement research run execution

```text
Implement Run Approved Searches. Execute approved queries sequentially through CourtListenerClient. Store research_queries execution metadata, research_results, network_requests, and audit_events. Continue after individual query failure. Support one page by default and a manual Load More button using validated next_url.
```

Acceptance:

```text
- Approved queries run in query_index order.
- Results are inserted.
- Query failures do not stop later queries.
- Session status becomes results_ready if at least one query succeeds.
- Load More appends results.
```

## Work Order 26 — Implement result review and authority saving

```text
Implement ResearchResultsReviewView and review actions: Save as Authority, Skip, Mark Potentially Adverse, Mark Not Adverse, Needs Later Review. Only saved/potentially adverse/needs later review results create authority rows. Completion is blocked while any result is unreviewed.
```

Acceptance:

```text
- Results are not auto-saved.
- Review state changes persist.
- Authority rows are created only by review actions.
- Completion blocking works.
```

## Work Order 27 — Implement authority library

```text
Implement Matter > Authorities list/detail views. Show authority metadata, preferred citation editing, user notes, review state, and use status. Enforce allowed use-status transitions and audit every status change.
```

Acceptance:

```text
- Saved authorities display.
- Preferred citation edits persist.
- Use-status transitions are enforced.
- Status changes write audit events.
```

## Work Order 28 — Implement structured output templates

```text
Add structured output templates and section contracts for Legal Issue Spotting, Research Plan, Case Result Summary, Rule Synthesis, Argument Outline, and Drafting Skeleton. Implement deterministic missing-section detection using exact heading matching.
```

Acceptance:

```text
- Each output type has required sections.
- Generated output stores present and missing sections.
- Missing sections are visible in UI.
```

## Work Order 29 — Implement structure repair and output versions

```text
Implement Repair Structure. Repair creates a new structured_output_versions row, preserves prior version, uses repair-structure-v1.md, inserts [NEEDS CONTENT] for missing headings, reruns section detection, and makes repaired version active.
```

Acceptance:

```text
- Original version preserved.
- Repaired version linked to parent.
- Missing-section detection reruns.
- Audit event written.
```

## Work Order 30 — Implement Outputs tab

```text
Implement Matter > Outputs list/detail UI. Show title, output type, status, created/updated dates, missing section count, version picker, Markdown preview, raw Markdown toggle, linked research session, and Repair Structure action.
```

Acceptance:

```text
- Outputs persist.
- Versions can be viewed.
- Repair action available when sections missing.
```

## Work Order 31 — Milestone 2 UI polish pass

```text
Apply the required UI polish: sidebar recent matters, exact status badges, empty states, right-side inspector panels, warning hierarchy, consistent card design, and native monochrome visual styling. Do not alter core runtime behavior.
```

Acceptance:

```text
- All specified empty states exist.
- Status badge labels match spec.
- Inspector panels use specified width behavior.
- Blocking warnings prevent blocked actions.
```

---

# 17. Milestone 2 Definition of Done

Milestone 2 is complete only when all conditions are true:

```text
1. User can create and edit a matter.
2. Matter has Chat, Research, Authorities, Outputs, Audit, and disabled Documents tab.
3. CourtListener token is stored only in Keychain.
4. Network policy blocks all non-CourtListener domains.
5. Every network request is logged.
6. Local rate-limit tracker blocks requests at default CourtListener limits.
7. User can create a research session.
8. Local model generates exactly 5 editable proposed queries.
9. User must approve at least one query before research runs.
10. CourtListener searches use GET /api/rest/v4/search/?q=<query>&type=o&highlight=on.
11. Search results are stored as reviewable research_results.
12. Search results are not saved as authorities automatically.
13. User can save, skip, mark adverse, mark not adverse, or mark needs later review.
14. Saved authorities appear in Matter > Authorities.
15. Authority use status transitions are enforced.
16. Research session completion is blocked if any result is unreviewed.
17. Structured output templates exist for all six output types.
18. Missing required Markdown sections are detected deterministically.
19. Structure repair creates a new version and preserves the old version.
20. Outputs are saved and visible in Matter > Outputs.
21. Milestone 2 audit events are written for matter, research, authority, output, and network actions.
22. UI polish requirements are implemented exactly.
```

---

# 18. Non-Negotiable Guardrails

```text
- Do not implement general web browsing.
- Do not implement CourtListener MCP.
- Do not send network requests without allowlist approval.
- Do not store CourtListener token outside Keychain.
- Do not auto-save search results as authorities.
- Do not mark authorities as verified automatically.
- Do not hide needs_citator_check status.
- Do not let structure repair invent substance.
- Do not overwrite structured output versions.
- Do not build document RAG in Milestone 2.
- Do not create background autonomous research.
- Do not add Python.
- Do not add localhost HTTP.
- Do not weaken sandboxing.
```
