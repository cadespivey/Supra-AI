import Foundation
import SupraResearch
import XCTest

final class ArchitectureUXTEgress03Tests: XCTestCase {
    private let fixture = ArchitectureUXEgressFixture()
    private let issuedAt = Date(timeIntervalSince1970: 731_000)

    /// T-EGRESS-03-WIRE expected RED: `LegalQueryEgressGate` and its exact
    /// provider/origin/query/purpose/session/source-set grant do not exist, so
    /// CourtListener can currently be called without this authorization boundary.
    func testExactGrantCarriesEveryNonDefaultBindingAndTransmitsDisplayedBytesOnce() async throws {
        let (gate, recorder, clock) = makeGate()
        let intent = fixture.intent()
        let preview = try await gate.preview(for: intent)

        XCTAssertEqual(preview.displayedQuery, fixture.query)
        XCTAssertEqual(preview.queryBytes, Data(fixture.query.utf8))
        XCTAssertEqual(preview.providerID, fixture.providerID)
        XCTAssertEqual(preview.origin, .formalResearch)
        XCTAssertEqual(preview.purpose, fixture.purpose)
        XCTAssertEqual(preview.matterID, fixture.matterID)
        XCTAssertEqual(preview.researchSessionID, fixture.sessionID)
        XCTAssertEqual(preview.sourceSetDigest, fixture.sourceSetDigest)
        XCTAssertEqual(preview.classification, .matterDerived)
        XCTAssertFalse(preview.displayedQuery.contains("DEFAULT-000"))

        let grant = try await gate.approve(
            preview: preview,
            approvedAt: clock.now(),
            expiresAt: clock.now().addingTimeInterval(30)
        )
        XCTAssertEqual(grant.version, fixture.grantVersion)

        _ = try await gate.searchOpinions(
            fixture.request(),
            intent: intent,
            authorization: .grant(grant),
            relatedResearchSessionID: fixture.sessionID
        )

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try XCTUnwrap(calls.first).request.query, preview.displayedQuery)
        XCTAssertEqual(try XCTUnwrap(calls.first).relatedResearchSessionID, fixture.sessionID)
    }

    /// T-EGRESS-03-PROVIDER expected RED: no provider-bound grant is checked at
    /// the `CourtListenerClientProtocol` execution boundary today.
    func testProviderMismatchMakesZeroTransportCalls() async throws {
        await assertBindingMismatch(
            changed: fixture.intent(providerID: fixture.mismatchedProviderID),
            field: .provider
        )
    }

    /// T-EGRESS-03-ORIGIN expected RED: the current provider call has no typed
    /// workflow-origin binding, so a formal-Research approval could be replayed by quick research.
    func testOriginMismatchMakesZeroTransportCalls() async throws {
        await assertBindingMismatch(
            changed: fixture.intent(origin: .quickResearch),
            field: .origin
        )
    }

    /// T-EGRESS-03-QUERY expected RED: displayed UTF-8 bytes are not bound to the
    /// actual `CourtListenerSearchRequest.query` at the transport call.
    func testAlteredQueryBytesMakeZeroTransportCalls() async throws {
        let (gate, recorder, clock) = makeGate()
        let intent = fixture.intent()
        let grant = try await approvedGrant(gate: gate, intent: intent, clock: clock)

        await assertEgressError(.bindingMismatch(.query)) {
            _ = try await gate.searchOpinions(
                fixture.request(query: fixture.alteredQuery),
                intent: intent,
                authorization: .grant(grant),
                relatedResearchSessionID: fixture.sessionID
            )
        }

        let calls = await recorder.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// Citation resolution is a provider query too. Its canonical cleaned bytes
    /// must equal the public-citation intent before the POST can occur.
    func testAlteredCitationLookupBytesMakeZeroTransportCalls() async throws {
        let (gate, recorder, _) = makeGate()
        let intent = fixture.intent(
            query: "516 U.S. 349",
            classification: .publicCitation
        )

        await assertEgressError(.bindingMismatch(.query)) {
            _ = try await gate.resolveCitations(
                [" 410 U.S. 113 "],
                intent: intent,
                authorization: .automaticPublicCitation
            )
        }

        let calls = await recorder.recordedCitationCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// T-EGRESS-03-PURPOSE expected RED: the current provider call accepts no
    /// task purpose, so approval for one legal action is not narrowly reusable.
    func testPurposeMismatchMakesZeroTransportCalls() async throws {
        await assertBindingMismatch(
            changed: fixture.intent(purpose: fixture.mismatchedPurpose),
            field: .purpose
        )
    }

    /// T-EGRESS-03-MATTER expected RED: the initiating matter is not part of a
    /// transport authorization today, so a grant cannot reject cross-matter reuse.
    func testMatterMismatchMakesZeroTransportCalls() async throws {
        await assertBindingMismatch(
            changed: fixture.intent(matterID: fixture.mismatchedMatterID),
            field: .matter
        )
    }

    /// T-EGRESS-03-SESSION expected RED: the operational logging session ID is
    /// not authorization and is not checked against an exact grant.
    func testResearchSessionMismatchMakesZeroTransportCalls() async throws {
        await assertBindingMismatch(
            changed: fixture.intent(sessionID: fixture.mismatchedSessionID),
            field: .researchSession
        )
    }

    /// T-EGRESS-03-SOURCE expected RED: no grant currently binds the exact local
    /// source-set digest that gave rise to a provider query.
    func testSourceSetMismatchMakesZeroTransportCalls() async throws {
        await assertBindingMismatch(
            changed: fixture.intent(sourceSetDigest: fixture.mismatchedSourceSetDigest),
            field: .sourceSetDigest
        )
    }

    /// T-EGRESS-03-REPLAY expected RED: provider calls carry no single-use token,
    /// so the same owner approval can currently authorize more than one transport effect.
    func testConsumedGrantCannotReplayAndSecondAttemptMakesNoTransportCall() async throws {
        let (gate, recorder, clock) = makeGate()
        let intent = fixture.intent()
        let grant = try await approvedGrant(gate: gate, intent: intent, clock: clock)

        _ = try await gate.searchOpinions(
            fixture.request(),
            intent: intent,
            authorization: .grant(grant),
            relatedResearchSessionID: fixture.sessionID
        )
        var calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)

        await assertEgressError(.grantReplayed) {
            _ = try await gate.searchOpinions(
                fixture.request(),
                intent: intent,
                authorization: .grant(grant),
                relatedResearchSessionID: fixture.sessionID
            )
        }
        calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    /// T-EGRESS-03-EXPIRY expected RED: CourtListener execution currently has no
    /// grant clock, so an expired preview approval cannot be rejected before transport.
    func testExpiredGrantMakesZeroTransportCalls() async throws {
        let (gate, recorder, clock) = makeGate()
        let intent = fixture.intent()
        let grant = try await gate.approve(
            preview: try await gate.preview(for: intent),
            approvedAt: clock.now(),
            expiresAt: clock.now().addingTimeInterval(30)
        )
        clock.advance(by: 31)

        await assertEgressError(.grantExpired) {
            _ = try await gate.searchOpinions(
                fixture.request(),
                intent: intent,
                authorization: .grant(grant),
                relatedResearchSessionID: fixture.sessionID
            )
        }

        let calls = await recorder.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// T-EGRESS-03-WIRING expected RED: formal Research and quick/legal chat both
    /// still invoke the raw CourtListener search protocol. The complete gate must
    /// sit on those actual call paths, not exist as an unused policy helper.
    func testFormalAndQuickResearchUseOneGateWithNoRawSearchBypass() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraSessionsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraSessions
            .appendingPathComponent("Sources/SupraSessions")
        let formal = try String(
            contentsOf: sourceRoot.appendingPathComponent("ResearchSessionController.swift"),
            encoding: .utf8
        )
        let quick = try String(
            contentsOf: sourceRoot.appendingPathComponent("GlobalChatController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(formal.contains("legalQueryEgressGate.searchOpinions("))
        XCTAssertTrue(quick.contains("legalQueryEgressGate.searchOpinions("))
        XCTAssertTrue(quick.contains("legalQueryEgressGate.searchDockets("))
        XCTAssertFalse(formal.contains("courtListenerClient.searchOpinions("))
        XCTAssertFalse(quick.contains("courtListenerClient.searchOpinions("))
        XCTAssertFalse(quick.contains("courtListenerClient.searchDockets("))
    }

    private func assertBindingMismatch(
        changed: LegalQueryEgressIntent,
        field: LegalQueryEgressBindingField,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let (gate, recorder, clock) = makeGate()
        do {
            let grant = try await approvedGrant(gate: gate, intent: fixture.intent(), clock: clock)
            await assertEgressError(.bindingMismatch(field), file: file, line: line) {
                _ = try await gate.searchOpinions(
                    fixture.request(query: String(decoding: changed.queryBytes, as: UTF8.self)),
                    intent: changed,
                    authorization: .grant(grant),
                    relatedResearchSessionID: changed.researchSessionID
                )
            }
        } catch {
            XCTFail("Fixture approval failed before mismatch check: \(error)", file: file, line: line)
        }
        let calls = await recorder.recordedCalls()
        XCTAssertTrue(calls.isEmpty, file: file, line: line)
    }

    private func approvedGrant(
        gate: LegalQueryEgressGate,
        intent: LegalQueryEgressIntent,
        clock: ArchitectureUXEgressClock
    ) async throws -> LegalQueryEgressGrant {
        let preview = try await gate.preview(for: intent)
        return try await gate.approve(
            preview: preview,
            approvedAt: clock.now(),
            expiresAt: clock.now().addingTimeInterval(30)
        )
    }

    private func makeGate() -> (
        gate: LegalQueryEgressGate,
        recorder: ArchitectureUXEgressCourtListenerRecorder,
        clock: ArchitectureUXEgressClock
    ) {
        let clock = ArchitectureUXEgressClock(issuedAt)
        let recorder = ArchitectureUXEgressCourtListenerRecorder()
        let gate = LegalQueryEgressGate(
            providerID: fixture.providerID,
            courtListenerClient: recorder,
            grantVersion: fixture.grantVersion,
            now: { clock.now() }
        )
        return (gate, recorder, clock)
    }
}
