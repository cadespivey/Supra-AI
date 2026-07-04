import CryptoKit
import Foundation

/// Result of a connector's non-network self-check (config validity). Live
/// reachability is a separate, opt-in test concern — health checks must never
/// surprise the app with public-service traffic.
public struct ConnectorHealth: Codable, Equatable, Sendable {
    public var connectorName: String
    public var checkedAt: Date
    public var reachable: Bool
    public var message: String
    public var sanitizedMetadata: [String: String]

    public init(
        connectorName: String,
        checkedAt: Date,
        reachable: Bool,
        message: String,
        sanitizedMetadata: [String: String] = [:]
    ) {
        self.connectorName = connectorName
        self.checkedAt = checkedAt
        self.reachable = reachable
        self.message = message
        self.sanitizedMetadata = sanitizedMetadata
    }
}

/// One cached HTTP response. Raw bytes are preserved base64-encoded with a
/// content hash; a hash mismatch on read is treated as a cache miss.
public struct LegalDataCacheEntry: Codable, Equatable, Sendable {
    public var connectorName: String
    public var operation: String
    public var requestURL: String
    public var requestParams: JSONValue
    public var retrievedAt: Date
    public var expiresAt: Date?
    public var httpStatus: Int
    public var rawPayloadBase64: String
    public var payloadHash: String

    public init(
        connectorName: String,
        operation: String,
        requestURL: String,
        requestParams: JSONValue,
        retrievedAt: Date,
        expiresAt: Date?,
        httpStatus: Int,
        rawPayload: Data
    ) {
        self.connectorName = connectorName
        self.operation = operation
        self.requestURL = requestURL
        self.requestParams = requestParams
        self.retrievedAt = retrievedAt
        self.expiresAt = expiresAt
        self.httpStatus = httpStatus
        self.rawPayloadBase64 = rawPayload.base64EncodedString()
        self.payloadHash = ConnectorHashing.sha256Hex(rawPayload)
    }

    public var rawPayload: Data? {
        Data(base64Encoded: rawPayloadBase64)
    }
}

/// The stable seam for future RAG/document ingestion: one normalized record
/// with full raw preservation and a neutral, source-attributed text rendering.
public struct LegalDataIngestionRecord: Codable, Equatable, Sendable {
    public var source: String
    public var sourceVariant: String?
    public var sourceRecordType: String
    public var sourceRecordId: String
    public var sourceUrl: String?
    public var retrievedAt: Date
    public var rawPayload: JSONValue
    public var normalizedPayload: JSONValue
    public var ragText: String
    public var rawHash: String
    public var normalizedHash: String

    public init(
        source: String,
        sourceVariant: String? = nil,
        sourceRecordType: String,
        sourceRecordId: String,
        sourceUrl: String? = nil,
        retrievedAt: Date,
        rawPayload: JSONValue,
        normalizedPayload: JSONValue,
        ragText: String
    ) {
        self.source = source
        self.sourceVariant = sourceVariant
        self.sourceRecordType = sourceRecordType
        self.sourceRecordId = sourceRecordId
        self.sourceUrl = sourceUrl
        self.retrievedAt = retrievedAt
        self.rawPayload = rawPayload
        self.normalizedPayload = normalizedPayload
        self.ragText = ragText
        self.rawHash = ConnectorHashing.sha256Hex(rawPayload.canonicalJSONString())
        self.normalizedHash = ConnectorHashing.sha256Hex(normalizedPayload.canonicalJSONString())
    }
}

/// Shared SHA-256 helpers (CryptoKit).
public enum ConnectorHashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }
}
