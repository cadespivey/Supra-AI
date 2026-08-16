import Foundation

/// Content-minimized facts presented to the persistence owner when a network
/// request reaches an auditable decision. It deliberately contains no Store
/// repository or database type.
public struct NetworkRequestAuditEntry: Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let domain: String
    public let method: String
    public let endpoint: String
    public let approved: Bool
    public let relatedResearchSessionID: String?
    public let blockedReason: String?
    public let requestMetadataJSON: String?

    public init(
        id: String,
        timestamp: Date,
        domain: String,
        method: String,
        endpoint: String,
        approved: Bool,
        relatedResearchSessionID: String? = nil,
        blockedReason: String? = nil,
        requestMetadataJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.method = method
        self.endpoint = endpoint
        self.approved = approved
        self.relatedResearchSessionID = relatedResearchSessionID
        self.blockedReason = blockedReason
        self.requestMetadataJSON = requestMetadataJSON
    }
}

/// Terminal facts for one previously recorded network request.
public struct NetworkRequestAuditCompletion: Equatable, Sendable {
    public let requestID: String
    public let statusCode: Int?
    public let errorMessage: String?
    public let responseMetadataJSON: String?

    public init(
        requestID: String,
        statusCode: Int?,
        errorMessage: String? = nil,
        responseMetadataJSON: String? = nil
    ) {
        self.requestID = requestID
        self.statusCode = statusCode
        self.errorMessage = errorMessage
        self.responseMetadataJSON = responseMetadataJSON
    }
}

/// The complete write authority required by the authorized HTTP boundary. A
/// transport given this capability cannot reach matters, documents, outputs,
/// settings, backup, or the raw database writer.
public protocol NetworkRequestAuditWriting: Sendable {
    @discardableResult
    func recordRequest(_ entry: NetworkRequestAuditEntry) throws -> String
    func finishRequest(_ completion: NetworkRequestAuditCompletion) throws
}
