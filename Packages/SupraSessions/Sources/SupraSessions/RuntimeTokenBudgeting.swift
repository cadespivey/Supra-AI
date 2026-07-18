import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

enum RuntimeTokenBudgeting {
    static func report(
        serializedPackets: [String],
        modelID: ModelID?,
        options rawOptions: GenerationOptions,
        runtimeClient: any RuntimeClientProtocol
    ) async -> TokenPackingReport {
        let options = rawOptions.clampedForRuntime()
        let exactCounts: [Int]? = if let modelID,
                                     let response = try? await runtimeClient.countTokens(
                                         CountTokensRequest(modelID: modelID, texts: serializedPackets)
                                     ) {
            response.counts
        } else {
            nil
        }
        return TokenBudgeter.chooseLargestFittingPrefix(
            serializedPackets: serializedPackets,
            exactCounts: exactCounts,
            maxContextTokens: options.maxContextTokens,
            outputReserveTokens: options.maxOutputTokens
        )
    }

    static func serializedPacket(systemPrompt: String?, prompt: String) -> String {
        guard let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !systemPrompt.isEmpty else { return prompt }
        return systemPrompt + "\n\n" + prompt
    }
}
