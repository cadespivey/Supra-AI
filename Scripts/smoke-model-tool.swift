// Operator tool for provisioning the protected release smoke model.
//
//   swift Scripts/smoke-model-tool.swift manifest --model-dir DIR --repo-id ORG/NAME --revision 40HEX
//   swift Scripts/smoke-model-tool.swift fingerprint --model-dir DIR
//
// `manifest` writes `.supra-model-manifest.json` describing every regular file in the
// tree (sha256 digests). `fingerprint` re-verifies the tree against the manifest and
// prints the canonical fingerprint whose value belongs in the
// SUPRA_RELEASE_SMOKE_MODEL_SHA256 release variable.
//
// The fingerprint document and encoder flags MUST stay byte-identical to
// SignedReleaseModelAuthorization/RuntimeModelContentBinding in the app:
// JSONEncoder with [.sortedKeys, .withoutEscapingSlashes], algorithm
// "supra-release-model-sha256-v1", files sorted strictly by relativePath.

import CryptoKit
import Foundation

let manifestFileName = ".supra-model-manifest.json"
let downloadStateFileName = ".supra-model-download-state.json"
let fingerprintAlgorithm = "supra-release-model-sha256-v1"

struct ManifestFile: Codable {
    var relativePath: String
    var size: Int64
    var digestAlgorithm: String
    var digest: String
}

struct Manifest: Codable {
    var schemaVersion: Int
    var repositoryID: String
    var revision: String
    var files: [ManifestFile]
}

struct FingerprintFile: Codable {
    var path: String
    var size: Int64
    var declaredDigestAlgorithm: String
    var declaredDigest: String
    var actualSHA256: String
}

struct FingerprintDocument: Codable {
    var algorithm: String
    var schemaVersion: Int
    var repositoryID: String
    var revision: String
    var files: [FingerprintFile]
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("smoke-model-tool: " + message + "\n").utf8))
    exit(1)
}

func streamedSHA256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func assertNoSymlink(_ url: URL) {
    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
        die("symlink is not allowed in a managed model tree: \(url.path)")
    }
}

func regularFiles(under root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
        options: []
    ) else { die("cannot enumerate \(root.path)") }
    var paths: [String] = []
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
        assertNoSymlink(url)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath + "/") else { die("entry escapes root: \(full)") }
        let relative = String(full.dropFirst(rootPath.count + 1))
        let name = (relative as NSString).lastPathComponent
        if name == manifestFileName { continue }
        if name == downloadStateFileName { die("remove \(relative) before provisioning") }
        if name == ".DS_Store" { die("remove \(relative); the tree must contain only declared files") }
        paths.append(relative)
    }
    return paths.sorted()
}

func fileSize(_ url: URL) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
}

func canonicalFingerprint(manifest: Manifest, root: URL) throws -> String {
    let sorted = manifest.files.sorted { $0.relativePath < $1.relativePath }
    let files: [FingerprintFile] = try sorted.map { entry in
        let url = root.appendingPathComponent(entry.relativePath)
        let actual = try streamedSHA256(of: url)
        let size = fileSize(url)
        guard size == entry.size else {
            die("size mismatch for \(entry.relativePath): manifest \(entry.size), on disk \(size)")
        }
        if entry.digestAlgorithm == "sha256", entry.digest.lowercased() != actual {
            die("sha256 mismatch for \(entry.relativePath)")
        }
        return FingerprintFile(
            path: entry.relativePath,
            size: entry.size,
            declaredDigestAlgorithm: entry.digestAlgorithm,
            declaredDigest: entry.digest.lowercased(),
            actualSHA256: actual
        )
    }
    let document = FingerprintDocument(
        algorithm: fingerprintAlgorithm,
        schemaVersion: manifest.schemaVersion,
        repositoryID: manifest.repositoryID,
        revision: manifest.revision.lowercased(),
        files: files
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(document)
    return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
}

func parseOptions(_ arguments: [String]) -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--"), index + 1 < arguments.count else {
            die("malformed arguments near \(key)")
        }
        options[String(key.dropFirst(2))] = arguments[index + 1]
        index += 2
    }
    return options
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["manifest", "fingerprint"].contains(command) else {
    die("usage: smoke-model-tool.swift manifest|fingerprint --model-dir DIR [--repo-id ORG/NAME --revision 40HEX]")
}
let options = parseOptions(Array(arguments.dropFirst()))
guard let modelDir = options["model-dir"] else { die("--model-dir is required") }
let root = URL(fileURLWithPath: modelDir, isDirectory: true)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    die("model directory does not exist: \(root.path)")
}
assertNoSymlink(root)

switch command {
case "manifest":
    guard let repoID = options["repo-id"], repoID.contains("/") else { die("--repo-id ORG/NAME is required") }
    guard let revision = options["revision"], revision.count == 40,
          revision.lowercased().allSatisfy({ $0.isHexDigit }) else {
        die("--revision must be the 40-hex resolved model commit")
    }
    let relativePaths = regularFiles(under: root)
    guard relativePaths.contains("config.json") else { die("config.json is missing from the model tree") }
    guard relativePaths.contains(where: { $0.lowercased().hasSuffix(".safetensors") }) else {
        die("no .safetensors weights found in the model tree")
    }
    let files: [ManifestFile] = try relativePaths.map { relative in
        let url = root.appendingPathComponent(relative)
        return ManifestFile(
            relativePath: relative,
            size: fileSize(url),
            digestAlgorithm: "sha256",
            digest: try streamedSHA256(of: url)
        )
    }
    let manifest = Manifest(
        schemaVersion: 1,
        repositoryID: repoID,
        revision: revision.lowercased(),
        files: files
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: root.appendingPathComponent(manifestFileName))
    print("wrote \(manifestFileName) with \(files.count) files")
    print("fingerprint: \(try canonicalFingerprint(manifest: manifest, root: root))")
case "fingerprint":
    let manifestURL = root.appendingPathComponent(manifestFileName)
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let declared = Set(manifest.files.map(\.relativePath))
    let present = Set(regularFiles(under: root))
    guard declared == present else {
        die("tree/manifest mismatch; undeclared: \(present.subtracting(declared).sorted()), missing: \(declared.subtracting(present).sorted())")
    }
    print(try canonicalFingerprint(manifest: manifest, root: root))
default:
    die("unreachable")
}
