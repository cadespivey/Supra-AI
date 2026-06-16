import Foundation

public struct DiagnosticEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let severity: DiagnosticSeverity
    public let category: RuntimeFailureCategory?
    public let message: String
    public let technicalDetails: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: DiagnosticSeverity,
        category: RuntimeFailureCategory? = nil,
        message: String,
        technicalDetails: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.message = message
        self.technicalDetails = technicalDetails
    }
}
