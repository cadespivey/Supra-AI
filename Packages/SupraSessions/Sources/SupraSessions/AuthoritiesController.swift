import Combine
import Foundation
import SupraCore
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
        public let reviewState: String
        public let useStatus: AuthorityUseStatus
        public let userNotes: String?
        public let rawMetadataJSON: String
    }

    @Published public private(set) var authorities: [AuthorityItem] = []

    private let store: SupraStore
    public let matterID: String

    public init(store: SupraStore, matterID: String) {
        self.store = store
        self.matterID = matterID
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
            summary: "“\(item.caseName)”: \(item.useStatus.rawValue) → \(target.rawValue)",
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
