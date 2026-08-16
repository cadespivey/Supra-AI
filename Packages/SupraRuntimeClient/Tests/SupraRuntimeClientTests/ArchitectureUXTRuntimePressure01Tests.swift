@testable import SupraRuntimeClient
import XCTest

/// T-RUNTIME-PRESSURE-01
///
/// Expected RED before WP-3.4: warning/critical pressure has no typed admission
/// or deterministic purge/cancel/eviction policy at the runtime owner.
final class ArchitectureUXTRuntimePressure01Tests: XCTestCase {
    func testWarningPurgesCachesAndBlocksOnlyNonessentialAdmission() throws {
        let snapshot = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 1_200,
            residents: [ArchitectureUXRuntimeResidencyWire.chatArtifact],
            pressure: .warning
        )
        let policy = RuntimeResidencyPolicy(maximumActions: 7)
        let plan = try policy.pressurePlan(
            snapshot: snapshot,
            queuedWork: [
                RuntimeQueuedResidencyWork(id: "foreground-713", workClass: .foreground),
                RuntimeQueuedResidencyWork(id: "background-719", workClass: .background),
                RuntimeQueuedResidencyWork(id: "speculative-727", workClass: .speculative),
            ]
        )

        XCTAssertEqual(plan.level, .warning)
        XCTAssertEqual(plan.actions, [.purgeDerivedCaches(bytes: 17)])
        XCTAssertEqual(plan.deniedWorkClasses, [.background, .speculative])
        XCTAssertFalse(plan.deniedWorkClasses.contains(.foreground))
        XCTAssertFalse(plan.actions.contains { action in
            if case .cancelQueuedWork = action { return true }
            return false
        })
        XCTAssertFalse(String(describing: plan).contains("DEFAULT-000"))
    }

    func testCriticalCancelsBackgroundThenPurgesAndEvictsInactiveEmbeddingFirst() async throws {
        let inactiveChat = RuntimeResidentArtifact(
            modelID: "chat-inactive-733",
            revision: "chat-rev-7",
            kind: .chat,
            estimatedBytes: 211,
            isActive: false,
            lastUseSequence: 5
        )
        let snapshot = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 1_200,
            residents: [
                inactiveChat,
                ArchitectureUXRuntimeResidencyWire.embeddingArtifact,
            ],
            pressure: .critical
        )
        let controlPlane = ArchitectureUXRuntimeResidencyControlPlane(snapshot: snapshot)
        let coordinator = RuntimeResidencyCoordinator(
            controlPlane: controlPlane,
            policy: RuntimeResidencyPolicy(maximumActions: 7)
        )
        let plan = try await coordinator.handlePressure(
            queuedWork: [
                RuntimeQueuedResidencyWork(id: "foreground-713", workClass: .foreground),
                RuntimeQueuedResidencyWork(id: "background-719", workClass: .background),
                RuntimeQueuedResidencyWork(id: "speculative-727", workClass: .speculative),
            ]
        )

        XCTAssertEqual(plan.actions, [
            .cancelQueuedWork(ids: ["background-719", "speculative-727"]),
            .purgeDerivedCaches(bytes: 17),
            .evictEmbeddingModel(id: "embedding-wire-719", revision: "embed-rev-7"),
            .evictChatModel(id: "chat-inactive-733", revision: "chat-rev-7"),
        ])
        let appliedActions = await controlPlane.actions()
        XCTAssertEqual(appliedActions, plan.actions)
        XCTAssertFalse(plan.actions.description.contains("foreground-713"))
        XCTAssertLessThanOrEqual(plan.actions.count, 7)
    }

    func testNPlusOneActionsFailClosedInsteadOfTruncatingPolicy() throws {
        let residents = (0..<8).map { index in
            RuntimeResidentArtifact(
                modelID: "embedding-pressure-\(index)",
                revision: "pressure-rev-7",
                kind: .embedding,
                estimatedBytes: 7,
                isActive: false,
                lastUseSequence: UInt64(index)
            )
        }
        let snapshot = ArchitectureUXRuntimeResidencyWire.snapshot(
            ceiling: 1_200,
            residents: residents,
            pressure: .critical
        )

        XCTAssertThrowsError(
            try RuntimeResidencyPolicy(maximumActions: 7).pressurePlan(
                snapshot: snapshot,
                queuedWork: []
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeResidencyError,
                .actionLimitExceeded(limit: 7, actual: 9)
            )
        }
    }
}
