import Foundation
import SupraCore

public enum NetworkRequestAuditCapabilityError: Error, Equatable, LocalizedError {
    case invalidField(String)
    case requestNotFound(id: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidField(field):
            return "Network audit field is invalid: \(field)"
        case let .requestNotFound(id):
            return "Network audit request does not exist: \(id)"
        }
    }
}

/// Store-owned implementation of the narrow network-audit write contract. The
/// wrapped repository is private, so callers cannot widen this value into an
/// unrelated Store mutation surface.
public final class NetworkRequestAuditStoreCapability: NetworkRequestAuditWriting, @unchecked Sendable {
    private let repository: NetworkRequestRepository

    init(repository: NetworkRequestRepository) {
        self.repository = repository
    }

    @discardableResult
    public func recordRequest(_ entry: NetworkRequestAuditEntry) throws -> String {
        try Self.validate(entry)
        let record = NetworkRequestRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            domain: entry.domain,
            method: entry.method,
            endpoint: entry.endpoint,
            approved: entry.approved,
            relatedResearchSessionID: entry.relatedResearchSessionID,
            blockedReason: entry.blockedReason,
            requestMetadataJSON: entry.requestMetadataJSON
        )
        return try repository.recordRequest(record).id
    }

    public func finishRequest(_ completion: NetworkRequestAuditCompletion) throws {
        guard !completion.requestID.isEmpty else {
            throw NetworkRequestAuditCapabilityError.invalidField("requestID")
        }
        let updated = try repository.finishRequestIfPresent(
            id: completion.requestID,
            statusCode: completion.statusCode,
            errorMessage: completion.errorMessage,
            responseMetadataJSON: completion.responseMetadataJSON
        )
        guard updated else {
            throw NetworkRequestAuditCapabilityError.requestNotFound(id: completion.requestID)
        }
    }

    private static func validate(_ entry: NetworkRequestAuditEntry) throws {
        let exactFields: [(String, String)] = [
            ("id", entry.id),
            ("domain", entry.domain),
            ("method", entry.method),
            ("endpoint", entry.endpoint),
        ]
        for (name, value) in exactFields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == value else {
                throw NetworkRequestAuditCapabilityError.invalidField(name)
            }
        }
        guard entry.endpoint.hasPrefix("/") else {
            throw NetworkRequestAuditCapabilityError.invalidField("endpoint")
        }
        if entry.approved, entry.blockedReason != nil {
            throw NetworkRequestAuditCapabilityError.invalidField("blockedReason")
        }
        if !entry.approved {
            guard let reason = entry.blockedReason,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NetworkRequestAuditCapabilityError.invalidField("blockedReason")
            }
        }
    }
}
