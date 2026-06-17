import Foundation
import SupraStore

public actor NetworkRequestLogger {
    private let repository: NetworkRequestRepository

    public init(repository: NetworkRequestRepository) {
        self.repository = repository
    }

    @discardableResult
    public func recordApprovedRequest(
        url: URL,
        method: String,
        relatedResearchSessionID: String? = nil,
        requestMetadataJSON: String? = nil
    ) throws -> String {
        let record = try repository.createRequest(
            domain: Self.domain(for: url),
            method: method,
            endpoint: Self.endpoint(for: url),
            approved: true,
            relatedResearchSessionID: relatedResearchSessionID,
            requestMetadataJSON: requestMetadataJSON
        )
        return record.id
    }

    @discardableResult
    public func recordBlockedRequest(
        url: URL,
        method: String,
        blockedReason: String,
        relatedResearchSessionID: String? = nil,
        requestMetadataJSON: String? = nil
    ) throws -> String {
        let record = try repository.createRequest(
            domain: Self.domain(for: url),
            method: method,
            endpoint: Self.endpoint(for: url),
            approved: false,
            relatedResearchSessionID: relatedResearchSessionID,
            blockedReason: blockedReason,
            requestMetadataJSON: requestMetadataJSON
        )
        return record.id
    }

    public func finishRequest(
        id: String,
        statusCode: Int?,
        errorMessage: String? = nil,
        responseMetadataJSON: String? = nil
    ) throws {
        try repository.finishRequest(
            id: id,
            statusCode: statusCode,
            errorMessage: errorMessage,
            responseMetadataJSON: responseMetadataJSON
        )
    }

    private static func domain(for url: URL) -> String {
        url.host?.lowercased() ?? "unknown"
    }

    private static func endpoint(for url: URL) -> String {
        url.path.isEmpty ? "/" : url.path
    }
}
