import Foundation

public struct CourtListenerSearchResponse: Codable, Equatable, Sendable {
    public let count: Int
    public let next: String?
    public let previous: String?
    public let results: [CourtListenerSearchResultDTO]
    /// Number of result objects on this page that failed to decode and were
    /// dropped by `decodePreservingRawResults` (not part of the wire format).
    public var droppedResultCount: Int = 0

    private enum CodingKeys: String, CodingKey {
        case count, next, previous, results
    }

    public init(
        count: Int,
        next: String? = nil,
        previous: String? = nil,
        results: [CourtListenerSearchResultDTO],
        droppedResultCount: Int = 0
    ) {
        self.count = count
        self.next = next
        self.previous = previous
        self.results = results
        self.droppedResultCount = droppedResultCount
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
        // Decode best-effort: one malformed result (an unexpected shape from the
        // API) should not discard the entire page of valid authorities.
        let results = resultObjects.compactMap { object -> CourtListenerSearchResultDTO? in
            guard
                let resultData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                let decoded = try? decoder.decode(CourtListenerSearchResultDTO.self, from: resultData)
            else { return nil }
            let raw = String(data: resultData, encoding: .utf8) ?? "{}"
            return CourtListenerSearchResultDTO(copying: decoded, rawResultJSON: raw)
        }
        return CourtListenerSearchResponse(
            count: count,
            next: next,
            previous: previous,
            results: results,
            droppedResultCount: resultObjects.count - results.count
        )
    }
}
