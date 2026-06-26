import Foundation
import SupraDraftingCore

// Generation + authority-firewall surface (MotionToDismiss §1 / LetterDemand §1.3).
// The slice ships the protocols + the deterministic firewall; the live model/network impls are
// out of slice. The firewall INVARIANT is the point: no model-originated cite or untraced fact
// ever reaches a draft.

public enum Decoding: Sendable, Equatable {
    case grounded   // temp≈0, Auth sections
    case creative   // /draft route, voice-driven letters
}

public struct VoiceContext: Sendable, Equatable {
    public let profile: AssistantVoiceProfile
    public let toneOnly: Bool   // ALWAYS true in grounded kinds (§8.6)

    public init(profile: AssistantVoiceProfile, toneOnly: Bool) {
        self.profile = profile
        self.toneOnly = toneOnly
    }
}

/// A minimal voice carrier — tone/register exemplars only, never facts.
public struct AssistantVoiceProfile: Sendable, Equatable {
    public let registerNotes: String
    public init(registerNotes: String) { self.registerNotes = registerNotes }
}

public struct PromptParts: Sendable {
    public var taskInstruction: String
    public var voice: VoiceContext?              // NIL for Auth kinds (§8.6)
    public var sectionContract: SectionRequirement
    public var facts: [GroundedFact]             // the ONLY fact source
    public var authorities: [VerifiedAuthority]  // may be empty → model writes [cite]
    public var decoding: Decoding

    public init(taskInstruction: String, voice: VoiceContext?, sectionContract: SectionRequirement,
                facts: [GroundedFact], authorities: [VerifiedAuthority], decoding: Decoding) {
        self.taskInstruction = taskInstruction
        self.voice = voice
        self.sectionContract = sectionContract
        self.facts = facts
        self.authorities = authorities
        self.decoding = decoding
    }
}

public protocol Generator: Sendable {
    func generate(_ parts: PromptParts) async throws -> GeneratedSection
}

public protocol LetterGenerator: Sendable {
    func generateLetter(_ parts: PromptParts) async throws -> GeneratedLetter
}

// MARK: - Authority firewall (the ONE network call; public cite strings only)

public struct CitatorHit: Sendable, Equatable {
    public let cite: CitationRef
    public let snippet: String
    public let onPointScore: Double

    public init(cite: CitationRef, snippet: String, onPointScore: Double) {
        self.cite = cite
        self.snippet = snippet
        self.onPointScore = onPointScore
    }
}

public enum CiteValidity: Sendable, Equatable {
    case confirmed, unknown, badFormat
}

public protocol CitatorClient: Sendable {
    func find(proposition: ScrubbedProposition) async -> [CitatorHit]   // network errors → []
    func validate(_ cite: CitationRef) async -> CiteValidity            // errors → .unknown
}

public enum AuthorityOutcome: Sendable, Equatable {
    case cite(VerifiedAuthority)
    case placeholder
}

/// Decision B: try to find authority; if inadequate/inconclusive → `[cite]` placeholder. Never invent.
public struct AuthorityResolver: Sendable {
    public let citator: CitatorClient
    public let threshold: Double

    public init(citator: CitatorClient, threshold: Double = 0.6) {
        self.citator = citator
        self.threshold = threshold
    }

    public func resolve(_ proposition: ScrubbedProposition) async -> AuthorityOutcome {
        let hits = await citator.find(proposition: proposition)
        guard let best = hits.max(by: { $0.onPointScore < $1.onPointScore }),
              best.onPointScore >= threshold else { return .placeholder }
        return .cite(VerifiedAuthority(cite: best.cite, snippet: best.snippet, source: .courtListener))
    }
}

/// The literal placeholder a draft carries when no authority was confirmed.
public let citePlaceholder = CitationRef(raw: "[cite]")
public let factPlaceholder = "[fact?]"
