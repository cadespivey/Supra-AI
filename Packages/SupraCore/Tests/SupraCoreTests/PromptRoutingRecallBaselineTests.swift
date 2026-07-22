import SupraCore
import XCTest

/// Phase 4 regression coverage for `ModelRouter.routePrompt`'s legal-intent inference.
///
/// ## Why this is a baseline and not a fix
///
/// The obvious repair — word-bounding the keyword matching, as was done for the verifier's
/// jurisdiction, refusal, and holding-vs-dicta rules — would make routing WORSE here, because the
/// safety asymmetry runs the other way:
///
///   looksLegal == true   → .legalQA    → requiresCitations / requiresJurisdiction /
///                                        requiresCourtListener all honor configuration
///   looksLegal == false  → .generalQA  → all three are FALSE; the answer is ungrounded
///
/// So over-firing is safe and under-firing is dangerous. Every substring collision in the current
/// list ("reliable" contains "liable", "issue " contains "sue ") pushes prompts toward the MORE
/// gated route. Tightening the match would strip that accidental protection while leaving the
/// real defect — recall — untouched.
///
/// The real defect is that ordinary legal questions match no marker at all and fall to
/// `.generalQA`. That cannot be fixed by another phrase list; it is the case for a semantic
/// classifier with a deterministic fail-closed backstop.
final class PromptRoutingRecallBaselineTests: XCTestCase {

    private let router = ModelRouter(configuration: .fromEnvironment())

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

    /// The gap is recall, not vocabulary: adding one marker word to the same question flips it to
    /// the gated route. A phrase list can always be extended and will always have a next miss —
    /// which is the argument against extending it again.
    func testAddingASingleMarkerWordFlipsTheSameQuestion() {
        let bare = mode("Can my landlord keep my security deposit?")
        let marked = mode("Can my landlord keep my security deposit under the lease agreement?")

        XCTAssertFalse(bare.requiresCitations, "BASELINE (defect)")
        XCTAssertTrue(marked.requiresCitations, "one marker word is the whole difference")
    }

    // MARK: - Over-firing, recorded as ACCEPTABLE

    /// Substring collisions send non-legal prompts to the gated legal route. That costs retrieval
    /// work and can produce a legal-research treatment of a plainly non-legal question, but it
    /// fails SAFE.
    ///
    /// PHASE 4: do not "fix" these by tightening the match in isolation. Precision here is only
    /// worth improving once recall is handled by something other than a phrase list, or the net
    /// effect is to remove gating from prompts that currently get it.
    func testSubstringCollisionsOverFireTowardTheGatedRoute() {
        // "reliable" contains "liable"; "issue " contains "sue ".
        XCTAssertTrue(mode("Is this API reliable?").requiresCitations,
                      "BASELINE: over-fires, but toward the safer route")
        XCTAssertTrue(mode("What is the issue here?").requiresCitations,
                      "BASELINE: over-fires, but toward the safer route")
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
