import CryptoKit
import Foundation

/// Canonical, content-addressed description of the exact model tree authorized
/// by the app. The runtime service must verify every entry before loading and
/// return `fingerprintSHA256` in its load response.
public struct RuntimeModelContentBinding: Codable, Equatable, Sendable {
    public static let fingerprintAlgorithm = "supra-release-model-sha256-v1"
    public static let supportedManifestSchemaVersion = 1

    public let algorithm: String
    public let schemaVersion: Int
    public let repositoryID: String
    public let revision: String
    public let files: [File]
    public let fingerprintSHA256: String

    public init(
        algorithm: String,
        schemaVersion: Int,
        repositoryID: String,
        revision: String,
        files: [File],
        fingerprintSHA256: String
    ) throws {
        let canonicalFingerprint = try Self.canonicalFingerprintSHA256(
            algorithm: algorithm,
            schemaVersion: schemaVersion,
            repositoryID: repositoryID,
            revision: revision,
            files: files
        )
        guard Self.isLowercaseHex(fingerprintSHA256, count: 64) else {
            throw RuntimeModelContentBindingError.invalidFingerprintSHA256
        }
        guard Self.constantTimeEqual(canonicalFingerprint, fingerprintSHA256) else {
            throw RuntimeModelContentBindingError.fingerprintMismatch
        }

        self.algorithm = algorithm
        self.schemaVersion = schemaVersion
        self.repositoryID = repositoryID
        self.revision = revision
        self.files = files
        self.fingerprintSHA256 = fingerprintSHA256
    }

