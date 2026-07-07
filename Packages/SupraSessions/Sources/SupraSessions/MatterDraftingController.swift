import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraDrafting
import SupraDraftingCore
import SupraExports
import SupraRuntimeClient
import SupraRuntimeInterface
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
        /// What produced this artifact — a wired catalog kind, or a free-form custom
        /// description. A custom artifact has no `DraftKindID`, so we never fake one.
        public let source: MatterDraftArtifactSource
        /// The on-disk format: a rendered `.docx` filing, or a markdown description/request.
        public let format: DraftArtifactFormat
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
        case missingRequiredSlots([String])
        case unsupportedJurisdiction(String)
        case unsupportedKind(DraftKindID)
        case emptyDescription
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .matterNotFound:
                return "The matter to draft for was not found."
            case .emptyDescription:
                return "Describe the work product you want before generating."
            case let .incompleteFirmProfile(missing):
                return "Complete your firm profile in Settings before drafting — still needed: \(missing.joined(separator: ", "))."
            case let .missingCaptionField(field):
                return "This matter is missing its \(field). Add it to the matter before drafting a court filing."
            case let .missingRequiredSlots(slots):
                return "Complete the Notice of Appearance fields before drafting — still needed: \(slots.joined(separator: ", "))."
            case let .unsupportedJurisdiction(jurisdiction):
                return "Notice of Appearance drafting is currently wired for Florida filings only. This matter looks like \(jurisdiction)."
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
    /// Present when the app can call the on-device model — required for the LLM-backed
    /// kinds (`letterDemand`). The deterministic notice path works without it.
    private let runtimeClient: (any RuntimeClientProtocol)?
    /// The firm's structural style overrides (letterhead/caption/signature/…), or nil to use the
    /// house default. Injected as the raw value type; in the app, `FirmStyleProfileController`
    /// (M2) supplies its `.profile` here. `nil` ⇒ output is byte-for-byte `.defaultFL`.
    private let firmStyleProfile: FirmStyleProfile?

    public init(
        store: SupraStore,
        runtimeClient: (any RuntimeClientProtocol)? = nil,
        storage: DocumentStorage = .makeDefault(),
        firmStyleProfile: FirmStyleProfile? = nil,
        pipelineFactory: (@Sendable () -> DraftPipeline)? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.storage = storage
        self.firmStyleProfile = firmStyleProfile
        // Default: deterministic verifier + the court/letter renderers. Injectable for tests.
        self.pipelineFactory = pipelineFactory ?? { DraftPipeline.makeDefault() }
    }

    /// The effective house style sheet for this matter's drafts: the firm's overrides resolved
    /// over `.defaultFL`, then clamped to the Fla. R. Jud. Admin. 2.520(a) floor so a firm can
    /// never push below 12 pt / 1" margins. `internal` (reachable via `@testable`), not `private`.
    /// With no `firmStyleProfile` set, this is exactly `.defaultFL` (invariant 5).
    func effectiveStyle() -> HouseStyleSheet {
        (firmStyleProfile ?? FirmStyleProfile()).resolved(over: .defaultFL).clampedToFloor()
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
        guard let caseNumber = matter.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !caseNumber.isEmpty else {
            return .failure(.missingCaptionField("case/docket number"))
        }
        let courtHeader = Self.courtHeader(for: matter)
        guard !courtHeader.isEmpty, courtHeader.caseInsensitiveCompare("Unspecified") != .orderedSame else {
            return .failure(.missingCaptionField("court"))
        }
        guard Self.isSupportedNoticeJurisdiction(matter: matter, courtHeader: courtHeader) else {
            return .failure(.unsupportedJurisdiction(courtHeader))
        }

        // Match the bar admission to the filing's court (court text first, then the
        // matter's jurisdiction); falls back to the primary license.
        let firm = Self.firmProfile(from: profile, jurisdiction: matter.court ?? matter.jurisdiction)
        let inputs = NoticeAppearance.Inputs(
            courtHeader: courtHeader,
            parties: Self.normalizedParties(parties),
            partyRepresented: partyRepresented.trimmingCharacters(in: .whitespacesAndNewlines),
            representedPartyName: representedPartyName.trimmingCharacters(in: .whitespacesAndNewlines),
            caseNumber: caseNumber,
            division: matter.judge?.trimmingCharacters(in: .whitespacesAndNewlines),   // division/judge line; nil-safe
            serviceDate: serviceDate,
            recipients: Self.normalizedRecipients(recipients)
        )
        let missingSlots = NoticeAppearanceInputValidator.validate(inputs: inputs, profile: firm)
        guard missingSlots.isEmpty else {
            return .failure(.missingRequiredSlots(missingSlots))
        }

        let pipeline = pipelineFactory()
        let result: DraftResult
        do {
            result = try await pipeline.runNotice(inputs, profile: firm, style: effectiveStyle())
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(.renderFailed(error.localizedDescription))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }

        do {
            let url = try persist(data: result.docx, matterID: matterID, title: NoticeAppearance.title, fileExtension: "docx")
            let followUps = result.followUps.map { DraftFollowUp(isBlocking: $0.severity == .blocking, message: $0.message) }
            recordAudit(matterID: matterID, label: DraftKindID.noticeAppearance.rawValue, fileName: url.lastPathComponent)
            return .success(DraftArtifact(source: .kind(.noticeAppearance), format: .docx, title: NoticeAppearance.title, fileURL: url, followUps: followUps))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    // MARK: - Request layer (multi-kind + custom)

    /// The kinds the app can actually generate, with display titles and a reason for
    /// any that are present in the catalog but not yet wired into the app. `isEnabled`
    /// is keyed off the controller's wired generation paths — NOT registry membership,
    /// since all three kinds have full registry definitions but only the notice is wired.
    public func availableDraftKinds() -> [DraftKindAvailability] {
        let wired = wiredKinds
        return DraftKindID.allCases.map { kind in
            DraftKindAvailability(
                id: kind,
                title: Self.displayTitle(for: kind),
                isEnabled: wired.contains(kind),
                disabledReason: wired.contains(kind)
                    ? nil
                    : "\(Self.displayTitle(for: kind)) drafting isn't wired into the app yet — use “Custom” to describe it for now."
            )
        }
    }

    /// Single entry point for the Draft Workspace. Dispatches a typed request to the
    /// matching generation path. The notice path renders a `.docx`; the custom path
    /// writes a markdown work-product description (clearly labeled — not a filing).
    public func draft(_ request: MatterDraftRequest, matterID: String) async -> Result<DraftArtifact, DraftError> {
        switch request {
        case let .noticeAppearance(input):
            return await draftNoticeOfAppearance(
                matterID: matterID,
                parties: input.parties,
                partyRepresented: input.partyRepresented,
                representedPartyName: input.representedPartyName,
                recipients: input.recipients,
                serviceDate: input.serviceDate
            )
        case let .customDescription(input):
            return await draftCustomDescription(matterID: matterID, input: input)
        }
    }

    /// Writes the user's free-form work-product description to a markdown file in the
    /// matter's exports. No model and no rendering: the output is the attorney's own
    /// words plus matter context, labeled as a drafting brief, so nothing is invented.
    public func draftCustomDescription(matterID: String, input: CustomDraftDescriptionInput) async -> Result<DraftArtifact, DraftError> {
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
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return .failure(.emptyDescription)
        }
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Work-Product Description"
        let markdown = Self.customDescriptionMarkdown(
            title: title,
            description: description,
            instructions: input.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            matter: matter
        )
        do {
            let url = try persist(data: Data(markdown.utf8), matterID: matterID, title: title, fileExtension: "md")
            recordAudit(matterID: matterID, label: "custom work-product description", fileName: url.lastPathComponent)
            let note = DraftFollowUp(
                isBlocking: false,
                message: "This is a work-product description in your own words — not a court-ready or model-generated filing. Use it as a drafting brief or starting point."
            )
            return .success(DraftArtifact(source: .customDescription, format: .markdown, title: title, fileURL: url, followUps: [note]))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    /// Generates a Demand Letter (the `letterDemand` kind) with the on-device drafting model.
    /// The user's structured inputs are the ONLY fact source; the model writes the body, then
    /// the deterministic letter pipeline (verifier + pre-file gate + letterhead renderer)
    /// produces the `.docx`. The caller must resolve/load the drafting model first.
    public func draftLetterDemand(
        matterID: String,
        input: LetterDraftInput,
        modelID: ModelID,
        route: ModelRoute
    ) async -> Result<DraftArtifact, DraftError> {
        guard !isGenerating else {
            message = "A draft is already generating. Wait for it to finish."
            return .failure(.renderFailed("already generating"))
        }
        guard let runtimeClient else {
            return .failure(.unsupportedKind(.letterDemand))
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
        let claim = input.claimSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else {
            return .failure(.missingRequiredSlots(["the claim or dispute the letter is about"]))
        }

        let firm = Self.firmProfile(from: profile, jurisdiction: matter.court ?? matter.jurisdiction)
        let facts = Self.letterFacts(from: input, claim: claim)
        let voice = AssistantVoiceProfile(registerNotes: Self.toneRegister(input.tone))
        let parts = LetterDemand.promptParts(facts: facts, profile: voice)
        let inputs = Self.letterInputs(from: input)

        let generator = RuntimeLetterGenerator(runtimeClient: runtimeClient, modelID: modelID, route: route)
        let generated: GeneratedLetter
        do {
            generated = try await generator.generateLetter(parts)
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
        guard !generated.paragraphs.isEmpty else {
            return .failure(.renderFailed("the model returned no letter body"))
        }

        let result: DraftResult
        do {
            result = try await pipelineFactory().runLetter(inputs, generated: generated, profile: firm, style: effectiveStyle())
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(.renderFailed(error.localizedDescription))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }

        do {
            let title = "Demand Letter"
            let url = try persist(data: result.docx, matterID: matterID, title: title, fileExtension: "docx")
            let followUps = result.followUps.map { DraftFollowUp(isBlocking: $0.severity == .blocking, message: $0.message) }
                + Self.letterBodyReviewNotes(generated.paragraphs)
            recordAudit(matterID: matterID, label: DraftKindID.letterDemand.rawValue, fileName: url.lastPathComponent)
            return .success(DraftArtifact(source: .kind(.letterDemand), format: .docx, title: title, fileURL: url, followUps: followUps))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    /// The kinds this controller can actually generate. `letterDemand` is LLM-backed, so it
    /// is only wired when a runtime is available; the notice path is always deterministic.
    private var wiredKinds: Set<DraftKindID> {
        runtimeClient == nil ? [.noticeAppearance] : [.noticeAppearance, .letterDemand]
    }

    /// Deterministic firewall scan of the model's letter body. `verifyLetter` only inspects a
    /// `GeneratedLetter`'s `citesUsed` (empty here — a demand letter asserts no authority), so it
    /// never sees the free-text prose. This scans that prose for citation-shaped references and
    /// for the `[fact?]`/`[cite]` placeholders the prompt tells the model to emit, and surfaces
    /// each as a review follow-up so the cue rides with the artifact rather than reaching the
    /// `.docx` silently. Heuristic by design — it flags for the attorney, never auto-edits.
    nonisolated private static func letterBodyReviewNotes(_ paragraphs: [String]) -> [DraftFollowUp] {
        let body = paragraphs.joined(separator: "\n")
        var notes: [DraftFollowUp] = []
        let citationPatterns = [
            #"\b[A-Z][\w.'&-]+ v\.? [A-Z][\w.'&-]+"#,                 // case name: Smith v. Jones
            #"\b\d{1,4} [A-Z][\w.]*\.?( \d[a-z]{0,2})? \d{1,4}\b"#,   // reporter: 123 So. 2d 456
            #"§\s?\d"#,                                                 // § 1983
            #"\bU\.?S\.?C\.?\b"#, #"\bC\.?F\.?R\.?\b"#, #"\bStat\."#,  // U.S.C. / C.F.R. / Fla. Stat.
        ]
        if citationPatterns.contains(where: { body.range(of: $0, options: .regularExpression) != nil }) {
            notes.append(DraftFollowUp(
                isBlocking: true,
                message: "The letter body appears to reference legal authority, but this draft has no verified citations — confirm or remove any case or statute reference before sending."
            ))
        }
        if body.contains("[cite]") {
            notes.append(DraftFollowUp(isBlocking: true, message: "The draft contains a [cite] placeholder — supply or remove the citation before sending."))
        }
        if body.contains("[fact?]") {
            notes.append(DraftFollowUp(isBlocking: true, message: "The draft contains a [fact?] placeholder — supply the missing fact before sending."))
        }
        return notes
    }

    nonisolated private static func letterFacts(from input: LetterDraftInput, claim: String) -> [GroundedFact] {
        var facts = [GroundedFact(text: claim, label: "claim", docId: "user-input", locator: "claim")]
        let amount = input.demandAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !amount.isEmpty {
            facts.append(GroundedFact(text: amount, label: "demandAmount", docId: "user-input", locator: "demandAmount"))
        }
        let deadline = input.responseDeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deadline.isEmpty {
            facts.append(GroundedFact(text: deadline, label: "responseDeadline", docId: "user-input", locator: "responseDeadline"))
        }
        return facts
    }

    nonisolated private static func toneRegister(_ tone: String) -> String {
        switch tone.lowercased() {
        case "final": return "firm, final, and unequivocal — a last demand before suit"
        case "measured": return "professional and measured, leaving room to resolve"
        default: return "firm but professional"
        }
    }

    nonisolated private static func letterInputs(from input: LetterDraftInput) -> LetterDemand.Inputs {
        let name = input.recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = AddressBlock(
            name: name,
            title: nil,
            firm: input.recipientFirm.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            street: input.recipientStreet.trimmingCharacters(in: .whitespacesAndNewlines),
            city: input.recipientCity.trimmingCharacters(in: .whitespacesAndNewlines),
            state: input.recipientState.trimmingCharacters(in: .whitespacesAndNewlines),
            zip: input.recipientZip.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let salutation = input.salutation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Dear \(name.isEmpty ? "Sir or Madam" : name):"
        return LetterDemand.Inputs(
            recipient: recipient,
            reSubject: input.reSubject.trimmingCharacters(in: .whitespacesAndNewlines),
            salutation: salutation,
            date: .today,
            deliveryNotation: input.deliveryNotation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            enclosures: [],
            cc: []
        )
    }

    private static func displayTitle(for kind: DraftKindID) -> String {
        switch kind {
        case .noticeAppearance: return "Notice of Appearance"
        case .motionToDismiss: return "Motion to Dismiss"
        case .letterDemand: return "Demand Letter"
        }
    }

    nonisolated private static func customDescriptionMarkdown(
        title: String,
        description: String,
        instructions: String,
        matter: MatterRecord
    ) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("> Work-product description — drafted by the user, not a court-ready filing or model output.")
        lines.append("")
        lines.append("**Matter:** \(matter.name)")
        if let court = matter.court?.trimmingCharacters(in: .whitespacesAndNewlines), !court.isEmpty {
            lines.append("**Court:** \(court)")
        }
        if let docket = matter.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !docket.isEmpty {
            lines.append("**Case no.:** \(docket)")
        }
        lines.append("")
        lines.append("## Requested work product")
        lines.append("")
        lines.append(description)
        if !instructions.isEmpty {
            lines.append("")
            lines.append("## Instructions / notes")
            lines.append("")
            lines.append(instructions)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Profile → FirmProfile (slot-only identity)

    /// Projects the user's `AssistantProfile` onto the drafting `FirmProfile`. Pure
    /// and `nonisolated` so it can be unit-tested without the MainActor controller.
    /// `jurisdiction` (a filing's court/jurisdiction text) selects which bar admission
    /// prints; an empty value falls back to the primary license.
    nonisolated public static func firmProfile(
        from profile: AssistantProfile,
        jurisdiction: String = ""
    ) -> FirmProfile {
        let license = profile.resolvedBarLicense(forJurisdiction: jurisdiction)
        let barLabel = BarJurisdictionCatalog.jurisdiction(id: license?.jurisdictionID)?.barLabel ?? "Bar No."
        return FirmProfile(
            firmName: profile.organization.trimmingCharacters(in: .whitespacesAndNewlines),
            signingAttorney: profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            barNumber: license?.barNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            barLabel: barLabel,
            office: OfficeBlock(
                street: profile.officeStreet.trimmingCharacters(in: .whitespacesAndNewlines),
                suite: profile.officeSuite.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                city: profile.officeCity.trimmingCharacters(in: .whitespacesAndNewlines),
                state: profile.officeState.trimmingCharacters(in: .whitespacesAndNewlines),
                zip: profile.officeZip.trimmingCharacters(in: .whitespacesAndNewlines),
                phone: profile.officePhone.trimmingCharacters(in: .whitespacesAndNewlines),
                fax: profile.officeFax.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            primaryEmail: profile.primaryEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            secondaryEmails: profile.secondaryEmails
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    nonisolated private static func courtHeader(for matter: MatterRecord) -> String {
        if let court = matter.court?.trimmingCharacters(in: .whitespacesAndNewlines), !court.isEmpty {
            return court
        }
        return matter.jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isSupportedNoticeJurisdiction(matter: MatterRecord, courtHeader: String) -> Bool {
        [matter.court, matter.jurisdiction, courtHeader]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { candidate in
                BarJurisdictionCatalog.match(candidate)?.id == "fl"
                    || candidate.localizedCaseInsensitiveContains("florida")
            }
    }

    nonisolated private static func normalizedParties(_ parties: [PartyLine]) -> [PartyLine] {
        parties.map {
            PartyLine(
                name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                designation: $0.designation.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    nonisolated private static func normalizedRecipients(_ recipients: [ServiceRecipient]) -> [ServiceRecipient] {
        recipients.map { recipient in
            ServiceRecipient(
                name: recipient.name.trimmingCharacters(in: .whitespacesAndNewlines),
                firm: recipient.firm.trimmingCharacters(in: .whitespacesAndNewlines),
                address: OfficeBlock(
                    street: recipient.address.street.trimmingCharacters(in: .whitespacesAndNewlines),
                    suite: recipient.address.suite?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    city: recipient.address.city.trimmingCharacters(in: .whitespacesAndNewlines),
                    state: recipient.address.state.trimmingCharacters(in: .whitespacesAndNewlines),
                    zip: recipient.address.zip.trimmingCharacters(in: .whitespacesAndNewlines),
                    phone: recipient.address.phone.trimmingCharacters(in: .whitespacesAndNewlines),
                    fax: recipient.address.fax?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ),
                emails: recipient.emails
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                role: recipient.role.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - Persistence

    private func persist(data: Data, matterID: String, title: String, fileExtension: String) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.fileStamp()
        let fileName = "\(sanitize(title))-\(stamp).\(fileExtension)"
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }

    private func recordAudit(matterID: String, label: String, fileName: String) {
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID,
            eventType: "draft_generated",
            actor: "user",
            summary: "Generated \(label) draft (\(fileName))",
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Request layer value types

/// What produced a `DraftArtifact`. Keeps custom artifacts out of `DraftKindID` so we
/// never introduce a fake `.custom` kind the registry/renderer don't support.
public enum MatterDraftArtifactSource: Sendable, Equatable {
    case kind(DraftKindID)
    case customDescription
}

public enum DraftArtifactFormat: String, Sendable, Equatable {
    case docx
    case markdown
}

/// A catalog kind plus whether the app can generate it right now and why not.
public struct DraftKindAvailability: Sendable, Equatable, Identifiable {
    public var id: DraftKindID
    public var title: String
    public var isEnabled: Bool
    public var disabledReason: String?

    public init(id: DraftKindID, title: String, isEnabled: Bool, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

/// The structured inputs for a Notice of Appearance, bundled so the Draft Workspace can
/// dispatch them through the shared `draft(_:matterID:)` entry point.
public struct NoticeAppearanceDraftInput: Sendable, Equatable {
    public var parties: [PartyLine]
    public var partyRepresented: String
    public var representedPartyName: String
    public var recipients: [ServiceRecipient]
    public var serviceDate: DateOnly

    public init(
        parties: [PartyLine],
        partyRepresented: String,
        representedPartyName: String,
        recipients: [ServiceRecipient],
        serviceDate: DateOnly = .today
    ) {
        self.parties = parties
        self.partyRepresented = partyRepresented
        self.representedPartyName = representedPartyName
        self.recipients = recipients
        self.serviceDate = serviceDate
    }
}

/// The user-facing inputs for a Demand Letter. The claim/amount/deadline become the
/// grounded facts the model may use; the rest fill the deterministic letter scaffold.
public struct LetterDraftInput: Sendable, Equatable {
    public var recipientName: String
    public var recipientFirm: String
    public var recipientStreet: String
    public var recipientCity: String
    public var recipientState: String
    public var recipientZip: String
    public var reSubject: String
    public var salutation: String
    public var claimSummary: String
    public var demandAmount: String
    public var responseDeadline: String
    public var tone: String
    public var deliveryNotation: String

    public init(
        recipientName: String = "",
        recipientFirm: String = "",
        recipientStreet: String = "",
        recipientCity: String = "",
        recipientState: String = "",
        recipientZip: String = "",
        reSubject: String = "",
        salutation: String = "",
        claimSummary: String = "",
        demandAmount: String = "",
        responseDeadline: String = "",
        tone: String = "firm",
        deliveryNotation: String = ""
    ) {
        self.recipientName = recipientName
        self.recipientFirm = recipientFirm
        self.recipientStreet = recipientStreet
        self.recipientCity = recipientCity
        self.recipientState = recipientState
        self.recipientZip = recipientZip
        self.reSubject = reSubject
        self.salutation = salutation
        self.claimSummary = claimSummary
        self.demandAmount = demandAmount
        self.responseDeadline = responseDeadline
        self.tone = tone
        self.deliveryNotation = deliveryNotation
    }
}

/// A free-form work-product description for kinds the app can't render yet.
public struct CustomDraftDescriptionInput: Sendable, Equatable {
    public var title: String
    public var description: String
    public var instructions: String

    public init(title: String, description: String, instructions: String = "") {
        self.title = title
        self.description = description
        self.instructions = instructions
    }
}

/// A typed drafting request dispatched by the Draft Workspace.
public enum MatterDraftRequest: Sendable, Equatable {
    case noticeAppearance(NoticeAppearanceDraftInput)
    case customDescription(CustomDraftDescriptionInput)
}

// MARK: - Convenience factory

extension DraftPipeline {
    /// The default chat pipeline: deterministic verifier + the court/letter renderer.
    /// The renderer dispatches on `RenderInput`, so one instance serves both shells.
    public static func makeDefault() -> DraftPipeline {
        DraftPipeline(verifier: DraftVerifier(), renderer: CompositeRenderer())
    }
}
