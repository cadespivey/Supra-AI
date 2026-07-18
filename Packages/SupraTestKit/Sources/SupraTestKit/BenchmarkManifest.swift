import CryptoKit
import Foundation

public struct BenchmarkFixtureManifest: Codable, Sendable {
    public var schemaVersion: Int
    public var dataClassification: String
    public var root: String
    public var artifacts: [BenchmarkArtifact]
}

public struct BenchmarkArtifact: Codable, Sendable {
    public var path: String
    public var sha256: String
    public var kind: String
    public var expectedDisposition: String?
}

/// Freezes the exact generated benchmark bytes. The manifest intentionally
/// lives beside, rather than inside, the benchmark root so it never hashes
/// itself and can be regenerated deterministically by `SeedCorpus`.
public enum BenchmarkManifestWriter {
    public enum ManifestError: Error {
        case missingBenchmarkProfile
        case unknownArtifact(String)
    }

    public static func write(
        matter: MatterSpec,
        matterDirectory: URL,
        relativeRoot: String,
        to manifestURL: URL
    ) throws {
        guard matter.benchmarkProfile != nil else { throw ManifestError.missingBenchmarkProfile }

        var declarations: [String: (kind: String, disposition: String?)] = [:]
        for document in matter.documents {
            let relativePath = document.folder + "/" + document.filename
            declarations[relativePath] = declaration(for: document.format)
        }
        declarations["Notes/attorney-notes.md"] = ("markdown", nil)
        declarations["_answer-key.json"] = ("json", nil)
        declarations["SYNTHETIC-DATA-ONLY.txt"] = ("text", nil)

        let enumerator = FileManager.default.enumerator(
            at: matterDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var artifacts: [BenchmarkArtifact] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(url.path.dropFirst(matterDirectory.path.count + 1))
            guard let declaration = declarations[relativePath] else {
                throw ManifestError.unknownArtifact(relativePath)
            }
            let data = try Data(contentsOf: url)
            artifacts.append(BenchmarkArtifact(
                path: relativePath,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                kind: declaration.kind,
                expectedDisposition: declaration.disposition
            ))
        }

        let manifest = BenchmarkFixtureManifest(
            schemaVersion: 1,
            dataClassification: "synthetic_fictional_nonprivileged",
            root: relativeRoot,
            artifacts: artifacts.sorted { $0.path < $1.path }
        )
        try JSONEncoder.pretty.encode(manifest).write(to: manifestURL)
    }

    private static func declaration(for format: DocumentSpec.Format) -> (String, String?) {
        switch format {
        case .pdf: return ("pdf", nil)
        case .scanned_pdf: return ("scanned_pdf", nil)
        case .mixed_pdf: return ("mixed_pdf", nil)
        case .locked_pdf: return ("locked_pdf", "encrypted_source")
        case .image_png: return ("png", nil)
        case .docx: return ("docx", nil)
        case .xlsx: return ("xlsx", nil)
        case .eml: return ("eml", nil)
        case .msg: return ("msg", "unsupported_by_policy")
        }
    }
}
