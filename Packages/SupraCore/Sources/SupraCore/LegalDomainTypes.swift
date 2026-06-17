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
}

public enum StructuredOutputStatus: String, Codable, Hashable, Sendable {
    case draft
    case needsReview = "needs_review"
    case complete
    case superseded
}
