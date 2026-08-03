import Combine
import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
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
        public let caseSummary: String?
        /// Recomputed against the live authority row. Nil means the state could
        /// not be read; callers must never infer readiness from raw JSON.
        public let failureToStateClaimReviewState: AuthorityReviewedPropositionState?
        public let rawMetadataJSON: String
    }

    /// The exact persisted opinion bytes available to the proposition editor.
    /// When CourtListener had to be consulted, the detail is returned as well so
    /// the authority reader can reuse the same response instead of fetching twice.
    public enum OpinionReviewPreparation: Sendable, Equatable {
        case ready(text: String, fetchedDetail: CourtListenerOpinionDetailDTO?)
        case unavailable(message: String)
    }

    @Published public private(set) var authorities: [AuthorityItem] = []

    private let store: SupraStore
    public let matterID: String
    private let courtListenerClient: any CourtListenerClientProtocol
    private let tokenStore: any APIKeyStoreProtocol
    private var runtimeClient: (any RuntimeClientProtocol)?
    private let legalConfiguration: LegalModelConfiguration
    /// Authorities with a summary generation in flight (UI busy state).
    @Published public private(set) var summarizingAuthorityIDs: Set<String> = []

    public init(
        store: SupraStore,
        matterID: String,
        legalConfiguration: LegalModelConfiguration = .fromEnvironment(),
        tokenStore: (any APIKeyStoreProtocol)? = nil,
        courtListenerClient: (any CourtListenerClientProtocol)? = nil,
        runtimeClient: (any RuntimeClientProtocol)? = nil
    ) {
        self.store = store
        self.matterID = matterID
        self.runtimeClient = runtimeClient
        self.legalConfiguration = legalConfiguration
        let resolvedTokenStore = tokenStore ?? APIKeyStoreComposition.live()
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

    /// Resolves the byte-authoritative opinion used for proposition review. A
    /// remotely hydrated body is persisted before it is returned, and the exact
    /// stored bytes are re-read and compared before the UI may review an excerpt.
    public func prepareOpinionForPropositionReview(
        authorityID: String
    ) async -> OpinionReviewPreparation {
        let authority: AuthorityRecord
        do {
            guard let stored = try store.authorities.fetchAuthority(id: authorityID),
                  stored.matterID == matterID,
                  stored.deletedAt == nil else {
                return .unavailable(message: "Authority not found.")
            }
            authority = stored
        } catch {
            return .unavailable(message: "Couldn't load the authority. Try again.")
        }

        if let text = authority.opinionText, !text.isEmpty {
            return .ready(text: text, fetchedDetail: nil)
        }
        guard let rawOpinionID = authority.opinionID,
              let opinionID = Int(rawOpinionID) else {
            return .unavailable(message: "No opinion text is available for this authority.")
        }
        guard hasCourtListenerToken else {
            return .unavailable(message: "Add a CourtListener token in Settings to fetch this opinion.")
        }

        let detail: CourtListenerOpinionDetailDTO
        do {
            detail = try await courtListenerClient.fetchOpinion(id: opinionID)
        } catch {
            return .unavailable(message: "Couldn't fetch the opinion from CourtListener. Try again.")
        }
        guard let fetchedText = detail.bodyText,
              !fetchedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(message: "CourtListener did not return readable opinion text.")
        }

        do {
            try store.authorities.updateOpinionText(authorityID: authorityID, text: fetchedText)
            guard let persisted = try store.authorities.fetchAuthority(id: authorityID)?.opinionText,
                  Data(persisted.utf8) == Data(fetchedText.utf8) else {
                return .unavailable(message: "Couldn't store the opinion text. Try again.")
            }
            load()
            return .ready(text: persisted, fetchedDetail: detail)
        } catch {
            return .unavailable(message: "Couldn't store the opinion text. Try again.")
        }
    }

    /// Records the supported motion proposition against the exact editor string.
    /// Preparation is repeated defensively so no caller can review a merely fetched,
    /// unpersisted opinion body.
    public func recordFailureToStateClaimReview(
        authorityID: String,
        excerpt: String
    ) async -> String? {
        switch await prepareOpinionForPropositionReview(authorityID: authorityID) {
        case .ready:
            break
        case .unavailable(let message):
            return message
        }
        defer { load() }
        do {
            _ = try store.authorities.reviewProposition(
                authorityID: authorityID,
                groundKey: .failureToStateClaim,
                excerpt: excerpt,
                reviewedBy: propositionReviewActor()
            )
            return nil
        } catch let error as AuthorityRepositoryError {
            return Self.reviewMessage(for: error)
        } catch {
            return "Couldn't save the proposition review. Try again."
        }
    }

    /// Removes ready or blocked proposition evidence through the audited Store
    /// lifecycle. Blocked evidence deliberately remains revocable.
    public func revokeFailureToStateClaimReview(authorityID: String) -> String? {
        defer { load() }
        do {
            try store.authorities.revokePropositionReview(
                authorityID: authorityID,
                revokedBy: propositionReviewActor()
            )
            return nil
        } catch let error as AuthorityRepositoryError {
            return Self.reviewMessage(for: error)
        } catch {
            return "Couldn't remove the proposition review. Try again."
        }
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
            let propositionState = try? store.authorities.reviewedPropositionState(
                authorityID: record.id,
                groundKey: .failureToStateClaim
            )
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
                caseSummary: CourtListenerText.clean(record.caseSummary),
                failureToStateClaimReviewState: propositionState,
                rawMetadataJSON: record.rawMetadataJSON
            )
        }
    }

    /// Generates and persists a ≤100-word case summary from the opinion text —
    /// the persisted copy when the authority has one, else a one-shot fetch.
    /// Grounded summarization only: with no opinion text there is no summary.
    /// Returns nil on success, else a user-facing reason.
    public func generateSummary(authorityID: String, modelID: ModelID) async -> String? {
        guard let runtimeClient else { return "Summaries need the local model runtime." }
        guard let item = authorities.first(where: { $0.id == authorityID }) else { return "Authority not found." }
        guard !summarizingAuthorityIDs.contains(authorityID) else { return nil }
        summarizingAuthorityIDs.insert(authorityID)
        defer { summarizingAuthorityIDs.remove(authorityID) }

        var opinionText = storedOpinionText(authorityID: authorityID)
        if opinionText == nil {
            opinionText = (await fetchOpinionDetail(opinionID: item.opinionID))?.bodyText
        }
        guard let opinionText, !opinionText.isEmpty else {
            return "No opinion text is available to summarize — open the case on CourtListener or re-run research."
        }

        // Head + tail window: the holding usually opens the opinion; the
        // disposition closes it. Bounded so a 200-page opinion can't blow the
        // context.
        let condensed: String
        if opinionText.count > 12_000 {
            condensed = opinionText.prefix(9_000) + "\n[…]\n" + opinionText.suffix(3_000)
        } else {
            condensed = opinionText
        }
        let prompt = """
        Summarize this judicial opinion in AT MOST 100 words for a litigator's authority library: the holding first, then the key reasoning. Neutral tone, no citations, no preamble — output ONLY the summary paragraph.

        CASE: \(item.caseNameFull ?? item.caseName)

        OPINION TEXT:
        \(condensed)
        """
        var options = ModelRouter(configuration: legalConfiguration).route(for: .generalQA).options
        options.thinkingBudget = .off
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: prompt,
            systemPrompt: nil,
            options: options
        )
        guard let raw = try? await runtimeClient.collectGeneratedText(request),
              case let .answer(answer) = ReasoningContent.resolve(rawOutput: raw, thinkingEnabled: false) else {
            return "The model didn't return a summary. Check that a model is loaded in the Models tab."
        }
        let summary = Self.cappedSummary(answer)
        guard !summary.isEmpty else { return "The model returned an empty summary." }
        // Proportionate grounding: an abstractive summary isn't held to the citation
        // contract, but a party/judge NAME it invents (absent from the opinion) is the one
        // fabrication a blurb can smuggle in — flag it in an out-of-band caveat that
        // travels with the persisted summary. Advisory, never a gate.
        let annotation = Self.groundedSummaryAnnotation(summary: summary, opinionText: opinionText)
        do {
            try store.authorities.updateCaseSummary(authorityID: authorityID, summary: annotation.annotated)
        } catch {
            return "Couldn't save the summary: \(error.localizedDescription)"
        }
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "authority_summary_generated", actor: "runtime",
            summary: "Generated case summary for “\(item.caseName)”"
                + (annotation.flaggedEntities.isEmpty ? "" : " (flagged \(annotation.flaggedEntities.count) ungrounded entity term(s))")
        )
        load()
        return nil
    }

    /// Annotates a model-generated case summary with an out-of-band caveat when it names a
    /// person/entity (or email/phone) that does not appear verbatim in the source opinion.
    /// A summary is abstractive — it legitimately paraphrases — so it is NOT held to the
    /// citation/quote contract; this reuses the entity-grounding check that grounded chat
    /// answers already run, as a proportionate advisory signal. Pure and deterministic so
    /// it is unit-testable without the runtime. Never blocks.
    nonisolated static func groundedSummaryAnnotation(
        summary: String, opinionText: String
    ) -> (annotated: String, flaggedEntities: [String]) {
        let issues = LegalCitationVerifier.verifyGroundedEntities(answer: summary, sourceText: opinionText)
        var seen = Set<String>()
        let flagged = issues.compactMap(\.excerpt).filter { seen.insert($0.lowercased()).inserted }
        guard !flagged.isEmpty else { return (summary, []) }
        let list = flagged.prefix(5).joined(separator: ", ")
        let caveat = "\n\n⚠️ Unverified: this AI summary references terms not found verbatim in the "
            + "opinion (\(list)). Confirm against the source before relying."
        return (summary + caveat, flagged)
    }

    /// Hard 100-word cap — the prompt asks, this enforces.
    static func cappedSummary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count > 100 else { return trimmed }
        return words.prefix(100).joined(separator: " ") + "…"
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

    private func propositionReviewActor() -> String {
        let profile: AssistantProfile = (
            try? store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self)
        ) ?? .empty
        let name = profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Local user" : name
    }

    private static func reviewMessage(for error: AuthorityRepositoryError) -> String {
        switch error {
        case .untrustedPropositionEvidenceOnInsert:
            "Couldn't save the proposition review. Try again."
        case .authorityNotFound:
            "Authority not found."
        case .reviewRequiresLiveAuthority:
            "This authority is no longer in the library."
        case .reviewRequiresNotAdverse:
            "Mark this authority not adverse before recording proposition support."
        case .reviewRequiresUserMarkedVerified:
            "Mark this authority verified before recording proposition support."
        case .opinionTextUnavailable:
            "No opinion text is available for this authority."
        case .effectiveCitationUnavailable:
            "Add a citation before recording proposition support."
        case .reviewerRequired:
            "A reviewer name is required."
        case .excerptEmpty:
            "Enter an exact excerpt from the stored opinion."
        case .excerptTooLong(let maximumUTF8Bytes):
            "The excerpt must be \(maximumUTF8Bytes == 2_000 ? "2,000" : String(maximumUTF8Bytes)) UTF-8 bytes or fewer."
        case .excerptNotFound:
            "That exact excerpt was not found in the stored opinion."
        case .excerptNotUnique:
            "That excerpt appears more than once. Select a longer unique excerpt."
        case .propositionReviewNotFound:
            "There is no proposition review to remove."
        }
    }
}
