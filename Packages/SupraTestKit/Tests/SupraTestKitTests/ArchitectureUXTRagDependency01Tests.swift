import Foundation
import XCTest

final class ArchitectureUXTRagDependency01Tests: XCTestCase {
    func testShippingGraphHasNoDaemonHostedRAGOrSecondOrchestrationStack() throws {
        let prohibited = [
            "langchain", "llamaindex", "chromadb", "pinecone", "weaviate", "qdrant",
            "hosted vector", "hosted trace", "python runtime",
        ]
        for root in shippingSourceRoots {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8).lowercased()
                for token in prohibited {
                    XCTAssertFalse(source.contains(token), "\(token) in \(url.path)")
                }
                XCTAssertFalse(source.contains("import redis"), "Redis dependency in \(url.path)")
                XCTAssertFalse(source.contains("redis://"), "Redis origin in \(url.path)")
                XCTAssertFalse(source.contains("process()"), "shipping subprocess in \(url.path)")
            }
        }
    }

    func testSignedGraphIsLockedAndManagedModelsAreRevisionAndDigestBound() throws {
        let resolved = repositoryRoot.appendingPathComponent("SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        let manifest = try String(contentsOf: repositoryRoot.appendingPathComponent("Packages/SupraSessions/Sources/SupraSessions/ModelArtifactManifest.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("public var revision: String"))
        XCTAssertTrue(manifest.contains("case sha256"))
        XCTAssertTrue(manifest.contains("constantTimeEqual"))

        let decision = try String(contentsOf: repositoryRoot.appendingPathComponent("Docs/Architecture/Remediation/Optional-Architecture-Decisions.yml"), encoding: .utf8)
        XCTAssertTrue(decision.contains("package_manifest_count: 14"))
        XCTAssertTrue(decision.contains("user_initiated_direct_download_not_bundled"))
        XCTAssertTrue(decision.contains("revision_pinned_manifest_and_content_fingerprint"))
    }

    private var shippingSourceRoots: [URL] {
        var roots = [repositoryRoot.appendingPathComponent("Apps/SupraAI/SupraAI")]
        let packages = repositoryRoot.appendingPathComponent("Packages")
        if let children = try? FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil) {
            roots.append(contentsOf: children.filter { $0.lastPathComponent != "SupraTestKit" }.map { $0.appendingPathComponent("Sources") })
        }
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
