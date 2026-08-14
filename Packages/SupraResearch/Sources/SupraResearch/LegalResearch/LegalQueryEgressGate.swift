import Foundation

/// Stable identity for one legal-data provider configuration. A network host
/// allow-list is necessary transport policy, but it is not query authority; the
/// provider identity is therefore one of the values bound into every grant.
public struct LegalDataProviderID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let courtListener = Self(rawValue: "courtlistener")
}

/// The product workflow that obtained or exercised query authority.
public enum LegalQueryEgressOrigin: String, Hashable, Sendable {
    case formalResearch
    case quickResearch
}

/// Deterministic privacy classification for the exact outbound query.
public enum LegalQueryEgressClassification: String, Hashable, Sendable {
    /// A conclusively parsed public reporter citation. This is the sole class
    /// eligible for the narrow automatic authority.
    case publicCitation
    /// A content-independent query entered and affirmatively run by the user.
    case userApprovedQuery
    /// A query derived from a matter or its local work product.
    case matterDerived
    /// Ambiguous provenance. This always requires its own exact preview grant.
    case unknown
}

public enum LegalQueryEgressBindingField: String, Hashable, Sendable {
    case provider
    case origin
    case query
    case purpose
    case matter
    case researchSession
    case sourceSetDigest
    case classification
}

public enum LegalQueryEgressError: Error, Equatable, Sendable {
    case invalidProvider
    case invalidQueryBytes
    case invalidPurpose
    case invalidSourceSetDigest
    case invalidApprovalWindow
    case invalidGrantVersion
    case grantNotIssued
    case bindingMismatch(LegalQueryEgressBindingField)
    case grantReplayed
    case grantExpired
    case approvalRequired
    case unknownClassification
}

extension LegalQueryEgressError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProvider:
            "The legal-data provider identity is unavailable. No query was sent."
        case .invalidQueryBytes:
            "The exact legal-data query could not be represented safely. No query was sent."
        case .invalidPurpose:
            "The legal-data query has no bounded purpose. No query was sent."
        case .invalidSourceSetDigest:
            "The legal-data query has an invalid source-set identity. No query was sent."
        case .invalidApprovalWindow:
            "The legal-data approval is not currently valid. No query was sent."
        case .invalidGrantVersion:
            "The legal-data approval version is invalid. No query was sent."
        case .grantNotIssued:
            "The legal-data approval was not issued by this provider boundary. No query was sent."
        case let .bindingMismatch(field):
            "The legal-data approval does not match the current \(field.rawValue) binding. No query was sent."
        case .grantReplayed:
            "This legal-data approval has already been used. No query was sent."
        case .grantExpired:
            "This legal-data approval has expired. No query was sent."
        case .approvalRequired:
            "Review and approve the exact provider query before sending it."
        case .unknownClassification:
            "The legal-data query classification is unresolved and cannot run automatically."
        }
    }
}

/// The complete, content-minimized authority request. The exact UTF-8 provider
/// query is retained because it must equal both the preview and transport bytes.
/// Local bodies never enter this value; a source set contributes only its digest.
public struct LegalQueryEgressIntent: Hashable, Sendable {
    public let providerID: LegalDataProviderID
    public let origin: LegalQueryEgressOrigin
    public let queryBytes: Data
    public let purpose: String
    public let matterID: String?
    public let researchSessionID: String?
    public let sourceSetDigest: String?
    public let classification: LegalQueryEgressClassification

    public init(
        providerID: LegalDataProviderID,
        origin: LegalQueryEgressOrigin,
        queryBytes: Data,
        purpose: String,
        matterID: String?,
        researchSessionID: String?,
        sourceSetDigest: String?,
        classification: LegalQueryEgressClassification
    ) {
        self.providerID = providerID
        self.origin = origin
        self.queryBytes = queryBytes
        self.purpose = purpose
        self.matterID = matterID
        self.researchSessionID = researchSessionID
        self.sourceSetDigest = sourceSetDigest
        self.classification = classification
    }
}

/// UI-safe representation of the precise provider-bound query awaiting approval.
public struct LegalQueryEgressPreview: Hashable, Sendable {
    public let displayedQuery: String
    public let queryBytes: Data
    public let providerID: LegalDataProviderID
    public let origin: LegalQueryEgressOrigin
    public let purpose: String
    public let matterID: String?
    public let researchSessionID: String?
    public let sourceSetDigest: String?
    public let classification: LegalQueryEgressClassification

    fileprivate init(intent: LegalQueryEgressIntent, displayedQuery: String) {
        self.displayedQuery = displayedQuery
        self.queryBytes = intent.queryBytes
        self.providerID = intent.providerID
        self.origin = intent.origin
        self.purpose = intent.purpose
        self.matterID = intent.matterID
        self.researchSessionID = intent.researchSessionID
        self.sourceSetDigest = intent.sourceSetDigest
        self.classification = intent.classification
    }

