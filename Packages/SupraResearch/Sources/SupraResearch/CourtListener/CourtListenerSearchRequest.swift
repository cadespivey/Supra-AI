import Foundation

public struct CourtListenerSearchRequest: Codable, Equatable, Sendable {
    public let query: String
    public let orderBy: String?
    public let highlight: Bool
    public let cursorURL: URL?

    public init(
        query: String,
        orderBy: String? = nil,
        highlight: Bool = true,
        cursorURL: URL? = nil
    ) {
        self.query = query
        self.orderBy = orderBy
        self.highlight = highlight
        self.cursorURL = cursorURL
    }
}
