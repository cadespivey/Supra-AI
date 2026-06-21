import Foundation

/// Example prompts shown on a blank global chat so a new or returning user has a
/// concrete starting point instead of an empty box. A legal practitioner sees a
/// rotating sample (four at a time) drawn at random from this set, so the empty
/// state stays fresh across new chats.
///
/// Each suggestion pairs a short button title with the full prompt that is sent
/// when tapped. Keep prompts model-agnostic and genuinely useful for legal work —
/// research, drafting, analysis, and explanation — without implying the answer is
/// verified legal advice.
public struct ChatSuggestion: Identifiable, Sendable, Equatable {
    public let id: String
    /// A short label for the suggestion card (a few words).
    public let title: String
    /// The full prompt placed in the composer / sent when the card is tapped.
    public let prompt: String
    /// SF Symbol shown on the card.
    public let systemImage: String

    public init(id: String, title: String, prompt: String, systemImage: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.systemImage = systemImage
    }
}

public enum ChatSuggestions {
    /// How many suggestions to show at once on the empty state.
    public static let displayCount = 4

    /// The full catalog of example prompts. Order here is not meaningful — the UI
    /// samples from it at random. Kept well above `displayCount` (36 entries) so a
    /// user rarely sees the same four twice in a row.
    public static let all: [ChatSuggestion] = [
        // MARK: Research & authority
        ChatSuggestion(
            id: "research-standard",
            title: "Find controlling authority",
            prompt: "Find the controlling authority on the standard for granting a preliminary injunction in the Ninth Circuit, and summarize the governing test.",
            systemImage: "books.vertical"
        ),
        ChatSuggestion(
            id: "research-element",
            title: "Elements of a claim",
            prompt: "What are the elements of a breach of fiduciary duty claim, and what does a plaintiff need to plead for each element?",
            systemImage: "list.bullet.rectangle"
        ),
        ChatSuggestion(
            id: "research-split",
            title: "Circuit split overview",
            prompt: "Is there a circuit split on whether a website's browsewrap terms are enforceable? Summarize the competing approaches.",
            systemImage: "arrow.triangle.branch"
        ),
        ChatSuggestion(
            id: "research-statute",
            title: "Explain a statute",
            prompt: "Explain, in plain English, what the federal anti-SLAPP landscape looks like and how it differs from state anti-SLAPP statutes.",
            systemImage: "doc.text.magnifyingglass"
        ),
        ChatSuggestion(
            id: "research-sol",
            title: "Statute of limitations",
            prompt: "What is the typical statute of limitations for a written contract claim, and what events can toll or restart the clock?",
            systemImage: "clock.badge.exclamationmark"
        ),
        ChatSuggestion(
            id: "research-standard-review",
            title: "Standard of review",
            prompt: "Explain the difference between de novo, abuse of discretion, and clear error standards of review on appeal, with an example of each.",
            systemImage: "scale.3d"
        ),

        // MARK: Drafting
        ChatSuggestion(
            id: "draft-demand",
            title: "Draft a demand letter",
            prompt: "Draft a professional demand letter for unpaid invoices totaling $24,500 owed by a former client, giving 14 days to cure before litigation.",
            systemImage: "envelope"
        ),
        ChatSuggestion(
            id: "draft-nda",
            title: "Draft a mutual NDA",
            prompt: "Draft a mutual non-disclosure agreement for two startups exploring a partnership, with a 3-year confidentiality term and standard carve-outs.",
            systemImage: "lock.doc"
        ),
        ChatSuggestion(
            id: "draft-clause",
            title: "Draft a contract clause",
            prompt: "Draft a limitation-of-liability clause that caps damages at fees paid in the prior 12 months and excludes liability for indirect damages.",
            systemImage: "doc.badge.plus"
        ),
        ChatSuggestion(
            id: "draft-motion",
            title: "Outline a motion",
            prompt: "Outline a motion to dismiss for failure to state a claim, including the sections I should include and the key arguments to develop.",
            systemImage: "doc.text"
        ),
        ChatSuggestion(
            id: "draft-engagement",
            title: "Engagement letter",
            prompt: "Draft a client engagement letter for a flat-fee trademark registration, covering scope, fees, and what is excluded.",
            systemImage: "signature"
        ),
        ChatSuggestion(
            id: "draft-discovery",
            title: "Interrogatories",
            prompt: "Draft a first set of interrogatories for a plaintiff in a breach-of-contract dispute over a software development agreement.",
            systemImage: "questionmark.folder"
        ),

        // MARK: Analysis & strategy
        ChatSuggestion(
            id: "analyze-irac",
            title: "IRAC analysis",
            prompt: "Walk through an IRAC analysis of whether an employee who posts criticism of their employer on social media can be lawfully terminated at will.",
            systemImage: "rectangle.3.group"
        ),
        ChatSuggestion(
            id: "analyze-risks",
            title: "Spot the risks",
            prompt: "I'm advising a SaaS company adding an arbitration clause to its terms of service. What are the main legal risks and enforceability pitfalls to flag?",
            systemImage: "exclamationmark.shield"
        ),
        ChatSuggestion(
            id: "analyze-counter",
            title: "Anticipate counterarguments",
            prompt: "I plan to argue that a non-compete is unenforceable as overly broad. What counterarguments should I expect from opposing counsel?",
            systemImage: "person.2.wave.2"
        ),
        ChatSuggestion(
            id: "analyze-remedies",
            title: "Compare remedies",
            prompt: "Compare the available remedies for breach of a real estate purchase agreement: specific performance, expectation damages, and rescission.",
            systemImage: "arrow.left.arrow.right"
        ),
        ChatSuggestion(
            id: "analyze-jurisdiction",
            title: "Personal jurisdiction",
            prompt: "Analyze whether a court would have personal jurisdiction over an out-of-state defendant whose only contact was selling goods through an online marketplace.",
            systemImage: "globe.americas"
        ),
        ChatSuggestion(
            id: "analyze-privilege",
            title: "Privilege questions",
            prompt: "When does attorney-client privilege attach to communications with in-house counsel, and what commonly waives it?",
            systemImage: "lock.shield"
        ),

        // MARK: Documents & review
        ChatSuggestion(
            id: "doc-summarize",
            title: "Summarize a contract",
            prompt: "I'll paste a contract. Summarize the key obligations, term and termination, payment terms, and any unusual or one-sided provisions.",
            systemImage: "doc.plaintext"
        ),
        ChatSuggestion(
            id: "doc-redline",
            title: "Suggest redlines",
            prompt: "I'll paste a clause from a vendor agreement. Suggest redlines to make it more favorable to the customer, with a short rationale for each.",
            systemImage: "pencil.line"
        ),
        ChatSuggestion(
            id: "doc-issues",
            title: "Issue-spot a fact pattern",
            prompt: "I'll describe a dispute between a landlord and tenant. Issue-spot the potential claims and defenses each side might raise.",
            systemImage: "magnifyingglass"
        ),
        ChatSuggestion(
            id: "doc-timeline",
            title: "Build a chronology",
            prompt: "I'll paste a set of dated events from a case file. Organize them into a clean chronology I can use to prepare for a deposition.",
            systemImage: "calendar"
        ),
        ChatSuggestion(
            id: "doc-translate",
            title: "Plain-English translation",
            prompt: "Translate this dense contract paragraph into plain English a non-lawyer client could understand, without losing legal meaning. I'll paste it next.",
            systemImage: "character.bubble"
        ),
        ChatSuggestion(
            id: "doc-checklist",
            title: "Due-diligence checklist",
            prompt: "Create a due-diligence checklist for acquiring a small business, covering corporate, employment, IP, contracts, and litigation.",
            systemImage: "checklist"
        ),

        // MARK: Litigation & procedure
        ChatSuggestion(
            id: "lit-deposition",
            title: "Deposition outline",
            prompt: "Draft a deposition outline for a corporate representative in a product-liability case involving an allegedly defective power tool.",
            systemImage: "person.crop.rectangle"
        ),
        ChatSuggestion(
            id: "lit-objections",
            title: "Common objections",
            prompt: "List the common evidentiary objections I can make during a deposition and a one-line explanation of when each applies.",
            systemImage: "hand.raised"
        ),
        ChatSuggestion(
            id: "lit-removal",
            title: "Removal to federal court",
            prompt: "Explain the requirements and deadlines for removing a case from state to federal court based on diversity jurisdiction.",
            systemImage: "building.columns"
        ),
        ChatSuggestion(
            id: "lit-settlement",
            title: "Settlement posture",
            prompt: "Help me think through a settlement strategy for an employment dispute where liability is uncertain but litigation costs are high.",
            systemImage: "hands.sparkles"
        ),
        ChatSuggestion(
            id: "lit-appeal",
            title: "Preserve an issue for appeal",
            prompt: "What do I need to do at trial to preserve an evidentiary issue for appeal, and what happens if I fail to object?",
            systemImage: "arrow.uturn.up"
        ),
        ChatSuggestion(
            id: "lit-discovery-dispute",
            title: "Meet-and-confer letter",
            prompt: "Draft a meet-and-confer letter raising deficiencies in opposing counsel's document production and requesting supplementation.",
            systemImage: "bubble.left.and.bubble.right"
        ),

        // MARK: Transactional & advisory
        ChatSuggestion(
            id: "advise-entity",
            title: "Choose an entity",
            prompt: "Compare an LLC, S-corp, and C-corp for a two-founder tech startup planning to raise venture funding within two years.",
            systemImage: "building.2"
        ),
        ChatSuggestion(
            id: "advise-employment",
            title: "Employee vs. contractor",
            prompt: "Explain the main tests courts use to distinguish an employee from an independent contractor, and the consequences of misclassification.",
            systemImage: "person.badge.shield.checkmark"
        ),
        ChatSuggestion(
            id: "advise-ip",
            title: "Protect a brand name",
            prompt: "A client wants to protect a new product name. Walk me through trademark clearance and the registration process at a high level.",
            systemImage: "checkmark.seal"
        ),
        ChatSuggestion(
            id: "advise-privacy",
            title: "Privacy compliance",
            prompt: "What should a consumer mobile app consider for privacy compliance across the CCPA and GDPR? Give me a prioritized starter checklist.",
            systemImage: "hand.raised.square"
        ),
        ChatSuggestion(
            id: "advise-cease",
            title: "Cease-and-desist",
            prompt: "Draft a cease-and-desist letter to a competitor using a confusingly similar logo, asserting trademark infringement.",
            systemImage: "nosign"
        ),
        ChatSuggestion(
            id: "advise-force-majeure",
            title: "Force majeure review",
            prompt: "Explain how a force majeure clause is typically interpreted, and what language makes it more likely to cover a supply-chain disruption.",
            systemImage: "cloud.bolt"
        )
    ]

    /// Returns `count` distinct suggestions chosen at random. When `count` exceeds
    /// the catalog size, the whole catalog (shuffled) is returned. Stable on its
    /// own input — callers re-invoke it to rotate the empty state.
    public static func sample(count: Int = displayCount) -> [ChatSuggestion] {
        guard count > 0 else { return [] }
        return Array(all.shuffled().prefix(count))
    }
}
