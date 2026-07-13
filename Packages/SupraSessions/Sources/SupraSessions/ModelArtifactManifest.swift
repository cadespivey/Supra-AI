import CryptoKit
import Foundation

/// The authoritative, revision-pinned description of one managed model install.
/// The same value is obtained from the repository metadata endpoint, persisted as
/// `.supra-model-manifest.json`, and re-verified before a managed model is loaded.
public struct ModelArtifactManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var repositoryID: String
    public var revision: String
    public var files: [File]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        repositoryID: String,
        revision: String,
        files: [File]
    ) {
        self.schemaVersion = schemaVersion
        self.repositoryID = repositoryID
        self.revision = revision.lowercased()
        self.files = files.sorted { $0.relativePath < $1.relativePath }
    }

    public struct File: Codable, Equatable, Sendable {
        public var relativePath: String
        public var size: Int64
        public var digestAlgorithm: DigestAlgorithm
        public var digest: String

        public init(
            relativePath: String,
            size: Int64,
            digestAlgorithm: DigestAlgorithm,
            digest: String
        ) {
            self.relativePath = relativePath
            self.size = size
            self.digestAlgorithm = digestAlgorithm
            self.digest = digest.lowercased()
        }
    }

    public enum DigestAlgorithm: String, Codable, Equatable, Sendable {
        /// Hash of the file bytes. Hugging Face exposes this for LFS artifacts.
        case sha256
        /// Git object hash: SHA-1 of `blob <size>\0` followed by the file bytes.
        case gitBlobSHA1 = "git-blob-sha1"
    }

    func canonicalized() -> Self {
        Self(
            schemaVersion: schemaVersion,
            repositoryID: repositoryID,
            revision: revision,
            files: files
        )
    }

    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ManagedModelIntegrityError.unsupportedManifestVersion(schemaVersion)
        }
        guard Self.isValidRepositoryID(repositoryID) else {
            throw ManagedModelIntegrityError.invalidRepositoryID
        }
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else {
            throw ManagedModelIntegrityError.unresolvedRevision
        }
        guard !files.isEmpty else { throw ManagedModelIntegrityError.emptyManifest }

        var seen = Set<String>()
        for file in files {
            try Self.validate(relativePath: file.relativePath)
            guard seen.insert(file.relativePath).inserted else {
                throw ManagedModelIntegrityError.duplicateArtifact(file.relativePath)
            }
            guard file.size >= 0 else {
                throw ManagedModelIntegrityError.invalidArtifactSize(file.relativePath)
            }
            let expectedCount = file.digestAlgorithm == .sha256 ? 64 : 40
            guard file.digest.count == expectedCount, file.digest.allSatisfy(\.isHexDigit) else {
                throw ManagedModelIntegrityError.invalidDigest(file.relativePath)
            }
        }

        guard files.contains(where: { $0.relativePath == "config.json" }) else {
            throw ManagedModelIntegrityError.missingRequiredFile("config.json")
        }
        let hasWeights = files.contains { file in
            let name = URL(fileURLWithPath: file.relativePath).lastPathComponent.lowercased()
            return name.hasSuffix(".safetensors")
                || name.hasSuffix(".gguf")
                || (name.hasPrefix("pytorch_model") && name.hasSuffix(".bin"))
                || name == "model.bin"
        }
        guard hasWeights else {
            throw ManagedModelIntegrityError.missingRequiredFile("model weights")
        }
    }

    static func validate(relativePath: String) throws {
        let reserved = Set([
            ManagedModelStorage.manifestFileName,
            ManagedModelStorage.downloadStateFileName,
        ])
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("%"),
              !relativePath.contains("\0"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !reserved.contains($0) })
        else {
            throw ManagedModelIntegrityError.invalidArtifactPath(relativePath)
        }
    }

    static func isValidRepositoryID(_ repositoryID: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        let components = repositoryID.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

enum ModelArtifactIntegrity {
    static func verify(_ data: Data, against artifact: ModelArtifactManifest.File) throws {
        guard Int64(data.count) == artifact.size else {
            throw ManagedModelIntegrityError.artifactSizeMismatch(artifact.relativePath)
        }
        let actual: String
        switch artifact.digestAlgorithm {
        case .sha256:
            actual = sha256Hex(data)
        case .gitBlobSHA1:
            actual = gitBlobSHA1Hex(data)
        }
        guard constantTimeEqual(actual, artifact.digest.lowercased()) else {
            throw ManagedModelIntegrityError.artifactDigestMismatch(artifact.relativePath)
        }
    }

    static func verify(_ url: URL, against artifact: ModelArtifactManifest.File) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ManagedModelIntegrityError.unsafeDestination(artifact.relativePath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ManagedModelIntegrityError.artifactMissing(artifact.relativePath)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber,
              number.int64Value == artifact.size else {
            throw ManagedModelIntegrityError.artifactSizeMismatch(artifact.relativePath)
        }
        let actual = try digest(of: url, algorithm: artifact.digestAlgorithm, size: artifact.size)
        guard constantTimeEqual(actual, artifact.digest.lowercased()) else {
            throw ManagedModelIntegrityError.artifactDigestMismatch(artifact.relativePath)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    static func gitBlobSHA1Hex(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().hexString
    }

    private static func digest(
        of url: URL,
        algorithm: ModelArtifactManifest.DigestAlgorithm,
        size: Int64
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().hexString
        case .gitBlobSHA1:
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\0".utf8))
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().hexString
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

public enum ManagedModelIntegrityError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedManifestVersion(Int)
    case invalidRepositoryID
    case unresolvedRevision
    case emptyManifest
    case invalidArtifactPath(String)
    case duplicateArtifact(String)
    case invalidArtifactSize(String)
    case invalidDigest(String)
    case missingRequiredFile(String)
    case invalidConfiguration
    case manifestMissing
    case manifestMismatch
    case artifactMissing(String)
    case artifactSizeMismatch(String)
    case artifactDigestMismatch(String)
    case unsafeDestination(String)
    case atomicInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedManifestVersion:
            "The downloaded model manifest uses an unsupported version. Re-download the model."
        case .invalidRepositoryID, .unresolvedRevision, .emptyManifest, .manifestMismatch:
            "The model repository metadata could not be verified. Try the download again."
        case let .invalidArtifactPath(path):
            "The model repository contains an unsafe file path: \(path)."
        case let .duplicateArtifact(path):
            "The model repository lists a file more than once: \(path)."
        case let .invalidArtifactSize(path), let .invalidDigest(path):
            "The model repository has incomplete integrity metadata for \(path)."
        case let .missingRequiredFile(file):
            "The model repository is missing required \(file)."
        case .invalidConfiguration:
            "The downloaded model configuration could not be verified."
        case .manifestMissing:
            "The downloaded model has no verified manifest. Re-download the model."
        case let .artifactMissing(file), let .artifactSizeMismatch(file), let .artifactDigestMismatch(file):
            "The downloaded model failed integrity verification for \(file). Re-download or repair it."
        case let .unsafeDestination(file):
            "The model file could not be placed safely: \(file)."
        case let .atomicInstallFailed(file):
            "The verified model file could not be installed: \(file)."
        }
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
