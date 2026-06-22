import Foundation

/// Token budgeting for prompt assembly. The runtime caps its KV cache at
/// `maxContextTokens` (a `RotatingKVCache`), so a prompt larger than the window is
/// not rejected — it silently rotates the FRONT of the prompt out as generation
/// proceeds. The front is exactly the system grounding and the highest-ranked
/// sources, so a confident answer can be produced from a prompt whose
/// "answer only from the sources" instructions were evicted. This helper computes
/// the safe prompt budget so callers can trim lower-priority context (oldest
/// conversation history) to fit instead.
public enum PromptBudget {
    /// Small reserve for chat-template special tokens (BOS/role markers) added on
    /// top of the message text the caller can see.
    public static let templateMargin = 256

    /// The number of tokens the prompt may occupy so that prompt + generated output
    /// both fit within `maxContextTokens` without the KV cache evicting the front of
    /// the prompt during generation. Never returns less than a small floor so a
    /// degenerate configuration still attempts a generation.
    public static func promptTokenBudget(maxContextTokens: Int, maxOutputTokens: Int) -> Int {
        // Reserve the output budget + a margin, but NEVER exceed the window itself: on
        // a degenerate/hostile tiny-context config the floor must not produce a budget
        // larger than maxContextTokens, or the trim/overflow check would never fire and
        // the front of the prompt would be evicted without being detected.
        min(max(1, maxContextTokens), max(512, maxContextTokens - maxOutputTokens - templateMargin))
    }
}
