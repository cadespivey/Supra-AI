import Foundation
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentLegalStructureLinkerTests: XCTestCase {
    /// T-STR-19 expected RED: recognized response nodes have no matter-scoped
    /// service that can link them to separately imported numbered requests.
    func testDiscoveryLinkerPairsSeparateDocumentsIdempotently() async throws {
        let fixture = try LegalPairFixture()
        let matter = try fixture.store.matters.createMatter(name: "Synthetic discovery pair")
        let requestURL = try fixture.write(
            "requests.txt",
            "Request No. 7: Produce every audit schedule and attachment."
        )
        let responseURL = try fixture.write(
            "responses.txt",
            "Response to Request No. 7: Schedules A-C are produced."
        )
        _ = try await fixture.importer.importSources([requestURL], matterID: matter.id)
        _ = try await fixture.importer.importSources([responseURL], matterID: matter.id)

        let linker = DocumentLegalStructureLinker(store: fixture.store)
        XCTAssertEqual(try linker.relink(matterID: matter.id), 1)
        let documents = try fixture.store.documentLibrary.fetchDocuments(matterID: matter.id)
        let requestDocument = try XCTUnwrap(documents.first { $0.displayName == "requests.txt" })
        let responseDocument = try XCTUnwrap(documents.first { $0.displayName == "responses.txt" })
        let requestNode = try XCTUnwrap(
            try fixture.store.documentStructure.fetchNodes(documentID: requestDocument.id)
                .first { $0.kind == "discovery_request" }
        )
        let responseNode = try XCTUnwrap(
            try fixture.store.documentStructure.fetchNodes(documentID: responseDocument.id)
                .first { $0.kind == "discovery_response" }
        )
        let firstEdges = try fixture.store.documentStructure.fetchEdges(documentID: responseDocument.id)
        XCTAssertTrue(firstEdges.contains {
            $0.fromNodeID == responseNode.id
                && $0.toNodeID == requestNode.id
                && $0.kind == "responds_to"
        })

        XCTAssertEqual(try linker.relink(matterID: matter.id), 1)
        XCTAssertEqual(
            try fixture.store.documentStructure.fetchEdges(documentID: responseDocument.id).map(\.id),
            firstEdges.map(\.id)
        )
    }

    /// T-STR-19 isolation wire-proof: numbered discovery in another matter is
    /// never eligible, even when family and number match exactly.
    func testDiscoveryLinkerNeverCrossesMatters() async throws {
        let fixture = try LegalPairFixture()
        let requestsMatter = try fixture.store.matters.createMatter(name: "Synthetic request matter")
        let responseMatter = try fixture.store.matters.createMatter(name: "Synthetic response matter")
        _ = try await fixture.importer.importSources(
            [try fixture.write("isolated-request.txt", "Request No. 12: Produce Exhibit G.")],
            matterID: requestsMatter.id
        )
        _ = try await fixture.importer.importSources(
            [try fixture.write("isolated-response.txt", "Response to Request No. 12: Exhibit G does not exist.")],
            matterID: responseMatter.id
        )

        let linker = DocumentLegalStructureLinker(store: fixture.store)
        XCTAssertEqual(try linker.relink(matterID: responseMatter.id), 0)
        let response = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocuments(matterID: responseMatter.id).first
        )
        XCTAssertTrue(try fixture.store.documentStructure.fetchEdges(documentID: response.id).isEmpty)
    }
}

private final class LegalPairFixture {
    let root: URL
    let store: SupraStore
    let importer: DocumentImportService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentLegalStructureLinkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SupraStore(url: root.appendingPathComponent("store.sqlite"))
        importer = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: root.appendingPathComponent("managed", isDirectory: true)),
            ocr: nil
        )
    }

    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
