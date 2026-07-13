import CryptoKit
import Darwin
import Foundation
@testable import SupraRuntimeModelSecurity
import SupraRuntimeInterface
import XCTest

/// RED contract for the private, immutable model tree handed to the runtime.
///
/// The public API fixed by these tests is deliberately small:
///
///     final class RuntimeModelSnapshot
///     init(sourceURL: URL, contentBinding: RuntimeModelContentBinding) throws
///     let snapshotURL: URL
///     let verifiedModelSHA256: String
///     func reverify() throws
///     func remove() throws
///
/// The instance owns its randomized private temporary root until `remove()` or
/// deinitialization. Creation and re-verification fail closed on byte, size,
/// topology, or link-count changes.
final class RuntimeModelSnapshotTests: XCTestCase {
    private static let algorithm = "supra-release-model-sha256-v1"
    private static let repositoryID = "mlx-community/Release-Smoke-4bit"
    private static let revision = String(repeating: "a", count: 40)

    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testCreatesDistinctPrivateSnapshotsWithIndependentInodesAndBytes() throws {
        let config = FixtureFile(
            path: "config.json",
            data: Data("{\"model\":\"release\"}\n".utf8)
        )
        let weights = FixtureFile(
            path: "weights/model.safetensors",
            data: Data((0..<64).map { UInt8($0) })
        )
        let files = [config, weights]
        let sourceURL = try makeSourceDirectory(containing: files)
        let binding = try makeBinding(for: files)

        let first = try RuntimeModelSnapshot(
            sourceURL: sourceURL,
            contentBinding: binding
        )
        defer { try? first.remove() }
        let second = try RuntimeModelSnapshot(
            sourceURL: sourceURL,
            contentBinding: binding
        )
        defer { try? second.remove() }

        XCTAssertNotEqual(first.snapshotURL, second.snapshotURL)
        XCTAssertNotEqual(first.snapshotURL.lastPathComponent, sourceURL.lastPathComponent)
        XCTAssertNotEqual(try inode(of: sourceURL), try inode(of: first.snapshotURL))
        XCTAssertNotEqual(try inode(of: sourceURL), try inode(of: second.snapshotURL))
        XCTAssertNotEqual(try inode(of: first.snapshotURL), try inode(of: second.snapshotURL))
        XCTAssertEqual(first.verifiedModelSHA256, binding.fingerprintSHA256)
        XCTAssertEqual(second.verifiedModelSHA256, binding.fingerprintSHA256)
        try assertPrivateTemporaryRoot(first.snapshotURL)
        try assertPrivateTemporaryRoot(second.snapshotURL)

        for file in files {
            let sourceFile = sourceURL.appendingPathComponent(file.path)
            let firstFile = first.snapshotURL.appendingPathComponent(file.path)
            let secondFile = second.snapshotURL.appendingPathComponent(file.path)

            XCTAssertEqual(try Data(contentsOf: firstFile), file.data)
            XCTAssertEqual(try Data(contentsOf: secondFile), file.data)
            XCTAssertNotEqual(try inode(of: sourceFile), try inode(of: firstFile))
            XCTAssertNotEqual(try inode(of: sourceFile), try inode(of: secondFile))
            XCTAssertNotEqual(try inode(of: firstFile), try inode(of: secondFile))
        }

        // Modify the existing source inode after snapshot creation. A true copy
        // or APFS clone remains byte-independent; a hard link does not.
        let sourceWeights = sourceURL.appendingPathComponent(weights.path)
        let replacement = Data(repeating: 0xFF, count: weights.data.count)
        try overwriteInPlace(replacement, at: sourceWeights)

        XCTAssertEqual(
            try Data(contentsOf: first.snapshotURL.appendingPathComponent(weights.path)),
            weights.data
        )
        XCTAssertEqual(
            try Data(contentsOf: second.snapshotURL.appendingPathComponent(weights.path)),
            weights.data
        )
        XCTAssertNoThrow(try first.reverify())
        XCTAssertNoThrow(try second.reverify())
    }