    /// Reproduces the authorization fingerprint. The returned hash covers the
    /// complete document below but deliberately excludes `fingerprintSHA256`.
    public static func canonicalFingerprintSHA256(
        algorithm: String,
        schemaVersion: Int,
        repositoryID: String,
        revision: String,
        files: [File]
    ) throws -> String {
        try validateCanonicalFields(
            algorithm: algorithm,
            schemaVersion: schemaVersion,
            repositoryID: repositoryID,
            revision: revision,
            files: files
        )
        let document = CanonicalFingerprintDocument(
            algorithm: algorithm,
            schemaVersion: schemaVersion,
            repositoryID: repositoryID,
            revision: revision,
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(document)
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: any Decoder) throws {
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        let receivedKeys = Set(dynamicContainer.allKeys.map(\.stringValue))
        guard receivedKeys == allowedKeys else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Model content binding keys are missing or unexpected."
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                algorithm: container.decode(String.self, forKey: .algorithm),
                schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
                repositoryID: container.decode(String.self, forKey: .repositoryID),
                revision: container.decode(String.self, forKey: .revision),
                files: container.decode([File].self, forKey: .files),
                fingerprintSHA256: container.decode(String.self, forKey: .fingerprintSHA256)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Model content binding is not canonical.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(repositoryID, forKey: .repositoryID)
        try container.encode(revision, forKey: .revision)
        try container.encode(files, forKey: .files)
        try container.encode(fingerprintSHA256, forKey: .fingerprintSHA256)
    }

    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let declaredDigestAlgorithm: String
        public let declaredDigest: String
        public let actualSHA256: String

        public init(
            path: String,
            size: Int64,
            declaredDigestAlgorithm: String,
            declaredDigest: String,
            actualSHA256: String
        ) {
            self.path = path
            self.size = size
            self.declaredDigestAlgorithm = declaredDigestAlgorithm
            self.declaredDigest = declaredDigest
            self.actualSHA256 = actualSHA256
        }

        public init(from decoder: any Decoder) throws {
            let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
            let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
            let receivedKeys = Set(dynamicContainer.allKeys.map(\.stringValue))
            guard receivedKeys == allowedKeys else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Model content binding file keys are missing or unexpected."
                    )
                )
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                path: try container.decode(String.self, forKey: .path),
                size: try container.decode(Int64.self, forKey: .size),
                declaredDigestAlgorithm: try container.decode(
                    String.self,
                    forKey: .declaredDigestAlgorithm
                ),
                declaredDigest: try container.decode(String.self, forKey: .declaredDigest),
                actualSHA256: try container.decode(String.self, forKey: .actualSHA256)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(size, forKey: .size)
            try container.encode(declaredDigestAlgorithm, forKey: .declaredDigestAlgorithm)
            try container.encode(declaredDigest, forKey: .declaredDigest)
            try container.encode(actualSHA256, forKey: .actualSHA256)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case path
            case size
            case declaredDigestAlgorithm
            case declaredDigest
            case actualSHA256
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case algorithm
        case schemaVersion
        case repositoryID
        case revision
        case files
        case fingerprintSHA256
    }

    private struct CanonicalFingerprintDocument: Encodable {
        let algorithm: String
        let schemaVersion: Int
        let repositoryID: String
        let revision: String
        let files: [File]
    }

    private static func validateCanonicalFields(
        algorithm: String,
        schemaVersion: Int,
        repositoryID: String,
        revision: String,
        files: [File]
    ) throws {
        guard algorithm == fingerprintAlgorithm else {
            throw RuntimeModelContentBindingError.unsupportedAlgorithm
        }
        guard schemaVersion == supportedManifestSchemaVersion else {
            throw RuntimeModelContentBindingError.unsupportedSchemaVersion(schemaVersion)
        }
        guard isValidRepositoryID(repositoryID) else {
            throw RuntimeModelContentBindingError.invalidRepositoryID
        }
        guard isLowercaseHex(revision, count: 40) else {
            throw RuntimeModelContentBindingError.invalidRevision
        }
        guard !files.isEmpty else {
            throw RuntimeModelContentBindingError.emptyFileList
        }

        var previousPath: String?
        for file in files {
            guard isSafeRelativePath(file.path) else {
                throw RuntimeModelContentBindingError.unsafePath(file.path)
            }
            if let previousPath, previousPath >= file.path {
                throw RuntimeModelContentBindingError.noncanonicalFileOrder
            }
            previousPath = file.path

            guard file.size >= 0 else {
                throw RuntimeModelContentBindingError.invalidFileSize(file.path)
            }
            let declaredDigestLength: Int
            switch file.declaredDigestAlgorithm {
            case "sha256":
                declaredDigestLength = 64
            case "git-blob-sha1":
                declaredDigestLength = 40
            default:
                throw RuntimeModelContentBindingError.unsupportedDeclaredDigestAlgorithm(
                    file.path
                )
            }
            guard isLowercaseHex(file.declaredDigest, count: declaredDigestLength) else {
                throw RuntimeModelContentBindingError.invalidDeclaredDigest(file.path)
            }
            guard isLowercaseHex(file.actualSHA256, count: 64) else {
                throw RuntimeModelContentBindingError.invalidActualSHA256(file.path)
            }
        }
    }

    private static func isValidRepositoryID(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty, component != ".", component != ".." else {
                return false
            }
            return component.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
                    || byte == 46
                    || byte == 95
            }
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        let reserved = Set([
            ".supra-model-manifest.json",
            ".supra-model-download-state.json",
        ])
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\\")
            && !value.contains("%")
            && !value.contains("\0")
            && !components.isEmpty
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && !reserved.contains(String($0))
            }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
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
}

public enum RuntimeModelContentBindingError: Error, Equatable, Sendable {
    case unsupportedAlgorithm
    case unsupportedSchemaVersion(Int)
    case invalidRepositoryID
    case invalidRevision
    case emptyFileList
    case noncanonicalFileOrder
    case unsafePath(String)
    case invalidFileSize(String)
    case unsupportedDeclaredDigestAlgorithm(String)
    case invalidDeclaredDigest(String)
    case invalidActualSHA256(String)
    case invalidFingerprintSHA256
    case fingerprintMismatch
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
