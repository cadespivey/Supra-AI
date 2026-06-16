import Foundation

/// Checks whether a Hugging Face model is loadable by the linked text runtime,
/// based on its `config.json` `model_type`.
///
/// The runtime (MLXLLM's `LLMModelFactory`) dispatches purely on `model_type`,
/// looked up in its type registry — NOT on the `architectures` name. This set
/// mirrors `LLMTypeRegistry` at the pinned `mlx-swift-lm` 3.31.3; update it when
/// that dependency is bumped (see Docs/Architecture/Dependencies.md).
enum ModelCompatibility {
    static let supportedModelTypes: Set<String> = [
        "acereason", "afmoe", "apertus", "baichuan_m1", "bailing_moe", "bitnet",
        "cohere", "deepseek_v3", "ernie4_5", "exaone4", "falcon_h1", "gemma",
        "gemma2", "gemma3", "gemma3_text", "gemma3n", "gemma4", "gemma4_text",
        "glm4", "glm4_moe", "glm4_moe_lite", "gpt_oss", "granite",
        "granitemoehybrid", "internlm2", "jamba_3b", "lfm2", "lfm2_moe",
        "lille-130m", "llama", "mimo", "mimo_v2_flash", "minicpm", "minimax",
        "mistral", "mistral3", "nanochat", "nemotron_h", "olmo2", "olmo3",
        "olmoe", "openelm", "phi", "phi3", "phimoe", "qwen2", "qwen3", "qwen3_5",
        "qwen3_5_moe", "qwen3_5_text", "qwen3_moe", "qwen3_next", "smollm3",
        "starcoder2"
    ]

    private struct Config: Decodable {
        let modelType: String?

        private enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }

    /// Returns a human-readable reason the model is unsupported, or `nil` if it
    /// looks loadable (also `nil` when `model_type` is absent/unparseable — we
    /// don't block on uncertainty; the load itself, and its surfaced error, decide).
    static func unsupportedReason(configJSON: Data) -> String? {
        guard
            let config = try? JSONDecoder().decode(Config.self, from: configJSON),
            let modelType = config.modelType,
            !modelType.isEmpty
        else {
            return nil
        }

        guard !supportedModelTypes.contains(modelType) else { return nil }

        return "This model’s type “\(modelType)” isn’t supported by the runtime yet — it loads MLX text models such as Llama, Qwen, Gemma, and Phi. Pick a different model."
    }
}
