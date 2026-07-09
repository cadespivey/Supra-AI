import Foundation
import SupraStore
@testable import SupraSessions
import XCTest

final class PracticeAreaTests: XCTestCase {
    private func row(_ name: String, count: Int = 1) -> MattersRepository.PracticeAreaUsageRow {
        MattersRepository.PracticeAreaUsageRow(name: name, matterCount: count)
    }

    // MARK: - Directory

    func testDominantSpellingWinsAcrossCaseVariants() {
        let directory = PracticeAreaDirectory.build(from: [
            row("commercial litigation", count: 1),
            row("Commercial Litigation", count: 3)
        ])

        XCTAssertEqual(directory.entries.count, 1)
        XCTAssertEqual(directory.entries.first?.name, "Commercial Litigation")
        XCTAssertEqual(directory.entries.first?.matterCount, 4)
    }

    func testSuggestionsSubstringMatchPrefixFirst() {
        let directory = PracticeAreaDirectory.build(from: [
            row("Commercial Litigation", count: 5),
            row("Litigation", count: 1),
            row("Real Estate", count: 2)
        ])

        // Both litigation entries match; the prefix match leads despite usage.
        XCTAssertEqual(directory.suggestions(for: "liti").map(\.name), ["Litigation", "Commercial Litigation"])
        XCTAssertEqual(directory.suggestions(for: "REAL").map(\.name), ["Real Estate"])
        XCTAssertTrue(directory.suggestions(for: " ").isEmpty)
    }

    func testIsApplied() {
        let directory = PracticeAreaDirectory.build(from: [row("Construction", count: 2)])
        let entry = directory.entries[0]
        XCTAssertTrue(directory.isApplied(entry, text: " Construction "))
        XCTAssertFalse(directory.isApplied(entry, text: "construction"))
    }

    // MARK: - Folder templates

    func testTemplateSelectionByKeyword() {
        XCTAssertEqual(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "Commercial Litigation"),
            ["Pleadings", "Discovery", "Motions", "Exhibits", "Correspondence", "Research", "Drafts"]
        )
        // More specific templates win over the broad litigation match.
        XCTAssertTrue(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "Construction Litigation")
                .contains("Change Orders")
        )
        XCTAssertTrue(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "Real Estate — Leasing")
                .contains("Title & Survey")
        )
        // Unknown or empty practice areas fall back to the general set.
        XCTAssertEqual(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "Admiralty"),
            PracticeAreaFolderTemplates.generalFolders
        )
        XCTAssertEqual(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "  "),
            PracticeAreaFolderTemplates.generalFolders
        )
    }

    func testTemplateMatchingIsWholeWordNotSubstring() {
        // "Intellectual Property" must not match real estate's old "property"
        // substring — no IP template exists, so it gets the general set.
        XCTAssertEqual(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "Intellectual Property"),
            PracticeAreaFolderTemplates.generalFolders
        )
        // "Property Insurance Litigation" is litigation, not real estate.
        XCTAssertEqual(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "Property Insurance Litigation"),
            ["Pleadings", "Discovery", "Motions", "Exhibits", "Correspondence", "Research", "Drafts"]
        )
        // Multi-word phrases still match across punctuation and case.
        XCTAssertTrue(
            PracticeAreaFolderTemplates.folders(forPracticeArea: "REAL-ESTATE (commercial)")
                .contains("Title & Survey")
        )
    }

    func testLitigationVariantOfSubjectTemplateAddsAdversarialBasics() {
        // "Real Estate Litigation" keeps the subject-matter folders but gains
        // Pleadings/Discovery, which plain real estate doesn't carry.
        let folders = PracticeAreaFolderTemplates.folders(forPracticeArea: "Real Estate Litigation")
        XCTAssertTrue(folders.contains("Title & Survey"))
        XCTAssertTrue(folders.contains("Pleadings"))
        XCTAssertTrue(folders.contains("Discovery"))
        // No duplicates when the template already has them (construction has
        // Pleadings; only Discovery is added).
        let construction = PracticeAreaFolderTemplates.folders(forPracticeArea: "Construction Litigation")
        XCTAssertEqual(construction.filter { $0 == "Pleadings" }.count, 1)
        XCTAssertTrue(construction.contains("Discovery"))
    }
}
