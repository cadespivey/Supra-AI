import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Store boundary for reversible deletion of document readiness state.
///
/// Expected RED: `DocumentLibraryRepository.softDeleteDocument` and
/// `softDeleteFolder` replace each document's pre-delete status with `deleted`,
/// while `restoreDocument` and `restoreFolder` unconditionally replace it with
/// `ready`. That loses terminal/review state and can manufacture a ready source.
final class ArchitectureUXTDataDeleteReadinessPreservationTests: XCTestCase {
    private enum Wire {
        static let matterName = "T_DATA_DELETE_STATE_01_MATTER_731"
        static let blobID = "T_DATA_DELETE_STATE_01_BLOB_733"
        static let blobSHA256 = "T_DATA_DELETE_STATE_01_SHA_737"
        static let forbiddenDefaultDocumentID = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_160_739)

        static let needsReview = ReadinessState(
            status: MatterDocumentStatus.needsReview.rawValue,
            extractionStatus: DocumentExtractionStatus.ocrComplete.rawValue,
            indexStatus: DocumentIndexStatus.stale.rawValue
        )
        static let stale = ReadinessState(
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.edited.rawValue,
            indexStatus: DocumentIndexStatus.stale.rawValue
        )
        static let failed = ReadinessState(
            status: MatterDocumentStatus.failed.rawValue,
            extractionStatus: DocumentExtractionStatus.failed.rawValue,
            indexStatus: DocumentIndexStatus.failed.rawValue
        )
    }

    private struct ReadinessState: Equatable {
        let status: String
        let extractionStatus: String
        let indexStatus: String

        init(status: String, extractionStatus: String, indexStatus: String) {
            self.status = status
            self.extractionStatus = extractionStatus
            self.indexStatus = indexStatus
        }

        init(document: MatterDocumentRecord) {
            self.init(
                status: document.status,
                extractionStatus: document.extractionStatus,
                indexStatus: document.indexStatus
            )
        }
    }

    private struct Fixture {
        let store: SupraStore
        let matter: MatterRecord
        let blob: DocumentBlobRecord
    }

    func testIndividualDocumentDeleteAndRestorePreservesExactPreDeleteReadinessState() throws {
        // Expected RED: the current individual delete path changes all three
        // non-default top-level states to `deleted`, then restore changes all
        // three to `ready` instead of restoring the exact original state.
        let fixture = try makeFixture()
        let cases: [(id: String, name: String, state: ReadinessState)] = [
            (
                "T_DATA_DELETE_STATE_01_INDIVIDUAL_REVIEW_741",
                "T_DATA_DELETE_STATE_01_INDIVIDUAL_REVIEW_741.pdf",
                Wire.needsReview
            ),
            (
                "T_DATA_DELETE_STATE_01_INDIVIDUAL_STALE_743",
                "T_DATA_DELETE_STATE_01_INDIVIDUAL_STALE_743.txt",
                Wire.stale
            ),
            (
                "T_DATA_DELETE_STATE_01_INDIVIDUAL_FAILED_747",
                "T_DATA_DELETE_STATE_01_INDIVIDUAL_FAILED_747.msg",
                Wire.failed
            ),
        ]
        try insertDocuments(cases, fixture: fixture, folderID: nil)

        for testCase in cases {
            try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: false,
                phase: "pre-delete"
            )

            try fixture.store.documentLibrary.softDeleteDocument(id: testCase.id)
            try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: true,
                phase: "soft-deleted"
            )

            try fixture.store.documentLibrary.restoreDocument(id: testCase.id)
            let restored = try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: false,
                phase: "restored"
            )
            if testCase.state.status != MatterDocumentStatus.ready.rawValue {
                XCTAssertNotEqual(
                    restored.status,
                    MatterDocumentStatus.ready.rawValue,
                    "restore must not manufacture ready for \(testCase.id)"
                )
            }
        }

        try assertExactDocumentIDs(cases.map(\.id), fixture: fixture)
    }

    func testFolderDeleteAndRestorePreservesEachDescendantDocumentReadinessState() throws {
        // Expected RED: folder deletion stamps each descendant document's
        // status as `deleted`, and folder restore promotes every matching row
        // to `ready`, collapsing distinct review/stale/failed states.
        let fixture = try makeFixture()
        let root = try fixture.store.documentLibrary.createFolder(
            matterID: fixture.matter.id,
            name: "T_DATA_DELETE_STATE_01_FOLDER_ROOT_751"
        )
        let child = try fixture.store.documentLibrary.createFolder(
            matterID: fixture.matter.id,
            name: "T_DATA_DELETE_STATE_01_FOLDER_CHILD_757",
            parentFolderID: root.id
        )
        let rootCases: [(id: String, name: String, state: ReadinessState)] = [
            (
                "T_DATA_DELETE_STATE_01_FOLDER_REVIEW_761",
                "T_DATA_DELETE_STATE_01_FOLDER_REVIEW_761.pdf",
                Wire.needsReview
            ),
        ]
        let childCases: [(id: String, name: String, state: ReadinessState)] = [
            (
                "T_DATA_DELETE_STATE_01_FOLDER_STALE_769",
                "T_DATA_DELETE_STATE_01_FOLDER_STALE_769.txt",
                Wire.stale
            ),
            (
                "T_DATA_DELETE_STATE_01_FOLDER_FAILED_773",
                "T_DATA_DELETE_STATE_01_FOLDER_FAILED_773.eml",
                Wire.failed
            ),
        ]
        try insertDocuments(rootCases, fixture: fixture, folderID: root.id)
        try insertDocuments(childCases, fixture: fixture, folderID: child.id)
        let cases = rootCases + childCases

        try fixture.store.documentLibrary.softDeleteFolder(id: root.id)

        XCTAssertNotNil(try fixture.store.documentLibrary.fetchFolder(id: root.id)?.deletedAt)
        XCTAssertNotNil(try fixture.store.documentLibrary.fetchFolder(id: child.id)?.deletedAt)
        for testCase in cases {
            try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: true,
                phase: "folder soft-delete"
            )
        }

        try fixture.store.documentLibrary.restoreFolder(id: root.id)

        XCTAssertNil(try fixture.store.documentLibrary.fetchFolder(id: root.id)?.deletedAt)
        XCTAssertNil(try fixture.store.documentLibrary.fetchFolder(id: child.id)?.deletedAt)
        for testCase in cases {
            let restored = try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: false,
                phase: "folder restore"
            )
            if testCase.state.status != MatterDocumentStatus.ready.rawValue {
                XCTAssertNotEqual(
                    restored.status,
                    MatterDocumentStatus.ready.rawValue,
                    "folder restore must not manufacture ready for \(testCase.id)"
                )
            }
        }

        try assertExactDocumentIDs(cases.map(\.id), fixture: fixture)
    }

    func testLegacyDeletedStatusRestoresFailClosedForDocumentAndFolder() throws {
        // Expected RED: both restore paths currently map legacy `deleted`
        // directly to `ready`. With no trustworthy pre-delete status to recover,
        // the only safe existing-schema fallback is `needs_review`.
        let fixture = try makeFixture()
        let folder = try fixture.store.documentLibrary.createFolder(
            matterID: fixture.matter.id,
            name: "T_DATA_DELETE_STATE_01_LEGACY_FOLDER_779"
        )
        let individualID = "T_DATA_DELETE_STATE_01_LEGACY_INDIVIDUAL_787"
        let folderDocumentID = "T_DATA_DELETE_STATE_01_LEGACY_FOLDER_DOCUMENT_797"
        try insertDocuments(
            [
                (
                    individualID,
                    "T_DATA_DELETE_STATE_01_LEGACY_INDIVIDUAL_787.pdf",
                    Wire.needsReview
                ),
            ],
            fixture: fixture,
            folderID: nil
        )
        try insertDocuments(
            [
                (
                    folderDocumentID,
                    "T_DATA_DELETE_STATE_01_LEGACY_FOLDER_DOCUMENT_797.txt",
                    Wire.failed
                ),
            ],
            fixture: fixture,
            folderID: folder.id
        )

        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET deleted_at = ?, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    Wire.timestamp,
                    MatterDocumentStatus.deleted.rawValue,
                    Wire.timestamp,
                    individualID,
                ]
            )
            try db.execute(
                sql: "UPDATE document_folders SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [Wire.timestamp, Wire.timestamp, folder.id]
            )
            try db.execute(
                sql: """
                UPDATE matter_documents
                SET deleted_at = ?, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    Wire.timestamp,
                    MatterDocumentStatus.deleted.rawValue,
                    Wire.timestamp,
                    folderDocumentID,
                ]
            )
        }

        let legacyIndividual = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(id: individualID)
        )
        let legacyFolderDocument = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(id: folderDocumentID)
        )
        XCTAssertEqual(legacyIndividual.status, MatterDocumentStatus.deleted.rawValue)
        XCTAssertNotNil(legacyIndividual.deletedAt)
        XCTAssertEqual(legacyFolderDocument.status, MatterDocumentStatus.deleted.rawValue)
        XCTAssertNotNil(legacyFolderDocument.deletedAt)
        XCTAssertNotNil(try fixture.store.documentLibrary.fetchFolder(id: folder.id)?.deletedAt)

        try fixture.store.documentLibrary.restoreDocument(id: individualID)
        let individual = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(id: individualID)
        )
        XCTAssertNil(individual.deletedAt)
        XCTAssertEqual(individual.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertNotEqual(individual.status, MatterDocumentStatus.ready.rawValue)
        XCTAssertEqual(individual.extractionStatus, Wire.needsReview.extractionStatus)
        XCTAssertEqual(individual.indexStatus, Wire.needsReview.indexStatus)

        try fixture.store.documentLibrary.restoreFolder(id: folder.id)
        let folderDocument = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(id: folderDocumentID)
        )
        XCTAssertNil(folderDocument.deletedAt)
        XCTAssertEqual(folderDocument.status, MatterDocumentStatus.needsReview.rawValue)
        XCTAssertNotEqual(folderDocument.status, MatterDocumentStatus.ready.rawValue)
        XCTAssertEqual(folderDocument.extractionStatus, Wire.failed.extractionStatus)
        XCTAssertEqual(folderDocument.indexStatus, Wire.failed.indexStatus)

        try assertExactDocumentIDs(
            [individualID, folderDocumentID],
            fixture: fixture
        )
    }

    func testMatterDeleteAndRestoreAlreadyPreservesEachDocumentReadinessState() throws {
        // Expected GREEN standing guard: the matter cascade already changes
        // only `deleted_at`/`updated_at`. This prevents the narrower document
        // and folder remediation from regressing that safe behavior.
        let fixture = try makeFixture()
        let folder = try fixture.store.documentLibrary.createFolder(
            matterID: fixture.matter.id,
            name: "T_DATA_DELETE_STATE_01_MATTER_FOLDER_809"
        )
        let cases: [(id: String, name: String, state: ReadinessState)] = [
            (
                "T_DATA_DELETE_STATE_01_MATTER_REVIEW_811",
                "T_DATA_DELETE_STATE_01_MATTER_REVIEW_811.pdf",
                Wire.needsReview
            ),
            (
                "T_DATA_DELETE_STATE_01_MATTER_STALE_821",
                "T_DATA_DELETE_STATE_01_MATTER_STALE_821.txt",
                Wire.stale
            ),
            (
                "T_DATA_DELETE_STATE_01_MATTER_FAILED_823",
                "T_DATA_DELETE_STATE_01_MATTER_FAILED_823.msg",
                Wire.failed
            ),
        ]
        try insertDocuments(cases, fixture: fixture, folderID: folder.id)

        try fixture.store.matters.softDeleteMatter(
            id: fixture.matter.id,
            deletedAt: Wire.timestamp
        )

        XCTAssertNil(try fixture.store.matters.fetchMatter(id: fixture.matter.id))
        XCTAssertNotNil(try fixture.store.documentLibrary.fetchFolder(id: folder.id)?.deletedAt)
        for testCase in cases {
            try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: true,
                phase: "matter soft-delete"
            )
        }

        XCTAssertTrue(try fixture.store.matters.restoreMatter(id: fixture.matter.id))
        XCTAssertNotNil(try fixture.store.matters.fetchMatter(id: fixture.matter.id))
        XCTAssertNil(try fixture.store.documentLibrary.fetchFolder(id: folder.id)?.deletedAt)
        for testCase in cases {
            try assertDocument(
                id: testCase.id,
                in: fixture.store,
                equals: testCase.state,
                isDeleted: false,
                phase: "matter restore"
            )
        }

        try assertExactDocumentIDs(cases.map(\.id), fixture: fixture)
    }

    private func makeFixture() throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: Wire.matterName)
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: Wire.blobID,
                sha256: Wire.blobSHA256,
                byteSize: 739,
                originalExtension: "wire",
                managedRelativePath: "synthetic/T_DATA_DELETE_STATE_01_BLOB_733.wire",
                mimeType: "application/x-t-data-delete-state-01",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Wire.timestamp,
                createdAt: Wire.timestamp
            )
        ).blob
        return Fixture(store: store, matter: matter, blob: blob)
    }

    private func insertDocuments(
        _ cases: [(id: String, name: String, state: ReadinessState)],
        fixture: Fixture,
        folderID: String?
    ) throws {
        for testCase in cases {
            _ = try fixture.store.documentLibrary.insertDocument(
                MatterDocumentRecord(
                    id: testCase.id,
                    matterID: fixture.matter.id,
                    blobID: fixture.blob.id,
                    folderID: folderID,
                    displayName: testCase.name,
                    importedRelativePath: "synthetic/\(testCase.name)",
                    sourceDisplayPath: "T_DATA_DELETE_STATE_01/\(testCase.name)",
                    status: testCase.state.status,
                    extractionStatus: testCase.state.extractionStatus,
                    indexStatus: testCase.state.indexStatus,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    extractionMethod: "T_DATA_DELETE_STATE_01_METHOD_827",
                    extractedTextChecksum: "T_DATA_DELETE_STATE_01_CHECKSUM_829",
                    importedAt: Wire.timestamp,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                )
            )
        }
    }

    @discardableResult
    private func assertDocument(
        id: String,
        in store: SupraStore,
        equals expected: ReadinessState,
        isDeleted: Bool,
        phase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MatterDocumentRecord {
        let document = try XCTUnwrap(
            store.documentLibrary.fetchDocument(id: id),
            "missing \(id) during \(phase)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            ReadinessState(document: document),
            expected,
            "readiness drift for \(id) during \(phase)",
            file: file,
            line: line
        )
        if isDeleted {
            XCTAssertNotNil(document.deletedAt, file: file, line: line)
        } else {
            XCTAssertNil(document.deletedAt, file: file, line: line)
        }
        XCTAssertNotEqual(
            document.id,
            Wire.forbiddenDefaultDocumentID,
            "the exact document output must not fall back to the default wire",
            file: file,
            line: line
        )
        return document
    }

    private func assertExactDocumentIDs(
        _ expectedIDs: [String],
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let outputIDs = try fixture.store.documentLibrary.fetchDocuments(
            matterID: fixture.matter.id,
            includeDeleted: true
        ).map(\.id)
        XCTAssertEqual(Set(outputIDs), Set(expectedIDs), file: file, line: line)
        XCTAssertFalse(
            outputIDs.contains(Wire.forbiddenDefaultDocumentID),
            "the exact fetched document-ID output must exclude DEFAULT-000",
            file: file,
            line: line
        )
    }
}
