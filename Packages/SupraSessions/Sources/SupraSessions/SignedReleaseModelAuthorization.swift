import CryptoKit
import Foundation
import SupraCore
import SupraRuntimeInterface

/// Holds a release-smoke model authorization from preflight through XPC load and
/// postflight. Only an exclusive, revision-pinned tree inside the app-managed
/// model root can be authorized.
public final class SignedReleaseModelAuthorization: @unchecked Sendable {
    public static let fingerprintAlgorithm = RuntimeModelContentBinding.fingerprintAlgorithm

    public let manifest: ModelArtifactManifest
    public let modelSHA256: String
    public let contentBinding: RuntimeModelContentBinding

    private let modelDirectory: URL
    private let managedRoot: URL
    private let modelBookmark: Data
    private let modelDirectoryIdentity: ModelDirectoryIdentity
    private let scopedAccess: SecurityScopedModelAccess

    private init(
        modelDirectory: URL,
        managedRoot: URL,
        manifest: ModelArtifactManifest,
        contentBinding: RuntimeModelContentBinding,
        modelBookmark: Data,
        modelDirectoryIdentity: ModelDirectoryIdentity,
        scopedAccess: SecurityScopedModelAccess
    ) {
        self.modelDirectory = modelDirectory
        self.managedRoot = managedRoot
        self.manifest = manifest
        self.modelSHA256 = contentBinding.fingerprintSHA256
        self.contentBinding = contentBinding
        self.modelBookmark = modelBookmark
        self.modelDirectoryIdentity = modelDirectoryIdentity
        self.scopedAccess = scopedAccess
    }

    deinit {
        scopedAccess.release()
    }

    public static func authorize(
        modelDirectory: URL,
        managedRoot: URL,
        expectedSHA256: String
    ) throws -> SignedReleaseModelAuthorization {
        guard isLowercaseSHA256(expectedSHA256) else {
            throw SignedReleaseModelAuthorizationError.invalidExpectedSHA256
        }

        let paths = try validatedPaths(modelDirectory: modelDirectory, managedRoot: managedRoot)
        let snapshot = try captureSnapshot(paths: paths)
        guard constantTimeEqual(snapshot.contentBinding.fingerprintSHA256, expectedSHA256) else {
            throw SignedReleaseModelAuthorizationError.fingerprintMismatch
        }

        let access = SecurityScopedModelAccess(url: paths.modelDirectory)
        guard access.hasAccess,
              let authorization = access.makeTransferableAuthorization() else {
            access.release()
            throw SignedReleaseModelAuthorizationError.transferableAuthorizationUnavailable
        }

        let result = SignedReleaseModelAuthorization(
            modelDirectory: paths.modelDirectory,
            managedRoot: paths.managedRoot,
            manifest: snapshot.manifest,
            contentBinding: snapshot.contentBinding,
            modelBookmark: authorization.bookmark,
            modelDirectoryIdentity: authorization.directoryIdentity,
            scopedAccess: access
        )
        try result.reverify()
        return result
    }

    public func makeLoadRequest(modelID: ModelID, displayName: String) throws -> LoadModelRequest {
        try reverify()
        return LoadModelRequest(
            modelID: modelID,
            modelPath: modelDirectory.path,
            displayName: displayName,
            modelBookmark: modelBookmark,
            managedRootPath: managedRoot.path,
            modelDirectoryIdentity: modelDirectoryIdentity,
            contentBinding: contentBinding
        )
    }

    /// Repeats the complete identity, tree, manifest, and byte-fingerprint
    /// verification. The signed smoke runner calls this after model unload.
    public func reverify() throws {
        guard ModelDirectoryIdentity(url: modelDirectory) == modelDirectoryIdentity else {
            throw SignedReleaseModelAuthorizationError.modelDirectoryIdentityMismatch
        }

        let paths = try Self.validatedPaths(
            modelDirectory: modelDirectory,
            managedRoot: managedRoot
        )
        let snapshot = try Self.captureSnapshot(paths: paths)

        guard ModelDirectoryIdentity(url: modelDirectory) == modelDirectoryIdentity else {
            throw SignedReleaseModelAuthorizationError.modelDirectoryIdentityMismatch
        }
        guard snapshot.manifest == manifest else {
            throw SignedReleaseModelAuthorizationError.manifestChanged
        }
        guard snapshot.contentBinding == contentBinding,
              Self.constantTimeEqual(
                  snapshot.contentBinding.fingerprintSHA256,
                  modelSHA256
              ) else {
            throw SignedReleaseModelAuthorizationError.fingerprintMismatch
        }
    }

