import Foundation
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers
import SupraCore
import SupraRuntimeInterface

protocol ChatModelController: Sendable {
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

enum MLXModelControllerError: LocalizedError {
    case modelDirectoryMissing(String)
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let path):
            "The model directory does not exist: \(path)"
        case .modelNotLoaded:
            "No MLX model is loaded."
        }
    }
}

actor MLXModelController: ChatModelController {
    private var container: ModelContainer?
    private var loadedPath: String?
    private var cancellationRequested = false

    func loadModel(path: String) async throws -> RuntimeMetrics {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MLXModelControllerError.modelDirectoryMissing(path)
        }

        let startedAt = Date()
        let modelURL = URL(fileURLWithPath: path, isDirectory: true)
        let loadedContainer = try await MLXLMTokenizers.loadModelContainer(from: modelURL)

        container = loadedContainer
        loadedPath = path
        cancellationRequested = false

        return RuntimeMetrics(loadTimeMs: Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        options: GenerationOptions,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> RuntimeMetrics {
        guard let container else {
            throw MLXModelControllerError.modelNotLoaded
        }

        cancellationRequested = false

        let stream = try await generationStream(
            container: container,
            prompt: prompt,
            systemPrompt: systemPrompt,
            options: options
        )

        var generatedTokenCount = 0
        var firstTokenLatencyMs: Int?
        var tokensPerSecond: Double?

        for await generation in stream {
            try Task.checkCancellation()
            if cancellationRequested {
                throw CancellationError()
            }

            switch generation {
            case .chunk(let text):
                if firstTokenLatencyMs == nil {
                    firstTokenLatencyMs = 0
                }
                generatedTokenCount += 1
                await onToken(text)

            case .info(let info):
                generatedTokenCount = info.generationTokenCount
                firstTokenLatencyMs = Int(info.promptTime * 1000)
                let measuredTokensPerSecond = info.tokensPerSecond
                tokensPerSecond = measuredTokensPerSecond.isFinite ? measuredTokensPerSecond : nil

            case .toolCall:
                break
            }
        }

        return RuntimeMetrics(
            firstTokenLatencyMs: firstTokenLatencyMs,
            tokensPerSecond: tokensPerSecond,
            generatedTokenCount: generatedTokenCount
        )
    }

    func cancel() async {
        cancellationRequested = true
    }

    func unload() async throws {
        cancellationRequested = true
        container = nil
        loadedPath = nil
    }

    func status() async -> RuntimeStatus {
        RuntimeStatus(
            state: container == nil ? .modelUnloaded : .modelLoaded,
            loadedModelID: nil,
            activeGenerationID: nil,
            message: loadedPath.map { "MLX model loaded from \($0)" } ?? "No MLX model loaded.",
            metrics: nil
        )
    }
}

private func generationStream(
    container: ModelContainer,
    prompt: String,
    systemPrompt: String?,
    options: GenerationOptions
) async throws -> AsyncStream<Generation> {
    let userInput = UserInput(chat: chatMessages(prompt: prompt, systemPrompt: systemPrompt))
    let input = try await container.prepare(input: userInput)

    return try await container.generate(
        input: input,
        parameters: GenerateParameters(
            maxTokens: options.maxOutputTokens,
            maxKVSize: options.contextLength,
            temperature: Float(options.temperature),
            topP: Float(options.topP)
        )
    )
}

private func chatMessages(prompt: String, systemPrompt: String?) -> [Chat.Message] {
    var messages: [Chat.Message] = []

    let trimmedSystemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedSystemPrompt, !trimmedSystemPrompt.isEmpty {
        messages.append(.system(trimmedSystemPrompt))
    }

    messages.append(.user(prompt))
    return messages
}
