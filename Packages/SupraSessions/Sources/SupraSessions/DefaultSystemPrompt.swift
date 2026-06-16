import Foundation

/// Loads the default system prompt bundled with the SupraSessions package.
public enum DefaultSystemPrompt {
    static let resourceName = "default-system-prompt-v1"

    /// The Milestone 1 legal-assistant system prompt, or `nil` if unavailable.
    public static func milestone1() -> String? {
        guard
            let url = Bundle.module.url(forResource: resourceName, withExtension: "md"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
