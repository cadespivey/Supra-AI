import Foundation
import SupraNetworking

/// Abstracts listing and downloading a model repository's files so the download
/// controller can be unit-tested against a stub.
public protocol ModelRepositoryFetching: Sendable {
    /// Resolves the repository's floating name to one immutable commit and returns
    /// complete size/digest metadata for every artifact.
    func fetchManifest(repoID: String) async throws -> ModelArtifactManifest
    /// Downloads one artifact from the resolved revision to a caller-owned partial path.
    /// `onBytes` receives the cumulative bytes transferred for THIS artifact as the
    /// transfer proceeds (already throttled by the transport); implementations may
    /// call it from any executor, and awaiting it lets tests observe each report
    /// deterministically before the transfer continues.
    func downloadFile(
        repoID: String,
        revision: String,
        artifact: ModelArtifactManifest.File,
        to destination: URL,
        onBytes: (@Sendable (Int64) async -> Void)?
    ) async throws
    /// Fetches `config.json` from the same immutable revision for the early
    /// compatibility check performed before multi-gigabyte weights are transferred.
    func fetchConfigJSON(repoID: String, revision: String) async throws -> Data?
}

public enum HuggingFaceError: Error, LocalizedError {
    case invalidRepoID(String)
    case requestFailed(String, Int)
    case emptyRepository(String)
    case incompleteMetadata(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepoID(repo):
            "‘\(repo)’ is not a valid Hugging Face repo id (expected ‘org/name’)."
        case let .requestFailed(file, code):
            "Download failed for \(file) (HTTP \(code))."
        case let .emptyRepository(repo):
            "No files found in \(repo)."
        case let .incompleteMetadata(file):
            "The repository did not provide verifiable size and digest metadata for \(file)."
        }
    }
}

/// Downloads MLX model repositories directly from the Hugging Face Hub over HTTPS.
public struct HuggingFaceClient: ModelRepositoryFetching {
    private let transport: PolicyEnforcingURLSessionTransport
    private let host = "https://huggingface.co"

    public init(session: URLSession = .shared) {
        self.transport = PolicyEnforcingURLSessionTransport(session: session)
    }

    public func fetchManifest(repoID: String) async throws -> ModelArtifactManifest {
        try Self.validate(repoID)
        guard var components = URLComponents(string: "\(host)/api/models/\(repoID)") else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }
        // `blobs=true` is the Hub API switch that supplies `size`, `blobId`, and
        // LFS SHA-256 metadata for every sibling. Without it the listing is not
        // sufficient to make an integrity decision.
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components.url else { throw HuggingFaceError.invalidRepoID(repoID) }
        try Self.enforceHost(url)
        let result = try await transport.data(
            for: URLRequest(url: url),
            policy: RedirectPolicy.huggingFace(initialURL: url)
        )
        try Self.check(result.response, file: "model index")

        return try Self.decodeManifest(repoID: repoID, data: result.data)
    }

    static func decodeManifest(repoID: String, data: Data) throws -> ModelArtifactManifest {
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        guard !info.siblings.isEmpty else { throw HuggingFaceError.emptyRepository(repoID) }
        let files = try info.siblings.map { sibling -> ModelArtifactManifest.File in
            if let lfs = sibling.lfs {
                guard !lfs.sha256.isEmpty else {
                    throw HuggingFaceError.incompleteMetadata(sibling.rfilename)
                }
                return ModelArtifactManifest.File(
                    relativePath: sibling.rfilename,
                    size: lfs.size,
                    digestAlgorithm: .sha256,
                    digest: lfs.sha256
                )
            }
            guard let size = sibling.size, let blobID = sibling.blobId, !blobID.isEmpty else {
                throw HuggingFaceError.incompleteMetadata(sibling.rfilename)
            }
            return ModelArtifactManifest.File(
                relativePath: sibling.rfilename,
                size: size,
                digestAlgorithm: .gitBlobSHA1,
                digest: blobID
            )
        }
        let manifest = ModelArtifactManifest(
            repositoryID: repoID,
            revision: info.sha,
            files: files
        )
        try manifest.validateStructure()
        return manifest
    }

    public func downloadFile(
        repoID: String,
        revision: String,
        artifact: ModelArtifactManifest.File,
        to destination: URL,
        onBytes: (@Sendable (Int64) async -> Void)?
    ) async throws {
        try Self.validate(repoID)
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else {
            throw HuggingFaceError.incompleteMetadata(artifact.relativePath)
        }
        try ModelArtifactManifest.validate(relativePath: artifact.relativePath)
        var allowedPathComponent = CharacterSet.urlPathAllowed
        allowedPathComponent.remove(charactersIn: "/?#")
        let encodedFile = artifact.relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowedPathComponent) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "\(host)/\(repoID)/resolve/\(revision)/\(encodedFile)") else {
            throw HuggingFaceError.requestFailed(artifact.relativePath, -1)
        }
        try Self.enforceHost(url)

        // The transport reports on URLSession's delegate queue; bridge each
        // (already ~2 MB-throttled) report into a task. Reports are cumulative,
        // so out-of-order delivery is harmless — the aggregator keeps the max.
        var bridgedProgress: (@Sendable (Int64) -> Void)?
        if let onBytes {
            bridgedProgress = { bytes in
                Task { await onBytes(bytes) }
            }
        }
        let result = try await transport.download(
            for: URLRequest(url: url),
            policy: RedirectPolicy.huggingFace(initialURL: url),
            onBytes: bridgedProgress
        )
        do {
            try Self.check(result.response, file: artifact.relativePath)
            let responseLength = result.response.expectedContentLength
            if responseLength >= 0, responseLength != artifact.size {
                throw ManagedModelIntegrityError.artifactSizeMismatch(artifact.relativePath)
            }
        } catch {
            try? FileManager.default.removeItem(at: result.temporaryURL)
            throw error
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: result.temporaryURL, to: destination)
    }

    public func fetchConfigJSON(repoID: String, revision: String) async throws -> Data? {
        try Self.validate(repoID)
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { return nil }
        guard let url = URL(string: "\(host)/\(repoID)/resolve/\(revision)/config.json") else {
            return nil
        }
        try Self.enforceHost(url)
        let result = try await transport.data(
            for: URLRequest(url: url),
            policy: RedirectPolicy.huggingFace(initialURL: url)
        )
        guard let http = result.response as? HTTPURLResponse else {
            throw HuggingFaceError.requestFailed("config.json", -1)
        }
        if !(200..<300).contains(http.statusCode) {
            return nil
        }
        return result.data
    }

    private static func validate(_ repoID: String) throws {
        let parts = repoID.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }
    }

    /// Fail-closed initial-host guard mirroring the app's default-deny network posture.
    /// Every request must begin at HTTPS `huggingface.co`; the shared redirect transport
    /// separately permits only the named token-free CDN origin in `RedirectPolicy`.
    private static func enforceHost(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "huggingface.co" else {
            throw HuggingFaceError.requestFailed(url.absoluteString, -1)
        }
    }

    private static func check(_ response: URLResponse, file: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HuggingFaceError.requestFailed(file, -1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HuggingFaceError.requestFailed(file, http.statusCode)
        }
    }

    private struct ModelInfo: Decodable {
        let sha: String
        let siblings: [Sibling]
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
            let blobId: String?
            let lfs: LFS?
        }
        struct LFS: Decodable {
            let sha256: String
            let size: Int64
        }
    }
}
