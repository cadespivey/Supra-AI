import Foundation
import SupraCore
import SupraDrafting
import SupraDraftingCore
import XCTest

final class MotionVerificationTests: XCTestCase {
    private let factOne = MotionFactEvidence(
        factID: "fact-1",
        text: "The fictional complaint alleges a written agreement dated January 4, 2026.",
        sourceID: "revision-1",
        locator: "p. 4"
    )
    private let factTwo = MotionFactEvidence(
        factID: "fact-2",
        text: "The fictional complaint does not attach the alleged agreement.",
        sourceID: "revision-2",
        locator: "p. 5"
    )
    private let authorityOne = MotionAuthorityEvidence(
        authorityID: "authority-1",
        citation: "Example v. Fictional, 123 So. 3d 456 (Fla. 1st DCA 2020)",
        reviewedExcerpt: "A complaint must plead ultimate facts supporting each element.",
        groundKey: "mtd.failureToStateClaim"
    )
    private let authorityTwo = MotionAuthorityEvidence(
        authorityID: "authority-2",
        citation: "Sample v. Placeholder, 789 So. 3d 101 (Fla. 2d DCA 2021)",
        reviewedExcerpt: "Conclusory allegations do not satisfy the pleading requirement.",
        groundKey: "mtd.failureToStateClaim"
    )

    private var evidence: MotionVerificationEvidence {
        MotionVerificationEvidence(
            facts: [factOne, factTwo],
            authorities: [authorityOne, authorityTwo]
        )
    }

    // MVS-02. Expected RED: runMotion has no evidence input and whole-document verification
    // emits no proposition support for the selected facts or reviewed authorities.
    func testValidMotionEmitsSupportedEvidenceForEverySelectedSource() async throws {
        let renderer = MotionCountingRenderer(identity: .init(id: "test.motion-renderer", version: "17"))
        let pipeline = DraftPipeline(verifier: DraftVerifier(), renderer: renderer)

        let result = try await pipeline.runMotion(model: validModel(), evidence: evidence, style: .defaultFL)

        XCTAssertEqual(renderer.renderCount, 1)
        XCTAssertEqual(result.propositionSupport.map(\.propositionID), [
            "motion.fact.fact-1",
            "motion.fact.fact-2",
            "motion.authority.authority-1",
            "motion.authority.authority-2"
        ])
        XCTAssertEqual(result.propositionSupport.map(\.status), Array(repeating: .supported, count: 4))
        XCTAssertEqual(result.propositionSupport.map { $0.evidence.first?.retainedExcerpt }, [
            factOne.text,
            factTwo.text,
            authorityOne.reviewedExcerpt,
            authorityTwo.reviewedExcerpt
        ])
        XCTAssertEqual(result.verificationReceipt.status, .passed)
        XCTAssertEqual(result.verificationReceipt.supportedPropositionIDs,
                       result.propositionSupport.map(\.propositionID))
    }

    // MVS-03. Expected RED: reordered, changed, or missing numbered facts pass the old
    // caption/signature/certificate-only verifier and reach the renderer.
    func testFactMismatchNeverReachesRenderer() async {
        let fixtures: [[String]] = [
            [factTwo.text, factOne.text],
            [factOne.text + " Materially changed.", factTwo.text],
            [factOne.text]
        ]

        for numberedFacts in fixtures {
            await assertBlocked(model: validModel(numberedFacts: numberedFacts), evidence: evidence)
        }
    }

    // MVS-04. Expected RED: changed/reordered reviewed paragraphs and an unknown citation
    // pass whole-document verification and render.
    func testAuthorityMismatchAndUnknownCitationNeverReachRenderer() async {
        let unknown = "Unknown v. Invented, 999 So. 3d 999 (Fla. 5th DCA 2022): An invented rule."
        let fixtures = [
            [authorityTwo.canonicalParagraph, authorityOne.canonicalParagraph],
            [authorityOne.canonicalParagraph + " Changed.", authorityTwo.canonicalParagraph],
            [authorityOne.canonicalParagraph, authorityTwo.canonicalParagraph, unknown]
        ]

        for paragraphs in fixtures {
            await assertBlocked(model: validModel(authorityParagraphs: paragraphs), evidence: evidence)
        }
    }

