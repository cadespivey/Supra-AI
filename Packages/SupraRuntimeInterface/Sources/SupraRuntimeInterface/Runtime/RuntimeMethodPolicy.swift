import Foundation

/// Stable logical identity for every method exposed by the runtime client or
/// its XPC protocols. Client-local lifecycle methods have no transport
/// selector; XPC callbacks use their actual Objective-C selector stem.
public enum RuntimeMethodID: String, CaseIterable, Codable, Hashable, Sendable {
    case connect
    case loadChatModel
    case generate
    case countTokens
    case cancelGeneration
    case recentEvents
    case unloadModel
    case reloadCurrentModel
    case runtimeStatus
    case restartRuntimeService
    case runtimeResidencySnapshot
    case evictRuntimeArtifact
    case resetRuntime
    case runtimeLifecycleDebugStatus
    case triggerReservationTerminationProbe
    case loadEmbeddingModel
    case embedTexts
    case embeddingStatus
    case receiveGenerationEvent

    public var transportSelector: String? {
        switch self {
        case .connect, .restartRuntimeService:
            nil
        case .receiveGenerationEvent:
            "receive"
        default:
            rawValue
        }
    }
}

public enum RuntimeMethodClassification: String, CaseIterable, Codable, Hashable, Sendable {
    case ordinaryDataPlane
    case recoveryControlPlane
    case independentlyAdmitted
}

public struct RuntimeMethodInvocationContext: Equatable, Sendable {
    public let wireID: String
    public let modelArtifactID: String
    public let modelRevision: String
    public let queueDepth: Int
    public let maximumQueuedTasks: Int
    public let priority: String

    public init(
        wireID: String,
        modelArtifactID: String,
        modelRevision: String,
        queueDepth: Int,
        maximumQueuedTasks: Int,
        priority: String
    ) {
        self.wireID = wireID
        self.modelArtifactID = modelArtifactID
        self.modelRevision = modelRevision
        self.queueDepth = queueDepth
        self.maximumQueuedTasks = maximumQueuedTasks
        self.priority = priority
    }
}

public struct RuntimeMethodClassificationReceipt: Equatable, Sendable {
    public let method: RuntimeMethodID
    public let classification: RuntimeMethodClassification
    public let wireID: String
    public let modelArtifactID: String
    public let modelRevision: String
    public let queueDepth: Int
    public let priority: String

    public var summary: String {
        [
            wireID,
            method.rawValue,
            classification.rawValue,
            modelArtifactID,
            modelRevision,
            String(queueDepth),
            priority,
        ].joined(separator: "|")
    }
}

public enum RuntimeMethodPolicyError: Error, Equatable, Sendable {
    case classificationMismatch(
        method: RuntimeMethodID,
        expected: RuntimeMethodClassification,
        actual: RuntimeMethodClassification
    )
    case invalidInvocationContext
    case queueDepthExceeded(limit: Int, actual: Int)
}

/// Exhaustive classification authority for the local runtime boundary.
public enum RuntimeMethodPolicy {
    public static func classification(
        for method: RuntimeMethodID
    ) -> RuntimeMethodClassification {
        switch method {
        case .loadChatModel,
             .generate,
             .countTokens,
             .unloadModel,
             .reloadCurrentModel,
             .loadEmbeddingModel,
             .embedTexts:
            .ordinaryDataPlane

        case .restartRuntimeService,
             .runtimeResidencySnapshot,
             .evictRuntimeArtifact,
             .resetRuntime,
             .triggerReservationTerminationProbe:
            .recoveryControlPlane

        case .connect,
             .cancelGeneration,
             .recentEvents,
             .runtimeStatus,
             .runtimeLifecycleDebugStatus,
             .embeddingStatus,
             .receiveGenerationEvent:
            .independentlyAdmitted
        }
    }

    @discardableResult
    public static func require(
        _ expected: RuntimeMethodClassification,
        for method: RuntimeMethodID
    ) throws -> RuntimeMethodClassification {
        let actual = classification(for: method)
        guard actual == expected else {
            throw RuntimeMethodPolicyError.classificationMismatch(
                method: method,
                expected: expected,
                actual: actual
            )
        }
        return actual
    }

    public static func receipt(
        for method: RuntimeMethodID,
        context: RuntimeMethodInvocationContext
    ) throws -> RuntimeMethodClassificationReceipt {
        guard !context.wireID.isEmpty,
              !context.modelArtifactID.isEmpty,
              !context.modelRevision.isEmpty,
              !context.priority.isEmpty,
              context.queueDepth >= 0,
              context.maximumQueuedTasks > 0 else {
            throw RuntimeMethodPolicyError.invalidInvocationContext
        }
        guard context.queueDepth <= context.maximumQueuedTasks else {
            throw RuntimeMethodPolicyError.queueDepthExceeded(
                limit: context.maximumQueuedTasks,
                actual: context.queueDepth
            )
        }
        return RuntimeMethodClassificationReceipt(
            method: method,
            classification: classification(for: method),
            wireID: context.wireID,
            modelArtifactID: context.modelArtifactID,
            modelRevision: context.modelRevision,
            queueDepth: context.queueDepth,
            priority: context.priority
        )
    }
}