    func testNestedDeclaredPathsArePreservedExactly() throws {
        let nested = FixtureFile(
            path: "artifacts/weights/model.safetensors",
            data: Data("nested model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [nested])
        let snapshot = try RuntimeModelSnapshot(
            sourceURL: sourceURL,
            contentBinding: makeBinding(for: [nested])
        )
        defer { try? snapshot.remove() }

        let destination = snapshot.snapshotURL.appendingPathComponent(nested.path)
        XCTAssertEqual(try Data(contentsOf: destination), nested.data)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.deletingLastPathComponent().path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNoThrow(try snapshot.reverify())
    }

    func testCreationRejectsMissingDeclaredFile() throws {
        let missing = FixtureFile(
            path: "missing.safetensors",
            data: Data("expected bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [])

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [missing])
            )
        )
    }

    func testCreationRejectsWrongDeclaredSize() throws {
        let sourceFile = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let wrongDeclaration = FixtureFile(
            path: sourceFile.path,
            data: sourceFile.data,
            expectedSize: Int64(sourceFile.data.count + 1)
        )
        let sourceURL = try makeSourceDirectory(containing: [sourceFile])

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [wrongDeclaration])
            )
        )
    }

    func testCreationRejectsWrongDeclaredSHA256() throws {
        let sourceFile = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let wrongDeclaration = FixtureFile(
            path: sourceFile.path,
            data: sourceFile.data,
            expectedSHA256: String(repeating: "0", count: 64)
        )
        let sourceURL = try makeSourceDirectory(containing: [sourceFile])

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [wrongDeclaration])
            )
        )
    }

    func testCreationRejectsFinalSymbolicLinkEvenWhenTargetBytesMatch() throws {
        let declared = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [])
        let outsideURL = try makeSourceDirectory(containing: [
            FixtureFile(path: "outside.safetensors", data: declared.data),
        ])
        try FileManager.default.createSymbolicLink(
            at: sourceURL.appendingPathComponent(declared.path),
            withDestinationURL: outsideURL.appendingPathComponent("outside.safetensors")
        )

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [declared])
            )
        )
    }

    func testCreationRejectsIntermediateSymbolicLinkEvenWhenTargetBytesMatch() throws {
        let declared = FixtureFile(
            path: "nested/model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [])
        let outsideURL = try makeSourceDirectory(containing: [
            FixtureFile(path: "model.safetensors", data: declared.data),
        ])
        try FileManager.default.createSymbolicLink(
            at: sourceURL.appendingPathComponent("nested"),
            withDestinationURL: outsideURL
        )

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [declared])
            )
        )
    }

    func testCreationRejectsHardLinkedDeclaredFile() throws {
        let declared = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [])
        let outsideURL = try makeSourceDirectory(containing: [
            FixtureFile(path: "outside.safetensors", data: declared.data),
        ])
        let outsideFile = outsideURL.appendingPathComponent("outside.safetensors")
        let declaredFile = sourceURL.appendingPathComponent(declared.path)
        let linkResult = outsideFile.path.withCString { oldPath in
            declaredFile.path.withCString { newPath in
                Darwin.link(oldPath, newPath)
            }
        }
        XCTAssertEqual(linkResult, 0)
        XCTAssertGreaterThan(try linkCount(of: declaredFile), 1)

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [declared])
            )
        )
    }

    func testCreationRejectsNonRegularDeclaredEntry() throws {
        let declared = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [])
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent(declared.path),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: makeBinding(for: [declared])
            )
        )
    }

    func testReverifyDetectsSnapshotByteMutation() throws {
        let declared = FixtureFile(
            path: "model.safetensors",
            data: Data("original model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [declared])
        let snapshot = try RuntimeModelSnapshot(
            sourceURL: sourceURL,
            contentBinding: makeBinding(for: [declared])
        )
        defer { try? snapshot.remove() }
        let snapshottedFile = snapshot.snapshotURL.appendingPathComponent(declared.path)
        try overwriteInPlace(
            Data(repeating: 0x58, count: declared.data.count),
            at: snapshottedFile
        )

        XCTAssertThrowsError(try snapshot.reverify())
    }

    func testRemoveIsIdempotentAndInvalidatesReverification() throws {
        let declared = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [declared])
        let snapshot = try RuntimeModelSnapshot(
            sourceURL: sourceURL,
            contentBinding: makeBinding(for: [declared])
        )
        let snapshotURL = snapshot.snapshotURL

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertNoThrow(try snapshot.remove())
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertNoThrow(try snapshot.remove())
        XCTAssertThrowsError(try snapshot.reverify())
    }

    func testRemoveDeletesRenamedOwnedRootWithoutDeletingPathReplacement() throws {
        let declared = FixtureFile(
            path: "weights/model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [declared])
        let snapshot = try RuntimeModelSnapshot(
            sourceURL: sourceURL,
            contentBinding: makeBinding(for: [declared])
        )
        let publishedURL = snapshot.snapshotURL
        let renamedURL = publishedURL.deletingLastPathComponent()
            .appendingPathComponent(
                publishedURL.lastPathComponent + "-renamed-" + UUID().uuidString,
                isDirectory: true
            )
        cleanupURLs.append(renamedURL)
        cleanupURLs.append(publishedURL)

        try FileManager.default.moveItem(at: publishedURL, to: renamedURL)
        try FileManager.default.createDirectory(
            at: publishedURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinelURL = publishedURL.appendingPathComponent("replacement-sentinel")
        let sentinel = Data("must survive snapshot cleanup".utf8)
        try sentinel.write(to: sentinelURL)

        XCTAssertNoThrow(try snapshot.remove())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: renamedURL.path),
            "cleanup must remove the owned root through its retained identity"
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinelURL),
            sentinel,
            "cleanup must not recurse through a replacement at the published path"
        )
        XCTAssertNoThrow(try snapshot.remove())
        XCTAssertThrowsError(try snapshot.reverify())
    }

    func testDeinitRemovesOwnedPrivateRoot() throws {
        let declared = FixtureFile(
            path: "model.safetensors",
            data: Data("model bytes".utf8)
        )
        let sourceURL = try makeSourceDirectory(containing: [declared])
        let binding = try makeBinding(for: [declared])
        weak var weakSnapshot: RuntimeModelSnapshot?
        var ownedURL: URL?

        do {
            let snapshot = try RuntimeModelSnapshot(
                sourceURL: sourceURL,
                contentBinding: binding
            )
            weakSnapshot = snapshot
            ownedURL = snapshot.snapshotURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.snapshotURL.path))
        }

        XCTAssertNil(weakSnapshot)
        let unwrappedURL = try XCTUnwrap(ownedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwrappedURL.path))
    }

    private func makeBinding(
        for fixtureFiles: [FixtureFile]
    ) throws -> RuntimeModelContentBinding {
        let files = fixtureFiles.map { file in
            RuntimeModelContentBinding.File(
                path: file.path,
                size: file.expectedSize,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: file.expectedSHA256,
                actualSHA256: file.expectedSHA256
            )
        }.sorted { $0.path < $1.path }
        let fingerprint = try canonicalFingerprint(for: files)
        return try RuntimeModelContentBinding(
            algorithm: Self.algorithm,
            schemaVersion: 1,
            repositoryID: Self.repositoryID,
            revision: Self.revision,
            files: files,
            fingerprintSHA256: fingerprint
        )
    }

    private func canonicalFingerprint(
        for files: [RuntimeModelContentBinding.File]
    ) throws -> String {
        let document = CanonicalFingerprintDocument(
            algorithm: Self.algorithm,
            schemaVersion: 1,
            repositoryID: Self.repositoryID,
            revision: Self.revision,
            files: files.map {
                CanonicalFingerprintDocument.File(
                    path: $0.path,
                    size: $0.size,
                    declaredDigestAlgorithm: $0.declaredDigestAlgorithm,
                    declaredDigest: $0.declaredDigest,
                    actualSHA256: $0.actualSHA256
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(document))
    }

    private func makeSourceDirectory(containing files: [FixtureFile]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeModelSnapshotSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        cleanupURLs.append(root)

        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try file.data.write(to: url)
        }
        return root
    }

    private func assertPrivateTemporaryRoot(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let canonicalTemporary = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let canonicalSnapshot = url
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let prefix = canonicalTemporary == "/"
            ? canonicalTemporary
            : canonicalTemporary + "/"
        XCTAssertTrue(
            canonicalSnapshot.hasPrefix(prefix),
            "snapshot must reside below the process temporary directory",
            file: file,
            line: line
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType,
            .typeDirectory,
            file: file,
            line: line
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber,
            file: file,
            line: line
        )
        XCTAssertEqual(
            permissions.intValue & 0o777,
            0o700,
            "snapshot root must be accessible only to its owner",
            file: file,
            line: line
        )
    }

    private func overwriteInPlace(_ data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private func linkCount(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.referenceCount] as? NSNumber).uint64Value
    }

    private struct FixtureFile {
        let path: String
        let data: Data
        let expectedSize: Int64
        let expectedSHA256: String

        init(
            path: String,
            data: Data,
            expectedSize: Int64? = nil,
            expectedSHA256: String? = nil
        ) {
            self.path = path
            self.data = data
            self.expectedSize = expectedSize ?? Int64(data.count)
            self.expectedSHA256 = expectedSHA256 ?? sha256(data)
        }
    }

    private struct CanonicalFingerprintDocument: Encodable {
        let algorithm: String
        let schemaVersion: Int
        let repositoryID: String
        let revision: String
        let files: [File]

        struct File: Encodable {
            let path: String
            let size: Int64
            let declaredDigestAlgorithm: String
            let declaredDigest: String
            let actualSHA256: String
        }
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
