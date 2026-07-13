import Foundation
import SupraNetworking

/// Abstracts listing and downloading a model repository's files so the download
/// controller can be unit-tested against a stub.
public protocol ModelRepositoryFetching: Sendable {
    /// All file paths in the repo (relative, may include subdirectories).
    func listModelFiles(repoID: String) async throws -> [String]
    /// Downloads a single repo file to `destination` (parent dirs created by caller).
    func downloadFile(repoID: String, file: String, to destination: URL) async throws
    /// The repo's `config.json` contents, or `nil` if it has none. Used to check
    /// architecture compatibility before downloading gigabytes of weights.
    func fetchConfigJSON(repoID: String) async throws -> Data?
}

public enum HuggingFaceError: Error, LocalizedError {
    case invalidRepoID(String)
    case requestFailed(String, Int)
    case emptyRepository(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepoID(repo):
            "‘\(repo)’ is not a valid Hugging Face repo id (expected ‘org/name’)."
        case let .requestFailed(file, code):
            "Download failed for \(file) (HTTP \(code))."
        case let .emptyRepository(repo):
            "No files found in \(repo)."
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

    public func listModelFiles(repoID: String) async throws -> [String] {
        try Self.validate(repoID)
        guard let url = URL(string: "\(host)/api/models/\(repoID)") else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }
        try Self.enforceHost(url)
        let result = try await transport.data(
            for: URLRequest(url: url),
            policy: RedirectPolicy.huggingFace(initialURL: url)
        )
        try Self.check(result.response, file: "model index")

        let info = try JSONDecoder().decode(ModelInfo.self, from: result.data)
        let files = info.siblings.map(\.rfilename).filter { !$0.isEmpty }
        guard !files.isEmpty else { throw HuggingFaceError.emptyRepository(repoID) }
        return files
    }

    public func downloadFile(repoID: String, file: String, to destination: URL) async throws {
        try Self.validate(repoID)
        let encodedFile = file
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "\(host)/\(repoID)/resolve/main/\(encodedFile)") else {
            throw HuggingFaceError.requestFailed(file, -1)
        }
        try Self.enforceHost(url)

        let result = try await transport.download(
            for: URLRequest(url: url),
            policy: RedirectPolicy.huggingFace(initialURL: url)
        )
        do {
            try Self.check(result.response, file: file)
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

    public func fetchConfigJSON(repoID: String) async throws -> Data? {
        try Self.validate(repoID)
        guard let url = URL(string: "\(host)/\(repoID)/resolve/main/config.json") else {
            return nil
        }
        try Self.enforceHost(url)
        let result = try await transport.data(
            for: URLRequest(url: url),
            policy: RedirectPolicy.huggingFace(initialURL: url)
        )
        if let http = result.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
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
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw HuggingFaceError.requestFailed(file, http.statusCode)
        }
    }

    private struct ModelInfo: Decodable {
        let siblings: [Sibling]
        struct Sibling: Decodable { let rfilename: String }
    }
}
