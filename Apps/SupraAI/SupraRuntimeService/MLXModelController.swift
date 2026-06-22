import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers
import SupraCore
import SupraRuntimeInterface

protocol ChatModelController: Sendable {
    func loadModel(bookmark: Data?, path: String) async throws -> RuntimeMetrics

    func generate(
        prompt: String,
        systemPrompt: String?,
        history: [GenerateRequest.Turn],
        options: GenerationOptions,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> RuntimeMetrics

    func cancel() async
    func unload() async throws
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
    /// True when the loaded model's chat template honors an `enable_thinking`
    /// flag (Qwen3-style reasoning models). For those we suppress the reasoning
    /// trace at generation time so it never reaches the chat or the validator.
    private var templateSupportsThinkingToggle = false

    func loadModel(bookmark: Data?, path: String) async throws -> RuntimeMetrics {
        let startedAt = Date()

        // Resolve a plain bookmark sent by the app to gain read access to the
        // model directory while staying sandboxed. The security scope must stay
        // open for the ENTIRE load — the multi-gigabyte weight shards are read
        // during `loadModelContainer`, so `stopAccessing` runs only on return.
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
                throw MLXModelControllerError.modelDirectoryMissing(path)
            }
            scopedURL = url
            resolvedURL = url
        } else {
            resolvedURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        defer { scopedURL?.stopAccessingSecurityScopedResource() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MLXModelControllerError.modelDirectoryMissing(resolvedURL.path)
        }

        let loadedContainer = try await MLXLMTokenizers.loadModelContainer(from: resolvedURL)

        container = loadedContainer
        loadedPath = resolvedURL.path
        cancellationRequested = false
        templateSupportsThinkingToggle = Self.templateSupportsThinkingToggle(in: resolvedURL)

        return RuntimeMetrics(loadTimeMs: Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        history: [GenerateRequest.Turn],
        options rawOptions: GenerationOptions,
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws -> RuntimeMetrics {
        guard let container else {
            throw MLXModelControllerError.modelNotLoaded
        }
        // Defense-in-depth: clamp parameters that crossed the XPC boundary so a
        // malformed/hostile request can't pass NaN/negative/absurd values to MLX.
        let options = rawOptions.clampedForRuntime()

        cancellationRequested = false

        let (stream, contextTrimmed, contextOverflowed) = try await generationStream(
            container: container,
            prompt: prompt,
            systemPrompt: systemPrompt,
            history: history,
            options: options,
            templateSupportsThinkingToggle: templateSupportsThinkingToggle
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

        // Treat hitting the output-token cap as truncation: the generation stopped
        // before the model's natural end, so any unterminated reasoning is partial.
        let truncated = generatedTokenCount >= options.maxOutputTokens
        // Reasoning was actually active only when the model's template honors the
        // thinking toggle AND the preset enabled it; otherwise a missing `</think>`
        // is normal (a plain model never emits one).
        let reasoningActive = templateSupportsThinkingToggle && options.thinkingBudget.enablesModelThinking
        return RuntimeMetrics(
            firstTokenLatencyMs: firstTokenLatencyMs,
            tokensPerSecond: tokensPerSecond,
            generatedTokenCount: generatedTokenCount,
            truncated: truncated,
            reasoningActive: reasoningActive,
            contextTrimmed: contextTrimmed,
            contextOverflowed: contextOverflowed
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

    /// Detects whether the model's chat template references `enable_thinking`,
    /// which Qwen3-style reasoning templates use to gate the `<think>` block.
    /// The template lives in `chat_template.jinja` or, failing that, the
    /// `chat_template` field of `tokenizer_config.json`. Models without it
    /// (e.g. Qwen2.5 Instruct) are left untouched.
    private static func templateSupportsThinkingToggle(in modelDirectory: URL) -> Bool {
        let jinjaURL = modelDirectory.appendingPathComponent("chat_template.jinja")
        if let template = try? String(contentsOf: jinjaURL, encoding: .utf8) {
            return template.contains("enable_thinking")
        }
        let configURL = modelDirectory.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let template = json["chat_template"] as? String {
            return template.contains("enable_thinking")
        }
        return false
    }
}

private func generationStream(
    container: ModelContainer,
    prompt: String,
    systemPrompt: String?,
    history: [GenerateRequest.Turn],
    options: GenerationOptions,
    templateSupportsThinkingToggle: Bool
) async throws -> (stream: AsyncStream<Generation>, contextTrimmed: Bool, contextOverflowed: Bool) {
    // `enable_thinking` is read by Qwen3-style chat templates. Drafting and
    // ordinary chat keep it off; legal reasoning/research presets can opt in.
    let additionalContext: [String: any Sendable]? = templateSupportsThinkingToggle
        ? ["enable_thinking": options.thinkingBudget.enablesModelThinking]
        : nil

    func prepared(_ turns: [GenerateRequest.Turn]) async throws -> LMInput {
        let userInput = UserInput(
            chat: chatMessages(prompt: prompt, systemPrompt: systemPrompt, history: turns),
            additionalContext: additionalContext
        )
        return try await container.prepare(input: userInput)
    }

    // Token budget so prompt + output fit the KV window. Beyond it the
    // RotatingKVCache silently evicts the FRONT of the prompt (the system grounding
    // and top sources) during generation. Protect those + the live question by
    // dropping the oldest conversation turns (the lowest-priority context) until the
    // prompt fits; flag when we had to.
    let budget = PromptBudget.promptTokenBudget(
        maxContextTokens: options.maxContextTokens,
        maxOutputTokens: options.maxOutputTokens
    )
    var keptHistory = history
    var input = try await prepared(keptHistory)
    var contextTrimmed = false
    while input.text.tokens.size > budget, !keptHistory.isEmpty {
        keptHistory.removeFirst()
        contextTrimmed = true
        input = try await prepared(keptHistory)
    }
    // If the system prompt + current prompt STILL overflow with no history left, the
    // front of the prompt (grounding contract + top evidence) is evicted mid-
    // generation and cannot be recovered — distinct from the benign history-drop case.
    let contextOverflowed = input.text.tokens.size > budget

    let stream = try await container.generate(
        input: input,
        parameters: GenerateParameters(
            maxTokens: options.maxOutputTokens,
            maxKVSize: options.maxContextTokens,
            temperature: Float(options.temperature),
            topP: Float(options.topP),
            topK: options.topK ?? 0,
            repetitionPenalty: options.repetitionPenalty.map { Float($0) },
            repetitionContextSize: 256
        )
    )
    return (stream, contextTrimmed, contextOverflowed)
}

private func chatMessages(
    prompt: String,
    systemPrompt: String?,
    history: [GenerateRequest.Turn]
) -> [Chat.Message] {
    var messages: [Chat.Message] = []

    let trimmedSystemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedSystemPrompt, !trimmedSystemPrompt.isEmpty {
        messages.append(.system(trimmedSystemPrompt))
    }

    // Prior turns so the model can answer follow-ups in context.
    for turn in history {
        switch turn.role {
        case .user: messages.append(.user(turn.content))
        case .assistant: messages.append(.assistant(turn.content))
        }
    }

    messages.append(.user(prompt))
    return messages
}