    // MVS-05. Expected RED: placeholders are not inspected by whole-document verification.
    func testMotionPlaceholdersNeverReachRenderer() async {
        for placeholder in ["[cite]", "[fact?]"] {
            await assertBlocked(
                model: validModel(introduction: "Defendant moves to dismiss. \(placeholder)"),
                evidence: evidence
            )
        }
    }

    // MVS-06. Expected RED: the pipeline accepts a clean verifier result with no complete
    // support coverage and invokes the renderer.
    func testIncompleteVerifierCoverageNeverReachesRenderer() async {
        let renderer = MotionCountingRenderer(identity: .init(id: "test.coverage-renderer", version: "23"))
        let pipeline = DraftPipeline(verifier: EmptySupportVerifier(), renderer: renderer)

        do {
            _ = try await pipeline.runMotion(model: validModel(), evidence: evidence, style: .defaultFL)
            XCTFail("missing fact and authority support coverage must block")
        } catch let error as DraftError {
            guard case .verificationBlocked = error else {
                return XCTFail("expected verificationBlocked, got \(error)")
            }
        } catch {
            XCTFail("expected DraftError.verificationBlocked, got \(error)")
        }
        XCTAssertEqual(renderer.renderCount, 0)
    }

    // MVS-06b. Expected RED: an empty required-ID list is treated as the generic no-coverage
    // case, so a clean injected verifier can render a motion with no facts or authorities.
    func testEmptyMotionEvidenceWithCleanVerifierNeverReachesRenderer() async {
        let renderer = MotionCountingRenderer(identity: .init(id: "test.empty-evidence-renderer", version: "29"))
        let pipeline = DraftPipeline(verifier: EmptySupportVerifier(), renderer: renderer)

        do {
            _ = try await pipeline.runMotion(
                model: validModel(),
                evidence: MotionVerificationEvidence(facts: [], authorities: []),
                style: .defaultFL
            )
            XCTFail("a motion with no selected evidence must block")
        } catch let error as DraftError {
            guard case .verificationBlocked = error else {
                return XCTFail("expected verificationBlocked, got \(error)")
            }
        } catch {
            XCTFail("expected DraftError.verificationBlocked, got \(error)")
        }
        XCTAssertEqual(renderer.renderCount, 0)
    }

    // MVS-07. Expected RED: DraftResult has no passed receipt or actual component identities,
    // and the ground/assembler owners publish no identity.
    func testReceiptAndContractOwnersExposeActualIdentities() async throws {
        let verifier = CompleteSupportVerifier(identity: .init(id: "test.verifier.nondefault", version: "31"))
        let renderer = MotionCountingRenderer(identity: .init(id: "test.renderer.nondefault", version: "47"))
        let pipeline = DraftPipeline(verifier: verifier, renderer: renderer)

        let result = try await pipeline.runMotion(model: validModel(), evidence: evidence, style: .defaultFL)

        XCTAssertEqual(result.verificationReceipt.verifierIdentity, verifier.identity)
        XCTAssertEqual(result.verificationReceipt.gateIdentity, PreFileGate.identity)
        XCTAssertEqual(result.verificationReceipt.rendererIdentity, renderer.identity)
        XCTAssertEqual(MotionGroundSpec.contractIdentity,
                       DraftComponentIdentity(id: "supra.drafting.motion-ground-contract", version: "3"))
        XCTAssertEqual(MotionToDismiss.assemblerIdentity,
                       DraftComponentIdentity(id: "supra.drafting.motion-to-dismiss-assembler", version: "2"))
    }

