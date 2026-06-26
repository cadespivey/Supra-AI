import Foundation
import SupraDrafting
import SupraDraftingCore
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
        p.fullName = "Jordan A. Reyes"
        p.organization = "Harwell & Branch, P.A."
        p.barNumber = "100847"
        p.officeStreet = "200 West Forsyth Street"
        p.officeSuite = "Suite 1400"
        p.officeCity = "Jacksonville"
        p.officeState = "Florida"
        p.officeZip = "32202"
        p.officePhone = "(904) 555-0142"
        p.officeFax = "(904) 555-0143"
        p.primaryEmail = "jreyes@harwellbranch.example"
        p.secondaryEmails = ["litdocket@harwellbranch.example"]
        return p
    }

    private func sampleParties() -> [PartyLine] {
        [PartyLine(name: "MERIDIAN CAPITAL PARTNERS, LLC,", designation: "Plaintiff,"),
         PartyLine(name: "ATLANTIC RIDGE HOLDINGS, INC.,", designation: "Defendant.")]
    }

    private func sampleRecipients() -> [ServiceRecipient] {
        [ServiceRecipient(name: "Marcus T. Whitfield, Esq.", firm: "Caldwell & Pierce, LLP",
                          address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                               city: "Jacksonville", state: "Florida", zip: "32202", phone: "", fax: nil),
                          emails: ["mwhitfield@caldwellpierce.example"], role: "Counsel for Plaintiff")]
    }

    // MARK: - Profile → FirmProfile projection

    func testProfileProjectsToFirmProfileSlotsOnly() {
        let firm = MatterDraftingController.firmProfile(from: completeProfile())
        XCTAssertEqual(firm.firmName, "Harwell & Branch, P.A.")
        XCTAssertEqual(firm.signingAttorney, "Jordan A. Reyes")
        XCTAssertEqual(firm.barNumber, "100847")
        XCTAssertEqual(firm.office.suite, "Suite 1400")
        XCTAssertEqual(firm.office.fax, "(904) 555-0143")
        XCTAssertEqual(firm.secondaryEmails, ["litdocket@harwellbranch.example"])
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
        p.fullName = "Jordan A. Reyes"   // only the name
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
            name: "Meridian v. Atlantic Ridge",
            court: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            judge: "CV-G",
            docketNumber: "2026-CA-001847"
        )
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id,
            parties: sampleParties(),
            partyRepresented: "Defendant",
            representedPartyName: "Atlantic Ridge Holdings, Inc.",
            recipients: sampleRecipients(),
            serviceDate: DateOnly(year: 2026, month: 6, day: 25)
        )

        switch result {
        case let .success(artifact):
            XCTAssertEqual(artifact.kind, .noticeAppearance)
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

    // MARK: - Firewall: never invents identity

    @MainActor
    func testIncompleteFirmProfileBlocksWithPreciseFieldsNotInvention() async throws {
        let store = try makeStore()
        var partial = AssistantProfile()
        partial.fullName = "Jordan A. Reyes"
        partial.organization = "Harwell & Branch, P.A."
        // bar number + office deliberately missing
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: partial)
        let matter = try store.matters.createMatter(name: "M", docketNumber: "2026-CA-001847")
        let controller = MatterDraftingController(store: store, storage: makeStorage())

        let result = await controller.draftNoticeOfAppearance(
            matterID: matter.id, parties: sampleParties(),
            partyRepresented: "Defendant", representedPartyName: "Atlantic Ridge Holdings, Inc.",
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
            partyRepresented: "Defendant", representedPartyName: "Atlantic Ridge Holdings, Inc.",
            recipients: sampleRecipients()
        )
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        guard case .missingCaptionField = error else { return XCTFail("expected missingCaptionField, got \(error)") }
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
}
