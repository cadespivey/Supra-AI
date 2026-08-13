import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Durable Store owner for T-DATA-PARTY-02. Sessions may validate a receipt,
/// but only Store can issue one after checking the current persisted revision,
/// canonical represented party, requested party, purpose, and canonical digest.
///
/// Expected RED: `SupraStore.matterIdentity`, its coherent snapshot read, and
/// its append-only party-confirmation issue/fetch APIs do not yet exist.
final class ArchitectureUXTDataPartyReceiptRepositoryTests: XCTestCase {
    private let matterID = "matter-831"
    private let canonicalPartyID = "party-813"
    private let requestedPartyID = "party-817"
    private let receiptID = "receipt-827"
    private let purpose = "notice_of_appearance:wire-831"
    private let confirmedAt = Date(timeIntervalSince1970: 1_946_160_827)

    func testSnapshotAndIssuedConfirmationAreExactRetrySafeAndDurable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-DATA-PARTY-RECEIPT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")

        let store = try SupraStore(url: databaseURL)
        try seedCanonicalIdentity(in: store.database.writer)

        let snapshot = try XCTUnwrap(
            store.matterIdentity.fetchSnapshot(matterID: matterID)
        )
        XCTAssertEqual(snapshot.matterID, matterID)
        XCTAssertEqual(snapshot.identityRevision, 7)
        XCTAssertEqual(snapshot.courtResolutionState, .court)
        XCTAssertEqual(snapshot.parties.map(\.id), [requestedPartyID, canonicalPartyID])
        XCTAssertEqual(snapshot.representations.map(\.id), ["representation-823"])
        XCTAssertEqual(snapshot.representations[0].serviceEmails, ["service+823@example.test"])
        XCTAssertFalse(String(describing: snapshot).contains("DEFAULT-000"))

        let request = makeRequest()
        let receipt = try store.matterIdentity.issuePartyConflictConfirmation(
            request: request,
            receiptID: receiptID,
            actor: "synthetic-attorney-829",
            confirmedAt: confirmedAt
        )
        XCTAssertEqual(receipt.id, receiptID)
        XCTAssertEqual(receipt.matterID, matterID)
        XCTAssertEqual(receipt.identityRevision, 7)
        XCTAssertEqual(receipt.canonicalRepresentedPartyID, canonicalPartyID)
        XCTAssertEqual(receipt.requestedRepresentedPartyID, requestedPartyID)
        XCTAssertEqual(receipt.purpose, purpose)
        XCTAssertEqual(receipt.requestDigestSHA256, request.requestDigestSHA256)
        XCTAssertEqual(receipt.actor, "synthetic-attorney-829")
        XCTAssertEqual(receipt.confirmedAt, confirmedAt)
        XCTAssertNotEqual(receipt.requestDigestSHA256, String(repeating: "0", count: 64))

        XCTAssertEqual(
            try store.matterIdentity.fetchPartyConflictConfirmations(matterID: matterID),
            [receipt]
        )
        XCTAssertEqual(
            try store.matterIdentity.issuePartyConflictConfirmation(
                request: request,
                receiptID: receiptID,
                actor: "synthetic-attorney-829",
                confirmedAt: confirmedAt
            ),
            receipt,
            "an exact retry returns the persisted receipt without appending"
        )
        XCTAssertEqual(
            try store.matterIdentity.fetchPartyConflictConfirmations(matterID: matterID),
            [receipt]
        )

        var conflictingRequest = request
        conflictingRequest = PartyConflictConfirmationRequest(
            matterID: conflictingRequest.matterID,
            identityRevision: conflictingRequest.identityRevision,
            canonicalRepresentedPartyID: conflictingRequest.canonicalRepresentedPartyID,
            requestedRepresentedPartyID: canonicalPartyID,
            purpose: conflictingRequest.purpose,
            requestDigestSHA256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(
            try store.matterIdentity.issuePartyConflictConfirmation(
                request: conflictingRequest,
                receiptID: receiptID,
                actor: "synthetic-attorney-829",
                confirmedAt: confirmedAt
            )
        ) { error in
            XCTAssertEqual(error as? MatterIdentityRepositoryError, .conflictingDecision)
        }
        XCTAssertEqual(
            try store.matterIdentity.fetchPartyConflictConfirmations(matterID: matterID),
            [receipt]
        )

        let reopened = try SupraStore(url: databaseURL)
        XCTAssertEqual(
            try reopened.matterIdentity.fetchPartyConflictConfirmations(matterID: matterID),
            [receipt]
        )
        XCTAssertEqual(
            try reopened.matterIdentity.fetchSnapshot(matterID: matterID),
            snapshot
        )
    }

    private func makeRequest() -> PartyConflictConfirmationRequest {
        let digest = requestDigest(
            matterID: matterID,
            identityRevision: 7,
            canonicalRepresentedPartyID: canonicalPartyID,
            requestedRepresentedPartyID: requestedPartyID,
            purpose: purpose
        )
        return PartyConflictConfirmationRequest(
            matterID: matterID,
            identityRevision: 7,
            canonicalRepresentedPartyID: canonicalPartyID,
            requestedRepresentedPartyID: requestedPartyID,
            purpose: purpose,
            requestDigestSHA256: digest
        )
    }

    private func seedCanonicalIdentity(in writer: any DatabaseWriter) throws {
        try writer.write { db in
            let timestamp = "2031-09-05T20:18:27.831Z"
            try db.execute(
                sql: """
                    INSERT INTO matters (
                        id, name, jurisdiction, party_perspective, court,
                        canonical_jurisdiction_id, canonical_court_id,
                        court_resolution_state, identity_revision,
                        created_at, updated_at
                    ) VALUES (
                        ?, 'Party repository wire 831', 'Florida', 'defendant',
                        'S.D. Fla.',
                        'federal-united-states-court-of-appeals-for-the-eleventh-circuit',
                        'federal-florida-united-states-district-court-for-the-southern-district-of-florida',
                        'court', 7, ?, ?
                    )
                    """,
                arguments: [matterID, timestamp, timestamp]
            )
            for party in [
                (
                    requestedPartyID, "Meridian Fabrication",
                    "MERIDIAN FABRICATION, LLC,", "plaintiff", 0,
                    "not_represented"
                ),
                (
                    canonicalPartyID, "Harbor Logistics",
                    "HARBOR LOGISTICS, INC.,", "defendant", 1,
                    "represented"
                ),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO matter_parties (
                            id, matter_id, display_name, caption_name, base_role,
                            caption_order, client_status, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        party.0, matterID, party.1, party.2, party.3,
                        party.4, party.5, timestamp, timestamp,
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO matter_representations (
                        id, matter_id, represented_party_id, relationship_kind,
                        representative_name, firm_name, service_address_json,
                        service_emails_json, service_order, created_at, updated_at
                    ) VALUES (
                        'representation-823', ?, ?, 'counsel',
                        'Avery Quinn, Esq.', 'Quinn Trial Group',
                        '{"street":"823 Harbor Street","city":"Miami","state":"Florida","postalCode":"33131"}',
                        '["service+823@example.test"]', 0, ?, ?
                    )
                    """,
                arguments: [matterID, requestedPartyID, timestamp, timestamp]
            )
        }
    }

    private func requestDigest(
        matterID: String,
        identityRevision: Int,
        canonicalRepresentedPartyID: String,
        requestedRepresentedPartyID: String,
        purpose: String
    ) -> String {
        let values = [
            "supra-party-conflict-confirmation-v1", matterID,
            String(identityRevision), canonicalRepresentedPartyID,
            requestedRepresentedPartyID, purpose,
        ]
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
