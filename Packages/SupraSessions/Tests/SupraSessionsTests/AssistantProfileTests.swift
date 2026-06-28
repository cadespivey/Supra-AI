import Foundation
import SupraStore
import XCTest
@testable import SupraSessions

final class AssistantProfileTests: XCTestCase {

    private let base = "BASE PROMPT"

    func testAttachmentsBlockLabelsSourcesAndRequestsCitations() {
        let block = GlobalChatController.attachmentsBlock([
            .init(name: "lease.pdf", text: "Tenant pays rent monthly."),
            .init(name: "notice.txt", text: "Notice dated March 1.")
        ])
        XCTAssertTrue(block.contains("[S1] lease.pdf"))
        XCTAssertTrue(block.contains("[S2] notice.txt"))
        XCTAssertTrue(block.lowercased().contains("cite"), "should ask the model to cite attachment-backed claims")
    }

    func testStoreComposesProfileOverGivenBase() throws {
        let store = try makeStore()
        var profile = AssistantProfile()
        profile.citationStyle = "Bluebook"
        profile.practiceAreas = "Bankruptcy"
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)

        let composed = try XCTUnwrap(store.composedAssistantPrompt(base: "ROUTE TASK PROMPT"))
        XCTAssertTrue(composed.hasPrefix("ROUTE TASK PROMPT"), "the task/route prompt must lead")
        XCTAssertTrue(composed.contains("# User profile"))
        XCTAssertTrue(composed.contains("Bluebook"), "the configured citation style must reach the prompt")
    }

    func testStoreReturnsBaseWhenNoProfileConfigured() throws {
        let store = try makeStore()
        // Nothing saved → base passes through unchanged.
        XCTAssertEqual(store.composedAssistantPrompt(base: "ROUTE TASK PROMPT"), "ROUTE TASK PROMPT")
        // An explicitly empty (unconfigured) profile also falls back to base.
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: AssistantProfile.empty)
        XCTAssertEqual(store.composedAssistantPrompt(base: "ROUTE TASK PROMPT"), "ROUTE TASK PROMPT")
    }

    private func makeStore() throws -> SupraStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    func testEmptyProfileComposesToBaseOnly() {
        let composed = AssistantProfile.empty.composedSystemPrompt(base: base)
        XCTAssertEqual(composed, base)
        XCTAssertFalse(composed.contains("# User profile"))
    }

    func testEmptyProfileWithNilBaseIsEmpty() {
        XCTAssertEqual(AssistantProfile.empty.composedSystemPrompt(base: nil), "")
    }

    func testDefaultStyleSectionIsOmitted() {
        var profile = AssistantProfile()
        profile.practiceAreas = "Commercial litigation"
        let composed = profile.composedSystemPrompt(base: base)
        XCTAssertTrue(composed.contains("# User profile"))
        XCTAssertTrue(composed.contains("## About the user"))
        // Untouched Balanced/Balanced must not inject a style block.
        XCTAssertFalse(composed.contains("## How to write for this user"))
    }

    func testNonDefaultToneIncludesStyleSection() {
        var profile = AssistantProfile()
        profile.formality = .formal
        let composed = profile.composedSystemPrompt(base: base)
        XCTAssertTrue(composed.contains("## How to write for this user"))
        XCTAssertTrue(composed.contains("- Formality: Formal."))
        XCTAssertFalse(composed.contains("Default length"))
    }

    func testVoiceNotesIncludeStyleSectionWithoutDefaults() {
        var profile = AssistantProfile()
        profile.voiceNotes = "Lead with the bottom line."
        let composed = profile.composedSystemPrompt(base: base)
        XCTAssertTrue(composed.contains("- Voice and style: Lead with the bottom line."))
        XCTAssertFalse(composed.contains("- Formality:"))
    }

    func testWritingSampleIsEmbedded() {
        var profile = AssistantProfile()
        profile.writingSamples = [.init(name: "brief.txt", excerpt: "The motion should be granted.")]
        let composed = profile.composedSystemPrompt(base: base)
        XCTAssertTrue(composed.contains("## The user's writing style"))
        XCTAssertTrue(composed.contains("### brief.txt"))
        XCTAssertTrue(composed.contains("The motion should be granted."))
    }

    func testWritingSamplesExcludedInGroundedContexts() {
        var profile = AssistantProfile()
        profile.practiceAreas = "Commercial litigation"
        profile.voiceNotes = "Lead with the bottom line."
        profile.writingSamples = [.init(name: "brief.txt", excerpt: "CONFIDENTIAL FACT: the settlement was $4.2M.")]
        let composed = profile.composedSystemPrompt(base: base, includeWritingSamples: false)
        // The verbatim excerpt (and its facts) must not appear in a grounded context.
        XCTAssertFalse(composed.contains("## The user's writing style"))
        XCTAssertFalse(composed.contains("### brief.txt"))
        XCTAssertFalse(composed.contains("CONFIDENTIAL FACT"))
        // The rest of the profile (identity, voice guidance) still applies.
        XCTAssertTrue(composed.contains("## About the user"))
        XCTAssertTrue(composed.contains("Lead with the bottom line."))
    }

    func testIsConfigured() {
        XCTAssertFalse(AssistantProfile.empty.isConfigured)

        var toneOnly = AssistantProfile()
        toneOnly.length = .concise
        XCTAssertTrue(toneOnly.isConfigured)

        var identityOnly = AssistantProfile()
        identityOnly.role = "Partner"
        XCTAssertTrue(identityOnly.isConfigured)
    }

    // MARK: - Multi-jurisdiction bar (F4)

    func testBarJurisdictionCatalogMatch() {
        XCTAssertEqual(BarJurisdictionCatalog.match("Florida")?.id, "fl")
        XCTAssertEqual(BarJurisdictionCatalog.match("FL")?.id, "fl")
        XCTAssertEqual(BarJurisdictionCatalog.match("fl")?.id, "fl")
        XCTAssertEqual(BarJurisdictionCatalog.match("California state and the Ninth Circuit")?.id, "ca")
        XCTAssertEqual(BarJurisdictionCatalog.match("District of Columbia")?.id, "dc")
        XCTAssertEqual(BarJurisdictionCatalog.match("D.C.")?.id, "dc")
        XCTAssertEqual(BarJurisdictionCatalog.match("D.C. Superior Court")?.id, "dc")
        XCTAssertNil(BarJurisdictionCatalog.match("Unspecified"))
        XCTAssertNil(BarJurisdictionCatalog.match(""))
        XCTAssertEqual(BarJurisdictionCatalog.jurisdiction(id: "fl")?.barLabel, "Florida Bar No.")
        XCTAssertEqual(BarJurisdictionCatalog.jurisdiction(id: "dc")?.barLabel, "D.C. Bar No.")
    }

    func testLegacyBarNumberMigratesToBarLicenseOnDecode() throws {
        var profile = AssistantProfile()
        profile.barNumber = "100847"
        profile.officeState = "Florida"
        // Round-trip through Codable to trigger init(from:) migration.
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AssistantProfile.self, from: data)
        XCTAssertEqual(decoded.barLicenses.count, 1)
        XCTAssertEqual(decoded.barLicenses.first?.jurisdictionID, "fl")
        XCTAssertEqual(decoded.barLicenses.first?.barNumber, "100847")
        XCTAssertEqual(decoded.primaryBarLicenseID, decoded.barLicenses.first?.id)
        XCTAssertEqual(decoded.barNumber, "", "legacy hidden field should be cleared after migration")
        XCTAssertTrue(decoded.hasAnyBarLicense)
    }

    func testHiddenLegacyBarNumberDoesNotSatisfyReadinessAfterStructuredRowsExist() {
        var profile = AssistantProfile()
        profile.fullName = "Harvey Specter"
        profile.organization = "Pearson Specter Litt"
        profile.barNumber = "100847"
        profile.barLicenses = [.init(jurisdictionID: "fl", barNumber: "")]
        profile.officeStreet = "1 Main"
        profile.officeCity = "Jacksonville"
        profile.officeState = "Florida"
        profile.officeZip = "32202"
        profile.officePhone = "904-555-0100"
        profile.primaryEmail = "hspecter@psl.com"

        XCTAssertFalse(profile.hasAnyBarLicense)
        XCTAssertFalse(profile.hasDraftingIdentity)
        XCTAssertNil(profile.resolvedBarLicense(forJurisdiction: "Florida"))
    }

    func testStructuredBarLicenseDeletionDoesNotFallBackToHiddenLegacyValue() {
        var profile = AssistantProfile()
        profile.barNumber = "100847"
        profile.barLicenses = []
        XCTAssertNotNil(profile.resolvedBarLicense(forJurisdiction: "Florida"), "pure legacy in-memory profiles still work")

        profile.barLicenses = [.init(jurisdictionID: "fl", barNumber: "")]
        XCTAssertNil(profile.resolvedBarLicense(forJurisdiction: "Florida"), "once structured rows exist, empty rows must not use hidden legacy data")
    }

    func testFirmProfileMatchesBarLicenseToCourtJurisdiction() {
        var profile = AssistantProfile()
        profile.fullName = "Harvey Specter"
        profile.organization = "Pearson Specter Litt"
        profile.barLicenses = [
            .init(jurisdictionID: "fl", barNumber: "100847"),
            .init(jurisdictionID: "tx", barNumber: "24011223")
        ]
        profile.primaryBarLicenseID = profile.barLicenses[0].id

        // A Texas court → Texas admission prints.
        let tx = MatterDraftingController.firmProfile(from: profile, jurisdiction: "Texas")
        XCTAssertEqual(tx.barNumber, "24011223")
        XCTAssertEqual(tx.barLabel, "Texas Bar No.")

        // No matching admission → primary (Florida) prints.
        let other = MatterDraftingController.firmProfile(from: profile, jurisdiction: "Georgia")
        XCTAssertEqual(other.barNumber, "100847")
        XCTAssertEqual(other.barLabel, "Florida Bar No.")
    }

    func testFirmProfileFallsBackToLegacyBarNumber() {
        var profile = AssistantProfile()
        profile.barNumber = "100847"
        profile.officeState = "Florida"
        // No structured licenses (in-memory profile, no decode) → synthesize from legacy.
        let firm = MatterDraftingController.firmProfile(from: profile)
        XCTAssertEqual(firm.barNumber, "100847")
        XCTAssertEqual(firm.barLabel, "Florida Bar No.")
    }
}
