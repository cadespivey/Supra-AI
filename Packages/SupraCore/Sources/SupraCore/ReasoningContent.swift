import Foundation

/// Separates a reasoning model's chain-of-thought from its user-facing answer.
///
/// Qwen3-style chat templates emit the opening `<think>` as part of the *prompt*
/// (right after the assistant turn marker), so the model's generated text looks
/// like `"<reasoning>…</think>\n\n<answer>"` — the close tag is present in the
/// output but the open tag usually is not. We therefore split on the first
/// `</think>`: everything after it is the answer, everything before it is the
/// reasoning. Text that contains no `</think>` (non-reasoning models, or models
/// run with thinking disabled) is returned unchanged, so this is safe to apply
/// to every model's output unconditionally.
public enum ReasoningContent {
    private static let closeTag = "</think>"
    private static let openTag = "<think>"

    /// The user-facing answer with any leading reasoning block removed.
    /// Returns `rawOutput` unchanged when there is no reasoning block.
    public static func answer(from rawOutput: String) -> String {
        guard let closeRange = rawOutput.range(of: closeTag) else {
            return rawOutput
        }
        return String(rawOutput[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reasoning block (the text up to the first `</think>`, minus a leading
    /// `<think>` if the model emitted one), or `nil` when there is none.
    /// Preserved so a future UI can surface reasoning in a collapsible section.
    public static func reasoning(from rawOutput: String) -> String? {
        guard let closeRange = rawOutput.range(of: closeTag) else {
            return nil
        }
        var block = String(rawOutput[..<closeRange.lowerBound])
        if let openRange = block.range(of: openTag) {
            block = String(block[openRange.upperBound...])
        }
        return block.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
