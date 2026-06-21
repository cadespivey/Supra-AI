import Foundation

public enum PartyPerspective: String, Codable, CaseIterable, Hashable, Sendable {
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

public enum ResearchSessionStatus: String, Codable, Hashable, Sendable {
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

public enum ResearchQueryStatus: String, Codable, Hashable, Sendable {
    case draft
    case approved
    case running
    case completed
    case failed
    case cancelled
}

public enum ResearchResultReviewState: String, Codable, CaseIterable, Hashable, Sendable {
    case unreviewed
    case saved
    case skipped
    case potentiallyAdverse = "potentially_adverse"
    case notAdverse = "not_adverse"
    case needsLaterReview = "needs_later_review"
}

public enum AuthorityUseStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unverified
    case retrievedFromCourtListener = "retrieved_from_courtlistener"
    case needsCitatorCheck = "needs_citator_check"
    case userMarkedVerified = "user_marked_verified"
    case doNotUse = "do_not_use"

    /// Human-readable label for display (the raw value is the persisted token).
    public var displayName: String {
        switch self {
        case .unverified: "Unverified"
        case .retrievedFromCourtListener: "Retrieved from CourtListener"
        case .needsCitatorCheck: "Needs citator check"
        case .userMarkedVerified: "Marked verified"
        case .doNotUse: "Do not use"
        }
    }
}

public enum StructuredOutputType: String, Codable, CaseIterable, Hashable, Sendable {
    case legalIssueSpotting = "legal_issue_spotting"
    case researchPlan = "research_plan"
    case caseResultSummary = "case_result_summary"
    case ruleSynthesis = "rule_synthesis"
    case argumentOutline = "argument_outline"
    case draftingSkeleton = "drafting_skeleton"
    // Milestone 3: document intelligence outputs.
    case documentQA = "document_qa"
    case documentQAMemo = "document_qa_memo"
    case factChronologyTable = "fact_chronology_table"
    case factChronologyNarrative = "fact_chronology_narrative"

    /// Document-intelligence outputs (M3) are produced by the document Q&A /
    /// chronology flows from the Documents tab, not by the research-template
    /// contract system used for the other output types.
    public var isDocumentOutput: Bool {
        switch self {
        case .documentQA, .documentQAMemo, .factChronologyTable, .factChronologyNarrative:
            true
        case .legalIssueSpotting, .researchPlan, .caseResultSummary, .ruleSynthesis,
             .argumentOutline, .draftingSkeleton:
            false
        }
    }

    /// Output types whose contract asserts specific legal authority (citations,
    /// holdings, controlling/supporting authorities). Because these are drafted
    /// from notes/documents without retrieving or verifying legal authority, any
    /// such output must always be flagged for citation review — independent of
    /// whether a citation in a recognized format was detected.
    public var assertsLegalAuthority: Bool {
        switch self {
        case .caseResultSummary, .ruleSynthesis, .argumentOutline, .researchPlan:
            true
        case .legalIssueSpotting, .draftingSkeleton,
             .documentQA, .documentQAMemo, .factChronologyTable, .factChronologyNarrative:
            false
        }
    }
}

public enum StructuredOutputStatus: String, Codable, Hashable, Sendable {
    case draft
    case needsReview = "needs_review"
    case complete
    case superseded
}
