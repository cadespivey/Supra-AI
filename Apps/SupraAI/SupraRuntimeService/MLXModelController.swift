import Foundation
import SupraCore
import SupraRuntimeInterface

protocol ChatModelController {
    func loadModel(path: String) async throws -> RuntimeMetrics

    func generate(
        prompt: String,
        systemPrompt: String?,
        options: GenerationOptions,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> RuntimeMetrics

    func cancel() async
    func unload() async throws
    func status() async -> RuntimeStatus
}

final class MLXModelController: ChatModelController {
    func loadModel(path: String) async throws -> RuntimeMetrics {
        RuntimeMetrics(loadTimeMs: 0)
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        options: GenerationOptions,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> RuntimeMetrics {
        RuntimeMetrics(generatedTokenCount: 0)
    }

    func cancel() async {}

    func unload() async throws {}

    func status() async -> RuntimeStatus {
        RuntimeStatus(
            state: .modelUnloaded,
            loadedModelID: nil,
            activeGenerationID: nil,
            message: "MLX controller shell is ready.",
            metrics: nil
        )
    }
}

