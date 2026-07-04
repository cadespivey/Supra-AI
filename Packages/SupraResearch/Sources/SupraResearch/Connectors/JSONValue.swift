import Foundation

/// Loss-tolerant representation of unknown JSON, used to preserve raw source
/// payloads on normalized government-data records. Numbers are held as
/// `Double`; connectors that need exact numeric round-tripping keep the
/// original raw bytes in their cache entries (documented limitation).
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Decodes arbitrary JSON bytes.
    public static func fromData(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Convenience accessors for normalizers.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// A string regardless of underlying scalar type — handy for source fields
    /// that arrive as either numbers or strings (e.g. complaint IDs, CIKs).
    public var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// Deterministic canonical JSON for hashing: object keys sorted, integers
    /// rendered without a fractional part, minimal string escaping.
    public func canonicalJSONString() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return Self.escaped(value)
        case .array(let values):
            return "[" + values.map { $0.canonicalJSONString() }.joined(separator: ",") + "]"
        case .object(let object):
            let members = object.keys.sorted().map { key in
                Self.escaped(key) + ":" + (object[key] ?? .null).canonicalJSONString()
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    private static func escaped(_ value: String) -> String {
        var output = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if character.value < 0x20 {
                    output += String(format: "\\u%04x", character.value)
                } else {
                    output.unicodeScalars.append(character)
                }
            }
        }
        return output + "\""
    }
}
