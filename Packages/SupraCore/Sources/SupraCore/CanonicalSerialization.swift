import CryptoKit
import Foundation

/// Versioned JSON bytes for identities and artifacts whose digest is part of a
/// persisted or published protocol. Callers choose the version and presentation
/// explicitly so a future format cannot silently retarget an existing digest.
public enum CanonicalJSON {
    public enum Version: String, Codable, Sendable {
        case v1
    }

    public enum Presentation: String, Codable, Sendable {
        case compact
        case prettyPrinted = "pretty_printed"
    }

    public static func encode<Value: Encodable>(
        _ value: Value,
        version: Version,
        presentation: Presentation
    ) throws -> Data {
        let encoder = JSONEncoder()
        switch version {
        case .v1:
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        if presentation == .prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        return try encoder.encode(value)
    }
}

/// One lowercase hexadecimal representation for SHA-256 values that cross a
/// package or persistence boundary.
public enum SHA256Digest {
    public static func lowercaseHex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
