import Foundation

/// One resolved (or unresolved) citation from CourtListener's
/// `/api/rest/v4/citation-lookup/` endpoint. `status` follows HTTP semantics per
/// citation: 200 = resolved, 404 = no matching opinion, 400 = unparseable.
public struct CourtListenerCitationLookupDTO: Codable, Equatable, Sendable {
    public struct Cluster: Codable, Equatable, Sendable {
        public let caseName: String?
        public let absoluteURL: String?

        public init(caseName: String? = nil, absoluteURL: String? = nil) {
            self.caseName = caseName
            self.absoluteURL = absoluteURL
        }

        private enum CodingKeys: String, CodingKey {
            case caseName = "case_name"
            case absoluteURL = "absolute_url"
        }
    }

    public let citation: String
    public let normalizedCitations: [String]
    public let status: Int
    public let errorMessage: String?
    public let clusters: [Cluster]

    public init(
        citation: String,
        normalizedCitations: [String] = [],
        status: Int,
        errorMessage: String? = nil,
        clusters: [Cluster] = []
    ) {
        self.citation = citation
        self.normalizedCitations = normalizedCitations
        self.status = status
        self.errorMessage = errorMessage
        self.clusters = clusters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.citation = try container.decodeIfPresent(String.self, forKey: .citation) ?? ""
        self.normalizedCitations = try container.decodeIfPresent([String].self, forKey: .normalizedCitations) ?? []
        self.status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 0
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.clusters = try container.decodeIfPresent([Cluster].self, forKey: .clusters) ?? []
    }

    /// Whether the citation resolved to at least one real opinion.
    public var resolved: Bool { status == 200 && !clusters.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case citation
        case normalizedCitations = "normalized_citations"
        case status
        case errorMessage = "error_message"
        case clusters
    }
}
