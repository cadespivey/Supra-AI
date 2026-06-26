import Foundation

/// A user-facing slash command offered as chat-composer autocomplete. Mirrors the
/// routing in `ModelRouter.parseSlashCommand` so what the menu offers is exactly what
/// the router understands (the router additionally accepts a few aliases).
public struct SlashCommand: Identifiable, Sendable, Equatable {
    public var id: String { command }
    /// The literal command typed at the start of a message, e.g. `/research`.
    public let command: String
    /// Short menu title, e.g. "Legal research".
    public let title: String
    /// One-line description of what the command does.
    public let summary: String

    public init(command: String, title: String, summary: String) {
        self.command = command
        self.title = title
        self.summary = summary
    }
}

public enum SlashCommandCatalog {
    /// The canonical commands surfaced in the composer (most common first). `-hq`
    /// variants run the same route on the higher-quality reasoning model.
    public static let all: [SlashCommand] = [
        SlashCommand(command: "/legal", title: "Legal Q&A",
                     summary: "Source-grounded legal answer with citations"),
        SlashCommand(command: "/research", title: "Legal research",
                     summary: "Thorough, source-grounded research memo"),
        SlashCommand(command: "/draft", title: "Draft",
                     summary: "Attorney-editable work product"),
        SlashCommand(command: "/critique", title: "Critique",
                     summary: "Red-team a draft for defects and unsupported claims"),
        SlashCommand(command: "/verify", title: "Verify",
                     summary: "Check an analysis against its retrieved sources"),
        SlashCommand(command: "/ask", title: "General",
                     summary: "General assistant — no legal grounding"),
        SlashCommand(command: "/legal-hq", title: "Legal Q&A (HQ)",
                     summary: "Legal Q&A on the higher-quality model"),
        SlashCommand(command: "/research-hq", title: "Research (HQ)",
                     summary: "Research on the higher-quality model"),
    ]

    /// Commands matching the text typed so far — used to drive the composer menu.
    /// Only fires while the user is still typing the command token at the very start
    /// of the message (a leading `/…` with no whitespace yet); returns `[]` once they
    /// type a space (i.e. begin the actual prompt) so the menu dismisses.
    public static func suggestions(for text: String) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace }) else { return [] }
        let prefix = text.lowercased()
        return all.filter { $0.command.hasPrefix(prefix) }
    }
}
