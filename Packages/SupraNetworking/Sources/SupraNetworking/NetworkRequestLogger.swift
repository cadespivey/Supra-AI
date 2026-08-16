import Foundation
import SupraCore

public actor NetworkRequestLogger {
    private let writer: any NetworkRequestAuditWriting
    private let requestID: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(writer: any NetworkRequestAuditWriting) {
        self.writer = writer
        self.requestID = { UUID().uuidString }
        self.now = Date.init
    }

    init(
        writer: any NetworkRequestAuditWriting,
        requestID: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date
    ) {
        self.writer = writer
        self.requestID = requestID
        self.now = now
    }

    @discardableResult
    public func recordApprovedRequest(
        url: URL,
        method: String,
        relatedResearchSessionID: String? = nil,
        requestMetadataJSON: String? = nil
    ) throws -> String {
        let entry = NetworkRequestAuditEntry(
            id: requestID(),
            timestamp: now(),
            domain: Self.domain(for: url),
            method: method,
            endpoint: Self.endpoint(for: url),
            approved: true,
            relatedResearchSessionID: relatedResearchSessionID,
            requestMetadataJSON: requestMetadataJSON
        )
        return try writer.recordRequest(entry)
    }

    @discardableResult
    public func recordBlockedRequest(
        url: URL,
        method: String,
        blockedReason: String,
        relatedResearchSessionID: String? = nil,
        requestMetadataJSON: String? = nil
    ) throws -> String {
        let entry = NetworkRequestAuditEntry(
            id: requestID(),
            timestamp: now(),
            domain: Self.domain(for: url),
            method: method,
            endpoint: Self.endpoint(for: url),
            approved: false,
            relatedResearchSessionID: relatedResearchSessionID,
            blockedReason: blockedReason,
            requestMetadataJSON: requestMetadataJSON
        )
        return try writer.recordRequest(entry)
    }

    public func finishRequest(
        id: String,
        statusCode: Int?,
        errorMessage: String? = nil,
        responseMetadataJSON: String? = nil
    ) throws {
        try writer.finishRequest(
            NetworkRequestAuditCompletion(
                requestID: id,
                statusCode: statusCode,
                errorMessage: errorMessage,
                responseMetadataJSON: responseMetadataJSON
            )
        )
    }

    private static func domain(for url: URL) -> String {
        url.host?.lowercased() ?? "unknown"
    }

    private static func endpoint(for url: URL) -> String {
        url.path.isEmpty ? "/" : url.path
    }
}
