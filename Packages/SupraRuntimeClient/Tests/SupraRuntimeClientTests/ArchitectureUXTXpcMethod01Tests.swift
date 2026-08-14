import Foundation
@testable import SupraRuntimeClient
import SupraRuntimeInterface
import XCTest

/// T-XPC-METHOD-01
///
/// Expected RED before the method-classification tranche: the XPC/client
/// methods have no exhaustive typed classification, the feature-facing
/// protocol still includes recovery controls, and the transport boundary does
/// not prove which admission policy owns each invocation.
final class ArchitectureUXTXpcMethod01Tests: XCTestCase {
    func testEveryRuntimeMethodHasOneExactClassification() {
        let ordinary: Set<RuntimeMethodID> = [
            .loadChatModel,
            .generate,
            .countTokens,
            .unloadModel,
            .reloadCurrentModel,
            .loadEmbeddingModel,
            .embedTexts,
        ]
        let recovery: Set<RuntimeMethodID> = [
            .restartRuntimeService,
            .runtimeResidencySnapshot,
            .evictRuntimeArtifact,
            .resetRuntime,
            .triggerReservationTerminationProbe,
        ]
        let independent: Set<RuntimeMethodID> = [
            .connect,
            .cancelGeneration,
            .recentEvents,
            .runtimeStatus,
            .runtimeLifecycleDebugStatus,
            .embeddingStatus,
            .receiveGenerationEvent,
        ]

        XCTAssertEqual(
            Set(RuntimeMethodID.allCases),
            ordinary.union(recovery).union(independent)
        )
        XCTAssertTrue(ordinary.isDisjoint(with: recovery))
        XCTAssertTrue(ordinary.isDisjoint(with: independent))
        XCTAssertTrue(recovery.isDisjoint(with: independent))

        for method in ordinary {
            XCTAssertEqual(RuntimeMethodPolicy.classification(for: method), .ordinaryDataPlane)
        }
        for method in recovery {
            XCTAssertEqual(RuntimeMethodPolicy.classification(for: method), .recoveryControlPlane)
        }
        for method in independent {
            XCTAssertEqual(RuntimeMethodPolicy.classification(for: method), .independentlyAdmitted)
        }
    }

    func testTransportProtocolSelectorsExactlyMatchTheClassifiedCatalog() throws {
        let source = try source(
            "Packages/SupraRuntimeInterface/Sources/SupraRuntimeInterface/XPC/RuntimeXPCProtocols.swift"
        )
        let declaredSelectors = Set(
            try functionNames(in: source)
        )
        let classifiedSelectors = Set(
            RuntimeMethodID.allCases.compactMap(\.transportSelector)
        )

        XCTAssertEqual(declaredSelectors, classifiedSelectors)
        XCTAssertEqual(declaredSelectors.count, 17)
        XCTAssertTrue(declaredSelectors.contains("loadChatModel"))
        XCTAssertTrue(declaredSelectors.contains("resetRuntime"))
        XCTAssertTrue(declaredSelectors.contains("receive"))
    }

    func testOrdinaryFeatureSurfaceCannotReachRecoveryControlPlane() throws {
        requireFeatureProtocol(RuntimeClient.self)
        requireRecoveryProtocol(RuntimeClient.self)
        requireFeatureProtocol(RuntimeSafetyClient.self)
        requireRecoveryProtocol(RuntimeSafetyClient.self)

        let clientProtocol = try source(
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClientProtocol.swift"
        )
        let coordinator = try source(
            "Packages/SupraSessions/Sources/SupraSessions/ModelExecutionCoordinator.swift"
        )
        let permit = try source(
            "Packages/SupraSessions/Sources/SupraSessions/ModelExecutionPermit.swift"
        )

        XCTAssertTrue(clientProtocol.contains("public protocol RuntimeFeatureClientProtocol"))
        XCTAssertTrue(clientProtocol.contains("public protocol RuntimeRecoveryClientProtocol"))
        XCTAssertTrue(
            coordinator.contains(
                "public typealias ModelExecutionGateway = RuntimeFeatureClientProtocol"
            )
        )
        XCTAssertTrue(
            permit.contains(
                "public final class ModelExecutionPermit: RuntimeFeatureClientProtocol"
            )
        )
        XCTAssertFalse(permit.contains("func restartRuntimeService("))
        XCTAssertFalse(permit.contains("func runtimeResidencySnapshot("))
        XCTAssertFalse(permit.contains("func evictRuntimeArtifact("))
        XCTAssertFalse(permit.contains("func resetRuntime("))
    }

