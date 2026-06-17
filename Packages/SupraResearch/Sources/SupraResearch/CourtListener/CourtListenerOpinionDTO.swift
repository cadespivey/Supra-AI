import Foundation

public struct CourtListenerOpinionDTO: Codable, Equatable, Sendable {
    public let id: Int?
    public let type: String?
    public let snippet: String?
    public let downloadURL: String?
    public let localPath: String?
    public let authorID: Int?
    public let perCuriam: Bool?
    public let sha1: String?

    public init(
        id: Int? = nil,
        type: String? = nil,
        snippet: String? = nil,
        downloadURL: String? = nil,
        localPath: String? = nil,
        authorID: Int? = nil,
        perCuriam: Bool? = nil,
        sha1: String? = nil
    ) {
        self.id = id
        self.type = type
        self.snippet = snippet
        self.downloadURL = downloadURL
        self.localPath = localPath
        self.authorID = authorID
        self.perCuriam = perCuriam
        self.sha1 = sha1
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case snippet
        case downloadURL = "download_url"
        case localPath = "local_path"
        case authorID = "author_id"
        case perCuriam = "per_curiam"
        case sha1
    }
}
