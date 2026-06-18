import XCTest
@testable import SupraSessions

final class AssistantProfileTests: XCTestCase {

    private let base = "BASE PROMPT"

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