    // MVS-08. Expected RED: exact paragraph matching currently accepts an arbitrary
    // nonblank ground key and an arbitrary non-Florida citation string.
    func testUnsupportedGroundAndNonFloridaCitationNeverReachRenderer() async {
        let unsupportedGround = MotionAuthorityEvidence(
            authorityID: "authority-wrong-ground",
            citation: authorityOne.citation,
            reviewedExcerpt: authorityOne.reviewedExcerpt,
            groundKey: "mtd.unsupportedGround"
        )
        let nonFloridaCitation = MotionAuthorityEvidence(
            authorityID: "authority-wrong-court",
            citation: "Example v. Fictional, 123 P.3d 456 (Cal. Ct. App. 2020)",
            reviewedExcerpt: authorityOne.reviewedExcerpt,
            groundKey: "mtd.failureToStateClaim"
        )

        for authority in [unsupportedGround, nonFloridaCitation] {
            let scopedEvidence = MotionVerificationEvidence(
                facts: [factOne],
                authorities: [authority]
            )
            await assertBlocked(
                model: validModel(
                    numberedFacts: [factOne.text],
                    authorityParagraphs: [authority.canonicalParagraph]
                ),
                evidence: scopedEvidence
            )
        }
    }

    // MVS-09. Expected RED: runMotion does not inspect cancellation after its
    // verifier await, so a verifier that returns nominal support while cancellation
    // is pending still reaches the synchronous gate and renderer.
    func testCancellationAfterMotionVerifierNeverReachesRenderer() async {
        let renderer = MotionCountingRenderer(
            identity: .init(id: "test.cancelled-motion-renderer", version: "1")
        )
        let verifier = CancellingCompleteSupportVerifier()
        let pipeline = DraftPipeline(verifier: verifier, renderer: renderer)
        let model = validModel()
        let scopedEvidence = evidence

        let task = Task {
            try await pipeline.runMotion(model: model, evidence: scopedEvidence, style: .defaultFL)
        }
        do {
            _ = try await task.value
            XCTFail("cancelled motion verification unexpectedly reached rendering")
        } catch is CancellationError {
            // Expected at the verifier-to-gate boundary.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(renderer.renderCount, 0)
    }

    // MVS-10. Expected RED: the current substring heuristic treats a Florida party name
    // or a federal Florida parenthetical as proof of Florida state authority, so these
    // federal and wrong-state citations reach the renderer.
    func testFederalAndPartyNameCitationFalsePositivesNeverReachRenderer() async {
        let unsupportedCitations = [
            "Florida Supply Corp. v. Example Holdings, 123 F. Supp. 3d 456 (S.D.N.Y. 2020)",
            "Example Holdings v. Fictional Supply, 456 F. Supp. 3d 789 (M.D. Fla. 2021)",
            "Florida Supply Corp. v. Example Holdings, 321 So. 3d 654 (Ga. Ct. App. 2022)",
        ]

        for (index, citation) in unsupportedCitations.enumerated() {
            let authority = MotionAuthorityEvidence(
                authorityID: "authority-false-positive-\(index)",
                citation: citation,
                reviewedExcerpt: authorityOne.reviewedExcerpt,
                groundKey: MotionGroundSpec.failureToStateClaim.key
            )
            let scopedEvidence = MotionVerificationEvidence(
                facts: [factOne],
                authorities: [authority]
            )
            await assertBlocked(
                model: validModel(
                    numberedFacts: [factOne.text],
                    authorityParagraphs: [authority.canonicalParagraph]
                ),
                evidence: scopedEvidence
            )
        }
    }

    // Standing guard: tightening the citation parser must preserve the two supported
    // Florida state forms used by this first vertical: Southern Reporter and Weekly.
    func testFloridaStateReporterCitationFormsRemainSupported() async throws {
        let supportedCitations = [
            "Example v. Fictional, 123 So. 3d 456 (Fla. 2020)",
            "Sample v. Placeholder, 49 Fla. L. Weekly D1234 (Fla. 4th DCA 2024)",
        ]

        for (index, citation) in supportedCitations.enumerated() {
            let authority = MotionAuthorityEvidence(
                authorityID: "authority-state-supported-\(index)",
                citation: citation,
                reviewedExcerpt: authorityOne.reviewedExcerpt,
                groundKey: MotionGroundSpec.failureToStateClaim.key
            )
            let scopedEvidence = MotionVerificationEvidence(facts: [factOne], authorities: [authority])
            let renderer = MotionCountingRenderer(
                identity: .init(id: "test.state-citation-renderer-\(index)", version: "1")
            )

            _ = try await DraftPipeline(verifier: DraftVerifier(), renderer: renderer).runMotion(
                model: validModel(
                    numberedFacts: [factOne.text],
                    authorityParagraphs: [authority.canonicalParagraph]
                ),
                evidence: scopedEvidence,
                style: .defaultFL
            )

            XCTAssertEqual(renderer.renderCount, 1)
        }
    }

    // MVS-11. Expected RED: exact facts may appear only in the statement of facts;
    // the verifier does not require the argument to apply the reviewed pleading
    // standards to each selected excerpt.
    func testFactApplicationMustBeExactCompleteOrderedAndAfterAuthorities() async {
        let expected = canonicalApplicationParagraphs
        let fixtures = [
            validModel(applicationParagraphs: []),
            validModel(applicationParagraphs: [expected[0] + " Changed.", expected[1]]),
            validModel(applicationParagraphs: Array(expected.reversed())),
        ]

        for model in fixtures {
            await assertBlocked(model: model, evidence: evidence)
        }
    }

    // MVS-12. Expected RED: uncited prose and headings outside the supported
    // one-ground body shape are not citation-shaped, so the old verifier lets
    // them reach the renderer without any selected-source binding.
    func testUncitedProseAndStructuralMutationNeverReachRenderer() async {
        var extraParagraph = validModel()
        extraParagraph.body.insert(
            .paragraph("The fictional pleading admits every element of the claim."),
            at: 1
        )
        var extraHeading = validModel()
        extraHeading.body.insert(.sectionHeading("ADDITIONAL ARGUMENT"), at: 4)

        for model in [extraParagraph, extraHeading] {
            await assertBlocked(model: model, evidence: evidence)
        }
    }

    private func validModel(
        numberedFacts: [String]? = nil,
        authorityParagraphs: [String]? = nil,
        applicationParagraphs: [String]? = nil,
        introduction: String = "Defendant moves to dismiss the fictional complaint."
    ) -> DocumentModel {
        MotionToDismiss.assemble(
            caption: CaptionModel(
                courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR FICTIONAL COUNTY, FLORIDA",
                parties: [
                    PartyLine(name: "ALPHA LLC,", designation: "Plaintiff,"),
                    PartyLine(name: "BETA LLC,", designation: "Defendant.")
                ],
                caseNumber: "2026-CA-000001",
                division: "CV-A",
                judge: nil
            ),
            title: "DEFENDANT'S MOTION TO DISMISS",
            introduction: [.paragraph(introduction)],
            numberedFacts: numberedFacts ?? evidence.facts.map(\.text),
            argumentPoints: [MotionToDismiss.ArgumentPoint(
                heading: "THE FICTIONAL COMPLAINT FAILS TO STATE A CLAIM.",
                body: (
                    (authorityParagraphs ?? evidence.authorities.map(\.canonicalParagraph))
                        + (applicationParagraphs ?? canonicalApplicationParagraphs)
                ).map(BodyBlock.paragraph)
            )],
            conclusion: "WHEREFORE, Defendant requests dismissal.",
            signature: signature,
            certificate: certificate
        )
    }

    private var canonicalApplicationParagraphs: [String] {
        evidence.facts.enumerated().map { index, fact in
            "Applying the reviewed pleading standards to selected fact \(index + 1) (“\(fact.text)”), the moving party submits that the excerpt does not plead the ultimate facts necessary to state a legally sufficient claim."
        }
    }

    private func assertBlocked(model: DocumentModel, evidence: MotionVerificationEvidence) async {
        let renderer = MotionCountingRenderer(identity: .init(id: "test.blocked-renderer", version: "5"))
        let pipeline = DraftPipeline(verifier: DraftVerifier(), renderer: renderer)
        do {
            _ = try await pipeline.runMotion(model: model, evidence: evidence, style: .defaultFL)
            XCTFail("unsafe motion reached the renderer")
        } catch let error as DraftError {
            guard case .verificationBlocked = error else {
                return XCTFail("expected verificationBlocked, got \(error)")
            }
        } catch {
            XCTFail("expected DraftError.verificationBlocked, got \(error)")
        }
        XCTAssertEqual(renderer.renderCount, 0)
    }

    private var signature: SignatureBlockModel {
        SignatureBlockModel(
            respectfullySubmitted: DateOnly(year: 2026, month: 8, day: 3),
            firmName: "Fictional Law",
            signingAttorney: "Avery Example",
            attorneys: [AttorneyLine(name: "Avery Example", barNumber: "Florida Bar No. 123456")],
            office: OfficeBlock(street: "1 Example Street", suite: nil, city: "Jacksonville", state: "Florida", zip: "32202", phone: "904-555-0100", fax: nil),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "avery@example.invalid", secondary: [])
        )
    }

