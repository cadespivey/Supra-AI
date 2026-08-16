import Foundation
import SupraCore

final class NetworkAuditRecorder: NetworkRequestAuditWriting, @unchecked Sendable {
    struct Record: Equatable, Sendable {
        let id: String
        let timestamp: Date
        let domain: String
        let method: String
        let endpoint: String
        let approved: Bool
        let relatedResearchSessionID: String?
        let blockedReason: String?
        let requestMetadataJSON: String?
        var statusCode: Int?
        var errorMessage: String?
        var responseMetadataJSON: String?

        init(entry: NetworkRequestAuditEntry) {
            id = entry.id
            timestamp = entry.timestamp
            domain = entry.domain
            method = entry.method
            endpoint = entry.endpoint
            approved = entry.approved
            relatedResearchSessionID = entry.relatedResearchSessionID
            blockedReason = entry.blockedReason
            requestMetadataJSON = entry.requestMetadataJSON
            statusCode = nil
            errorMessage = nil
            responseMetadataJSON = nil
        }
    }

    enum Error: Swift.Error, Equatable {
        case duplicateID(String)
        case requestNotFound(String)
    }

    private let lock = NSLock()
    private var storedRecords: [Record] = []

    var records: [Record] {
        lock.withLock { storedRecords }
    }

    func fetchRecent(limit: Int) -> [Record] {
        lock.withLock {
            Array(storedRecords.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.id > rhs.id
            }.prefix(limit))
        }
    }

    @discardableResult
    func recordRequest(_ entry: NetworkRequestAuditEntry) throws -> String {
        try lock.withLock {
            guard !storedRecords.contains(where: { $0.id == entry.id }) else {
                throw Error.duplicateID(entry.id)
            }
            storedRecords.append(Record(entry: entry))
        }
        return entry.id
    }

    func finishRequest(_ completion: NetworkRequestAuditCompletion) throws {
        try lock.withLock {
            guard let index = storedRecords.firstIndex(where: { $0.id == completion.requestID }) else {
                throw Error.requestNotFound(completion.requestID)
            }
            storedRecords[index].statusCode = completion.statusCode
            storedRecords[index].errorMessage = completion.errorMessage
            storedRecords[index].responseMetadataJSON = completion.responseMetadataJSON
        }
    }
}
