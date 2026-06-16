import Foundation

public struct RedactionPolicy: Codable, Hashable, Sendable {
    public var redactLocalPaths: Bool
    public var replacement: String

    public init(
        redactLocalPaths: Bool = true,
        replacement: String = "<redacted-path>"
    ) {
        self.redactLocalPaths = redactLocalPaths
        self.replacement = replacement
    }

    public static let `default` = RedactionPolicy()

    public func redact(_ text: String) -> String {
        guard redactLocalPaths else { return text }

        let patterns = [
            #"/Users/[^\s\)",;]+"#,
            #"/Volumes/[^\s\)",;]+"#,
            #"file:///[^\s\)",;]+"#,
            #"\\/Users\\/[^\s\)",;]+"#,
            #"\\/Volumes\\/[^\s\)",;]+"#,
            #"file:\\/\\/\\/[^\s\)",;]+"#
        ]

        return patterns.reduce(text) { current, pattern in
            current.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
    }
}
