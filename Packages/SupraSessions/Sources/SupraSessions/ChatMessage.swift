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

/// A retained document packet row supplied to a completed matter-chat request.
/// This deliberately remains distinct from `MessageCitation`: presence means the
/// source was provided in the final packet, not that the model cited or used it.
public struct ProvidedDocumentSource: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let documentID: String?
    public let documentName: String
    public let locator: DocumentSourceLocator?
    public let excerpt: String

    public init(
        id: String,
        label: String,
        documentID: String?,
        documentName: String,
        locator: DocumentSourceLocator?,
        excerpt: String
    ) {
        self.id = id
        self.label = label
        self.documentID = documentID
        self.documentName = documentName
        self.locator = locator
        self.excerpt = excerpt
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
    /// Final retained document packet supplied to a completed matter-chat message.
    /// It is not evidence that the response used or cited a particular row.
    public var providedSources: [ProvidedDocumentSource]
    /// Advisory, in-memory results from comparing explicit quoted `[S#]` passages
    /// with the retained packet. They are derived on completion and reload, never
    /// persisted or used to alter the answer, citations, or assurance state.
    public var quoteWarnings: [MatterChatQuoteWarning]
    /// Present for grounded document answers whose persisted packet establishes
    /// an assurance state. Ordinary chat turns remain nil.
    public var assuranceState: OutputAssuranceState?

    public init(
        id: String,
        role: MessageRole,
        content: String,
        status: MessageStatus,
        citations: [MessageCitation] = [],
        providedSources: [ProvidedDocumentSource] = [],
        quoteWarnings: [MatterChatQuoteWarning] = [],
        assuranceState: OutputAssuranceState? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.citations = citations
        self.providedSources = providedSources
        self.quoteWarnings = quoteWarnings
        self.assuranceState = assuranceState
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
