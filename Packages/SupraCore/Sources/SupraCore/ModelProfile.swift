import Foundation

public struct ModelProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: ModelID
    public var displayName: String
    public var localPath: String
    public var readinessState: RuntimeReadinessState
    public var validationStatus: ValidationRunStatus?
    public var lastValidatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ModelID = ModelID(),
        displayName: String,
        localPath: String,
        readinessState: RuntimeReadinessState = .unavailable,
        validationStatus: ValidationRunStatus? = nil,
        lastValidatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.localPath = localPath
        self.readinessState = readinessState
        self.validationStatus = validationStatus
        self.lastValidatedAt = lastValidatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
