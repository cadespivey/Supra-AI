import SupraCore
import XCTest

/// Phase 4 regression coverage for `ModelRouter.routePrompt`'s legal-intent inference.
///
/// ## Why Phase 4 does not merely tighten the old marker list
///
/// Before semantic inference, word-bounding the keyword matching would have made routing worse,
/// because the safety asymmetry runs the other way:
///
///   looksLegal == true   → .legalQA    → requiresCitations / requiresJurisdiction /
///                                        requiresCourtListener all honor configuration
///   looksLegal == false  → .generalQA  → all three are FALSE; the answer is ungrounded
///
/// Phase 4 first protects recall with semantic inference and a fail-closed backstop. Only then is
/// it safe to remove accidental substring matches and measure the resulting precision.
final class PromptRoutingRecallBaselineTests: XCTestCase {

    private struct FixedClassifier: PromptIntentClassifying {
        let result: PromptIntentClassification

        func classify(_ prompt: String) -> PromptIntentClassification {
            result
        }
    }

    private let router = ModelRouter(configuration: LegalModelConfiguration(
        requireCitations: true,
        jurisdictionRequired: true
    ))

    private func mode(_ prompt: String) -> ModelRoute {
        router.routePrompt(prompt).route
    }

    // MARK: - Legal-intent recall

    /// T-RTE-01: each question expresses legal intent without relying on the old marker list.
    /// Phase 4 must route every one through the citation and jurisdiction gates.
    func testOrdinaryLegalQuestionsUseTheGatedRoute() {
        let missed = [
            "What did the Ninth Circuit say about arbitration clauses?",
            "Can my landlord keep my security deposit?",
            "What is the deadline to file an answer?",
            "Does the parol evidence rule apply here?",
            "Is a verbal agreement binding in Florida?",
            "How do I respond to a subpoena?",
        ]
        for prompt in missed {
            let route = mode(prompt)
            XCTAssertTrue(
                route.requiresCitations,
                "legal question must require citations: \(prompt)"
            )
            XCTAssertTrue(
                route.requiresJurisdiction,
                "legal question must require jurisdiction: \(prompt)"
            )
        }
    }

    /// T-RTE-05: legal intent must not depend on adding one word from a marker list.
    func testLegalIntentDoesNotDependOnSingleMarkerWord() {
        let bare = mode("Can my landlord keep my security deposit?")
        let marked = mode("Can my landlord keep my security deposit under the lease agreement?")

        XCTAssertTrue(bare.requiresCitations)
        XCTAssertTrue(marked.requiresCitations)
    }

    // MARK: - Precision

    /// T-RTE-08: once semantic recall and the fail-closed path exist, incidental substrings no
    /// longer need to provide accidental safety ("reliable" contains "liable", "issue" contains
    /// "sue").
    func testIncidentalSubstringsRemainGeneralOnceRecallIsProtected() {
        XCTAssertFalse(mode("Is this API reliable?").requiresCitations)
        XCTAssertFalse(mode("What is the issue here?").requiresCitations)
    }

    // MARK: - Fail-closed classifier contract

    /// T-RTE-04: an unavailable or low-confidence semantic result cannot silently select the
    /// ungated route.
    func testUncertainClassificationFailsClosedToLegal() {
        let router = ModelRouter(intentClassifier: FixedClassifier(result: .uncertain))

        let route = router.routePrompt("A prompt outside the classifier corpus").route

        XCTAssertEqual(route.mode, .legalQA)
        XCTAssertTrue(route.requiresCitations)
        XCTAssertTrue(route.requiresJurisdiction)
    }

    /// T-RTE-03: deterministic markers remain an independent safety override rather than an
    /// assumption about the semantic model's score.
    func testUnequivocalLegalMarkerOverridesGeneralClassification() {
        let router = ModelRouter(intentClassifier: FixedClassifier(result: .general))

        let route = router.routePrompt("What is the standard for summary judgment?").route

        XCTAssertEqual(route.mode, .legalQA)
        XCTAssertTrue(route.requiresCitations)
    }

    /// T-RTE-02: explicit commands are authoritative even when inference would disagree.
    func testSlashCommandBypassesInjectedClassifier() {
        let legalClassifier = FixedClassifier(result: .legal)
        let generalClassifier = FixedClassifier(result: .general)

        XCTAssertEqual(
            ModelRouter(intentClassifier: legalClassifier).routePrompt("/ask what is 2+2").route.mode,
            .generalQA
        )
        XCTAssertEqual(
            ModelRouter(intentClassifier: generalClassifier)
                .routePrompt("/legal is this enforceable").route.mode,
            .legalQA
        )
    }

    // MARK: - Marker-homonym false gating (committed baseline)

    /// BASELINE (defect): every prompt below is unambiguously non-legal, yet the
    /// deterministic marker override gates it — "sue" the name, "holding" the gerund,
    /// an APA "citation", a consumer "warranty", the Supreme Court BUILDING,
    /// biological "regulation", "elements of" a story, directional "right to", and
    /// "good faith" matched across a hyphen. The injected `.general` classifier
    /// proves the marker alone causes the gating, so this baseline is deterministic
    /// on every machine. The user-visible cost is a jurisdiction demand on a casual
    /// question (#115 review, finding 1).
    ///
    /// These assertions document the defect; INVERT them when marker refinement
    /// lands. The refinement must keep the committed corpus's legal recall at 1.0
    /// (PromptRoutingCorpusTests) — do not fix these by deleting markers wholesale.
    func testMarkerHomonymsCurrentlyGateNonLegalPrompts() {
        let router = ModelRouter(
            configuration: LegalModelConfiguration(
                requireCitations: true,
                jurisdictionRequired: true
            ),
            intentClassifier: FixedClassifier(result: .general)
        )
        for prompt in [
            "Can you ask Sue about the meeting tomorrow?",
            "I'm holding a party on Saturday afternoon.",
            "How do I format an APA citation?",
            "Is my MacBook still under warranty?",
            "What time does the Supreme Court building open for tourists?",
            "How does blood sugar regulation work?",
            "What are the elements of a good story?",
            "Scroll right to see the hidden columns.",
            "Recommend a good faith-based charity.",
        ] {
            XCTAssertTrue(
                router.routePrompt(prompt).route.requiresCitations,
                "BASELINE (defect): marker homonym no longer gates — if deliberate, invert this assertion: \(prompt)"
            )
        }
    }

    // MARK: - Invariants Phase 4 must preserve

    /// Explicit slash commands bypass inference entirely and must keep doing so — they are the
    /// user's own unambiguous statement of intent.
    func testExplicitSlashCommandsBypassInference() {
        XCTAssertEqual(router.routePrompt("/ask what is 2+2").command, "/ask")
        XCTAssertFalse(router.routePrompt("/ask what is 2+2").route.requiresCitations)
        XCTAssertEqual(router.routePrompt("/legal is this enforceable").command, "/legal")
        XCTAssertTrue(router.routePrompt("/legal is this enforceable").route.requiresCitations)
    }

    /// A prompt carrying an unambiguous legal marker must stay on the gated route. This is the one
    /// assertion here that must never flip in either direction.
    func testUnambiguousLegalMarkersStayGated() {
        for prompt in [
            "What is the standard for summary judgment?",
            "Find case law on promissory estoppel.",
            "Which statute of limitations applies?",
        ] {
            XCTAssertTrue(mode(prompt).requiresCitations, prompt)
        }
    }
}
