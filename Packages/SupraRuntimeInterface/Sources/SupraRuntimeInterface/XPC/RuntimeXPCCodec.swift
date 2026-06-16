import Foundation

public enum RuntimeXPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    private static var encoder: JSONEncoder {
        JSONEncoder()
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

