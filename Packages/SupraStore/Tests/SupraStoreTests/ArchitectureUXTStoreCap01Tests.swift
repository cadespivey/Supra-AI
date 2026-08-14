import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// T-STORE-CAP-01 introduces the narrow write capability that lets a transport
/// record network audit facts without receiving the whole Store or its unrelated
/// repositories. Backup, restore inspection, and benchmark reads remain explicit
/// privileged paths over the database owner.
final class ArchitectureUXTStoreCap01Tests: XCTestCase {
    private let recordID = "record-713"
    private let wireID = "T_STORE_CAP_01_WIRE_731"

    func testNarrowCapabilityWritesOnlySevenExactNetworkRowsAndFailsClosedAtEight() throws {
        // Expected RED: SupraCore has no NetworkRequestAuditWriting contract and
        // SupraStore does not vend a narrow networkRequestAudits capability.
        let store = try SupraStore.inMemory()
        try store.appSettings.setSetting(recordID, value: wireID)
        let capability: any NetworkRequestAuditWriting = store.networkRequestAudits
        let countsBefore = try rowCounts(store)

        for index in 1...7 {
            let request = request(index: index)
            XCTAssertEqual(try capability.recordRequest(request), request.id)
        }

        let rows = try store.networkRequests.fetchRecent(limit: 8)
        XCTAssertEqual(rows.map(\.id).sorted(), (1...7).map { "\(recordID)-\($0)" })
        XCTAssertEqual(Set(rows.map(\.domain)), ["provider-713.example"])
        XCTAssertEqual(Set(rows.map(\.endpoint)), Set((1...7).map { "/wire/731/\($0)" }))
        XCTAssertTrue(rows.allSatisfy { $0.requestMetadataJSON?.contains(wireID) == true })
        XCTAssertTrue(rows.allSatisfy { $0.requestMetadataJSON?.contains("DEFAULT-000") == false })
        XCTAssertEqual(try store.appSettings.getSetting(recordID, as: String.self), wireID)

        let countsAfterSeven = try rowCounts(store)
        for (table, count) in countsBefore where table != "network_requests" {
            XCTAssertEqual(countsAfterSeven[table], count, "narrow capability mutated \(table)")
        }
        XCTAssertEqual(countsAfterSeven["network_requests"], (countsBefore["network_requests"] ?? 0) + 7)

        try store.database.writer.write { database in
            try database.execute(
                sql: """
                CREATE TRIGGER t_store_cap_01_n_plus_one
                BEFORE INSERT ON network_requests
                WHEN NEW.id = 'record-713-8'
                BEGIN
                    SELECT RAISE(ABORT, 'T_STORE_CAP_01_N_PLUS_1_8');
                END
                """
            )
        }
        let exactSnapshot = try rowCounts(store)
        XCTAssertThrowsError(try capability.recordRequest(request(index: 8)))
        XCTAssertEqual(try rowCounts(store), exactSnapshot)
        XCTAssertNil(try store.networkRequests.fetchRecent(limit: 8).first { $0.id == "\(recordID)-8" })
    }

    func testCapabilityCompletesOnlyAnExistingOwnedRequest() throws {
        // Expected RED: the current repository completion silently accepts an
        // unknown ID and no narrow capability exposes a typed failure.
        let store = try SupraStore.inMemory()
        let capability: any NetworkRequestAuditWriting = store.networkRequestAudits
        let request = request(index: 7)
        _ = try capability.recordRequest(request)

        try capability.finishRequest(
            NetworkRequestAuditCompletion(
                requestID: request.id,
                statusCode: 207,
                errorMessage: nil,
                responseMetadataJSON: #"{"wire":"T_STORE_CAP_01_WIRE_731","version":7}"#
            )
        )

        let row = try XCTUnwrap(try store.networkRequests.fetchRecent(limit: 1).first)
        XCTAssertEqual(row.id, recordID + "-7")
        XCTAssertEqual(row.statusCode, 207)
        XCTAssertEqual(
            row.responseMetadataJSON,
            #"{"wire":"T_STORE_CAP_01_WIRE_731","version":7}"#
        )
        XCTAssertFalse((row.responseMetadataJSON ?? "").contains("DEFAULT-000"))

        let snapshot = try rowCounts(store)
        XCTAssertThrowsError(
            try capability.finishRequest(
                NetworkRequestAuditCompletion(
                    requestID: "record-713-8",
                    statusCode: 599,
                    errorMessage: "T_STORE_CAP_01_N_PLUS_1_8",
                    responseMetadataJSON: nil
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkRequestAuditCapabilityError,
                .requestNotFound(id: "record-713-8")
            )
        }
        XCTAssertEqual(try rowCounts(store), snapshot)
    }

    func testPrivilegedBackupRestoreInspectionAndBenchmarkReadPathsRetainParity() throws {
        // Expected RED: no explicit narrow capability boundary is present to
        // prove that privileged database-owner paths remain available unchanged.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "T-STORE-CAP-01-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("live.sqlite")
        let backupURL = root.appendingPathComponent("backup", isDirectory: true)
        let store = try SupraStore(url: databaseURL)
        try store.appSettings.setSetting(recordID, value: wireID)
        let privilegedCount = try store.database.writer.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM app_settings WHERE key = ?",
                arguments: [recordID]
            )
        }
        XCTAssertEqual(privilegedCount, 1, "the benchmark-style read must retain exact parity")

        let result = try BackupService.runBackup(
            writer: store.database.writer,
            blobsDirectory: nil,
            destination: backupURL,
            appVersion: "7.0.713",
            appBuild: "713",
            keep: 7,
            now: { Date(timeIntervalSince1970: 731) }
        )
        let candidates = try RestoreSnapshotInspector.discover(in: backupURL)
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidate.isRestorable)
        XCTAssertEqual(candidate.snapshotURL, result.snapshotURL)
        XCTAssertEqual(candidate.summary?.appVersion, "7.0.713")
        XCTAssertEqual(candidate.summary?.appBuild, "713")

        let restoredSnapshot = try SupraStore(url: candidate.snapshotURL)
        let exactValue = try restoredSnapshot.appSettings.getSetting(recordID, as: String.self)
        XCTAssertEqual(exactValue, wireID)
        XCTAssertFalse((exactValue ?? "").contains("DEFAULT-000"))
    }

    private func request(index: Int) -> NetworkRequestAuditEntry {
        NetworkRequestAuditEntry(
            id: "\(recordID)-\(index)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(700 + index)),
            domain: "provider-713.example",
            method: "POST",
            endpoint: "/wire/731/\(index)",
            approved: true,
            relatedResearchSessionID: "research-session-713",
            blockedReason: nil,
            requestMetadataJSON: #"{"wire":"T_STORE_CAP_01_WIRE_731","version":7}"#
        )
    }

    private func rowCounts(_ store: SupraStore) throws -> [String: Int] {
        try store.database.writer.read { database in
            let tableNames = try String.fetchAll(
                database,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """
            )
            return try Dictionary(uniqueKeysWithValues: tableNames.map { table in
                let quoted = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
                let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(quoted)") ?? -1
                return (table, count)
            })
        }
    }
}