    private static func captureSnapshot(paths: ValidatedPaths) throws -> Snapshot {
        let manifest = try ManagedModelStorage.loadVerifiedManifest(at: paths.modelDirectory)
        try verifyExclusiveTree(in: paths.modelDirectory, manifest: manifest)
        let contentBinding = try contentBinding(
            modelDirectory: paths.modelDirectory,
            manifest: manifest
        )

        // Close the most useful mutation window: the declared hashes and exact
        // tree must still be valid after the independent SHA-256 pass finishes.
        let manifestAfterFingerprint = try ManagedModelStorage.loadVerifiedManifest(
            at: paths.modelDirectory
        )
        guard manifestAfterFingerprint == manifest else {
            throw SignedReleaseModelAuthorizationError.manifestChanged
        }
        try verifyExclusiveTree(in: paths.modelDirectory, manifest: manifest)
        return Snapshot(manifest: manifest, contentBinding: contentBinding)
    }

    private static func validatedPaths(
        modelDirectory: URL,
        managedRoot: URL
    ) throws -> ValidatedPaths {
        let root = managedRoot.standardizedFileURL
        let model = modelDirectory.standardizedFileURL
        try requireDirectory(root, error: .managedRootUnavailable)
        try requireDirectory(model, error: .modelDirectoryUnavailable)

        guard !isSymbolicLink(root) else {
            throw SignedReleaseModelAuthorizationError.symbolicLink(".")
        }

        let relativePath = try strictRelativePath(of: model, beneath: root)
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if isSymbolicLink(current) {
                let relative = String(current.path.dropFirst(root.path.count + 1))
                throw SignedReleaseModelAuthorizationError.symbolicLink(relative)
            }
        }

        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalModel = model.resolvingSymlinksInPath().standardizedFileURL
        _ = try strictRelativePath(of: canonicalModel, beneath: canonicalRoot)
        return ValidatedPaths(managedRoot: root, modelDirectory: model)
    }

    private static func requireDirectory(
        _ url: URL,
        error: SignedReleaseModelAuthorizationError
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw error
        }
    }

    private static func strictRelativePath(of candidate: URL, beneath root: URL) throws -> String {
        let rootPath = root.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard candidate.path != rootPath, candidate.path.hasPrefix(prefix) else {
            throw SignedReleaseModelAuthorizationError.modelDirectoryOutsideManagedRoot
        }
        return String(candidate.path.dropFirst(prefix.count))
    }

    private static func verifyExclusiveTree(
        in modelDirectory: URL,
        manifest: ModelArtifactManifest
    ) throws {
        let allowedFiles = Set(
            manifest.files.map(\.relativePath) + [ManagedModelStorage.manifestFileName]
        )
        var allowedDirectories = Set<String>()
        for artifact in manifest.files {
            let components = artifact.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var current = ""
            for component in components.dropLast() {
                current = current.isEmpty ? component : current + "/" + component
                allowedDirectories.insert(current)
            }
        }

        try inspectDirectory(
            modelDirectory,
            relativeDirectory: "",
            allowedFiles: allowedFiles,
            allowedDirectories: allowedDirectories
        )
    }

    private static func inspectDirectory(
        _ directory: URL,
        relativeDirectory: String,
        allowedFiles: Set<String>,
        allowedDirectories: Set<String>
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let relativePath = relativeDirectory.isEmpty
                ? entry.lastPathComponent
                : relativeDirectory + "/" + entry.lastPathComponent
            let values = try entry.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw SignedReleaseModelAuthorizationError.symbolicLink(relativePath)
            }
            if values.isDirectory == true {
                guard allowedDirectories.contains(relativePath) else {
                    throw SignedReleaseModelAuthorizationError.undeclaredEntry(relativePath)
                }
                try inspectDirectory(
                    entry,
                    relativeDirectory: relativePath,
                    allowedFiles: allowedFiles,
                    allowedDirectories: allowedDirectories
                )
            } else if values.isRegularFile == true {
                guard allowedFiles.contains(relativePath) else {
                    throw SignedReleaseModelAuthorizationError.undeclaredEntry(relativePath)
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
                guard let referenceCount = attributes[.referenceCount] as? NSNumber,
                      referenceCount.intValue == 1 else {
                    throw SignedReleaseModelAuthorizationError.hardLinkedEntry(relativePath)
                }
            } else {
                throw SignedReleaseModelAuthorizationError.unsupportedEntry(relativePath)
            }
        }
    }

    private static func contentBinding(
        modelDirectory: URL,
        manifest: ModelArtifactManifest
    ) throws -> RuntimeModelContentBinding {
        let files = try manifest.files.sorted { $0.relativePath < $1.relativePath }.map { artifact in
            let url = try ManagedModelStorage.safeDestination(
                for: artifact.relativePath,
                in: modelDirectory
            )
            return RuntimeModelContentBinding.File(
                path: artifact.relativePath,
                size: artifact.size,
                declaredDigestAlgorithm: artifact.digestAlgorithm.rawValue,
                declaredDigest: artifact.digest.lowercased(),
                actualSHA256: try sha256(of: url)
            )
        }
        let fingerprint = try RuntimeModelContentBinding.canonicalFingerprintSHA256(
            algorithm: fingerprintAlgorithm,
            schemaVersion: manifest.schemaVersion,
            repositoryID: manifest.repositoryID,
            revision: manifest.revision.lowercased(),
            files: files
        )
        return try RuntimeModelContentBinding(
            algorithm: fingerprintAlgorithm,
            schemaVersion: manifest.schemaVersion,
            repositoryID: manifest.repositoryID,
            revision: manifest.revision.lowercased(),
            files: files,
            fingerprintSHA256: fingerprint
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private struct ValidatedPaths {
        let managedRoot: URL
        let modelDirectory: URL
    }

    private struct Snapshot {
        let manifest: ModelArtifactManifest
        let contentBinding: RuntimeModelContentBinding
    }
}

public enum SignedReleaseModelAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    case invalidExpectedSHA256
    case managedRootUnavailable
    case modelDirectoryUnavailable
    case modelDirectoryOutsideManagedRoot
    case symbolicLink(String)
    case hardLinkedEntry(String)
    case undeclaredEntry(String)
    case unsupportedEntry(String)
    case fingerprintMismatch
    case transferableAuthorizationUnavailable
    case modelDirectoryIdentityMismatch
    case manifestChanged

    public var errorDescription: String? {
        switch self {
        case .invalidExpectedSHA256:
            "The protected release model fingerprint is invalid."
        case .managedRootUnavailable, .modelDirectoryUnavailable:
            "The protected release model directory is unavailable."
        case .modelDirectoryOutsideManagedRoot:
            "The protected release model is outside the app-managed model root."
        case let .symbolicLink(relativePath):
            "The protected release model contains a symbolic link at \(relativePath)."
        case let .hardLinkedEntry(relativePath):
            "The protected release model contains a hard-linked entry at \(relativePath)."
        case let .undeclaredEntry(relativePath):
            "The protected release model contains an undeclared entry at \(relativePath)."
        case let .unsupportedEntry(relativePath):
            "The protected release model contains an unsupported entry at \(relativePath)."
        case .fingerprintMismatch:
            "The protected release model fingerprint does not match."
        case .transferableAuthorizationUnavailable:
            "The protected release model could not be authorized for the runtime service."
        case .modelDirectoryIdentityMismatch:
            "The protected release model directory changed during authorization."
        case .manifestChanged:
            "The protected release model manifest changed during authorization."
        }
    }
}
