import Combine
import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraStore

/// The matter's authority library (spec §11): lists saved authorities and edits
/// preferred citation, notes, and use status with enforced transitions + audit.
@MainActor
public final class AuthoritiesController: ObservableObject {
    public struct AuthorityItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let caseName: String
        public let caseNameFull: String?
        public let citations: [String]
        public let preferredCitation: String?
        public let court: String?
        public let dateFiled: Date?
        public let docketNumber: String?
        public let absoluteURL: String?
        public let opinionID: String?
        public let reviewState: String
        public let useStatus: AuthorityUseStatus
        public let userNotes: String?
        public let rawMetadataJSON: String
    }

    @Published public private(set) var authorities: [AuthorityItem] = []

    private let store: SupraStore
    public let matterID: String
    private let courtListenerClient: any CourtListenerClientProtocol
    private let tokenStore: any APIKeyStoreProtocol

    public init(
        store: SupraStore,
        matterID: String,
        legalConfiguration: LegalModelConfiguration = .fromEnvironment(),
        tokenStore: (any APIKeyStoreProtocol)? = nil,
        courtListenerClient: (any CourtListenerClientProtocol)? = nil
    ) {
        self.store = store
        self.matterID = matterID
        let resolvedTokenStore = tokenStore ?? EnvironmentBackedTokenStore(primary: KeychainTokenStore())
        self.tokenStore = resolvedTokenStore
        self.courtListenerClient = courtListenerClient ?? CourtListenerClient(
            httpClient: AuthorizedHTTPClient(
                keyStore: resolvedTokenStore,
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests),
                redactsQueryValues: !legalConfiguration.logPrivilegedQueryTerms
            ),
            baseURLOverride: legalConfiguration.courtListenerBaseURL
        )
    }

    public var hasCourtListenerToken: Bool {
        (try? tokenStore.hasCourtListenerToken()) ?? false
    }

    /// Fetches the full opinion (text + HTML) for an authority from CourtListener's
    /// allow-listed opinion-detail endpoint. Returns nil if there's no opinion id
    /// or the fetch fails. Used to show a longer passage and an HTML view/download.
    public func fetchOpinionDetail(opinionID: String?) async -> CourtListenerOpinionDetailDTO? {
        guard let opinionID, let id = Int(opinionID) else { return nil }
        return try? await courtListenerClient.fetchOpinion(id: id)
    }

    /// The opinion text persisted on the saved record (spec §4.3), so the reader
    /// works offline without a fetch.
    public func storedOpinionText(authorityID: String) -> String? {
        let text = (try? store.authorities.fetchAuthorities(matterID: matterID))?
            .first { $0.id == authorityID }?
            .opinionText
        return (text?.isEmpty == false) ? text : nil
    }

    /// The app-managed location of a previously-downloaded opinion PDF, or nil if
    /// none has been downloaded for this opinion.
    public func storedOpinionPDF(opinionID: String?) -> URL? {
        guard let opinionID, let url = Self.opinionPDFURL(opinionID: opinionID) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads the opinion PDF from CourtListener's storage CDN into app-managed
    /// storage and returns its local URL (nil on failure). The token is never sent
    /// to the CDN. Subsequent opens reuse the stored file via `storedOpinionPDF`.
    public func downloadOpinionPDF(opinionID: String?, from cdnURL: URL) async -> URL? {
        guard let opinionID, let destination = Self.opinionPDFURL(opinionID: opinionID) else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let data = try? await courtListenerClient.downloadOpinionPDF(from: cdnURL),
              data.starts(with: [0x25, 0x50, 0x44, 0x46]) // "%PDF" magic — reject non-PDF bodies
        else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// `Application Support/SupraAI/OpinionPDFs/opinion-<id>.pdf` (inside the app
    /// container — no file-access entitlement needed).
    private static func opinionPDFURL(opinionID: String) -> URL? {
        let safeID = opinionID.filter { $0.isNumber || $0.isLetter || $0 == "-" }
        guard !safeID.isEmpty,
              let support = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
              )
        else { return nil }
        let dir = support.appendingPathComponent("SupraAI/OpinionPDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("opinion-\(safeID).pdf")
    }

    public func load() {
        authorities = ((try? store.authorities.fetchAuthorities(matterID: matterID)) ?? []).map { record in
            let citations = (try? JSONDecoder().decode([String].self, from: Data(record.citationJSON.utf8))) ?? []
            // Defensive: authorities saved before CourtListener-text sanitization
            // can still carry `<mark>` highlight markup / HTML entities.
            return AuthorityItem(
                id: record.id,
                caseName: CourtListenerText.clean(record.caseName) ?? record.caseName,
                caseNameFull: CourtListenerText.clean(record.caseNameFull),
                citations: CourtListenerText.cleanList(citations),
                preferredCitation: CourtListenerText.clean(record.preferredCitation),
                court: CourtListenerText.clean(record.court),
                dateFiled: record.dateFiled,
                docketNumber: CourtListenerText.clean(record.docketNumber),
                absoluteURL: record.absoluteURL,
                opinionID: record.opinionID,
                reviewState: record.reviewState,
                useStatus: AuthorityUseStatus(rawValue: record.useStatus) ?? .unverified,
                userNotes: record.userNotes,
                rawMetadataJSON: record.rawMetadataJSON
            )
        }
    }

    /// Soft-deletes a saved authority (removes it from the library). Writes an
    /// `authority_soft_deleted` audit event, mirroring document soft-delete.
    public func deleteAuthority(id: String) {
        guard let item = authorities.first(where: { $0.id == id }) else { return }
        _ = try? store.authorities.softDeleteAuthority(id: id)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "authority_soft_deleted", actor: "user",
            summary: "Removed authority “\(item.caseName)”",
            relatedTable: "authorities", relatedID: id
        )
        load()
    }

    /// Changes use status only when the transition is permitted (spec §11.4),
    /// writing an authority_status_changed audit event. Returns false if blocked.
    @discardableResult
    public func changeUseStatus(authorityID: String, to target: AuthorityUseStatus) -> Bool {
        guard let item = authorities.first(where: { $0.id == authorityID }),
              item.useStatus.canTransition(to: target) else { return false }
        try? store.authorities.updateUseStatus(authorityID: authorityID, useStatus: target)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "authority_status_changed", actor: "user",
            summary: "“\(item.caseName)”: \(item.useStatus.displayName) → \(target.displayName)",
            relatedTable: "authorities", relatedID: authorityID
        )
        load()
        return true
    }

    public func updatePreferredCitation(authorityID: String, _ citation: String) {
        try? store.authorities.updatePreferredCitation(authorityID: authorityID, preferredCitation: citation)
        load()
    }

    public func updateUserNotes(authorityID: String, _ notes: String) {
        try? store.authorities.updateUserNotes(authorityID: authorityID, userNotes: notes)
        load()
    }
}
