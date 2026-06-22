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

    func testIsConfigured() {
        XCTAssertFalse(AssistantProfile.empty.isConfigured)

        var toneOnly = AssistantProfile()
        toneOnly.length = .concise
        XCTAssertTrue(toneOnly.isConfigured)

        var identityOnly = AssistantProfile()
        identityOnly.role = "Partner"
        XCTAssertTrue(identityOnly.isConfigured)
    }
}
