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

    func testCompleteSpellingTieBreaksAlphabetically() {
        // Expected RED: the deterministic ranking helper does not exist yet;
        // the existing Dictionary.max has no final tie-break when count/date tie.
        let tiedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(
            ClientDirectory.canonicalSpellingRanksHigher(
                name: "Alpha Holdings",
                count: 1,
                lastUsedAt: tiedAt,
                than: "Zulu Holdings",
                otherCount: 1,
                otherLastUsedAt: tiedAt
            )
        )
        let spellings = [
            "Zulu Holdings", "Yankee Holdings", "Xray Holdings", "Whiskey Holdings",
            "Victor Holdings", "Uniform Holdings", "Tango Holdings", "Alpha Holdings"
        ]
        let directory = ClientDirectory.build(from: spellings.map { row("201", $0, count: 1) })

        XCTAssertEqual(directory.entries.first?.name, "Alpha Holdings")
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

    func testWhitespaceOnlyClientIDRowIsTreatedAsNameOnly() throws {
        // Expected RED: build treats every non-nil client ID as numbered, so a
        // whitespace-only value survives as an unusable client number.
        let directory = ClientDirectory.build(from: [
            row("  \t ", "Northstar Analytics", count: 2)
        ])

        let entry = try XCTUnwrap(directory.entries.first)
        XCTAssertEqual(directory.entries.count, 1)
        XCTAssertNil(entry.clientID)
        XCTAssertEqual(entry.name, "Northstar Analytics")
        XCTAssertEqual(entry.matterCount, 2)
    }

    func testNameOnlyMinorityAliasMergesIntoUniqueNumberedClient() {
        // Expected RED: numbered clients currently retain only their dominant
        // display spelling, so a known minority alias becomes a separate client.
        let directory = ClientDirectory.build(from: [
            row("301", "SmartSky Networks LLC", count: 3),
            row("301", "SmartSky Networks", count: 1),
            row(nil, "smartsky networks", count: 1)
        ])

        XCTAssertEqual(directory.entries.count, 1)
        XCTAssertEqual(directory.entries.first?.clientID, "301")
        XCTAssertEqual(directory.entries.first?.name, "SmartSky Networks LLC")
        XCTAssertEqual(directory.entries.first?.matterCount, 5)
        XCTAssertEqual(directory.suggestions(forName: "smartsky networks").first?.clientID, "301")
        XCTAssertEqual(
            directory.groupIdentity(clientID: nil, clientNames: "SMARTSKY NETWORKS")?.key,
            "id:301"
        )
    }

    func testSharedMinorityAliasRemainsAmbiguous() {
        // Expected RED: the old directory discarded minority aliases entirely;
        // retaining them must not introduce an arbitrary merge when two numbered
        // clients have both used the same alias.
        let directory = ClientDirectory.build(from: [
            row("410", "Pinecrest Holdings", count: 3),
            row("410", "Legacy Client", count: 1),
            row("411", "Harbor Services", count: 3),
            row("411", "Legacy Client", count: 1),
            row(nil, "LEGACY CLIENT", count: 1)
        ])

        XCTAssertEqual(directory.entries.count, 3)
        XCTAssertTrue(directory.entries.contains { $0.clientID == nil && $0.name == "LEGACY CLIENT" })
        XCTAssertEqual(
            Set(directory.suggestions(forName: "legacy client").compactMap(\.clientID)),
            ["410", "411"]
        )
        XCTAssertEqual(
            directory.groupIdentity(clientID: nil, clientNames: "legacy client")?.key,
            "name:legacy client"
        )
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
