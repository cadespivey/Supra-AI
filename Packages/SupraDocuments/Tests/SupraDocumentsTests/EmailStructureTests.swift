import Foundation
@testable import SupraDocuments
import XCTest

final class EmailStructureTests: XCTestCase {
    /// T-STR-15/T-STR-16 expected RED: `.eml` extraction still emits the generic
    /// wrapper, so RFC headers and quoted-reply boundaries are not represented.
    func testEmailStructurePreservesHeadersAndSegmentsQuotedReply() async throws {
        let result = try await EmailExtractor().extract(fileURL: try emailFixture())
        let nodes = result.structure.nodes

        let message = try XCTUnwrap(nodes.first { $0.kind == .emailMessage })
        let header = try XCTUnwrap(nodes.first { $0.kind == .header })
        let body = try XCTUnwrap(nodes.first { $0.kind == .emailBody })
        let quote = try XCTUnwrap(nodes.first { $0.kind == .emailQuote })

        XCTAssertEqual(message.parentNodeKey, "document")
        XCTAssertEqual(header.parentNodeKey, message.nodeKey)
        XCTAssertEqual(body.parentNodeKey, message.nodeKey)
        XCTAssertEqual(quote.parentNodeKey, message.nodeKey)
        XCTAssertTrue(header.textContent?.contains("Message-ID: <synthetic-thread-003@example.test>") == true)
        XCTAssertTrue(header.textContent?.contains("In-Reply-To: <synthetic-thread-002@example.test>") == true)
        XCTAssertTrue(header.textContent?.contains("References: <synthetic-thread-001@example.test> <synthetic-thread-002@example.test>") == true)
        XCTAssertTrue(header.textContent?.contains("Bcc: audit@example.test") == true)

        let payload = try jsonObject(message.payloadJSON)
        XCTAssertEqual(payload["messageID"] as? String, "<synthetic-thread-003@example.test>")
        XCTAssertEqual(payload["inReplyTo"] as? String, "<synthetic-thread-002@example.test>")
        XCTAssertEqual(payload["references"] as? [String], [
            "<synthetic-thread-001@example.test>",
            "<synthetic-thread-002@example.test>",
        ])

        let flatText = try XCTUnwrap(result.parts.first?.text)
        XCTAssertEqual(text(for: body, in: flatText), "Current answer with inline chart cid:synthetic-chart-001.")
        XCTAssertEqual(
            text(for: quote, in: flatText),
            "--- Original Message ---\nFrom: Morgan Vale\nPlease confirm the schedule."
        )
        XCTAssertTrue(flatText.contains("Subject: RE: Synthetic schedule"))
        XCTAssertFalse(flatText.contains("Bcc: audit@example.test"), "legacy flat header summary must remain unchanged")
        XCTAssertFalse(flatText.contains("Message-ID:"), "RFC graph metadata must not change flat retrieval text")
    }

    /// T-STR-18 expected RED: the inline MIME part is imported as a child file,
    /// but there is no CID-addressable `attachment_ref` structure node or edge.
    func testCIDInlineImageIsAnAttachmentReferenceWithoutChangingAttachmentImport() async throws {
        let result = try await EmailExtractor().extract(fileURL: try emailFixture())

        XCTAssertEqual(result.attachments.map(\.fileName), ["synthetic-chart.png"])
        let reference = try XCTUnwrap(result.structure.nodes.first { $0.kind == .attachmentRef })
        let payload = try jsonObject(reference.payloadJSON)
        XCTAssertEqual(payload["contentID"] as? String, "synthetic-chart-001")
        XCTAssertEqual(payload["fileName"] as? String, "synthetic-chart.png")
        XCTAssertEqual(payload["disposition"] as? String, "inline")
        XCTAssertTrue(result.structure.edges.contains {
            $0.fromNodeKey == "email/body/0"
                && $0.toNodeKey == reference.nodeKey
                && $0.kind == .references
        })
    }

    private func emailFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailStructureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("thread-reply.eml")
        let image = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let email = """
        From: Dana Quill <dquill@example.test>
        To: Morgan Vale <mvale@example.test>
        Bcc: audit@example.test
        Subject: RE: Synthetic schedule
        Date: Tue, 27 Jan 2026 14:22:00 -0500
        Message-ID: <synthetic-thread-003@example.test>
        In-Reply-To: <synthetic-thread-002@example.test>
        References: <synthetic-thread-001@example.test> <synthetic-thread-002@example.test>
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="BOUNDARY"

        --BOUNDARY
        Content-Type: text/plain; charset=utf-8

        Current answer with inline chart cid:synthetic-chart-001.

        --- Original Message ---
        From: Morgan Vale
        Please confirm the schedule.
        --BOUNDARY
        Content-Type: image/png; name="synthetic-chart.png"
        Content-Disposition: inline; filename="synthetic-chart.png"
        Content-ID: <synthetic-chart-001>
        Content-Transfer-Encoding: base64

        \(image)
        --BOUNDARY--
        """
        try email.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func jsonObject(_ json: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(json?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func text(for node: ExtractedStructureNode, in source: String) -> String? {
        guard let start = node.charStart, let end = node.charEnd else { return node.textContent }
        let lower = source.index(source.startIndex, offsetBy: start)
        let upper = source.index(source.startIndex, offsetBy: end)
        return String(source[lower..<upper])
    }
}
