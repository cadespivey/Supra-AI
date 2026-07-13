import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXLMTokenizers
import SupraCore
import SupraRuntimeInterface

/// Loads a local embedding model and produces normalized vectors. Requests are
/// serialized by the actor so one embedding batch cannot race another (plan
/// §1.4). Kept separate from the chat `ChatModelController`.
protocol EmbeddingModelController: Sendable {
    /// Loads the model from a managed directory (resolving a sandbox bookmark if
    /// provided) and returns its vector dimension.
    func loadModel(
        bookmark: Data?,
        path: String,
        managedRootPath: String?,
        expectedIdentity: ModelDirectoryIdentity?,
        expectedDimension: Int?
    ) async throws -> Int
    func embed(texts: [String], normalize: Bool) async throws -> [[Float]]
    func unload() async
}

enum EmbeddingModelControllerError: LocalizedError {
    case modelDirectoryMissing(String)
    case modelNotLoaded
    case emptyEmbedding
    case dimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let path):
            "The embedding model directory does not exist: \(path)"
        case .modelNotLoaded:
            "No embedding model is loaded."
        case .emptyEmbedding:
            "The embedding model produced no output."
        case let .dimensionMismatch(expected, actual):
            "Embedding dimension mismatch: expected \(expected), model produced \(actual)."
        }
    }
}

actor MLXEmbeddingModelController: EmbeddingModelController {
    private var container: EmbedderModelContainer?
    private var dimension: Int?

    func loadModel(
        bookmark: Data?,
        path: String,
        managedRootPath: String?,
        expectedIdentity: ModelDirectoryIdentity?,
        expectedDimension: Int?
    ) async throws -> Int {
        let access = try RuntimeModelDirectoryAccess(
            bookmark: bookmark,
            requestedPath: path,
            managedRootPath: managedRootPath,
            expectedIdentity: expectedIdentity
        )
        defer { access.close() }
        let resolvedURL = access.url

        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: resolvedURL,
            using: TokenizersLoader()
        )
        // Determine the output dimension with a tiny probe embedding.
        let probe = try await Self.embed(container: loaded, texts: ["dimension probe"], normalize: true)
        guard let first = probe.first, !first.isEmpty else {
            throw EmbeddingModelControllerError.emptyEmbedding
        }
        if let expectedDimension, expectedDimension != first.count {
            throw EmbeddingModelControllerError.dimensionMismatch(
                expected: expectedDimension,
                actual: first.count
            )
        }

        // Commit only after access, factory load, probe, and dimension validation
        // all succeed, and after revalidating that the directory was not replaced
        // during those async operations. A failed replacement therefore leaves the
        // prior model live and consistent with the service's reported state.
        try access.validateIdentity()
        container = loaded
        dimension = first.count
        return first.count
    }

    func embed(texts: [String], normalize: Bool) async throws -> [[Float]] {
        guard let container else { throw EmbeddingModelControllerError.modelNotLoaded }
        guard !texts.isEmpty else { return [] }
        return try await Self.embed(container: container, texts: texts, normalize: normalize)
    }

    func unload() async {
        container = nil
        dimension = nil
    }

    /// Tokenizes, runs the encoder, and pools to one vector per text. Vectors are
    /// L2-normalized when requested so cosine similarity reduces to a dot product.
    private static func embed(
        container: EmbedderModelContainer,
        texts: [String],
        normalize: Bool
    ) async throws -> [[Float]] {
        await container.perform { context in
            let tokenizer = context.tokenizer
            let padToken = tokenizer.eosTokenId ?? 0

            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = encoded.reduce(into: 16) { $0 = max($0, $1.count) }

            let padded = stacked(
                encoded.map { tokens in
                    MLXArray(tokens + Array(repeating: padToken, count: maxLength - tokens.count))
                }
            )
            let mask = padded .!= MLXArray(padToken)
            let tokenTypes = MLXArray.zeros(like: padded)

            let output = context.model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let pooled = context.pooling(output, mask: mask, normalize: normalize, applyLayerNorm: false)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }
}
