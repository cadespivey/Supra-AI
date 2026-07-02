import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// One inline citation attached to a chat message: a legal-research authority
/// (`[A#]`, opens its CourtListener `url`) or a matter-document source (`[S#]`,
/// opens the in-app preview at `locator`'s page). Resolved from `message_citations`.
/// Resolvable pointer behind an inline `[A#]` legal-authority citation — enough to
/// open the in-app opinion reader (spec §2.5): hydration keys plus the case header.
public struct AuthorityCitationRef: Codable, Sendable, Equatable {
    public var opinionID: String?
    public var clusterID: String?
    public var citation: String?
    public var court: String?
    public var dateFiled: String?

    public init(opinionID: String? = nil, clusterID: String? = nil, citation: String? = nil, court: String? = nil, dateFiled: String? = nil) {
        self.opinionID = opinionID
        self.clusterID = clusterID
        self.citation = citation
        self.court = court
        self.dateFiled = dateFiled
    }
}

public struct MessageCitation: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case authority
        case source
    }

    public let id: String
    public let label: String          // "A1" / "S1" (no brackets)
    public let kind: Kind
    public let url: String?           // [A#] CourtListener URL
    public let documentID: String?    // [S#]
    public let locator: DocumentSourceLocator?   // [S#]
    /// [A#] reader pointer, decoded from the citation's locator JSON. Nil for [S#]
    /// and for authority citations persisted before the reader existed (those fall
    /// back to opening the CourtListener URL).
    public let authorityRef: AuthorityCitationRef?
    public let displayName: String?
    public let matchText: String?

    public init(
        id: String,
        label: String,
        kind: Kind,
        url: String? = nil,
        documentID: String? = nil,
        locator: DocumentSourceLocator? = nil,
        authorityRef: AuthorityCitationRef? = nil,
        displayName: String? = nil,
        matchText: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.url = url
        self.documentID = documentID
        self.locator = locator
        self.authorityRef = authorityRef
        self.displayName = displayName
        self.matchText = matchText
    }

    init(record: MessageCitationRecord) {
        // The locator JSON column carries a per-kind payload: a document locator for
        // [S#], an authority reader ref for [A#].
        let kind = MessageCitation.Kind(rawValue: record.kind) ?? .authority
        let locatorData = record.locatorJSON.flatMap { $0.data(using: .utf8) }
        let locator: DocumentSourceLocator? = kind == .source
            ? locatorData.flatMap { try? JSONDecoder().decode(DocumentSourceLocator.self, from: $0) }
            : nil
        let authorityRef: AuthorityCitationRef? = kind == .authority
            ? locatorData.flatMap { try? JSONDecoder().decode(AuthorityCitationRef.self, from: $0) }
            : nil
        self.init(
            id: record.id,
            label: record.label,
            kind: kind,
            url: record.url,
            documentID: record.documentID,
            locator: locator,
            authorityRef: authorityRef,
            displayName: record.displayName,
            matchText: record.matchText
        )
    }
}

/// A view-facing snapshot of a single chat message.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let role: MessageRole
    public var content: String
    public var status: MessageStatus
    /// Inline citations resolved for a completed assistant message (empty otherwise).
    public var citations: [MessageCitation]

    public init(
        id: String,
        role: MessageRole,
        content: String,
        status: MessageStatus,
        citations: [MessageCitation] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.citations = citations
    }

    init(record: MessageRecord) {
        self.init(
            id: record.id,
            role: MessageRole(rawValue: record.role) ?? .assistant,
            content: record.content,
            status: MessageStatus(rawValue: record.status) ?? .pending
        )
    }

    /// `true` while an assistant message is still being generated.
    public var isStreaming: Bool {
        role == .assistant && status == .pending
    }
}
