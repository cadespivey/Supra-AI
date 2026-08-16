import Foundation
import SupraResearch
import XCTest

final class ArchitectureUXTEgress04Tests: XCTestCase {
    private let fixture = ArchitectureUXEgressFixture()
    private let now = Date(timeIntervalSince1970: 743_000)

    /// T-EGRESS-04-AUTO expected RED: the provider boundary has no typed query
    /// classification, so `unknown` cannot fail closed before an automatic call.
    func testUnknownClassificationCannotUseAutomaticPublicCitationAuthority() async throws {
        let (gate, recorder) = makeGate()
        let intent = fixture.intent(classification: .unknown)

        await assertEgressError(.unknownClassification) {
            _ = try await gate.searchOpinions(
                fixture.request(),
                intent: intent,
                authorization: .automaticPublicCitation,
                relatedResearchSessionID: fixture.sessionID
            )
        }

        let calls = await recorder.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// T-EGRESS-04-NONE expected RED: a caller can currently invoke the provider
    /// without either a conclusive public-citation classification or an exact grant.
    func testUnknownClassificationWithoutApprovalMakesZeroTransportCalls() async throws {
        let (gate, recorder) = makeGate()
        let intent = fixture.intent(classification: .unknown)

        await assertEgressError(.approvalRequired) {
            _ = try await gate.searchOpinions(
                fixture.request(),
                intent: intent,
                authorization: .none,
                relatedResearchSessionID: fixture.sessionID
            )
        }

        let calls = await recorder.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// T-EGRESS-04-APPROVED expected RED: D-16 permits an unknown query only
    /// after the owner approves its exact provider-bound preview; that positive
    /// path does not exist yet. This guards against implementing "unknown" as an
    /// unconditional allow or an unconditional dead end.
    func testUnknownClassificationMayExecuteOnlyWithItsOwnExactPreviewGrant() async throws {
        let (gate, recorder) = makeGate()
        let intent = fixture.intent(classification: .unknown)
        let preview = try await gate.preview(for: intent)
        XCTAssertEqual(preview.displayedQuery, fixture.query)
        XCTAssertEqual(preview.classification, .unknown)

        let grant = try await gate.approve(
            preview: preview,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )
        _ = try await gate.searchOpinions(
            fixture.request(),
            intent: intent,
            authorization: .grant(grant),
            relatedResearchSessionID: fixture.sessionID
        )

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    private func makeGate() -> (
        gate: LegalQueryEgressGate,
        recorder: ArchitectureUXEgressCourtListenerRecorder
    ) {
        let recorder = ArchitectureUXEgressCourtListenerRecorder()
        let timestamp = now
        let gate = LegalQueryEgressGate(
            providerID: fixture.providerID,
            courtListenerClient: recorder,
            grantVersion: fixture.grantVersion,
            now: { timestamp }
        )
        return (gate, recorder)
    }
}
