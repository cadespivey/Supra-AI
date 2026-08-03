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
                       DraftComponentIdentity(id: "supra.drafting.motion-ground-contract", version: "2"))
        XCTAssertEqual(MotionToDismiss.assemblerIdentity,
                       DraftComponentIdentity(id: "supra.drafting.motion-to-dismiss-assembler", version: "1"))
    }

    private func validModel(
        numberedFacts: [String]? = nil,
        authorityParagraphs: [String]? = nil,
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
                body: (authorityParagraphs ?? evidence.authorities.map(\.canonicalParagraph)).map(BodyBlock.paragraph)
            )],
            conclusion: "WHEREFORE, Defendant requests dismissal.",
            signature: signature,
            certificate: certificate
        )
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
