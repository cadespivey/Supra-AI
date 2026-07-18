import Foundation
import SupraCore
import SupraDocuments
import SupraSessions
import SupraStore
@testable import SupraTestKit
import XCTest

/// T-ISO-01..03 establish reusable matter-isolation probes before later schema
/// work adds ledgers, revisions, runs, relations, and classification rows.
final class BenchmarkIsolationTests: XCTestCase {
    func testParallelMatterQueriesNeverReturnTheOtherMattersRows() throws {
        // T-ISO-01 expected RED: BenchmarkIsolationProbe query observations are missing.
        let fixture = try makeStoreFixture("query")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let matterA = try fixture.store.matters.createMatter(name: "Parallel Matter A")
        let matterB = try fixture.store.matters.createMatter(name: "Parallel Matter B")

        let folderA = try fixture.store.documentLibrary.createFolder(matterID: matterA.id, name: "Same Display Name")
        let folderB = try fixture.store.documentLibrary.createFolder(matterID: matterB.id, name: "Same Display Name")
        let sourceSetA = try fixture.store.documentSources.createSourceSet(
            matterID: matterA.id,
            mode: .autoSource,
            retrievalQuery: "same external locator"
        )
        let sourceSetB = try fixture.store.documentSources.createSourceSet(
            matterID: matterB.id,
            mode: .autoSource,
            retrievalQuery: "same external locator"
        )
        let outputA = try fixture.store.structuredOutputs.createOutput(
            matterID: matterA.id,
            title: "Same Output",
            outputType: .documentQA
        )
        let outputB = try fixture.store.structuredOutputs.createOutput(
            matterID: matterB.id,
            title: "Same Output",
            outputType: .documentQA
        )
        XCTAssertNotEqual(folderA.id, folderB.id)
        XCTAssertNotEqual(sourceSetA.id, sourceSetB.id)
        XCTAssertNotEqual(outputA.id, outputB.id)

        let observations = [
            BenchmarkMatterQueryObservation(
                surface: "document_folders",
                requestedMatterID: matterA.id,
                returnedMatterIDs: try fixture.store.documentLibrary.fetchFolders(matterID: matterA.id).map(\.matterID)
            ),
            BenchmarkMatterQueryObservation(
                surface: "document_source_sets",
                requestedMatterID: matterA.id,
                returnedMatterIDs: try fixture.store.documentSources.fetchSourceSets(matterID: matterA.id).map(\.matterID)
            ),
            BenchmarkMatterQueryObservation(
                surface: "structured_outputs",
                requestedMatterID: matterB.id,
                returnedMatterIDs: try fixture.store.structuredOutputs.fetchOutputs(matterID: matterB.id).map(\.matterID)
            ),
        ]
        XCTAssertNoThrow(try BenchmarkIsolationProbe.verifyQueryIsolation(observations))

        let plantedLeak = BenchmarkMatterQueryObservation(
            surface: "future_relation_rows",
            requestedMatterID: matterA.id,
            returnedMatterIDs: [matterA.id, matterB.id]
        )
        XCTAssertThrowsError(try BenchmarkIsolationProbe.verifyQueryIsolation(observations + [plantedLeak]))
    }

