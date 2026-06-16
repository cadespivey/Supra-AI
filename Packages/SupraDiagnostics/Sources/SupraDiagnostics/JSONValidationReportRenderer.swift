import Foundation
import SupraCore

public struct JSONValidationReportRenderer: Sendable {
    private let redactionPolicy: RedactionPolicy

    public init(redactionPolicy: RedactionPolicy = .default) {
        self.redactionPolicy = redactionPolicy
    }

    public func render(_ report: ValidationReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        DateCoding.configure(encoder)

        let encoded = try encoder.encode(report)
        guard let json = String(data: encoded, encoding: .utf8) else {
            return encoded
        }

        return Data(redactionPolicy.redact(json).utf8)
    }
}
