import Foundation
import SupraCore

enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = DateCoding.encoder
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: [], debugDescription: "Encoded JSON was not UTF-8.")
            )
        }
        return string
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        let data = Data(string.utf8)
        return try DateCoding.decoder.decode(type, from: data)
    }
}