    private var certificate: CertificateModel {
        CertificateModel(
            date: DateOnly(year: 2026, month: 8, day: 3),
            clause: .flEPortal,
            documentTitle: "MOTION TO DISMISS",
            recipients: [ServiceRecipient(
                name: "Casey Fictional, Esq.",
                firm: "Fictional Counsel",
                address: OfficeBlock(street: "2 Example Street", suite: nil, city: "Jacksonville", state: "Florida", zip: "32202", phone: "904-555-0101", fax: nil),
                emails: ["casey@example.invalid"],
                role: "Counsel for Plaintiff"
            )],
            signOffAttorney: "Avery Example"
        )
    }
}

private struct EmptySupportVerifier: Verifier {
    let identity = DraftComponentIdentity(id: "test.empty-support-verifier", version: "1")

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        VerificationResult(failures: [], followUps: [], propositionSupport: [])
    }
}

private struct CompleteSupportVerifier: Verifier {
    let identity: DraftComponentIdentity

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        guard case let .motion(_, evidence) = unit else {
            return VerificationResult(
                failures: [GateFailure(gate: .contract, detail: "wrong unit", repair: .deterministicFix)],
                followUps: []
            )
        }
        let support = (evidence.facts.map { ("motion.fact.\($0.factID)", $0.sourceID, $0.factID, $0.locator, $0.text) }
            + evidence.authorities.map { ("motion.authority.\($0.authorityID)", $0.authorityID, $0.citation, $0.groundKey, $0.reviewedExcerpt) })
            .compactMap { propositionID, sourceID, label, locator, excerpt in
                try? PropositionSupportResult(
                    propositionID: propositionID,
                    status: .supported,
                    reasons: ["test support"],
                    evidence: [SupportEvidence(
                        sourceID: sourceID,
                        sourceLabel: label,
                        locator: locator,
                        retainedExcerpt: excerpt,
                        verifierName: identity.id,
                        verifierVersion: identity.version
                    )],
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
        return VerificationResult(failures: [], followUps: [], propositionSupport: support)
    }
}

private struct CancellingCompleteSupportVerifier: Verifier {
    let identity = DraftComponentIdentity(id: "test.cancelling-complete-verifier", version: "1")

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        let result = await CompleteSupportVerifier(identity: identity)
            .verify(unit, kind: kind, style: style)
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return result
    }
}

private final class MotionCountingRenderer: Renderer, @unchecked Sendable {
    let identity: DraftComponentIdentity
    private(set) var renderCount = 0

    init(identity: DraftComponentIdentity) {
        self.identity = identity
    }

    func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        renderCount += 1
        return Data("motion-rendered".utf8)
    }
}
