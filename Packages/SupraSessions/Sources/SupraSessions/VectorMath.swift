import Foundation

/// Float32 little-endian vector encode/decode + normalization and dot product
/// (plan §7.3). Vectors are normalized at write time so cosine similarity reduces
/// to a dot product.
public enum VectorMath {
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var little = value.bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            result[index] = Float(bitPattern: bits)
        }
        return result
    }

    public static func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        var sum: Float = 0
        for index in 0..<count { sum += a[index] * b[index] }
        return sum
    }
}

/// Produces embeddings for text. Abstracted so indexing/retrieval can be tested
/// without the runtime model.
public protocol TextEmbedder: Sendable {
    /// Stable instance id (the registered model record id — a UUID).
    var modelID: String { get }
    /// The Hugging Face repo id (e.g. "BAAI/bge-base-en-v1.5"), used to resolve the
    /// catalog entry (and its query-instruction prefix). Distinct from `modelID`.
    var modelRepoID: String { get }
    var modelDisplayName: String { get }
    var modelRevision: String? { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
