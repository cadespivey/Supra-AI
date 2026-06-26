import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraDrafting
import SupraDraftingCore
import SupraExports
import SupraStore

/// Generates a downloadable court/letter draft from a matter + the user's firm
/// profile, on device, via the `SupraDrafting` pipeline + `SupraExports` renderer.
///
/// This is the chat-facing bridge for the drafting engine shipped in 1.5.2: it
/// resolves slots from the matter (caption/parties) and the `AssistantProfile`
/// (firm identity), runs the pipeline, writes the `.docx` into the matter's
/// managed `exports/` directory, records an audit event, and returns the file URL
/// plus any firewall follow-ups (`[cite]` / `[fact?]` flags, missing slots) for the
/// attorney to review. Nothing is invented: if the firm identity is incomplete, or
/// a required caption field is missing, it returns a precise blocking prompt instead
/// of guessing.
@MainActor
public final class MatterDraftingController: ObservableObject {
    public struct DraftArtifact: Sendable, Equatable {
        public let kind: DraftKindID
        public let title: String
        public let fileURL: URL
        public let followUps: [DraftFollowUp]

        /// Advisory/blocking notes the attorney must review before relying on the draft.
        public var reviewNotes: [String] { followUps.map(\.message) }
        public var hasBlocking: Bool { followUps.contains { $0.isBlocking } }
    }

    public struct DraftFollowUp: Sendable, Equatable {
        public let isBlocking: Bool
        public let message: String
    }

    public enum DraftError: Error, LocalizedError, Equatable {
        case matterNotFound
        case incompleteFirmProfile(missing: [String])
        case missingCaptionField(String)
        case unsupportedKind(DraftKindID)
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .matterNotFound:
                return "The matter to draft for was not found."
            case let .incompleteFirmProfile(missing):
                return "Complete your firm profile in Settings before drafting — still needed: \(missing.joined(separator: ", "))."
            case let .missingCaptionField(field):
                return "This matter is missing its \(field). Add it to the matter before drafting a court filing."
            case let .unsupportedKind(kind):
                return "Drafting for \(kind.rawValue) isn't wired into chat yet."
            case let .renderFailed(detail):
                return "The draft could not be rendered: \(detail)."
            }
        }
    }

    @Published public private(set) var isGenerating = false
    @Published public var message: String?

    private let store: SupraStore
    private let storage: DocumentStorage
    private let pipelineFactory: @Sendable () -> DraftPipeline

    public init(
        store: SupraStore,
        storage: DocumentStorage = .makeDefault(),
        pipelineFactory: (@Sendable () -> DraftPipeline)? = nil
    ) {
        self.store = store
        self.storage = storage
        // Default: deterministic verifier + the court/letter renderers. Injectable for tests.
        self.pipelineFactory = pipelineFactory ?? { DraftPipeline.makeDefault() }
    }

    // MARK: - Public entry point

    /// Drafts a Notice of Appearance for a matter, writing a `.docx` to managed
    /// storage and returning its URL + review notes. The deterministic, no-LLM kind
    /// — the first wired into chat.
    public func draftNoticeOfAppearance(
        matterID: String,
        parties: [PartyLine],
        partyRepresented: String,
        representedPartyName: String,
        recipients: [ServiceRecipient],
        serviceDate: DateOnly = DateOnly.today
    ) async -> Result<DraftArtifact, DraftError> {
        guard !isGenerating else {
            message = "A draft is already generating. Wait for it to finish."
            return .failure(.renderFailed("already generating"))
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        guard let matter = try? store.matters.fetchMatter(id: matterID) else {
            return .failure(.matterNotFound)
        }
        let profile = (try? store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self)) ?? .empty
        guard profile.hasDraftingIdentity else {
            return .failure(.incompleteFirmProfile(missing: profile.missingDraftingIdentityFields))
        }
        guard let caseNumber = matter.docketNumber, !caseNumber.isEmpty else {
            return .failure(.missingCaptionField("case/docket number"))
        }
        let courtHeader = (matter.court?.isEmpty == false) ? matter.court! : matter.jurisdiction

        let firm = Self.firmProfile(from: profile)
        let inputs = NoticeAppearance.Inputs(
            courtHeader: courtHeader,
            parties: parties,
            partyRepresented: partyRepresented,
            representedPartyName: representedPartyName,
            caseNumber: caseNumber,
            division: matter.judge,   // division/judge line; nil-safe
            serviceDate: serviceDate,
            recipients: recipients
        )

        let pipeline = pipelineFactory()
        let result: DraftResult
        do {
            result = try await pipeline.runNotice(inputs, profile: firm, style: .defaultFL)
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(.renderFailed(error.localizedDescription))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }

        do {
            let url = try persist(docx: result.docx, matterID: matterID, kind: .noticeAppearance, title: NoticeAppearance.title)
            let followUps = result.followUps.map { DraftFollowUp(isBlocking: $0.severity == .blocking, message: $0.message) }
            recordAudit(matterID: matterID, kind: .noticeAppearance, fileName: url.lastPathComponent)
            return .success(DraftArtifact(kind: .noticeAppearance, title: NoticeAppearance.title, fileURL: url, followUps: followUps))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    // MARK: - Profile → FirmProfile (slot-only identity)

    /// Projects the user's `AssistantProfile` onto the drafting `FirmProfile`. Pure
    /// and `nonisolated` so it can be unit-tested without the MainActor controller.
    nonisolated public static func firmProfile(from profile: AssistantProfile) -> FirmProfile {
        FirmProfile(
            firmName: profile.organization,
            signingAttorney: profile.fullName,
            barNumber: profile.barNumber,
            office: OfficeBlock(
                street: profile.officeStreet,
                suite: profile.officeSuite.isEmpty ? nil : profile.officeSuite,
                city: profile.officeCity,
                state: profile.officeState,
                zip: profile.officeZip,
                phone: profile.officePhone,
                fax: profile.officeFax.isEmpty ? nil : profile.officeFax
            ),
            primaryEmail: profile.primaryEmail,
            secondaryEmails: profile.secondaryEmails
        )
    }

    // MARK: - Persistence

    private func persist(docx: Data, matterID: String, kind: DraftKindID, title: String) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.fileStamp()
        let fileName = "\(sanitize(title))-\(stamp).docx"
        let url = directory.appendingPathComponent(fileName)
        try docx.write(to: url)
        return url
    }

    private func recordAudit(matterID: String, kind: DraftKindID, fileName: String) {
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: "draft_generated",
            actor: "user",
            summary: "Generated \(kind.rawValue) draft (\(fileName))",
            relatedTable: "matters",
            relatedID: matterID
        )
    }

    private func sanitize(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").prefix(60).description
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Convenience factory

extension DraftPipeline {
    /// The default chat pipeline: deterministic verifier + the court/letter renderer.
    /// The renderer dispatches on `RenderInput`, so one instance serves both shells.
    public static func makeDefault() -> DraftPipeline {
        DraftPipeline(verifier: DraftVerifier(), renderer: CompositeRenderer())
    }
}
