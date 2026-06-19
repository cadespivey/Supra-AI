import Foundation

public struct CourtListenerSearchRequest: Codable, Equatable, Sendable {
    public let query: String
    public let orderBy: String?
    public let highlight: Bool
    public let cursorURL: URL?
    public let courtIDs: [String]
    public let dateFiledAfter: String?
    public let dateFiledBefore: String?
    public let citation: String?

    public init(
        query: String,
        orderBy: String? = nil,
        highlight: Bool = true,
        cursorURL: URL? = nil,
        courtIDs: [String] = [],
        dateFiledAfter: String? = nil,
        dateFiledBefore: String? = nil,
        citation: String? = nil
    ) {
        self.query = query
        self.orderBy = orderBy
        self.highlight = highlight
        self.cursorURL = cursorURL
        self.courtIDs = courtIDs
        self.dateFiledAfter = dateFiledAfter
        self.dateFiledBefore = dateFiledBefore
        self.citation = citation
    }
}