    fileprivate var intent: LegalQueryEgressIntent {
        LegalQueryEgressIntent(
            providerID: providerID,
            origin: origin,
            queryBytes: queryBytes,
            purpose: purpose,
            matterID: matterID,
            researchSessionID: researchSessionID,
            sourceSetDigest: sourceSetDigest,
            classification: classification
        )
    }
}

/// Opaque, single-use proof that one exact preview was approved. Construction is
/// intentionally internal to the gate so another package cannot forge a grant.
public struct LegalQueryEgressGrant: Hashable, Sendable {
    public let version: Int
    public let approvedAt: Date
    public let expiresAt: Date

    fileprivate let id: UUID
    fileprivate let intent: LegalQueryEgressIntent

    fileprivate init(
        id: UUID,
        version: Int,
        intent: LegalQueryEgressIntent,
        approvedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.version = version
        self.intent = intent
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
    }
}

public enum LegalQueryEgressAuthorization: Sendable {
    /// Explicit absence, used to make fail-closed caller decisions visible.
    case none
    /// Narrow policy authority for a conclusively typed public reporter citation.
    case automaticPublicCitation
    /// Owner approval for one exact provider-bound preview.
    case grant(LegalQueryEgressGrant)
}

/// The sole CourtListener search execution boundary. It validates policy and
/// consumes grants synchronously inside the actor before awaiting transport, so
/// concurrent attempts cannot both spend the same approval.
public actor LegalQueryEgressGate {
    public static let maximumGrantLifetime: TimeInterval = 5 * 60

    private let providerID: LegalDataProviderID
    private let courtListenerClient: any CourtListenerClientProtocol
    private let grantVersion: Int
    private let now: @Sendable () -> Date
    private var issuedGrants: [UUID: LegalQueryEgressGrant] = [:]
    private var consumedGrantIDs: Set<UUID> = []

    public init(
        providerID: LegalDataProviderID,
        courtListenerClient: any CourtListenerClientProtocol,
        grantVersion: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.providerID = providerID
        self.courtListenerClient = courtListenerClient
        self.grantVersion = grantVersion
        self.now = now
    }

    public func preview(for intent: LegalQueryEgressIntent) throws -> LegalQueryEgressPreview {
        try validate(intent)
        guard intent.providerID == providerID else {
            throw LegalQueryEgressError.bindingMismatch(.provider)
        }
        guard let displayedQuery = String(data: intent.queryBytes, encoding: .utf8),
              Data(displayedQuery.utf8) == intent.queryBytes else {
            throw LegalQueryEgressError.invalidQueryBytes
        }
        return LegalQueryEgressPreview(intent: intent, displayedQuery: displayedQuery)
    }

    public func approve(
        preview: LegalQueryEgressPreview,
        approvedAt: Date,
        expiresAt: Date
    ) throws -> LegalQueryEgressGrant {
        let intent = preview.intent
        try validate(intent)
        guard intent.providerID == providerID else {
            throw LegalQueryEgressError.bindingMismatch(.provider)
        }
        guard grantVersion > 0 else {
            throw LegalQueryEgressError.invalidGrantVersion
        }
        guard approvedAt <= now(),
              expiresAt > now(),
              expiresAt > approvedAt,
              expiresAt.timeIntervalSince(approvedAt) <= Self.maximumGrantLifetime else {
            throw LegalQueryEgressError.invalidApprovalWindow
        }

        let grant = LegalQueryEgressGrant(
            id: UUID(),
            version: grantVersion,
            intent: intent,
            approvedAt: approvedAt,
            expiresAt: expiresAt
        )
        issuedGrants[grant.id] = grant
        return grant
    }

    public func searchOpinions(
        _ request: CourtListenerSearchRequest,
        intent: LegalQueryEgressIntent,
        authorization: LegalQueryEgressAuthorization,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        try authorize(
            request: request,
            intent: intent,
            authorization: authorization,
            relatedResearchSessionID: relatedResearchSessionID
        )
        return try await courtListenerClient.searchOpinions(
            request,
            relatedResearchSessionID: relatedResearchSessionID
        )
    }

    public func searchDockets(
        _ request: CourtListenerSearchRequest,
        intent: LegalQueryEgressIntent,
        authorization: LegalQueryEgressAuthorization,
        relatedResearchSessionID: String? = nil
    ) async throws -> CourtListenerSearchResponse {
        try authorize(
            request: request,
            intent: intent,
            authorization: authorization,
            relatedResearchSessionID: relatedResearchSessionID
        )
        return try await courtListenerClient.searchDockets(
            request,
            relatedResearchSessionID: relatedResearchSessionID
        )
    }

    /// The semantic bytes CourtListener places in the citation-lookup `text`
    /// field before form encoding. Keeping canonicalization here lets the caller
    /// bind exactly what the provider client will transmit without retaining the
    /// surrounding answer or prompt that the citations were extracted from.
    public static func citationLookupQueryBytes(_ citations: [String]) -> Data {
        let cleaned = citations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Data(cleaned.joined(separator: "\n").utf8)
    }

    /// Provider-bound citation resolution. Only deterministic citation strings
    /// enter this method; the exact cleaned, joined bytes must match the typed
    /// intent before the CourtListener POST can occur.
    public func resolveCitations(
        _ citations: [String],
        intent: LegalQueryEgressIntent,
        authorization: LegalQueryEgressAuthorization
    ) async throws -> [CourtListenerCitationLookupDTO] {
        try authorize(
            outboundQueryBytes: Self.citationLookupQueryBytes(citations),
            intent: intent,
            authorization: authorization,
            relatedResearchSessionID: nil
        )
        return try await courtListenerClient.resolveCitations(citations)
    }

    private func authorize(
        request: CourtListenerSearchRequest,
        intent: LegalQueryEgressIntent,
        authorization: LegalQueryEgressAuthorization,
        relatedResearchSessionID: String?
    ) throws {
        try authorize(
            outboundQueryBytes: Data(request.query.utf8),
            intent: intent,
            authorization: authorization,
            relatedResearchSessionID: relatedResearchSessionID
        )
    }

    private func authorize(
        outboundQueryBytes: Data,
        intent: LegalQueryEgressIntent,
        authorization: LegalQueryEgressAuthorization,
        relatedResearchSessionID: String?
    ) throws {
        try validate(intent)
        guard intent.providerID == providerID else {
            throw LegalQueryEgressError.bindingMismatch(.provider)
        }
        guard outboundQueryBytes == intent.queryBytes else {
            throw LegalQueryEgressError.bindingMismatch(.query)
        }
        guard relatedResearchSessionID == intent.researchSessionID else {
            throw LegalQueryEgressError.bindingMismatch(.researchSession)
        }

        switch authorization {
        case .none:
            throw LegalQueryEgressError.approvalRequired

        case .automaticPublicCitation:
            guard intent.classification != .unknown else {
                throw LegalQueryEgressError.unknownClassification
            }
            guard intent.classification == .publicCitation else {
                throw LegalQueryEgressError.approvalRequired
            }

        case let .grant(grant):
            guard !consumedGrantIDs.contains(grant.id) else {
                throw LegalQueryEgressError.grantReplayed
            }
            guard now() < grant.expiresAt else {
                throw LegalQueryEgressError.grantExpired
            }
            guard grant.version == grantVersion else {
                throw LegalQueryEgressError.invalidGrantVersion
            }
            guard issuedGrants[grant.id] == grant else {
                throw LegalQueryEgressError.grantNotIssued
            }
            if let mismatch = Self.firstMismatch(approved: grant.intent, actual: intent) {
                throw LegalQueryEgressError.bindingMismatch(mismatch)
            }

            // Consume before the first external await. A timeout or response error
            // cannot prove that the provider saw no bytes, so retry needs a new grant.
            consumedGrantIDs.insert(grant.id)
            issuedGrants[grant.id] = nil
        }
    }

    private func validate(_ intent: LegalQueryEgressIntent) throws {
        guard !intent.providerID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LegalQueryEgressError.invalidProvider
        }
        guard !intent.queryBytes.isEmpty,
              let query = String(data: intent.queryBytes, encoding: .utf8),
              !query.isEmpty,
              Data(query.utf8) == intent.queryBytes else {
            throw LegalQueryEgressError.invalidQueryBytes
        }
        guard !intent.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LegalQueryEgressError.invalidPurpose
        }
        if let digest = intent.sourceSetDigest,
           digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LegalQueryEgressError.invalidSourceSetDigest
        }
    }

    private static func firstMismatch(
        approved: LegalQueryEgressIntent,
        actual: LegalQueryEgressIntent
    ) -> LegalQueryEgressBindingField? {
        if approved.providerID != actual.providerID { return .provider }
        if approved.origin != actual.origin { return .origin }
        if approved.queryBytes != actual.queryBytes { return .query }
        if approved.purpose != actual.purpose { return .purpose }
        if approved.matterID != actual.matterID { return .matter }
        if approved.researchSessionID != actual.researchSessionID { return .researchSession }
        if approved.sourceSetDigest != actual.sourceSetDigest { return .sourceSetDigest }
        if approved.classification != actual.classification { return .classification }
        return nil
    }
}
