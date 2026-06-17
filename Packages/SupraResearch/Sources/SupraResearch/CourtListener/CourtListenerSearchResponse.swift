import Foundation

public struct CourtListenerSearchResponse: Codable, Equatable, Sendable {
    public let count: Int
    public let next: String?
    public let previous: String?
    public let results: [CourtListenerSearchResultDTO]

    public init(
        count: Int,
        next: String? = nil,
        previous: String? = nil,
        results: [CourtListenerSearchResultDTO]
    ) {
        self.count = count
        self.next = next
        self.previous = previous
        self.results = results
    }

    static func decodePreservingRawResults(from data: Data) throws -> CourtListenerSearchResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CourtListenerError.decodingFailed
        }
        let count = root["count"] as? Int ?? 0
        let next = root["next"] as? String
        let previous = root["previous"] as? String
        let resultObjects = root["results"] as? [[String: Any]] ?? []
        let decoder = JSONDecoder()
        let results = try resultObjects.map { object in
            let resultData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let decoded = try decoder.decode(CourtListenerSearchResultDTO.self, from: resultData)
            let raw = String(data: resultData, encoding: .utf8) ?? "{}"
            return CourtListenerSearchResultDTO(copying: decoded, rawResultJSON: raw)
        }
        return CourtListenerSearchResponse(
            count: count,
            next: next,
            previous: previous,
            results: results
        )
    }
}
