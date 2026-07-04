import Foundation

/// SEC-specific error constructors. HTTP status mapping lives in
/// `LegalDataConnectorError.fromHTTPStatus` (applied by the shared executor);
/// this file only covers the SEC-side validation and parse failures so every
/// call site produces the same sanitized shape. Messages never echo raw input
/// values — a CIK or concept string could contain user-typed search text.
enum SecEdgarErrorMapping {
    static func validationError(operation: String, message: String) -> LegalDataConnectorError {
        LegalDataConnectorError(
            kind: .validation,
            connectorName: SecEdgarConnector.connectorName,
            operation: operation,
            retryable: false,
            message: message
        )
    }

    static func parseError(operation: String, sourceURL: String?) -> LegalDataConnectorError {
        LegalDataConnectorError(
            kind: .parse,
            connectorName: SecEdgarConnector.connectorName,
            operation: operation,
            sourceURL: sourceURL,
            retryable: false,
            message: "The SEC EDGAR response could not be parsed as the expected JSON shape."
        )
    }

    static func encodingError(operation: String) -> LegalDataConnectorError {
        LegalDataConnectorError(
            kind: .importFailed,
            connectorName: SecEdgarConnector.connectorName,
            operation: operation,
            retryable: false,
            message: "A normalized SEC EDGAR record could not be encoded for ingestion."
        )
    }
}
