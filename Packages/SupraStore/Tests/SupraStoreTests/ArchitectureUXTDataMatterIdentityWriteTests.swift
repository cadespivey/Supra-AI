import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Store-owned RED contract for the Matter Create/Edit boundary that must land
/// before native app wiring. One command commits the canonical court identity,
/// explicit parties, and their representations as a coherent revision.
///
/// Expected RED: `MatterIdentityCreateCommand`, `MatterIdentityUpdateCommand`,
/// and the corresponding `MatterIdentityRepository.createMatter(command:)` and
/// `updateMatter(command:)` APIs do not exist. The current APIs can create or
/// edit legacy matter strings, but cannot atomically publish the structured
/// identity graph used by drafting and research.
final class ArchitectureUXTDataMatterIdentityWriteTests: XCTestCase {
    private let matterID = "matter-write-913"
    private let clientPartyID = "party-client-917"
    private let opponentPartyID = "party-opponent-919"
    private let representationID = "representation-923"

    private let catalogVersion = "jurisdiction-courts-v1"
    private let catalogDigest =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"
    private let jurisdictionID =
        "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    private let districtCourtID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
    private let bankruptcyCourtID =
        "federal-florida-united-states-bankruptcy-court-for-the-southern-district-of-florida"

    private let legacyClientNames =
        "Legacy Alpha Client 929; Legacy Beta Client 937 — preserve, never split"

