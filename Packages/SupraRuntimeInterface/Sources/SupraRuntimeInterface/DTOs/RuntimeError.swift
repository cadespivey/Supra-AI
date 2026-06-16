import Foundation

public struct RuntimeError: Codable, Sendable {
    public let category: String
    public let message: String
    public let technicalDetails: String?

    public init(category: String, message: String, technicalDetails: String? = nil) {
        self.category = category
        self.message = message
        self.technicalDetails = technicalDetails
    }
}
