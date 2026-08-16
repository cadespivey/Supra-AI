import Foundation

public enum RuntimeXPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    public static func decodeRequest<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        policy: RuntimeBudgetPolicy = .production
    ) throws -> T {
        guard data.count <= policy.maxEncodedRequestBytes else {
            throw RuntimeBudgetViolation(
                dimension: .encodedRequestBytes,
                limit: policy.maxEncodedRequestBytes,
                actual: data.count
            )
        }
        return try decoder.decode(type, from: data)
    }

    public static func decodeResponse<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        policy: RuntimeBudgetPolicy = .production
    ) throws -> T {
        guard data.count <= policy.maxEncodedResponseBytes else {
            throw RuntimeBudgetViolation(
                dimension: .encodedResponseBytes,
                limit: policy.maxEncodedResponseBytes,
                actual: data.count
            )
        }
        return try decoder.decode(type, from: data)
    }

    private static var encoder: JSONEncoder {
        JSONEncoder()
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
