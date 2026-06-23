import Foundation

/// The user's personalization profile. Structured inputs (who they are, how they
/// write, how they cite) plus excerpts of their own writing are assembled into the
/// assistant's "soul document" — the system prompt that shapes every response.
public struct AssistantProfile: Codable, Equatable, Sendable {
    /// Persistence keys in the app-settings store.
    public static let profileKey = "assistant.profile"
    /// The composed system prompt the chat/matter controllers read at send time.
    public static let systemPromptKey = "assistant.systemPrompt"

    public enum Formality: String, Codable, CaseIterable, Sendable, Identifiable {
        case formal, balanced, plainSpoken
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .formal: "Formal"
            case .balanced: "Balanced"
            case .plainSpoken: "Plain-spoken"
            }
        }
    }

    public enum Length: String, Codable, CaseIterable, Sendable, Identifiable {
        case concise, balanced, thorough
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .concise: "Concise"
            case .balanced: "Balanced"
            case .thorough: "Thorough"
            }
        }
    }

    /// An excerpt of the user's own writing, used to learn their voice/formatting.
    public struct WritingSample: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var excerpt: String

        public init(id: String = UUID().uuidString, name: String, excerpt: String) {
            self.id = id
            self.name = name
            self.excerpt = excerpt
        }
    }

    // Who you are
    public var fullName: String = ""
    public var role: String = ""
    public var organization: String = ""
    public var jurisdictions: String = ""
    public var practiceAreas: String = ""
    // How to write
    public var formality: Formality = .balanced
    public var length: Length = .balanced
    public var voiceNotes: String = ""
    // Citations
    public var citationStyle: String = ""
    public var citationNotes: String = ""
    // Anything else
    public var additionalInstructions: String = ""
    // Reference writing
    public var writingSamples: [WritingSample] = []

    public init() {}

    public static let empty = AssistantProfile()

    public var isConfigured: Bool {
        !fullName.isEmpty || !role.isEmpty || !organization.isEmpty || !jurisdictions.isEmpty
            || !practiceAreas.isEmpty || !voiceNotes.isEmpty || !citationStyle.isEmpty
            || !citationNotes.isEmpty || !additionalInstructions.isEmpty || !writingSamples.isEmpty
            || formality != .balanced || length != .balanced
    }

    // Resilient decoding so adding fields later never drops a saved profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        organization = try c.decodeIfPresent(String.self, forKey: .organization) ?? ""
        jurisdictions = try c.decodeIfPresent(String.self, forKey: .jurisdictions) ?? ""
        practiceAreas = try c.decodeIfPresent(String.self, forKey: .practiceAreas) ?? ""
        formality = try c.decodeIfPresent(Formality.self, forKey: .formality) ?? .balanced
        length = try c.decodeIfPresent(Length.self, forKey: .length) ?? .balanced
        voiceNotes = try c.decodeIfPresent(String.self, forKey: .voiceNotes) ?? ""
        citationStyle = try c.decodeIfPresent(String.self, forKey: .citationStyle) ?? ""
        citationNotes = try c.decodeIfPresent(String.self, forKey: .citationNotes) ?? ""
        additionalInstructions = try c.decodeIfPresent(String.self, forKey: .additionalInstructions) ?? ""
        writingSamples = try c.decodeIfPresent([WritingSample].self, forKey: .writingSamples) ?? []
    }

    /// The "soul document": the base prompt augmented with everything the user told
    /// us. Empty sections are omitted so a sparse profile stays focused.
    ///
    /// `includeWritingSamples` gates the verbatim writing-style excerpts. They belong
    /// only in drafting/voice contexts; in grounded factual ones (research, Q&A,
    /// structured outputs) they must be omitted, because the model otherwise mines
    /// their prose as fact and can let it override the matter's actual documents.
    public func composedSystemPrompt(base: String?, includeWritingSamples: Bool = true) -> String {
        var profile: [String] = []

        var identity: [String] = []
        if !fullName.isEmpty {
            identity.append("You are assisting \(fullName)\(role.isEmpty ? "" : ", \(role)")\(organization.isEmpty ? "" : " at \(organization)").")
        } else if !role.isEmpty {
            identity.append("You are assisting a \(role)\(organization.isEmpty ? "" : " at \(organization)").")
        }
        if !jurisdictions.isEmpty { identity.append("Primary jurisdiction(s): \(jurisdictions).") }
        if !practiceAreas.isEmpty { identity.append("Practice area(s): \(practiceAreas).") }
        if !identity.isEmpty { profile.append("## About the user\n" + identity.joined(separator: " ")) }

        // Only describe style when the user actually deviated from the defaults or
        // added notes — otherwise an untouched profile would inject a redundant
        // "Balanced / Balanced" block on every request.
        var style: [String] = []
        if formality != .balanced { style.append("- Formality: \(formality.label).") }
        if length != .balanced { style.append("- Default length: \(length.label).") }
        if !voiceNotes.isEmpty { style.append("- Voice and style: \(voiceNotes)") }
        if !style.isEmpty {
            profile.append("## How to write for this user\n" + style.joined(separator: "\n"))
        }

        var cites: [String] = []
        if !citationStyle.isEmpty {
            cites.append("- Citation style: \(citationStyle).")
            // Fold in the baked-in guidance for a recognized style/state so the
            // assistant cites the way that jurisdiction expects.
            if let guidance = CitationStyleCatalog.style(named: citationStyle)?.guidance {
                cites.append("- \(guidance)")
            }
        }
        if !citationNotes.isEmpty { cites.append("- \(citationNotes)") }
        if !cites.isEmpty { profile.append("## Citations\n" + cites.joined(separator: "\n")) }

        if !additionalInstructions.isEmpty {
            // The user's free-text instructions are standing preferences for tone,
            // format, and emphasis. They are framed (not pasted raw) so they can't be
            // read as granting capabilities the assistant lacks — e.g. an instruction
            // to "log your time" or "note actions taken" must shape wording, never
            // license the model to claim it searched, reviewed, or filed anything, and
            // never override the sources or grounding for a task.
            profile.append(
                "## Additional instructions\nApply the following standing preferences to tone, format, "
                + "and emphasis. They do not grant any capability or authority to take actions, and they "
                + "never override the factual grounding or sources for a task:\n\n\(additionalInstructions)"
            )
        }

        if includeWritingSamples, !writingSamples.isEmpty {
            var samples = [
                "## The user's writing style",
                "The following are excerpts of the user's OWN past writing, provided solely as STYLE EXEMPLARS so you can emulate their voice, tone, structure, and formatting. They are not part of the current matter and are not evidence: never treat their content as fact, never reuse their parties, names, dates, figures, or holdings, and never let them override or substitute for the matter's documents or your cited sources. Match the style only; draw all substance from the actual sources for the task at hand."
            ]
            for sample in writingSamples {
                samples.append("")
                samples.append("### \(sample.name)")
                samples.append(sample.excerpt)
            }
            profile.append(samples.joined(separator: "\n"))
        }

        var sections: [String] = []
        if let base, !base.isEmpty { sections.append(base) }
        if !profile.isEmpty {
            sections.append("# User profile\nApply the following to every response for this user.\n\n" + profile.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n---\n\n")
    }
}