    func testOrdinaryWireCarriesExactClassificationAndFiniteQueueBoundary() throws {
        let accepted = try RuntimeMethodPolicy.receipt(
            for: .generate,
            context: RuntimeMethodInvocationContext(
                wireID: "T_XPC_METHOD_01_WIRE_731",
                modelArtifactID: "model-wire-713",
                modelRevision: "rev-7",
                queueDepth: 7,
                maximumQueuedTasks: 7,
                priority: "foregroundInteractive"
            )
        )

        XCTAssertEqual(accepted.method, .generate)
        XCTAssertEqual(accepted.classification, .ordinaryDataPlane)
        XCTAssertEqual(accepted.wireID, "T_XPC_METHOD_01_WIRE_731")
        XCTAssertEqual(accepted.modelArtifactID, "model-wire-713")
        XCTAssertEqual(accepted.modelRevision, "rev-7")
        XCTAssertEqual(accepted.queueDepth, 7)
        XCTAssertEqual(accepted.priority, "foregroundInteractive")
        XCTAssertEqual(
            accepted.summary,
            "T_XPC_METHOD_01_WIRE_731|generate|ordinaryDataPlane|model-wire-713|rev-7|7|foregroundInteractive"
        )
        XCTAssertFalse(accepted.summary.contains("DEFAULT-000"))
        XCTAssertFalse(accepted.summary.contains("default priority"))

        XCTAssertThrowsError(
            try RuntimeMethodPolicy.receipt(
                for: .generate,
                context: RuntimeMethodInvocationContext(
                    wireID: "T_XPC_METHOD_01_WIRE_731_N_PLUS_1_8",
                    modelArtifactID: "model-wire-713",
                    modelRevision: "rev-7",
                    queueDepth: 8,
                    maximumQueuedTasks: 7,
                    priority: "foregroundInteractive"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeMethodPolicyError,
                .queueDepthExceeded(limit: 7, actual: 8)
            )
        }
    }

    func testClientMethodsDeclareTheirExpectedBoundaryClassification() throws {
        let client = try source(
            "Packages/SupraRuntimeClient/Sources/SupraRuntimeClient/RuntimeClient.swift"
        )
        let requiredRoutes = [
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .loadChatModel)",
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .generate)",
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .countTokens)",
            "RuntimeMethodPolicy.require(.independentlyAdmitted, for: .cancelGeneration)",
            "RuntimeMethodPolicy.require(.independentlyAdmitted, for: .recentEvents)",
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .unloadModel)",
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .reloadCurrentModel)",
            "RuntimeMethodPolicy.require(.independentlyAdmitted, for: .runtimeStatus)",
            "RuntimeMethodPolicy.require(.recoveryControlPlane, for: .runtimeResidencySnapshot)",
            "RuntimeMethodPolicy.require(.recoveryControlPlane, for: .evictRuntimeArtifact)",
            "RuntimeMethodPolicy.require(.recoveryControlPlane, for: .resetRuntime)",
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .loadEmbeddingModel)",
            "RuntimeMethodPolicy.require(.ordinaryDataPlane, for: .embedTexts)",
            "RuntimeMethodPolicy.require(.independentlyAdmitted, for: .embeddingStatus)",
        ]

        for route in requiredRoutes {
            XCTAssertTrue(client.contains(route), "Missing runtime method route: \(route)")
        }
        XCTAssertFalse(client.contains("DEFAULT-000"))
    }

    private func requireFeatureProtocol<T: RuntimeFeatureClientProtocol>(_: T.Type) {}

    private func requireRecoveryProtocol<T: RuntimeRecoveryClientProtocol>(_: T.Type) {}

    private func functionNames(in source: String) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: #"(?m)^\s*func\s+([A-Za-z][A-Za-z0-9_]*)\s*\("#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[nameRange])
        }
    }

    private func source(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
