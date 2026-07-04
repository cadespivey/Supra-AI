import Foundation

/// Typed, sanitized error for the government-data connectors. One struct with
/// a `Kind` (rather than a nine-case enum duplicating the same payload) so
/// callers can switch on `kind` while every error carries uniform provenance.
///
/// `message` and `sanitizedMetadata` must NEVER contain secrets, the SEC
/// User-Agent contents, local paths, raw payloads, stack traces, or raw
/// user-entered query terms.
public struct LegalDataConnectorError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: String, Equatable, Sendable {
        case config
        case validation
        case rateLimit
        case sourceUnavailable
        case download
        case notFound
        case parse
        case importFailed
        case transport
    }

    public var kind: Kind
    public var connectorName: String
    public var operation: String
    public var sourceVariant: String?
    public var sourceURL: String?
    public var httpStatus: Int?
    public var retryable: Bool
    public var message: String
    public var sanitizedMetadata: [String: String]

    public init(
        kind: Kind,
        connectorName: String,
        operation: String,
        sourceVariant: String? = nil,
        sourceURL: String? = nil,
        httpStatus: Int? = nil,
        retryable: Bool = false,
        message: String,
        sanitizedMetadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.connectorName = connectorName
        self.operation = operation
        self.sourceVariant = sourceVariant
        self.sourceURL = sourceURL
        self.httpStatus = httpStatus
        self.retryable = retryable
        self.message = message
        self.sanitizedMetadata = sanitizedMetadata
    }

    public var errorDescription: String? {
        "\(connectorName) \(operation) failed (\(kind.rawValue)): \(message)"
    }

    /// The plan's HTTP status mapping table.
    public static func fromHTTPStatus(
        _ status: Int,
        connectorName: String,
        operation: String,
        sourceURL: String? = nil
    ) -> LegalDataConnectorError {
        let kind: Kind
        let retryable: Bool
        let message: String
        switch status {
        case 400, 422:
            kind = .validation; retryable = false
            message = "The source rejected the request as invalid (HTTP \(status))."
        case 401, 403:
            kind = .sourceUnavailable; retryable = false
            message = "The source refused access (HTTP \(status))."
        case 404:
            kind = .notFound; retryable = false
            message = "The requested record was not found (HTTP 404)."
        case 429:
            kind = .rateLimit; retryable = true
            message = "The source rate-limited the request (HTTP 429)."
        case 500...599:
            kind = .sourceUnavailable; retryable = true
            message = "The source is temporarily unavailable (HTTP \(status))."
        default:
            kind = .transport; retryable = false
            message = "Unexpected response from the source (HTTP \(status))."
        }
        return LegalDataConnectorError(
            kind: kind,
            connectorName: connectorName,
            operation: operation,
            sourceURL: sourceURL,
            httpStatus: status,
            retryable: retryable,
            message: message,
            sanitizedMetadata: ["httpStatus": String(status)]
        )
    }
}
