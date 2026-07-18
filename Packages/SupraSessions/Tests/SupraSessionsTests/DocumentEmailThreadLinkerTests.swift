import Foundation
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentEmailThreadLinkerTests: XCTestCase {
    /// T-STR-17 expected RED: there is no matter-scoped post-import linker, so
    /// separately imported RFC messages never receive cross-document edges.
    func testLinkerCreatesIdempotentReplyAndThreadEdgesWithinMatter() async throws {
        let fixture = try Fixture()
        let matter = try fixture.store.matters.createMatter(name: "Synthetic email thread")
        let rootURL = try fixture.writeEmail(
            name: "root.eml",
            messageID: "<thread-root@example.test>",
            subject: "Synthetic schedule"
        )
        let replyURL = try fixture.writeEmail(
            name: "reply.eml",
            messageID: "<thread-reply@example.test>",
            inReplyTo: "<thread-root@example.test>",
            references: ["<thread-root@example.test>"],
            subject: "RE: Synthetic schedule"
        )

        _ = try await fixture.importer.importSources([rootURL], matterID: matter.id)
        _ = try await fixture.importer.importSources([replyURL], matterID: matter.id)
        let linker = DocumentEmailThreadLinker(store: fixture.store)
        XCTAssertEqual(try linker.relink(matterID: matter.id), 2)

        let documents = try fixture.store.documentLibrary.fetchDocuments(matterID: matter.id)
        let root = try XCTUnwrap(documents.first { $0.displayName == "root.eml" })
        let reply = try XCTUnwrap(documents.first { $0.displayName == "reply.eml" })
        let rootNode = try XCTUnwrap(try fixture.store.documentStructure.fetchNodes(documentID: root.id).first {
            $0.kind == "email_message"
        })
        let replyNode = try XCTUnwrap(try fixture.store.documentStructure.fetchNodes(documentID: reply.id).first {
            $0.kind == "email_message"
        })
        let firstEdges = try fixture.store.documentStructure.fetchEdges(documentID: reply.id)
        XCTAssertTrue(firstEdges.contains {
            $0.fromNodeID == replyNode.id && $0.toNodeID == rootNode.id && $0.kind == "in_reply_to"
        })
        XCTAssertTrue(firstEdges.contains {
            $0.fromNodeID == replyNode.id && $0.toNodeID == rootNode.id && $0.kind == "thread_member"
        })
        XCTAssertFalse(firstEdges.contains { $0.fromNodeID == $0.toNodeID })

        XCTAssertEqual(try linker.relink(matterID: matter.id), 2)
        let secondEdges = try fixture.store.documentStructure.fetchEdges(documentID: reply.id)
        XCTAssertEqual(secondEdges.map(\.id), firstEdges.map(\.id), "relink must replace deterministically")
    }

    /// T-STR-17 isolation wire-proof: a matching Message-ID in another matter
    /// must remain unavailable to the reply linker.
    func testLinkerNeverCrossesMatterBoundary() async throws {
        let fixture = try Fixture()
        let firstMatter = try fixture.store.matters.createMatter(name: "Synthetic first matter")
        let secondMatter = try fixture.store.matters.createMatter(name: "Synthetic isolated matter")
        let rootURL = try fixture.writeEmail(
            name: "other-root.eml",
            messageID: "<isolated-root@example.test>",
            subject: "Other matter root"
        )
        let replyURL = try fixture.writeEmail(
            name: "isolated-reply.eml",
            messageID: "<isolated-reply@example.test>",
            inReplyTo: "<isolated-root@example.test>",
            references: ["<isolated-root@example.test>"],
            subject: "RE: Other matter root"
        )

        _ = try await fixture.importer.importSources([rootURL], matterID: firstMatter.id)
        _ = try await fixture.importer.importSources([replyURL], matterID: secondMatter.id)
        let linker = DocumentEmailThreadLinker(store: fixture.store)

        XCTAssertEqual(try linker.relink(matterID: secondMatter.id), 0)
        let reply = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocuments(matterID: secondMatter.id).first
        )
        XCTAssertTrue(try fixture.store.documentStructure.fetchEdges(documentID: reply.id).isEmpty)
    }
}

private final class Fixture {
    let root: URL
    let store: SupraStore
    let importer: DocumentImportService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentEmailThreadLinkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SupraStore(url: root.appendingPathComponent("store.sqlite"))
        importer = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: root.appendingPathComponent("managed", isDirectory: true)),
            ocr: nil
        )
    }

    func writeEmail(
        name: String,
        messageID: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String
    ) throws -> URL {
        var headers = [
            "From: sender@example.test",
            "To: recipient@example.test",
            "Subject: \(subject)",
            "Message-ID: \(messageID)",
        ]
        if let inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { headers.append("References: \(references.joined(separator: " "))") }
        headers.append("Content-Type: text/plain; charset=utf-8")
        let url = root.appendingPathComponent(name)
        try (headers.joined(separator: "\n") + "\n\nSynthetic email body for \(name).")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
