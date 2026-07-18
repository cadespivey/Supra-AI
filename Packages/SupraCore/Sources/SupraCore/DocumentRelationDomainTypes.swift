import Foundation

public enum DocumentRelationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case exactDuplicate = "exact_duplicate"
    case normalizedDuplicate = "normalized_duplicate"
    case renderVariant = "render_variant"
    case nearDuplicate = "near_duplicate"
    case draftOf = "draft_of"
    case executedCopyOf = "executed_copy_of"
    case amendmentOf = "amendment_of"
    case redlineOf = "redline_of"
    case supersedes
    case exhibitOf = "exhibit_of"
    case attachmentOf = "attachment_of"

    public var isSymmetric: Bool {
        switch self {
        case .exactDuplicate, .normalizedDuplicate, .renderVariant, .nearDuplicate:
            true
        case .draftOf, .executedCopyOf, .amendmentOf, .redlineOf, .supersedes,
             .exhibitOf, .attachmentOf:
            false
        }
    }
}

public enum DocumentRelationReviewState: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case confirmed
    case rejected
}

public enum DocumentRelationProposer: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case user
}
