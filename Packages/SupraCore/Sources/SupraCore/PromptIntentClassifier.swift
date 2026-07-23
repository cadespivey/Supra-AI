import Foundation
import NaturalLanguage

/// A three-way intent result. Only `.general` is permission to use the ungated route;
/// `.uncertain` deliberately carries different meaning from `.general` so callers can fail closed.
public enum PromptIntentClassification: String, Codable, Hashable, Sendable {
    case legal
    case general
    case uncertain
}

/// Synchronous and model-load independent: routing must be known before the app decides which
/// chat model and legal-grounding pipeline to load.
public protocol PromptIntentClassifying: Sendable {
    func classify(_ prompt: String) -> PromptIntentClassification
}

/// On-device semantic intent classification using Apple's English sentence embedding.
///
/// The embedding revision, intent exemplars, margin, and minimum similarity are all pinned here.
/// There is no network or chat-model dependency. If the OS asset or a vector is unavailable, the
/// classifier returns `.uncertain`; `ModelRouter` owns the deterministic fail-closed policy.
public struct SemanticPromptIntentClassifier: PromptIntentClassifying {
    private static let embeddingRevision = 1
    private static let neighborCount = 3
    private static let minimumMargin = 0.025
    private static let minimumSimilarity = -0.10

    /// Training exemplars are intentionally separate from the committed holdout corpus in tests.
    /// They describe broad intents rather than enumerate marker words.
    private static let legalExemplars = [
        "What did the appellate court decide about arbitration?",
        "May a landlord retain a tenant's deposit?",
        "When is the response to a complaint due?",
        "Does an evidence doctrine exclude this testimony?",
        "Is an oral agreement enforceable in this state?",
        "What must I do after receiving a subpoena?",
        "What claims can an employee bring for discrimination?",
        "Which court has jurisdiction over this dispute?",
        "Can the police search a vehicle without a warrant?",
        "What damages are available for breach of duty?",
        "How can a parent modify a child custody order?",
        "What law governs eviction of a residential tenant?",
        "Must a company preserve evidence after threatened litigation?",
        "What did the federal circuit court hold in this case?",
        "How long does a claimant have to appeal the judgment?",
        "Can this contractual clause be enforced?",
    ]

    private static let generalExemplars = [
        "Is this software API stable and reliable?",
        "What is the problem with this computer program?",
        "How do I bake a loaf of sourdough bread?",
        "What will the weather be tomorrow?",
        "Help me write a friendly project update email.",
        "What is the capital of France?",
        "How do I plan a vacation itinerary?",
        "Explain how photosynthesis works.",
        "What is twelve multiplied by nine?",
        "How can I improve my running pace?",
        "Summarize the main ideas in this article.",
        "Suggest a dinner recipe using lentils.",
        "Why is my wireless network connection slow?",
        "Create an agenda for our weekly team meeting.",
        "What are the rules of this board game?",
        "How can I organize files on my laptop?",
        "Help me plan a three-day city vacation.",
        "Who won the sports game or chess tournament?",
        "Will it rain this weekend?",
    ]

    private struct ExemplarVectors: Sendable {
        let legal: [[Double]]
        let general: [[Double]]
    }

    private static let exemplarVectors: ExemplarVectors? = {
        guard let embedding = NLEmbedding.sentenceEmbedding(
            for: .english,
            revision: embeddingRevision
        ) else {
            return nil
        }
        let legal = legalExemplars.compactMap { embedding.vector(for: $0) }.map(normalized)
        let general = generalExemplars.compactMap { embedding.vector(for: $0) }.map(normalized)
        guard legal.count == legalExemplars.count, general.count == generalExemplars.count else {
            return nil
        }
        return ExemplarVectors(legal: legal, general: general)
    }()

    public init() {}

    public func classify(_ prompt: String) -> PromptIntentClassification {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .general }
        guard
            let vectors = Self.exemplarVectors,
            let embedding = NLEmbedding.sentenceEmbedding(
                for: .english,
                revision: Self.embeddingRevision
            ),
            let rawPromptVector = embedding.vector(for: trimmed)
        else {
            return .uncertain
        }

        let promptVector = Self.normalized(rawPromptVector)
        let legalScore = Self.nearestScore(promptVector, exemplars: vectors.legal)
        let generalScore = Self.nearestScore(promptVector, exemplars: vectors.general)
        let bestScore = max(legalScore, generalScore)
        guard bestScore >= Self.minimumSimilarity else { return .uncertain }

        if legalScore - generalScore >= Self.minimumMargin {
            return .legal
        }
        if generalScore - legalScore >= Self.minimumMargin {
            return .general
        }
        return .uncertain
    }

    private static func nearestScore(_ vector: [Double], exemplars: [[Double]]) -> Double {
        let scores = exemplars.map { exemplar in
            zip(vector, exemplar).reduce(0.0) { $0 + ($1.0 * $1.1) }
        }.sorted(by: >)
        let nearest = scores.prefix(neighborCount)
        return nearest.reduce(0.0, +) / Double(nearest.count)
    }

    private static func normalized(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }
}

/// A deterministic override that gates without consulting the semantic classifier.
/// Matching is token/phrase bounded — an API being "reliable" is not the legal term
/// "liable", and an "issue" does not contain the verb "sue" — but bounding cannot
/// disambiguate homonyms: "ask Sue", "holding a party", an APA "citation", a MacBook
/// "warranty", and the Supreme Court BUILDING all still gate (measured baseline:
/// PromptRoutingRecallBaselineTests.testMarkerHomonymsCurrentlyGateNonLegalPrompts).
/// That trade is deliberate: every miss here fails toward the gated route, never
/// away from it. Refine only with the homonym baseline and the routing corpus's
/// recall gate both in view.
enum DeterministicLegalIntentMarkers {
    private static let phrases = [
        "case law", "statute", "regulation", "precedent", "jurisdiction",
        "legal authority", "legal standard", "holding", "motion to dismiss",
        "summary judgment", "pleading", "bluebook", "citation", "docket",
        "plaintiff", "defendant", "appellant", "appellee", "injunction",
        "court of appeals", "district court", "supreme court", "contract law",
        "under california law", "under new york law", "governing law", "elements of",
        "cause of action", "burden of proof", "standard of review", "recover damages",
        "damages under", "lawsuit", "sue", "can i sue", "liable", "liability",
        "breach of", "negligence", "statute of limitations", "tort", "wrongful",
        "discrimination", "is it legal", "legal to", "my legal rights",
        "what are my rights", "lease agreement", "evict", "custody", "alimony",
        "warranty", "easement", "fiduciary", "good faith", "due process",
        "first amendment", "is enforceable", "legally required", "legally binding",
        "right to",
    ]

    static func matches(_ prompt: String) -> Bool {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let padded = " \(words.joined(separator: " ")) "
        if phrases.contains(where: { padded.contains(" \($0) ") }) {
            return true
        }
        return words.contains { $0.hasPrefix("indemnif") }
    }
}
