import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXLMTokenizers
import OSLog
import SupraCore
import SupraRuntimeInterface
import SupraRuntimeModelSecurity

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
        contentBinding: RuntimeModelContentBinding,
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
    private static let logger = Logger(
        subsystem: "ai.supra.SupraAI.SupraRuntimeService",
        category: "embedding-model-snapshot"
    )
    private let budgetValidator: RuntimeRequestBudgetValidator
    private var container: EmbedderModelContainer?
    private var modelSnapshot: RuntimeModelSnapshot?
    private var snapshotsPendingRemoval: [RuntimeModelSnapshot] = []
    private var dimension: Int?

    init(budgetPolicy: RuntimeBudgetPolicy = .production) {
        self.budgetValidator = RuntimeRequestBudgetValidator(policy: budgetPolicy)
    }

    func loadModel(
        bookmark: Data?,
        path: String,
        managedRootPath: String?,
        expectedIdentity: ModelDirectoryIdentity?,
        contentBinding: RuntimeModelContentBinding,
        expectedDimension: Int?
    ) async throws -> Int {
        try cleanupRetiredSnapshots()
        let access = try RuntimeModelDirectoryAccess(
            bookmark: bookmark,
            requestedPath: path,
            managedRootPath: managedRootPath,
            expectedIdentity: expectedIdentity
        )
        defer { access.close() }
        let resolvedURL = access.url
        let pendingSnapshot = try RuntimeModelSnapshot(
            sourceURL: resolvedURL,
            contentBinding: contentBinding
        )

        do {
            let loaded = try await EmbedderModelFactory.shared.loadContainer(
                from: pendingSnapshot.snapshotURL,
                using: TokenizersLoader()
            )
            // Determine the output dimension with a tiny probe embedding.
            let probe = try await Self.embed(
                container: loaded,
                texts: ["dimension probe"],
                normalize: true,
                budgetValidator: budgetValidator
            )
            guard let first = probe.first, !first.isEmpty else {
                throw EmbeddingModelControllerError.emptyEmbedding
            }
            if let expectedDimension, expectedDimension != first.count {
                throw EmbeddingModelControllerError.dimensionMismatch(
                    expected: expectedDimension,
                    actual: first.count
                )
            }

            // Commit only after the independently owned snapshot and original
            // source identity both survive the complete asynchronous load.
            try pendingSnapshot.reverify()
            try access.validateIdentity()
            let previousSnapshot = modelSnapshot
            container = loaded
            modelSnapshot = pendingSnapshot
            dimension = first.count
            retireSnapshot(previousSnapshot)
            return first.count
        } catch {
            retireSnapshot(pendingSnapshot)
            throw error
        }
    }

    func embed(texts: [String], normalize: Bool) async throws -> [[Float]] {
        guard let container else { throw EmbeddingModelControllerError.modelNotLoaded }
        guard !texts.isEmpty else { return [] }
        return try await Self.embed(
            container: container,
            texts: texts,
            normalize: normalize,
            budgetValidator: budgetValidator
        )
    }

    func unload() async {
        container = nil
        dimension = nil
        let snapshot = modelSnapshot
        modelSnapshot = nil
        retireSnapshot(snapshot)
        try? cleanupRetiredSnapshots()
    }

    private func retireSnapshot(_ snapshot: RuntimeModelSnapshot?) {
        guard let snapshot else { return }
        do {
            try snapshot.remove()
        } catch {
            snapshotsPendingRemoval.append(snapshot)
            Self.logger.fault("Retaining an embedding model snapshot after cleanup failed.")
        }
    }

    private func cleanupRetiredSnapshots() throws {
        guard !snapshotsPendingRemoval.isEmpty else { return }

        var stillPending: [RuntimeModelSnapshot] = []
        var firstError: Error?
        for snapshot in snapshotsPendingRemoval {
            do {
                try snapshot.remove()
            } catch {
                stillPending.append(snapshot)
                if firstError == nil { firstError = error }
            }
        }
        snapshotsPendingRemoval = stillPending
        if let firstError { throw firstError }
    }

    /// Tokenizes, runs the encoder, and pools to one vector per text. Vectors are
    /// L2-normalized when requested so cosine similarity reduces to a dot product.
    private static func embed(
        container: EmbedderModelContainer,
        texts: [String],
        normalize: Bool,
        budgetValidator: RuntimeRequestBudgetValidator
    ) async throws -> [[Float]] {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let padToken = tokenizer.eosTokenId ?? 0

            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            try budgetValidator.validateEmbeddingTokenShape(
                tokenCounts: encoded.map { max(16, $0.count) }
            )
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
