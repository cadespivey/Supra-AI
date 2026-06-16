import Foundation

public enum DateCoding {
    public static func configure(_ encoder: JSONEncoder) {
        encoder.dateEncodingStrategy = .iso8601
    }

    public static func configure(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .iso8601
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        configure(encoder)
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        configure(decoder)
        return decoder
    }
}
