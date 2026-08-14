import Foundation
import SupraCore
import SupraResearch
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class ArchitectureUXTEgress05Tests: XCTestCase {
    private let fixture = ArchitectureUXEgressFixture()
    private let sourceBodyCanary = "SOURCE-BODY-CANARY-743"
    private let quickAttachmentCanary = "QUICK-ATTACHMENT-BODY-CANARY-751"
    private let unrelatedDefault = "DEFAULT-BODY-000"
    private let now = Date(timeIntervalSince1970: 751_000)

    /// T-EGRESS-05-SHAPE expected RED: the typed intent does not exist yet. Its
    /// exact shape must carry the approved query and content-free source identity,
    /// never raw document or quick-attachment bodies that a transport layer could append.
    func testEgressIntentCarriesFingerprintButNoRawLocalBodyFields() {
        let labels = Set(
            Mirror(reflecting: fixture.intent()).children.compactMap(\.label)
        )
        XCTAssertEqual(
            labels,
            [
                "providerID", "origin", "queryBytes", "purpose", "matterID",
                "researchSessionID", "sourceSetDigest", "classification",
            ]
        )
        XCTAssertFalse(labels.contains("sourceBody"))
        XCTAssertFalse(labels.contains("quickAttachmentBody"))
    }

    /// T-EGRESS-05-BOUNDARY expected RED: the provider boundary does not yet own
    /// exact preview bytes or a source-set-bound grant. The only bytes it may send
    /// are the query bytes shown to and approved by the owner; a source-set digest
    /// conveys identity, never authority to append local source bodies.
    func testSourceSetGrantTransmitsOnlyExactPreviewBytesAndNoLocalBodyCanaries() async throws {
        let (gate, recorder) = makeGate()
        let intent = fixture.intent()
        let preview = try await gate.preview(for: intent)
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
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.request.query, preview.displayedQuery)
        XCTAssertFalse(call.request.query.contains(sourceBodyCanary))
        XCTAssertFalse(call.request.query.contains(quickAttachmentCanary))
        XCTAssertFalse(call.request.query.contains(unrelatedDefault))
    }

    /// T-EGRESS-05-EXPLICIT expected RED: no positive exact-preview grant path
    /// exists for owner-approved body text. A canary may leave only when it is part
    /// of the exact displayed bytes and the grant is for those same bytes.
    func testBodyCanaryCanTransmitOnlyWhenExactlyPreviewedAndApproved() async throws {
        let (gate, recorder) = makeGate()
        let approvedQuery = "\(fixture.query) \(sourceBodyCanary)"
        let intent = fixture.intent(query: approvedQuery)
        let preview = try await gate.preview(for: intent)

        XCTAssertEqual(preview.displayedQuery, approvedQuery)
        XCTAssertTrue(preview.displayedQuery.contains(sourceBodyCanary))
        XCTAssertFalse(preview.displayedQuery.contains(quickAttachmentCanary))
        XCTAssertFalse(preview.displayedQuery.contains(unrelatedDefault))

        let grant = try await gate.approve(
            preview: preview,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )
        _ = try await gate.searchOpinions(
            fixture.request(query: approvedQuery),
            intent: intent,
            authorization: .grant(grant),
            relatedResearchSessionID: fixture.sessionID
        )

        let calls = await recorder.recordedCalls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.request.query, approvedQuery)
        XCTAssertTrue(call.request.query.contains(sourceBodyCanary))
        XCTAssertFalse(call.request.query.contains(quickAttachmentCanary))
        XCTAssertFalse(call.request.query.contains(unrelatedDefault))
    }

    /// T-EGRESS-05-R0 is a justified standing guard: R0 already classifies a
    /// legal request from the visible user question rather than the attachment-
    /// augmented model prompt. It remains here so the full grant implementation
    /// cannot regress that containment while adding the positive approval path.
    func testQuickAttachmentBodiesNeverJoinAutomaticPublicCitationTransport() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "T_EGRESS_05_WIRE_731")
        let response = CourtListenerSearchResponse(
            count: 1,
            results: [
                CourtListenerSearchResultDTO(
                    absoluteURL: "/opinion/713/synthetic-v-example/",
                    caseName: "Synthetic v. Example",
                    citation: ["516 U.S. 349"],
                    clusterID: 713,
                    court: "Supreme Court of the United States",
                    courtID: "scotus",
                    dateFiled: "1996-02-21",
                    opinions: [CourtListenerOpinionDTO(id: 719, snippet: "Synthetic public holding.")],
                    status: "Published"
                )
            ]
        )
        let recorder = ArchitectureUXEgressCourtListenerRecorder(response: response)
        let runtime = StubRuntimeClient { request in
            let answer = request.prompt.contains("SOURCE PACKET")
                ? "The synthetic authority states the rule [A1]."
                : "planner output must not be needed for a public citation"
            return .events([
                .event(request, 1, .token, token: answer),
                .event(request, 2, .generationCompleted),
            ])
        }
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: runtime,
            scope: .matter(id: matter.id),
            courtListenerClient: recorder
        )
        controller.loadChats()

        await controller.performSend(
            prompt: "What did 516 U.S. 349 hold?",
            attachments: [
                ChatAttachmentContext(
                    id: "quick-attachment-751",
                    name: "synthetic-local-note.txt",
                    text: "\(sourceBodyCanary) \(quickAttachmentCanary) \(unrelatedDefault)"
                )
            ],
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        let query = try XCTUnwrap(calls.first).request.query
        XCTAssertEqual(query, "516 U.S. 349")
        XCTAssertFalse(query.contains(sourceBodyCanary))
        XCTAssertFalse(query.contains(quickAttachmentCanary))
        XCTAssertFalse(query.contains(unrelatedDefault))
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
