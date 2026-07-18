import CryptoKit
import Foundation
import ImageIO
import PDFKit
import XCTest

/// T-BEN-01/T-BEN-02 freeze the synthetic document-ingestion benchmark before
/// the benchmark runner or production extraction behavior is introduced.
final class BenchmarkFixtureContractTests: XCTestCase {
    private struct Manifest: Decodable {
        var schemaVersion: Int
        var dataClassification: String
        var root: String
        var artifacts: [Artifact]
    }

    private struct Artifact: Decodable {
        var path: String
        var sha256: String
        var kind: String
        var expectedDisposition: String?
    }

    private let requiredTaskKeyFields = [
        "lists", "chronology", "comparisons", "contradictions",
        "negatives", "structures", "versions",
    ]

    func testBenchmarkManifestDeclaresOnlyDecodableSyntheticArtifacts() throws {
        // T-BEN-01 expected RED: TestData/benchmark-manifest.json and its
        // declared synthetic benchmark artifacts do not exist yet.
        let root = repoRoot()
        let manifestURL = root.appendingPathComponent("TestData/benchmark-manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.dataClassification, "synthetic_fictional_nonprivileged")
        XCTAssertFalse(manifest.artifacts.isEmpty)

        let corpusRoot = root.appendingPathComponent(manifest.root, isDirectory: true)
        let declaredPaths = Set(manifest.artifacts.map(\.path))
        XCTAssertEqual(declaredPaths.count, manifest.artifacts.count, "manifest paths must be unique")

        let actualPaths = try recursiveFilePaths(relativeTo: corpusRoot)
        XCTAssertEqual(actualPaths, declaredPaths, "benchmark root contains undeclared or missing files")

        for artifact in manifest.artifacts {
            let url = corpusRoot.appendingPathComponent(artifact.path)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Self.sha256(data), artifact.sha256, "hash mismatch: \(artifact.path)")
            try assertDecodable(artifact, data: data, at: url)
        }

        let marker = try String(contentsOf: corpusRoot.appendingPathComponent("SYNTHETIC-DATA-ONLY.txt"), encoding: .utf8)
        XCTAssertTrue(marker.contains("SYNTHETIC, FICTIONAL, AND NONPRIVILEGED"))
    }

    func testEveryMatterHasCompleteResolvableTaskAnswerKeys() throws {
        // T-BEN-02 expected RED: current answer keys have qa/chronology only;
        // they lack the required taskKeys fields, stable IDs, and evidence locators.
        let specsURL = repoRoot().appendingPathComponent("TestData/specs", isDirectory: true)
        let specURLs = try FileManager.default.contentsOfDirectory(at: specsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(specURLs.isEmpty)

        var answerIDs = Set<String>()
        for specURL in specURLs {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: specURL)) as? [String: Any],
                "\(specURL.lastPathComponent): root must be an object"
            )
            let documents = try XCTUnwrap(object["documents"] as? [[String: Any]])
            let filenames = Set(documents.compactMap { $0["filename"] as? String })
            XCTAssertEqual(filenames.count, documents.count, "\(specURL.lastPathComponent): duplicate or missing document filename")

            let answerKey = try XCTUnwrap(object["answerKey"] as? [String: Any])
            let taskKeys = try XCTUnwrap(
                answerKey["taskKeys"] as? [String: Any],
                "\(specURL.lastPathComponent): missing answerKey.taskKeys"
            )

            for field in requiredTaskKeyFields {
                let entries = try XCTUnwrap(
                    taskKeys[field] as? [[String: Any]],
                    "\(specURL.lastPathComponent): missing taskKeys.\(field)"
                )
                XCTAssertFalse(entries.isEmpty, "\(specURL.lastPathComponent): taskKeys.\(field) must not be empty")

                for entry in entries {
                    let id = try XCTUnwrap(entry["id"] as? String, "\(field) entry is missing id")
                    XCTAssertFalse(id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    XCTAssertTrue(answerIDs.insert(id).inserted, "duplicate answer-key id: \(id)")

                    let prompt = try XCTUnwrap(entry["prompt"] as? String, "\(id): missing prompt")
                    let expectedAnswer = try XCTUnwrap(entry["expectedAnswer"] as? String, "\(id): missing expectedAnswer")
                    XCTAssertFalse(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    XCTAssertFalse(expectedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    let evidence = try XCTUnwrap(entry["evidence"] as? [[String: Any]], "\(id): missing evidence")
                    XCTAssertFalse(evidence.isEmpty, "\(id): evidence must not be empty")
                    for locator in evidence {
                        let source = try XCTUnwrap(locator["sourceFilename"] as? String, "\(id): evidence source missing")
                        let hint = try XCTUnwrap(locator["locatorHint"] as? String, "\(id): evidence locator missing")
                        XCTAssertTrue(filenames.contains(source), "\(id): unresolved source \(source)")
                        XCTAssertFalse(hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func assertDecodable(_ artifact: Artifact, data: Data, at url: URL) throws {
        switch artifact.kind {
        case "docx", "xlsx":
            XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04], "invalid OOXML container: \(artifact.path)")
        case "eml":
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(text.contains("From:"), artifact.path)
            XCTAssertTrue(text.contains("Message-ID:"), artifact.path)
        case "msg":
            XCTAssertEqual(artifact.expectedDisposition, "unsupported_by_policy")
        case "pdf", "scanned_pdf":
            let document = try XCTUnwrap(PDFDocument(url: url), artifact.path)
            XCTAssertGreaterThan(document.pageCount, 0)
            XCTAssertFalse(document.isLocked)
        case "mixed_pdf":
            let document = try XCTUnwrap(PDFDocument(url: url), artifact.path)
            let pageText = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            XCTAssertTrue(pageText.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            XCTAssertTrue(pageText.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        case "locked_pdf":
            let document = try XCTUnwrap(PDFDocument(url: url), artifact.path)
            XCTAssertTrue(document.isLocked)
            XCTAssertEqual(artifact.expectedDisposition, "encrypted_source")
        case "png":
            XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil), artifact.path)
        case "json":
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: data), artifact.path)
        case "markdown", "text":
            XCTAssertNotNil(String(data: data, encoding: .utf8), artifact.path)
        default:
            XCTFail("unknown artifact kind \(artifact.kind): \(artifact.path)")
        }
    }

    private func recursiveFilePaths(relativeTo root: URL) throws -> Set<String> {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        )
        var paths = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                paths.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return paths
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}
