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
    func loadModel(bookmark: Data?, path: String) async throws -> Int
    func embed(texts: [String], normalize: Bool) async throws -> [[Float]]
    func unload() async
}

enum EmbeddingModelControllerError: LocalizedError {
    case modelDirectoryMissing(String)
    case modelNotLoaded
    case emptyEmbedding

    var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let path):
            "The embedding model directory does not exist: \(path)"
        case .modelNotLoaded:
            "No embedding model is loaded."
        case .emptyEmbedding:
            "The embedding model produced no output."
        }
    }
}

actor MLXEmbeddingModelController: EmbeddingModelController {
    private var container: EmbedderModelContainer?
    private var dimension: Int?

    func loadModel(bookmark: Data?, path: String) async throws -> Int {
        // Resolve a sandbox bookmark (if any) and keep the scope open for the
        // whole load, mirroring MLXModelController.
        let resolvedURL: URL
        var scopedURL: URL?
        if let bookmark {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw EmbeddingModelControllerError.modelDirectoryMissing(path)
            }
            scopedURL = url
            resolvedURL = url
        } else {
            resolvedURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        defer { scopedURL?.stopAccessingSecurityScopedResource() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EmbeddingModelControllerError.modelDirectoryMissing(resolvedURL.path)
        }

        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: resolvedURL,
            using: TokenizersLoader()
        )
        container = loaded

        // Determine the output dimension with a tiny probe embedding.
        let probe = try await Self.embed(container: loaded, texts: ["dimension probe"], normalize: true)
        guard let first = probe.first, !first.isEmpty else {
            throw EmbeddingModelControllerError.emptyEmbedding
        }
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
