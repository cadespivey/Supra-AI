import Foundation

/// Strongly-typed identifiers. The persistence layer standardized on `String`
/// ids, so only the identifiers actually threaded through typed APIs live here
/// (the runtime model/generation ids and the embedding-model id). Other entities
/// are addressed by `String` id in `SupraStore`.

public struct ModelID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct GenerationID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct DocumentEmbeddingModelID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