    func testSharedBlobKeepsDocumentsTagsAndSourcePacketsMatterLocal() async throws {
        // T-ISO-02 expected RED: the shared-blob isolation observation is missing.
        let fixture = try makeStoreFixture("blob")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let matterA = try fixture.store.matters.createMatter(name: "Shared Blob A")
        let matterB = try fixture.store.matters.createMatter(name: "Shared Blob B")
        let source = fixture.root.appendingPathComponent("shared-ledger.txt")
        try Data("SYNTHETIC EXACT-ISOLATION-731 shared ledger fact".utf8).write(to: source)

        let storage = DocumentStorage(root: fixture.root.appendingPathComponent("storage", isDirectory: true))
        let importer = DocumentImportService(store: fixture.store, storage: storage, ocr: nil)
        let importA = try await importer.importSources([source], matterID: matterA.id)
        let importB = try await importer.importSources([source], matterID: matterB.id)
        XCTAssertEqual(importA.report.discoveredCount, 1)
        XCTAssertEqual(importB.report.discoveredCount, 1)
        let documentA = try XCTUnwrap(try fixture.store.documentLibrary.fetchDocuments(matterID: matterA.id).first)
        let documentB = try XCTUnwrap(try fixture.store.documentLibrary.fetchDocuments(matterID: matterB.id).first)

        let tagA = try fixture.store.documentLibrary.createTag(matterID: matterA.id, name: "Only Matter A")
        let tagB = try fixture.store.documentLibrary.createTag(matterID: matterB.id, name: "Only Matter B")
        XCTAssertNoThrow(try fixture.store.documentLibrary.assignTag(tagID: tagA.id, documentID: documentA.id))
        XCTAssertNoThrow(try fixture.store.documentLibrary.assignTag(tagID: tagB.id, documentID: documentB.id))

        let indexedA = try await DocumentIndexingService(store: fixture.store).indexMatter(matterID: matterA.id)
        let indexedB = try await DocumentIndexingService(store: fixture.store).indexMatter(matterID: matterB.id)
        XCTAssertEqual(indexedA, 1)
        XCTAssertEqual(indexedB, 1)
        let retrieval = DocumentRetrievalService(store: fixture.store)
        let sourcesA = try await retrieval.retrieve(
            matterID: matterA.id,
            query: "EXACT-ISOLATION-731",
            scope: .wholeMatter
        ).sources
        let sourcesB = try await retrieval.retrieve(
            matterID: matterB.id,
            query: "EXACT-ISOLATION-731",
            scope: .wholeMatter
        ).sources

        let observation = BenchmarkSharedBlobObservation(
            blobIDs: [documentA.blobID, documentB.blobID],
            documentIDsByMatter: [matterA.id: [documentA.id], matterB.id: [documentB.id]],
            tagNamesByDocument: [
                documentA.id: try fixture.store.documentLibrary.fetchTags(documentID: documentA.id).map(\.name),
                documentB.id: try fixture.store.documentLibrary.fetchTags(documentID: documentB.id).map(\.name),
            ],
            sourceDocumentIDsByMatter: [
                matterA.id: Set(sourcesA.map(\.documentID)),
                matterB.id: Set(sourcesB.map(\.documentID)),
            ]
        )
        XCTAssertNoThrow(try BenchmarkIsolationProbe.verifySharedBlobIsolation(observation))
        XCTAssertEqual(documentA.blobID, documentB.blobID, "the global content-addressed blob seam must be exercised")
        XCTAssertNotEqual(documentA.id, documentB.id)

        var plantedLeak = observation
        plantedLeak.sourceDocumentIDsByMatter[matterA.id, default: []].insert(documentB.id)
        XCTAssertThrowsError(try BenchmarkIsolationProbe.verifySharedBlobIsolation(plantedLeak))
    }

    func testCrossMatterWriteGuardRejectsFutureSurfacesAndAtomicOutputWrite() throws {
        // T-ISO-03 expected RED: the reusable cross-matter write guard is missing.
        let fixture = try makeStoreFixture("write")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let matterA = try fixture.store.matters.createMatter(name: "Write Matter A")
        let matterB = try fixture.store.matters.createMatter(name: "Write Matter B")

        for surface in ["relation", "corpus_run_source", "citation_revision", "classification"] {
            XCTAssertThrowsError(
                try BenchmarkIsolationProbe.requireSameMatter(
                    surface: surface,
                    ownerMatterID: matterA.id,
                    relatedMatterIDs: [matterA.id, matterB.id]
                )
            )
        }
        XCTAssertNoThrow(
            try BenchmarkIsolationProbe.requireSameMatter(
                surface: "same_matter_control",
                ownerMatterID: matterA.id,
                relatedMatterIDs: [matterA.id, matterA.id]
            )
        )

        let outputID = "cross-matter-output"
        let output = StructuredOutputRecord(
            id: outputID,
            matterID: matterA.id,
            title: "Synthetic cross-matter write",
            outputType: StructuredOutputType.documentQA.rawValue
        )
        let wrongMatterSourceSet = DocumentSourceSetRecord(
            id: "wrong-matter-source-set",
            matterID: matterB.id,
            mode: DocumentSourceSetMode.autoSource.rawValue
        )
        XCTAssertThrowsError(
            try fixture.store.structuredOutputs.createVersionWithSourceSetAtomically(
                structuredOutputID: outputID,
                newOutput: output,
                sourceSet: wrongMatterSourceSet,
                outputSources: [],
                contentMarkdown: "Synthetic",
                verificationStatus: .legacyUnverified,
                verificationVersion: "",
                verificationResults: [],
                outputStatus: .draft
            )
        )
        XCTAssertTrue(try fixture.store.structuredOutputs.fetchOutputs(matterID: matterA.id).isEmpty)
        XCTAssertTrue(try fixture.store.documentSources.fetchSourceSets(matterID: matterB.id).isEmpty)
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: matterA.id).isEmpty)
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: matterB.id).isEmpty)
    }

    private func makeStoreFixture(_ suffix: String) throws -> (root: URL, store: SupraStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BenchmarkIsolation-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try SupraStore(url: root.appendingPathComponent("test.sqlite")))
    }
}
