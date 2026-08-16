import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Store RED for the shipping Matter editor aggregate. Identity correctness is
/// not enough if a later chat, audit, folder, or ancillary-field write can fail
/// after the matter has become visible.
///
/// Expected RED: the identity commands do not yet accept
/// `MatterIdentityWorkspaceDetails`, so the shipping editor must perform these
/// writes after `MatterIdentityRepository` commits. The late-failure triggers
/// below therefore cannot be rolled back with the identity graph.
final class ArchitectureUXTDataMatterWorkspaceAtomicityTests: XCTestCase {
    private let matterID = "matter-workspace-atomic-1013"
    private let representedPartyID = "party-workspace-represented-1019"
    private let opposingPartyID = "party-workspace-opposing-1021"
    private let representationID = "representation-workspace-1031"
    private let catalogVersion = "jurisdiction-courts-v1"
    private let catalogDigest =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"
    private let jurisdictionID =
        "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    private let courtID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"

    func testLateStarterFolderFailureRollsBackTheCompleteCreateAndExactRetryPublishesOnce() throws {
        let store = try SupraStore.inMemory()
        let command = createCommand()
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_workspace_folder_1049
                BEFORE INSERT ON document_folders
                WHEN NEW.matter_id = 'matter-workspace-atomic-1013'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic late folder failure 1049');
                END
                """)
        }

        XCTAssertThrowsError(try store.matterIdentity.createMatter(command: command))
        try assertAggregateCounts(store, expected: 0)
        XCTAssertNil(try store.matterIdentity.fetchSnapshot(matterID: matterID))

        try store.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER fail_workspace_folder_1049")
        }
        let created = try store.matterIdentity.createMatter(command: command)
        let exactRetry = try store.matterIdentity.createMatter(command: command)

        XCTAssertEqual(exactRetry, created)
        XCTAssertEqual(created.identityRevision, 1)
        try assertAggregateCounts(store, expected: 1)
        try store.database.writer.read { db in
            let matter = try XCTUnwrap(MatterRecord.fetchOne(db, key: matterID))
            XCTAssertEqual(matter.name, "Aster Harbor v. Northline Rail 1033")
            XCTAssertEqual(matter.judge, "Hon. Synthetic Rowan 1039")
            XCTAssertEqual(matter.docketNumber, "1:26-cv-01043")
            XCTAssertEqual(matter.practiceArea, "Commercial Litigation 1051")
            XCTAssertEqual(matter.notes, "Atomic create note 1061")
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM document_folders WHERE matter_id = ? ORDER BY id",
                    arguments: [matterID]
                ),
                ["Atomic Pleadings 1063", "Atomic Drafts 1069"]
            )
        }
    }

    func testLateUpdateAuditFailureRestoresPriorWorkspaceAndIdentityBeforeExactRetry() throws {
        let store = try SupraStore.inMemory()
        let created = try store.matterIdentity.createMatter(command: createCommand())
        let originalMatter = try XCTUnwrap(store.matters.fetchMatter(id: matterID))
        let update = updateCommand()
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_workspace_update_audit_1087
                BEFORE INSERT ON audit_events
                WHEN NEW.matter_id = 'matter-workspace-atomic-1013'
                  AND NEW.event_type = 'matter_updated'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic late update audit failure 1087');
                END
                """)
        }

        XCTAssertThrowsError(try store.matterIdentity.updateMatter(command: update))
        XCTAssertEqual(
            try store.matterIdentity.fetchSnapshot(matterID: matterID),
            created,
            "the identity revision and party graph must roll back together"
        )
        let afterFailure = try XCTUnwrap(store.matters.fetchMatter(id: matterID))
        XCTAssertEqual(afterFailure.name, originalMatter.name)
        XCTAssertEqual(afterFailure.judge, originalMatter.judge)
        XCTAssertEqual(afterFailure.docketNumber, originalMatter.docketNumber)
        XCTAssertEqual(afterFailure.notes, originalMatter.notes)
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_identity_conversion_receipts WHERE matter_id = ?",
                    arguments: [matterID]
                ),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM audit_events WHERE matter_id = ? AND event_type = 'matter_updated'",
                    arguments: [matterID]
                ),
                0
            )
        }

        try store.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER fail_workspace_update_audit_1087")
        }
        let updated = try store.matterIdentity.updateMatter(command: update)
        let exactRetry = try store.matterIdentity.updateMatter(command: update)

        XCTAssertEqual(exactRetry, updated)
        XCTAssertEqual(updated.identityRevision, 2)
        XCTAssertEqual(updated.parties.map(\.clientStatus), [.notRepresented, .represented])
        let persisted = try XCTUnwrap(store.matters.fetchMatter(id: matterID))
        XCTAssertEqual(persisted.name, "Aster Harbor v. Northline Rail — Edited 1091")
        XCTAssertEqual(persisted.judge, "Hon. Synthetic Vega 1093")
        XCTAssertEqual(persisted.docketNumber, "1:26-cv-01097")
        XCTAssertEqual(persisted.notes, "Atomic update note 1099")
        try store.database.writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_identity_conversion_receipts WHERE matter_id = ?",
                    arguments: [matterID]
                ),
                2
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM audit_events WHERE matter_id = ? AND event_type = 'matter_updated'",
                    arguments: [matterID]
                ),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_parties WHERE matter_id = ?",
                    arguments: [matterID]
                ),
                2
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_representations WHERE matter_id = ?",
                    arguments: [matterID]
                ),
                1
            )
        }
    }

    private func createCommand() -> MatterIdentityCreateCommand {
        MatterIdentityCreateCommand(
            matterID: matterID,
            name: "Aster Harbor v. Northline Rail 1033",
            legacyJurisdictionText: "Florida legacy evidence 1037",
            legacyCourtText: "S.D. Fla. legacy evidence 1041",
            legacyPartyPerspective: .plaintiff,
            legacyClientNames: "Aster Harbor legacy client bytes 1047",
            courtResolutionState: .court,
            canonicalCatalogVersion: catalogVersion,
            canonicalCatalogDigestSHA256: catalogDigest,
            canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdictionID),
            canonicalCourtID: CanonicalCourtID(rawValue: courtID),
            parties: parties(representedStatus: .represented),
            representations: representations(representedPartyID: opposingPartyID),
            workspaceDetails: MatterIdentityWorkspaceDetails(
                name: "Aster Harbor v. Northline Rail 1033",
                judge: "Hon. Synthetic Rowan 1039",
                docketNumber: "1:26-cv-01043",
                practiceArea: "Commercial Litigation 1051",
                matterDescription: "Fictional workspace description 1053",
                internalMatterID: "LAW-1057",
                clientID: "CLIENT-1059",
                clientMatterID: "CLIENT-MATTER-1060",
                notes: "Atomic create note 1061",
                starterFolderNames: ["Atomic Pleadings 1063", "Atomic Drafts 1069"]
            )
        )
    }

    private func updateCommand() -> MatterIdentityUpdateCommand {
        MatterIdentityUpdateCommand(
            matterID: matterID,
            expectedIdentityRevision: 1,
            legacyJurisdictionText: "Florida edited evidence 1071",
            legacyCourtText: "S.D. Fla. edited evidence 1073",
            legacyPartyPerspective: .defendant,
            legacyClientNames: "Northline Rail legacy client bytes 1079",
            courtResolutionState: .court,
            canonicalCatalogVersion: catalogVersion,
            canonicalCatalogDigestSHA256: catalogDigest,
            canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdictionID),
            canonicalCourtID: CanonicalCourtID(rawValue: courtID),
            parties: parties(representedStatus: .notRepresented),
            representations: representations(representedPartyID: representedPartyID),
            workspaceDetails: MatterIdentityWorkspaceDetails(
                name: "Aster Harbor v. Northline Rail — Edited 1091",
                judge: "Hon. Synthetic Vega 1093",
                docketNumber: "1:26-cv-01097",
                practiceArea: "Appellate Litigation 1103",
                matterDescription: "Fictional edited workspace 1109",
                internalMatterID: "LAW-1117",
                clientID: "CLIENT-1123",
                clientMatterID: "CLIENT-MATTER-1129",
                notes: "Atomic update note 1099"
            )
        )
    }

    private func parties(
        representedStatus: MatterPartyClientStatus
    ) -> [MatterPartyIdentity] {
        [
            MatterPartyIdentity(
                id: representedPartyID,
                matterID: matterID,
                displayName: "Aster Harbor Fabrication 1151",
                captionName: "ASTER HARBOR FABRICATION 1151,",
                baseRole: .plaintiff,
                captionOrder: 0,
                clientStatus: representedStatus
            ),
            MatterPartyIdentity(
                id: opposingPartyID,
                matterID: matterID,
                displayName: "Northline Rail Logistics 1153",
                captionName: "NORTHLINE RAIL LOGISTICS 1153,",
                baseRole: .defendant,
                captionOrder: 1,
                clientStatus: representedStatus == .represented
                    ? .notRepresented : .represented
            ),
        ]
    }

    private func representations(
        representedPartyID: String
    ) -> [MatterRepresentationIdentity] {
        [
            MatterRepresentationIdentity(
                id: representationID,
                matterID: matterID,
                representedPartyID: representedPartyID,
                relationshipKind: .counsel,
                representativeName: "Avery Synthetic, Esq. 1163",
                firmName: "Synthetic Trial Group 1169",
                serviceAddress: MatterServiceAddress(
                    street: "1171 Fictional Avenue",
                    city: "Miami",
                    state: "Florida",
                    postalCode: "33131"
                ),
                serviceEmails: ["service+1177@example.test"],
                serviceOrder: 0
            )
        ]
    }

    private func assertAggregateCounts(
        _ store: SupraStore,
        expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try store.database.writer.read { db in
            for (table, column, multiplier) in [
                ("matters", "id", 1),
                ("matter_identity_conversion_receipts", "matter_id", 1),
                ("matter_parties", "matter_id", 2),
                ("matter_representations", "matter_id", 1),
                ("chats", "matter_id", 1),
                ("audit_events", "matter_id", 1),
                ("document_folders", "matter_id", 2),
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
                        arguments: [matterID]
                    ),
                    expected * multiplier,
                    "unexpected persisted count for \(table)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
