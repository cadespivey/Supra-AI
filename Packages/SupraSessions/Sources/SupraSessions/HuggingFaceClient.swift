import Foundation

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
    private let session: URLSession
    private let host = "https://huggingface.co"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func listModelFiles(repoID: String) async throws -> [String] {
        try Self.validate(repoID)
        guard let url = URL(string: "\(host)/api/models/\(repoID)") else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }
        try Self.enforceHost(url)
        let (data, response) = try await session.data(from: url)
        try Self.check(response, file: "model index")

        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
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

        let (tempURL, response) = try await session.download(from: url)
        do {
            try Self.check(response, file: file)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
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
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    public func fetchConfigJSON(repoID: String) async throws -> Data? {
        try Self.validate(repoID)
        guard let url = URL(string: "\(host)/\(repoID)/resolve/main/config.json") else {
            return nil
        }
        try Self.enforceHost(url)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return data
    }

    private static func validate(_ repoID: String) throws {
        let parts = repoID.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }
    }

    /// Fail-closed host guard mirroring the app's default-deny network posture. This
    /// client is deliberately outside `SupraNetworking.NetworkPolicyService` — it fetches
    /// public, token-free model weights, never legal data or credentialed endpoints — so
    /// it enforces its own https-only, single-host allow-list here. Any URL that is not
    /// HTTPS `huggingface.co` throws rather than being sent, so a future change to `host`
    /// (or a maliciously-shaped repo/file id) can't silently open a new egress path.
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