    func testCanonicalCreatePersistsOnlyTheExplicitIdentityGraphAndIsRetrySafe() throws {
        let store = try SupraStore.inMemory()
        let command = makeCreateCommand()

        let created: MatterIdentitySnapshot = try store.matterIdentity.createMatter(
            command: command
        )
        assertCreatedSnapshot(created)

        let exactRetry: MatterIdentitySnapshot = try store.matterIdentity.createMatter(
            command: command
        )
        XCTAssertEqual(exactRetry, created)
        assertPersistedCounts(
            store,
            matterID: matterID,
            matters: 1,
            parties: 2,
            representations: 1,
            sourceReceipts: 1
        )
        try store.database.writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT legacy_client_names
                        FROM matter_identity_conversion_receipts
                        WHERE matter_id = ? AND identity_revision = 1
                        """,
                    arguments: [matterID]
                ),
                legacyClientNames,
                "the compatibility string is preserved only as source evidence"
            )
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT display_name FROM matter_parties WHERE matter_id = ? ORDER BY caption_order",
                    arguments: [matterID]
                ),
                ["Harbor Logistics, Inc.", "Meridian Fabrication, LLC"]
            )
        }

        let conflictingRetry = MatterIdentityCreateCommand(
            matterID: matterID,
            name: "Conflicting duplicate matter 941",
            legacyJurisdictionText: "Florida",
            legacyCourtText: "S.D. Fla.",
            legacyPartyPerspective: .defendant,
            legacyClientNames: legacyClientNames,
            courtResolutionState: .court,
            canonicalCatalogVersion: catalogVersion,
            canonicalCatalogDigestSHA256: catalogDigest,
            canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdictionID),
            canonicalCourtID: CanonicalCourtID(rawValue: districtCourtID),
            parties: makeParties(clientStatus: .represented),
            representations: makeRepresentations(
                matterID: matterID,
                representedPartyID: opponentPartyID,
                representativeName: "Avery Quinn, Esq."
            )
        )
        XCTAssertThrowsError(
            try store.matterIdentity.createMatter(command: conflictingRetry)
        )
        XCTAssertEqual(
            try store.matterIdentity.fetchSnapshot(matterID: matterID),
            created,
            "a conflicting retry must not replace an already-published identity"
        )
    }

    func testCrossMatterGraphFailureRollsBackEveryCreateSideEffect() throws {
        let store = try SupraStore.inMemory()
        let foreignMatter = try store.matters.createMatter(name: "Foreign wire matter 947")
        let targetMatterID = "matter-atomic-953"
        let foreignPartyID = "party-foreign-959"

        let invalid = MatterIdentityCreateCommand(
            matterID: targetMatterID,
            name: "Atomic graph wire 953",
            legacyJurisdictionText: "Florida",
            legacyCourtText: "S.D. Fla.",
            legacyPartyPerspective: .neutral,
            legacyClientNames: "Legacy source 961",
            courtResolutionState: .court,
            canonicalCatalogVersion: catalogVersion,
            canonicalCatalogDigestSHA256: catalogDigest,
            canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdictionID),
            canonicalCourtID: CanonicalCourtID(rawValue: districtCourtID),
            parties: [
                MatterPartyIdentity(
                    id: "party-target-957",
                    matterID: targetMatterID,
                    displayName: "Target Party 957",
                    captionName: "TARGET PARTY 957,",
                    baseRole: .plaintiff,
                    captionOrder: 0,
                    clientStatus: .represented
                ),
                MatterPartyIdentity(
                    id: foreignPartyID,
                    matterID: foreignMatter.id,
                    displayName: "Foreign Party 959",
                    captionName: "FOREIGN PARTY 959,",
                    baseRole: .defendant,
                    captionOrder: 1,
                    clientStatus: .notRepresented
                ),
            ],
            representations: makeRepresentations(
                matterID: targetMatterID,
                representedPartyID: foreignPartyID,
                representativeName: "Cross Matter Counsel 967"
            )
        )

        XCTAssertThrowsError(try store.matterIdentity.createMatter(command: invalid))
        assertPersistedCounts(
            store,
            matterID: targetMatterID,
            matters: 0,
            parties: 0,
            representations: 0,
            sourceReceipts: 0
        )
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_parties WHERE matter_id = ?",
                    arguments: [foreignMatter.id]
                ),
                0,
                "a rejected target graph must not leak its party into another matter"
            )
        }
    }

    func testCanonicalEditReplacesStaleCourtIdentityAndBumpsOneRevision() throws {
        let store = try SupraStore.inMemory()
        let created: MatterIdentitySnapshot = try store.matterIdentity.createMatter(
            command: makeCreateCommand()
        )
        XCTAssertEqual(created.identityRevision, 1)

        let update = makeUpdateCommand(canonicalCourtID: bankruptcyCourtID)
        let updated: MatterIdentitySnapshot = try store.matterIdentity.updateMatter(
            command: update
        )

        XCTAssertEqual(updated.matterID, matterID)
        XCTAssertEqual(updated.identityRevision, 2)
        XCTAssertEqual(updated.courtResolutionState, .court)
        XCTAssertEqual(updated.canonicalCatalogVersion, catalogVersion)
        XCTAssertEqual(updated.canonicalCatalogDigestSHA256, catalogDigest)
        XCTAssertEqual(updated.canonicalJurisdictionID?.rawValue, jurisdictionID)
        XCTAssertEqual(updated.canonicalCourtID?.rawValue, bankruptcyCourtID)
        XCTAssertNotEqual(updated.canonicalCourtID?.rawValue, districtCourtID)
        XCTAssertEqual(updated.legacyCourtText, "Bankr. S.D. Fla.")
        XCTAssertEqual(updated.parties.map(\.id), [clientPartyID, opponentPartyID])
        XCTAssertEqual(updated.parties.map(\.clientStatus), [.notRepresented, .represented])
        XCTAssertEqual(updated.representations.map(\.id), [representationID])
        XCTAssertEqual(updated.representations[0].representedPartyID, clientPartyID)
        XCTAssertEqual(updated.representations[0].representativeName, "Jordan Rowan, Esq.")

        let exactRetry: MatterIdentitySnapshot = try store.matterIdentity.updateMatter(
            command: update
        )
        XCTAssertEqual(exactRetry, updated)
        assertPersistedCounts(
            store,
            matterID: matterID,
            matters: 1,
            parties: 2,
            representations: 1,
            sourceReceipts: 2
        )

        let staleConflict = makeUpdateCommand(canonicalCourtID: districtCourtID)
        XCTAssertThrowsError(
            try store.matterIdentity.updateMatter(command: staleConflict)
        )
        XCTAssertEqual(
            try store.matterIdentity.fetchSnapshot(matterID: matterID),
            updated,
            "a different payload at the consumed revision must not restore stale IDs"
        )
    }

    private func makeCreateCommand() -> MatterIdentityCreateCommand {
        MatterIdentityCreateCommand(
            matterID: matterID,
            name: "Harbor Logistics v. Meridian Fabrication 913",
            legacyJurisdictionText: "Florida",
            legacyCourtText: "S.D. Fla.",
            legacyPartyPerspective: .defendant,
            legacyClientNames: legacyClientNames,
            courtResolutionState: .court,
            canonicalCatalogVersion: catalogVersion,
            canonicalCatalogDigestSHA256: catalogDigest,
            canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdictionID),
            canonicalCourtID: CanonicalCourtID(rawValue: districtCourtID),
            parties: makeParties(clientStatus: .represented),
            representations: makeRepresentations(
                matterID: matterID,
                representedPartyID: opponentPartyID,
                representativeName: "Avery Quinn, Esq."
            )
        )
    }

    private func makeUpdateCommand(canonicalCourtID: String) -> MatterIdentityUpdateCommand {
        MatterIdentityUpdateCommand(
            matterID: matterID,
            expectedIdentityRevision: 1,
            legacyJurisdictionText: "Florida",
            legacyCourtText: "Bankr. S.D. Fla.",
            legacyPartyPerspective: .plaintiff,
            legacyClientNames: legacyClientNames,
            courtResolutionState: .court,
            canonicalCatalogVersion: catalogVersion,
            canonicalCatalogDigestSHA256: catalogDigest,
            canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdictionID),
            canonicalCourtID: CanonicalCourtID(rawValue: canonicalCourtID),
            parties: makeParties(clientStatus: .notRepresented),
            representations: makeRepresentations(
                matterID: matterID,
                representedPartyID: clientPartyID,
                representativeName: "Jordan Rowan, Esq."
            )
        )
    }

    private func makeParties(
        clientStatus: MatterPartyClientStatus
    ) -> [MatterPartyIdentity] {
        [
            MatterPartyIdentity(
                id: clientPartyID,
                matterID: matterID,
                displayName: "Harbor Logistics, Inc.",
                captionName: "HARBOR LOGISTICS, INC.,",
                baseRole: .defendant,
                captionOrder: 0,
                clientStatus: clientStatus
            ),
            MatterPartyIdentity(
                id: opponentPartyID,
                matterID: matterID,
                displayName: "Meridian Fabrication, LLC",
                captionName: "MERIDIAN FABRICATION, LLC,",
                baseRole: .plaintiff,
                captionOrder: 1,
                clientStatus: clientStatus == .represented ? .notRepresented : .represented
            ),
        ]
    }

    private func makeRepresentations(
        matterID: String,
        representedPartyID: String,
        representativeName: String
    ) -> [MatterRepresentationIdentity] {
        [
            MatterRepresentationIdentity(
                id: representationID,
                matterID: matterID,
                representedPartyID: representedPartyID,
                relationshipKind: .counsel,
                representativeName: representativeName,
                firmName: "Synthetic Trial Group 971",
                serviceAddress: MatterServiceAddress(
                    street: "971 Fictional Avenue",
                    city: "Miami",
                    state: "Florida",
                    postalCode: "33131"
                ),
                serviceEmails: ["service+971@example.test"],
                serviceOrder: 0
            )
        ]
    }

    private func assertCreatedSnapshot(
        _ snapshot: MatterIdentitySnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.matterID, matterID, file: file, line: line)
        XCTAssertEqual(snapshot.identityRevision, 1, file: file, line: line)
        XCTAssertEqual(snapshot.courtResolutionState, .court, file: file, line: line)
        XCTAssertEqual(snapshot.canonicalCatalogVersion, catalogVersion, file: file, line: line)
        XCTAssertEqual(
            snapshot.canonicalCatalogDigestSHA256,
            catalogDigest,
            file: file,
            line: line
        )
        XCTAssertEqual(snapshot.canonicalJurisdictionID?.rawValue, jurisdictionID, file: file, line: line)
        XCTAssertEqual(snapshot.canonicalCourtID?.rawValue, districtCourtID, file: file, line: line)
        XCTAssertNotEqual(snapshot.canonicalCourtID?.rawValue, bankruptcyCourtID, file: file, line: line)
        XCTAssertEqual(snapshot.legacyJurisdictionText, "Florida", file: file, line: line)
        XCTAssertEqual(snapshot.legacyCourtText, "S.D. Fla.", file: file, line: line)
        XCTAssertEqual(snapshot.parties.map(\.id), [clientPartyID, opponentPartyID], file: file, line: line)
        XCTAssertEqual(snapshot.representations.map(\.id), [representationID], file: file, line: line)
        XCTAssertFalse(
            snapshot.parties.contains { legacyClientNames.contains($0.displayName) },
            "legacy client_names must not manufacture a structured party",
            file: file,
            line: line
        )
        XCTAssertFalse(String(describing: snapshot).contains("DEFAULT-000"), file: file, line: line)
    }

    private func assertPersistedCounts(
        _ store: SupraStore,
        matterID: String,
        matters: Int,
        parties: Int,
        representations: Int,
        sourceReceipts: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNoThrow(try store.database.writer.read { db in
            for (table, identityColumn, expected) in [
                ("matters", "id", matters),
                ("matter_parties", "matter_id", parties),
                ("matter_representations", "matter_id", representations),
                ("matter_identity_conversion_receipts", "matter_id", sourceReceipts),
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM \(table) WHERE \(identityColumn) = ?",
                        arguments: [matterID]
                    ),
                    expected,
                    "unexpected \(table) count",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                0
            )
        })
    }
}
