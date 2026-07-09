import Foundation
import SupraStore
@testable import SupraSessions
import XCTest

final class ClientDirectoryTests: XCTestCase {
    private func row(
        _ clientID: String?,
        _ name: String?,
        count: Int = 1,
        lastUsed: Date = Date(timeIntervalSince1970: 0)
    ) -> MattersRepository.ClientUsageRow {
        MattersRepository.ClientUsageRow(
            clientID: clientID,
            clientNames: name,
            matterCount: count,
            lastUsedAt: lastUsed
        )
    }

    func testDominantSpellingWinsPerClientNumber() {
        let directory = ClientDirectory.build(from: [
            row("100", "Fritz Martin Cabinetry", count: 1),
            row("100", "Fritz Martin Cabinetry LLC", count: 3),
            row("100", nil, count: 2)
        ])

        XCTAssertEqual(directory.entries.count, 1)
        XCTAssertEqual(directory.entries.first?.clientID, "100")
        XCTAssertEqual(directory.entries.first?.name, "Fritz Martin Cabinetry LLC")
        XCTAssertEqual(directory.entries.first?.matterCount, 6)
    }

    func testSpellingTieBreaksToMostRecentlyUsed() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let directory = ClientDirectory.build(from: [
            row("200", "Vistage FL", count: 2, lastUsed: older),
            row("200", "Vistage Florida", count: 2, lastUsed: newer)
        ])

        XCTAssertEqual(directory.entries.first?.name, "Vistage Florida")
    }

    func testNameOnlyRowsMergeIntoUniqueNumberedClient() {
        let directory = ClientDirectory.build(from: [
            row("300", "SmartSky Networks LLC", count: 2),
            row(nil, "smartsky networks llc", count: 1)
        ])

        // Same client, one matter missing its number: one entry, counts combined,
        // so typing the name recommends the number.
        XCTAssertEqual(directory.entries.count, 1)
        XCTAssertEqual(directory.entries.first?.clientID, "300")
        XCTAssertEqual(directory.entries.first?.matterCount, 3)
    }

    func testAmbiguousNameOnlyRowStaysStandalone() {
        let directory = ClientDirectory.build(from: [
            row("400", "First American Title Insurance Co.", count: 1),
            row("401", "First American Title Insurance Co.", count: 1),
            row(nil, "First American Title Insurance Co.", count: 1)
        ])

        // Two client numbers share the name — don't guess which one the
        // name-only matter belongs to.
        XCTAssertEqual(directory.entries.count, 3)
        XCTAssertTrue(directory.entries.contains { $0.clientID == nil })
    }

    func testNumberSuggestionsPrefixMatchExactFirst() {
        let directory = ClientDirectory.build(from: [
            row("10", "Ten Co.", count: 1),
            row("100", "Hundred Co.", count: 5),
            row("200", "Other Co.", count: 1)
        ])

        let matches = directory.suggestions(forNumber: "10")
        // "100" is more used, but the exact match leads.
        XCTAssertEqual(matches.map(\.clientID), ["10", "100"])
        XCTAssertTrue(directory.suggestions(forNumber: "2").map(\.clientID) == ["200"])
        XCTAssertTrue(directory.suggestions(forNumber: "9").isEmpty)
        XCTAssertTrue(directory.suggestions(forNumber: "  ").isEmpty)
    }

    func testNameSuggestionsSubstringMatchPrefixFirst() {
        let directory = ClientDirectory.build(from: [
            row("500", "Atlantic Rail Partners", count: 1),
            row("501", "Gulf & Atlantic Railroad", count: 5)
        ])

        let matches = directory.suggestions(forName: "atlantic")
        // Both match, but the prefix match leads despite lower usage.
        XCTAssertEqual(matches.map(\.clientID), ["500", "501"])
        // Diacritic- and case-insensitive.
        XCTAssertEqual(directory.suggestions(forName: "GÜLF").map(\.clientID), ["501"])
        XCTAssertTrue(directory.suggestions(forName: "").isEmpty)
    }

    func testGroupIdentityMergesSpellingsAndNameOnlyMatters() {
        let directory = ClientDirectory.build(from: [
            row("700", "Fritz Martin Cabinetry LLC", count: 2),
            row(nil, "fritz martin cabinetry llc", count: 1),
            row(nil, "Solo Name Client", count: 1)
        ])

        // Numbered matter: id key, canonical label regardless of its own spelling.
        let numbered = directory.groupIdentity(clientID: "700", clientNames: "fritz martin cabinetry llc")
        XCTAssertEqual(numbered?.key, "id:700")
        XCTAssertEqual(numbered?.label, "Fritz Martin Cabinetry LLC")

        // A name-only matter joins the numbered client it unambiguously matches.
        let nameOnly = directory.groupIdentity(clientID: nil, clientNames: "FRITZ MARTIN CABINETRY LLC")
        XCTAssertEqual(nameOnly?.key, "id:700")
        XCTAssertEqual(nameOnly?.label, "Fritz Martin Cabinetry LLC")

        // A standalone name-only client keys on the folded name.
        let solo = directory.groupIdentity(clientID: nil, clientNames: "solo name client")
        XCTAssertEqual(solo?.key, "name:solo name client")
        XCTAssertEqual(solo?.label, "Solo Name Client")

        XCTAssertNil(directory.groupIdentity(clientID: nil, clientNames: "  "))
        XCTAssertNil(directory.groupIdentity(clientID: nil, clientNames: nil))
    }

    func testGroupIdentityKeepsAmbiguousNamesApart() {
        let directory = ClientDirectory.build(from: [
            row("800", "First American Title", count: 1),
            row("801", "First American Title", count: 1)
        ])

        // Two numbered clients share the name — a name-only matter joins neither.
        let ambiguous = directory.groupIdentity(clientID: nil, clientNames: "first american title")
        XCTAssertEqual(ambiguous?.key, "name:first american title")
        XCTAssertEqual(directory.groupIdentity(clientID: "801", clientNames: nil)?.key, "id:801")
    }

    func testEntryForNumberAndIsApplied() throws {
        let directory = ClientDirectory.build(from: [
            row("600", "VyStar Credit Union", count: 2)
        ])

        let entry = try XCTUnwrap(directory.entry(forNumber: " 600 "))
        XCTAssertEqual(entry.name, "VyStar Credit Union")
        XCTAssertNil(directory.entry(forNumber: "601"))

        XCTAssertTrue(directory.isApplied(entry, number: "600", name: "VyStar Credit Union"))
        XCTAssertFalse(directory.isApplied(entry, number: "600", name: "VyStar CU"))
        XCTAssertFalse(directory.isApplied(entry, number: "", name: "VyStar Credit Union"))
    }
}
