import Foundation
import SupraCore
import SupraDrafting
import SupraDraftingCore
import SupraRuntimeInterface
@testable import SupraSessions
import SupraDocuments
import SupraStore
import XCTest

/// End-to-end coverage for the chat document-drafting integration: profile→firm
/// projection, the intent parser, and the controller producing a real downloadable
/// `.docx` — including the firewall guarantees (no invented identity, blocking
/// prompts when data is missing).
final class MatterDraftingControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    private func makeStorage() -> DocumentStorage {
        DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("DraftFiles-\(UUID().uuidString)"))
    }

    private func completeProfile() -> AssistantProfile {
        var p = AssistantProfile()
        p.fullName = "Harvey Specter"
        p.organization = "Pearson Specter Litt"
        p.barNumber = "100847"
        p.officeStreet = "200 West Forsyth Street"
        p.officeSuite = "Suite 1400"
        p.officeCity = "Jacksonville"
        p.officeState = "Florida"
        p.officeZip = "32202"
        p.officePhone = "(904) 555-0142"
        p.officeFax = "(904) 555-0143"
        p.primaryEmail = "hspecter@pearsonspecterlitt.example"
        p.secondaryEmails = ["litdocket@pearsonspecterlitt.example"]
        return p
    }

    private func sampleParties() -> [PartyLine] {
        [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
         PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")]
    }

    private func sampleRecipients() -> [ServiceRecipient] {
        [ServiceRecipient(name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                          address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                               city: "Jacksonville", state: "Florida", zip: "32202", phone: "", fax: nil),
                          emails: ["dhardman@hardmantanner.example"], role: "Counsel for Plaintiff")]
    }

    // MARK: - Profile → FirmProfile projection

    func testProfileProjectsToFirmProfileSlotsOnly() {
        let firm = MatterDraftingController.firmProfile(from: completeProfile())
        XCTAssertEqual(firm.firmName, "Pearson Specter Litt")
        XCTAssertEqual(firm.signingAttorney, "Harvey Specter")
        XCTAssertEqual(firm.barNumber, "100847")
        XCTAssertEqual(firm.office.suite, "Suite 1400")
        XCTAssertEqual(firm.office.fax, "(904) 555-0143")
        XCTAssertEqual(firm.secondaryEmails, ["litdocket@pearsonspecterlitt.example"])
    }

    func testEmptyOptionalOfficeFieldsBecomeNilNotEmptyString() {
        var p = completeProfile()
        p.officeSuite = ""
        p.officeFax = ""
        let firm = MatterDraftingController.firmProfile(from: p)
        XCTAssertNil(firm.office.suite)
        XCTAssertNil(firm.office.fax)
    }

    // MARK: - Drafting identity readiness

    func testProfileMissingIdentityIsNotDraftReady() {
        var p = AssistantProfile()
        p.fullName = "Harvey Specter"   // only the name
        XCTAssertFalse(p.hasDraftingIdentity)
        XCTAssertTrue(p.missingDraftingIdentityFields.contains("bar number"))
        XCTAssertTrue(p.missingDraftingIdentityFields.contains("office street"))
    }

    func testCompleteProfileIsDraftReady() {
        XCTAssertTrue(completeProfile().hasDraftingIdentity)
        XCTAssertTrue(completeProfile().missingDraftingIdentityFields.isEmpty)
    }

    // MARK: - End-to-end: produces a real downloadable .docx

    @MainActor
    func testDraftNoticeProducesOpenableDocxOnDisk() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            judge: "CV-G",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients(),
            serviceDate: DateOnly(year: 2026, month: 6, day: 25)
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.source, .kind(.noticeAppearance))
            XCTAssertEqual(artifact.format, .docx)
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
            XCTAssertEqual(artifact.fileURL.pathExtension, "docx")
            let data = try Data(contentsOf: artifact.fileURL)
            XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "must be a valid OPC zip")
            XCTAssertFalse(artifact.hasBlocking, "a complete notice should raise no blocking follow-ups")
        case let .failure(error):
            XCTFail("expected success, got \(error)")
        }

        // Audit event recorded.
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertTrue(events.contains { $0.eventType == "draft_generated" })
    }

    // MARK: - Multi-kind request layer

    @MainActor
    func testAvailableDraftKindsEnablesOnlyWiredNoticeWithReasons() throws {
        let store = try makeStore()
        let controller = MatterDraftingController(store: store, storage: makeStorage())
        let kinds = controller.availableDraftKinds()

        XCTAssertEqual(kinds.count, DraftKindID.allCases.count)
        let notice = kinds.first { $0.id == .noticeAppearance }
        XCTAssertEqual(notice?.isEnabled, true)
        XCTAssertNil(notice?.disabledReason)
        // The other kinds exist in the registry but are NOT wired, so they must be
        // disabled with a reason — not silently hidden or wrongly enabled.
        for kind in [DraftKindID.motionToDismiss, .letterDemand] {
            let availability = kinds.first { $0.id == kind }
            XCTAssertEqual(availability?.isEnabled, false, "\(kind) should be disabled")
            XCTAssertNotNil(availability?.disabledReason, "\(kind) needs a disabled reason")
        }
    }

    @MainActor
    func testCustomDescriptionWritesLabeledMarkdownArtifact() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail", docketNumber: "2026-CA-001847")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draft(
            .customDescription(CustomDraftDescriptionInput(
                title: "Reply brief outline",
                description: "Outline a reply addressing the statute-of-frauds defense.",
                instructions: "Keep it to three points."
            )),
            matterID: matter.id
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.source, .customDescription)
            XCTAssertEqual(artifact.format, .markdown)
            XCTAssertEqual(artifact.fileURL.pathExtension, "md")
            XCTAssertFalse(artifact.hasBlocking)
            // The artifact is clearly labeled as a description, not a filing, and carries
            // the user's words + matter context (no invented content).
            let body = try String(contentsOf: artifact.fileURL, encoding: .utf8)
            XCTAssertTrue(body.contains("not a court-ready filing"))
            XCTAssertTrue(body.contains("statute-of-frauds defense"))
            XCTAssertTrue(body.contains("2026-CA-001847"))
            XCTAssertTrue(body.contains("Keep it to three points."))
        case let .failure(error):
            XCTFail("expected success, got \(error)")
        }
    }

    @MainActor
    func testCustomDescriptionRequiresNonEmptyDescription() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "M")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draft(
            .customDescription(CustomDraftDescriptionInput(title: "Untitled", description: "   ")),
            matterID: matter.id
        )

        guard case .failure(.emptyDescription) = result else {
            return XCTFail("expected .emptyDescription, got \(result)")
        }
    }

    // MARK: - Demand Letter (LLM-backed)

    @MainActor
    func testLetterDemandEnabledOnlyWhenRuntimePresent() throws {
        let store = try makeStore()
        // No runtime → letter disabled-with-reason.
        let offline = MatterDraftingController(store: store, storage: makeStorage())
        let letterOffline = offline.availableDraftKinds().first { $0.id == .letterDemand }
        XCTAssertEqual(letterOffline?.isEnabled, false)
        XCTAssertNotNil(letterOffline?.disabledReason)
        // Runtime present → letter enabled.
        let online = MatterDraftingController(store: store, runtimeClient: StubRuntimeClient(), storage: makeStorage())
        let letterOnline = online.availableDraftKinds().first { $0.id == .letterDemand }
        XCTAssertEqual(letterOnline?.isEnabled, true)
        XCTAssertNil(letterOnline?.disabledReason)
    }

    @MainActor
    func testDraftLetterDemandProducesOpenableDocx() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let body = #"{"paragraphs":[{"text":"The defendant has not paid the $42,000 invoice due under the supply agreement.","factLabels":["claim"],"citationLabels":[]},{"text":"Demand is made for $42,000 by July 15, 2026.","factLabels":["demandAmount","responseDeadline"],"citationLabels":[]},{"text":"Govern yourself accordingly.","factLabels":[],"citationLabels":[]}]}"#
        let runtime = StubRuntimeClient(outcome: { request in
            // The drafting model is invoked with the fact-scoped prompt.
            XCTAssertTrue(request.prompt.contains("untrustedText"))
            XCTAssertTrue(request.systemPrompt?.contains("SECURITY BOUNDARY") == true)
            return .events([
                .event(request, 0, .token, token: body),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = MatterDraftingController(store: store, runtimeClient: runtime, storage: makeStorage())

        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.",
            recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville",
            recipientState: "Florida",
            recipientZip: "32202",
            reSubject: "Unpaid invoice #4471",
            claimSummary: "The defendant has not paid the $42,000 invoice due under the supply agreement.",
            demandAmount: "$42,000",
            responseDeadline: "July 15, 2026",
            tone: "firm"
        )
        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: input,
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.source, .kind(.letterDemand))
            XCTAssertEqual(artifact.format, .docx)
            XCTAssertEqual(artifact.fileURL.pathExtension, "docx")
            let data = try Data(contentsOf: artifact.fileURL)
            XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "must be a valid OPC zip")
        case let .failure(error):
            XCTFail("expected success, got \(error)")
        }
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testLetterBodyScanBlocksCitationsAndPlaceholdersWithoutSideEffects() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        // A non-compliant model reply: it cites a case and leaves a [fact?] placeholder.
        let body = "As held in Smith v. Jones, your client must pay.\n\nThe balance of [fact?] remains outstanding."
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: body), .event(request, 1, .generationCompleted)])
        })
        let storage = makeStorage()
        let renderer = StyleSpyRenderer()
        let controller = MatterDraftingController(
            store: store,
            runtimeClient: runtime,
            storage: storage,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )

        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: LetterDraftInput(recipientName: "X", recipientStreet: "1 Main", recipientCity: "Jax",
                                    recipientState: "FL", recipientZip: "32202", claimSummary: "Unpaid balance"),
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )

        guard case .failure(.verificationBlocked) = result else {
            return XCTFail("unsafe prose must return a typed block, not a file with review notes")
        }
        XCTAssertEqual(renderer.renderCount, 0, "unsafe prose reached the renderer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.exportsDirectory(forMatterID: matter.id).path))
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testStructuredUnsupportedLetterHasNoRenderFileOrAuditSideEffects() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors")
        let response = #"{"paragraphs":[{"text":"The debtor committed fraud.","factLabels":["claim"],"citationLabels":[]}]}"#
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: response), .event(request, 1, .generationCompleted)])
        })
        let storage = makeStorage()
        let renderer = StyleSpyRenderer()
        let controller = MatterDraftingController(
            store: store,
            runtimeClient: runtime,
            storage: storage,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: renderer) }
        )

        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: LetterDraftInput(
                recipientName: "X", recipientStreet: "1 Main", recipientCity: "Jax",
                recipientState: "FL", recipientZip: "32202", claimSummary: "The invoice remains unpaid."
            ),
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )

        guard case .failure(.verificationBlocked) = result else {
            return XCTFail("unsupported structured output must return a typed block")
        }
        XCTAssertEqual(renderer.renderCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.exportsDirectory(forMatterID: matter.id).path))
        XCTAssertFalse(try store.auditEvents.fetchEvents(matterID: matter.id).contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testDraftLetterDemandRequiresClaim() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "M")
        let controller = MatterDraftingController(store: store, runtimeClient: StubRuntimeClient(), storage: makeStorage())

        let result = await controller.draftLetterDemand(
            matterID: matter.id,
            input: LetterDraftInput(recipientName: "X", claimSummary: "   "),
            modelID: ModelID(),
            route: ModelRouter().route(for: .drafting)
        )
        guard case .failure = result else {
            return XCTFail("expected failure when the claim is empty")
        }
    }

    // MARK: - Firewall: never invents identity

    @MainActor
    func testIncompleteFirmProfileBlocksWithPreciseFieldsNotInvention() async throws {
        let store = try makeStore()
        var partial = AssistantProfile()
        partial.fullName = "Harvey Specter"
        partial.organization = "Pearson Specter Litt"
        // bar number + office deliberately missing
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: partial)
        let matter = try store.matters.createMatter(name: "M", docketNumber: "2026-CA-001847")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .incompleteFirmProfile(missing) = error else { return XCTFail("expected incompleteFirmProfile, got \(error)") }
        XCTAssertTrue(missing.contains("bar number"))
        // No file was written.
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertFalse(events.contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testMissingCaseNumberBlocksRatherThanGuessing() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "No docket matter")  // no docketNumber
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case .missingCaptionField = error else { return XCTFail("expected missingCaptionField, got \(error)") }
    }

    @MainActor
    func testEmptyServiceRecipientsBlockBeforeRendering() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: []
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .missingRequiredSlots(missing) = error else {
            return XCTFail("expected missingRequiredSlots, got \(error)")
        }
        XCTAssertTrue(missing.contains("service recipients"))
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        XCTAssertFalse(events.contains { $0.eventType == "draft_generated" })
    }

    @MainActor
    func testIncompleteCaptionBlocksBeforeRendering() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "")],
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .missingRequiredSlots(missing) = error else {
            return XCTFail("expected missingRequiredSlots, got \(error)")
        }
        XCTAssertTrue(missing.contains("complete caption parties"))
        XCTAssertTrue(missing.contains("caption party 1 designation"))
    }

    @MainActor
    func testInvalidRecipientEmailBlocksBeforeRendering() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            docketNumber: "2026-CA-001847"
        )
        var recipients = sampleRecipients()
        recipients[0].emails = ["not-an-email"]
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: recipients
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case let .missingRequiredSlots(missing) = error else {
            return XCTFail("expected missingRequiredSlots, got \(error)")
        }
        XCTAssertTrue(missing.contains("valid service recipient 1 service e-mail"))
    }

    @MainActor
    func testNonFloridaNoticeDraftingIsBlocked() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "Texas Matter",
            jurisdiction: "Texas",
            court: "IN THE DISTRICT COURT OF TRAVIS COUNTY, TEXAS",
            docketNumber: "2026-CI-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients()
        )

        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case .unsupportedJurisdiction = error else {
            return XCTFail("expected unsupportedJurisdiction, got \(error)")
        }
    }

    // MARK: - Intent parser

    func testParserRecognizesExplicitSlashCommand() {
        let match = DraftRequestParser.parse("/draft notice of appearance")
        XCTAssertEqual(match?.kind, .noticeAppearance)
        XCTAssertEqual(match?.isExplicitCommand, true)
    }

    func testParserRecognizesNaturalLanguageDraftRequest() {
        XCTAssertEqual(DraftRequestParser.parse("Please draft a notice of appearance for this matter")?.kind, .noticeAppearance)
        XCTAssertEqual(DraftRequestParser.parse("prepare a motion to dismiss")?.kind, .motionToDismiss)
        XCTAssertEqual(DraftRequestParser.parse("generate a demand letter")?.kind, .letterDemand)
    }

    func testParserDoesNotFireOnAQuestionAboutTheDocument() {
        // A question, no drafting verb → must not trigger a file generation.
        XCTAssertNil(DraftRequestParser.parse("what is a notice of appearance?"))
        XCTAssertNil(DraftRequestParser.parse("does the motion to dismiss standard apply here"))
    }

    func testParserReturnsNilForNonDraftingChat() {
        XCTAssertNil(DraftRequestParser.parse("summarize the deposition transcript"))
        XCTAssertNil(DraftRequestParser.parse(""))
    }

    // MARK: - M1-T7: effectiveStyle() + firmStyleProfile injection (controller wiring)

    // T-CTRL-01 — no profile ⇒ effectiveStyle() is exactly .defaultFL (invariant 5).
    // RED: undefined member `effectiveStyle` / `firmStyleProfile`.
    @MainActor
    func testEffectiveStyleWithoutProfileIsDefaultFL() throws {
        let store = try makeStore()
        let controller = MatterDraftingController(store: store, storage: makeStorage())
        XCTAssertEqual(controller.effectiveStyle(), HouseStyleSheet.defaultFL)
    }

    // T-CTRL-04 — a below-floor profile is clamped to 24/1440 through the controller (invariant 1).
    @MainActor
    func testBelowFloorProfileClampedThroughController() throws {
        let store = try makeStore()
        var p = FirmStyleProfile()
        p.pageFontHalfPoints = 20
        p.pageMarginTwips = EdgeInsets(top: 720, leading: 720, bottom: 720, trailing: 720)
        let controller = MatterDraftingController(store: store, storage: makeStorage(), firmStyleProfile: p)
        XCTAssertEqual(controller.effectiveStyle().page.fontHalfPoints, 24)
        XCTAssertNotEqual(controller.effectiveStyle().page.fontHalfPoints, 20)
        XCTAssertEqual(controller.effectiveStyle().page.marginTwips.leading, 1440)
    }

    // T-CTRL-05 — the APP path: with NO injected profile, effectiveStyle() falls back to the
    // profile PERSISTED in the store (FirmStyleProfileController's autosave target), read fresh
    // so Settings edits apply at the next draft without reconstructing the controller.
    // WIRE-PROOF at the fallback layer. RED: effectiveStyle() ignores the store ⇒ "CASE NO.: ".
    @MainActor
    func testEffectiveStyleFallsBackToStoredProfile() throws {
        let store = try makeStore()
        var p = FirmStyleProfile()
        p.captionCaseNumberLabel = "CASE NUMBER: "
        try store.appSettings.setSetting(FirmStyleProfile.profileKey, value: p)

        let controller = MatterDraftingController(store: store, storage: makeStorage()) // no injection
        XCTAssertEqual(controller.effectiveStyle().caption.caseNumberLabel, "CASE NUMBER: ")
        XCTAssertNotEqual(controller.effectiveStyle().caption.caseNumberLabel, "CASE NO.: ")
    }

    // T-CTRL-02 — the Notice path passes effectiveStyle() (not .defaultFL) into runNotice.
    // WIRE-PROOF: a non-default caseNumberLabel is captured by a spy renderer.
    @MainActor
    func testNoticePassesEffectiveStyleToRunNotice() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(
            name: "McKernon Motors v. Liberty Rail",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            judge: "CV-G",
            docketNumber: "2026-CA-001847"
        )
        let spy = StyleSpyRenderer()
        var p = FirmStyleProfile()
        p.captionCaseNumberLabel = "CASE NUMBER: "
        let controller = MatterDraftingController(
            store: store, storage: makeStorage(), firmStyleProfile: p,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: spy) })

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Liberty Rail, LLC",
            recipients: sampleRecipients(), serviceDate: DateOnly(year: 2026, month: 6, day: 25))
        if case let .failure(error) = result { XCTFail("draft failed before render: \(error)") }

        let captured = try XCTUnwrap(spy.captured, "renderer never received a style")
        XCTAssertEqual(captured.caption.caseNumberLabel, "CASE NUMBER: ")   // effectiveStyle reached the renderer
        XCTAssertNotEqual(captured.caption.caseNumberLabel, "CASE NO.: ")   // not the default sheet
    }

    // T-CTRL-03 — the Letter path passes effectiveStyle() into runLetter. WIRE-PROOF via tagline.
    @MainActor
    func testLetterPassesEffectiveStyleToRunLetter() async throws {
        let store = try makeStore()
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: completeProfile())
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let body = #"{"paragraphs":[{"text":"The defendant has not paid the $42,000 invoice due under the supply agreement.","factLabels":["claim"],"citationLabels":[]}]}"#
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: body), .event(request, 1, .generationCompleted)])
        })
        let spy = StyleSpyRenderer()
        var p = FirmStyleProfile()
        p.letterheadTagline = "Counselors at Law"
        let controller = MatterDraftingController(
            store: store, runtimeClient: runtime, storage: makeStorage(), firmStyleProfile: p,
            pipelineFactory: { DraftPipeline(verifier: DraftVerifier(), renderer: spy) })

        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.", recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville", recipientState: "Florida", recipientZip: "32202",
            reSubject: "Unpaid invoice #4471",
            claimSummary: "The defendant has not paid the $42,000 invoice due under the supply agreement.",
            demandAmount: "$42,000", responseDeadline: "July 15, 2026", tone: "firm")
        let result = await controller.draftLetterDemand(
            matterID: matter.id, input: input, modelID: ModelID(),
            route: ModelRouter().route(for: .drafting))
        if case let .failure(error) = result { XCTFail("draft failed before render: \(error)") }

        let captured = try XCTUnwrap(spy.captured, "renderer never received a style")
        XCTAssertEqual(captured.letterhead?.headerBlock.tagline, "Counselors at Law")
        XCTAssertNotEqual(captured.letterhead?.headerBlock.tagline, "Attorneys at Law")
    }

    // MARK: - M4-T1: Track B voice (prose register only — never structure)

    // T-VOICE-01a — the register helper enriches from the saved AssistantProfile style surface;
    // an unconfigured profile yields exactly the canned tone phrase (prompt parity).
    // RED: undefined `MatterDraftingController.voiceRegister(tone:profile:)`.
    func testRegisterNotesEnrichedFromAssistantProfile() {
        var styled = completeProfile()
        styled.voiceNotes = "terse, aggressive"
        styled.formality = .plainSpoken
        let enriched = MatterDraftingController.voiceRegister(tone: "firm", profile: styled)
        XCTAssertTrue(enriched.contains("terse"))                          // voiceNotes present
        XCTAssertTrue(enriched.contains("firm but professional"))          // base tone kept

        let plain = MatterDraftingController.voiceRegister(tone: "firm", profile: .empty)
        XCTAssertEqual(plain, "firm but professional")                     // unconfigured ⇒ unchanged
        XCTAssertFalse(plain.contains("terse"))
    }

    // T-VOICE-01b — WIRE-PROOF through the real letter path: the drafting prompt the runtime
    // receives carries the attorney's voiceNotes cue. If the generation closure never fires,
    // the draft fails ("no letter body") and the XCTFail below trips — no silent skip.
    @MainActor
    func testLetterPromptCarriesEnrichedRegister() async throws {
        let store = try makeStore()
        var styled = completeProfile()
        styled.voiceNotes = "terse, aggressive"
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: styled)
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertTrue(request.prompt.contains("terse"),
                          "drafting prompt must carry the attorney's voiceNotes register cue")
            return .events([
                .event(request, 0, .token, token: #"{"paragraphs":[{"text":"The defendant has not paid the $42,000 invoice due under the supply agreement.","factLabels":["claim"],"citationLabels":[]}]}"#),
                .event(request, 1, .generationCompleted)
            ])
        })
        let controller = MatterDraftingController(store: store, runtimeClient: runtime, storage: makeStorage())

        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.", recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville", recipientState: "Florida", recipientZip: "32202",
            reSubject: "Unpaid invoice #4471",
            claimSummary: "The defendant has not paid the $42,000 invoice due under the supply agreement.",
            demandAmount: "$42,000", responseDeadline: "July 15, 2026", tone: "firm")
        let result = await controller.draftLetterDemand(
            matterID: matter.id, input: input, modelID: ModelID(),
            route: ModelRouter().route(for: .drafting))
        if case let .failure(error) = result { XCTFail("draft failed: \(error)") }
    }

    // T-VOICE-02 — STANDING GUARD (GREEN from HEAD, no pre-implementation RED — justified in the
    // TESTPLAN): the voice carrier and the generation output must never grow a structural field.
    // Fails only if a future change adds one (invariant 3: no model-originated structure).
    func testVoiceCarriesNoStructure() {
        let voice = AssistantVoiceProfile(registerNotes: "x")
        XCTAssertEqual(Mirror(reflecting: voice).children.compactMap(\.label), ["registerNotes"])

        let letter = GeneratedLetter(paragraphProvenance: [])
        XCTAssertEqual(Mirror(reflecting: letter).children.compactMap(\.label),
                       ["paragraphProvenance"])
    }
}

/// Captures the `style:` argument the pipeline forwards to the renderer, so the controller
/// wiring tests can prove `effectiveStyle()` (not `.defaultFL`) reaches the render call. Returns
/// dummy bytes — the tests inspect the captured sheet, not the document. `@unchecked Sendable`
/// is safe here: the render happens on the controller's @MainActor and the test awaits it.
final class StyleSpyRenderer: Renderer, @unchecked Sendable {
    private(set) var captured: HouseStyleSheet?
    private(set) var renderCount = 0
    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        renderCount += 1
        captured = style
        return Data()
    }
}
