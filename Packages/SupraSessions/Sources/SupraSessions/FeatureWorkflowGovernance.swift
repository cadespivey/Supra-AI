import Foundation

/// Bounded, typed governance primitives shared by fixed feature workflows.
/// They are deliberately not an agent framework: the feature owns its steps,
/// while this file owns admission, authority, completion, memory, and handoff
/// invariants at each effect boundary.
public enum WorkflowBudgetDimension: String, Codable, CaseIterable, Sendable {
    case modelCalls
    case toolCalls
    case inputTokens
    case outputTokens
    case elapsedMilliseconds
    case retries
    case repetitions
    case egressBytes
    case workingSetBytes
}

public struct ModelTaskBudgetUsage: Codable, Equatable, Sendable {
    public var modelCalls: Int
    public var toolCalls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var elapsedMilliseconds: Int
    public var retries: Int
    public var repetitions: Int
    public var egressBytes: Int
    public var workingSetBytes: Int

    public init(
        modelCalls: Int = 0,
        toolCalls: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        elapsedMilliseconds: Int = 0,
        retries: Int = 0,
        repetitions: Int = 0,
        egressBytes: Int = 0,
        workingSetBytes: Int = 0
    ) {
        self.modelCalls = modelCalls
        self.toolCalls = toolCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.elapsedMilliseconds = elapsedMilliseconds
        self.retries = retries
        self.repetitions = repetitions
        self.egressBytes = egressBytes
        self.workingSetBytes = workingSetBytes
    }

    fileprivate func adding(_ delta: Self) -> Self {
        Self(
            modelCalls: modelCalls + delta.modelCalls,
            toolCalls: toolCalls + delta.toolCalls,
            inputTokens: inputTokens + delta.inputTokens,
            outputTokens: outputTokens + delta.outputTokens,
            elapsedMilliseconds: elapsedMilliseconds + delta.elapsedMilliseconds,
            retries: retries + delta.retries,
            repetitions: repetitions + delta.repetitions,
            egressBytes: egressBytes + delta.egressBytes,
            workingSetBytes: max(workingSetBytes, delta.workingSetBytes)
        )
    }

    fileprivate func value(for dimension: WorkflowBudgetDimension) -> Int {
        switch dimension {
        case .modelCalls: modelCalls
        case .toolCalls: toolCalls
        case .inputTokens: inputTokens
        case .outputTokens: outputTokens
        case .elapsedMilliseconds: elapsedMilliseconds
        case .retries: retries
        case .repetitions: repetitions
        case .egressBytes: egressBytes
        case .workingSetBytes: workingSetBytes
        }
    }
}

public enum WorkflowTerminalReason: Error, Codable, Equatable, Sendable {
    case budgetExceeded(dimension: WorkflowBudgetDimension, limit: Int, attempted: Int)
}

public enum WorkflowBudgetAdmission: Equatable, Sendable {
    case admitted
    case stopped(WorkflowTerminalReason)
}

public struct ModelTaskBudget: Sendable {
    public let taskID: String
    public let limits: ModelTaskBudgetUsage
    public private(set) var usage: ModelTaskBudgetUsage
    public private(set) var terminalReason: WorkflowTerminalReason?

    public init(taskID: String, limits: ModelTaskBudgetUsage) {
        precondition(!taskID.isEmpty)
        precondition(WorkflowBudgetDimension.allCases.allSatisfy { limits.value(for: $0) > 0 })
        self.taskID = taskID
        self.limits = limits
        self.usage = ModelTaskBudgetUsage()
    }

    /// Admission happens before the caller performs a model/tool/file/network
    /// effect. Once terminal, every later request remains stopped.
    public mutating func admit(_ delta: ModelTaskBudgetUsage) -> WorkflowBudgetAdmission {
        if let terminalReason { return .stopped(terminalReason) }
        let attempted = usage.adding(delta)
        for dimension in WorkflowBudgetDimension.allCases {
            let attemptedValue = attempted.value(for: dimension)
            let limit = limits.value(for: dimension)
            guard attemptedValue <= limit else {
                let reason = WorkflowTerminalReason.budgetExceeded(
                    dimension: dimension,
                    limit: limit,
                    attempted: attemptedValue
                )
                terminalReason = reason
                return .stopped(reason)
            }
        }
        usage = attempted
        return .admitted
    }
}

public enum WorkflowToolEffectClass: String, Codable, CaseIterable, Sendable {
    case readLocal
    case writeLocal
    case externalRead
    case externalWrite
    case credential
    case destructive
    case unknown
}

public struct WorkflowToolIntent: Codable, Equatable, Sendable {
    public let taskID: String
    public let matterID: String
    public let toolID: String
    public let effect: WorkflowToolEffectClass
    public let payloadDigest: String
    public let version: Int

    public init(taskID: String, matterID: String, toolID: String, effect: WorkflowToolEffectClass, payloadDigest: String, version: Int) {
        self.taskID = taskID
        self.matterID = matterID
        self.toolID = toolID
        self.effect = effect
        self.payloadDigest = payloadDigest
        self.version = version
    }
}

public struct WorkflowEffectGrant: Codable, Equatable, Sendable {
    public let taskID: String
    public let matterID: String
    public let toolID: String
    public let effect: WorkflowToolEffectClass
    public let payloadDigest: String
    public let version: Int

    public init(matching intent: WorkflowToolIntent) {
        taskID = intent.taskID
        matterID = intent.matterID
        toolID = intent.toolID
        effect = intent.effect
        payloadDigest = intent.payloadDigest
        version = intent.version
    }
}

public enum WorkflowAuthorizationDecision: Equatable, Sendable {
    case allowed
    case denied(reason: String)
}

public enum WorkflowToolAuthorizer {
    public static func authorize(
        _ intent: WorkflowToolIntent,
        grant: WorkflowEffectGrant?,
        advancedEnabled _: Bool = false
    ) -> WorkflowAuthorizationDecision {
        guard intent.effect != .unknown else { return .denied(reason: "unknown_effect") }
        guard let grant else { return .denied(reason: "missing_grant") }
        let matches = grant.taskID == intent.taskID
            && grant.matterID == intent.matterID
            && grant.toolID == intent.toolID
            && grant.effect == intent.effect
            && grant.payloadDigest == intent.payloadDigest
            && grant.version == intent.version
        return matches ? .allowed : .denied(reason: "grant_mismatch")
    }
}

public enum WorkflowPostcondition: Equatable, Sendable {
    case verified(identity: String, digest: String)
    case failed(expectedIdentity: String, observedIdentity: String?)
    case unknown(identity: String)
}

public enum WorkflowCompletionDecision: Equatable, Sendable {
    case completed
    case failed
    case unknown
}

public enum WorkflowOutcomeGate {
    public static func evaluate(_ postconditions: [WorkflowPostcondition]) -> WorkflowCompletionDecision {
        guard !postconditions.isEmpty else { return .unknown }
        if postconditions.contains(where: { if case .failed = $0 { true } else { false } }) {
            return .failed
        }
        if postconditions.contains(where: { if case .unknown = $0 { true } else { false } }) {
            return .unknown
        }
        return .completed
    }
}

public struct WorkflowSourceReference: Codable, Equatable, Sendable {
    public let matterID: String
    public let sourceID: String
    public let version: Int
    public let digest: String

    public init(matterID: String, sourceID: String, version: Int, digest: String) {
        self.matterID = matterID
        self.sourceID = sourceID
        self.version = version
        self.digest = digest
    }
}

public struct WorkflowMemoryCandidate: Equatable, Sendable {
    public let matterID: String
    public let recordID: String
    public let recordVersion: Int
    public let valueDigest: String
    public let sourceReferences: [WorkflowSourceReference]
    public let ownerApproved: Bool

    public init(matterID: String, recordID: String, recordVersion: Int, valueDigest: String, sourceReferences: [WorkflowSourceReference], ownerApproved: Bool) {
        self.matterID = matterID
        self.recordID = recordID
        self.recordVersion = recordVersion
        self.valueDigest = valueDigest
        self.sourceReferences = sourceReferences
        self.ownerApproved = ownerApproved
    }
}

public enum WorkflowMemoryDecision: Equatable, Sendable {
    case persist
    case deny(reason: String)
}

public enum WorkflowMemoryGate {
    public static func evaluate(_ candidate: WorkflowMemoryCandidate, targetMatterID: String) -> WorkflowMemoryDecision {
        guard candidate.matterID == targetMatterID else { return .deny(reason: "matter_mismatch") }
        guard candidate.ownerApproved else { return .deny(reason: "owner_approval_required") }
        guard !candidate.sourceReferences.isEmpty,
              candidate.sourceReferences.allSatisfy({
                  $0.matterID == targetMatterID
                      && !$0.sourceID.isEmpty
                      && $0.version > 0
                      && !$0.digest.isEmpty
              }) else { return .deny(reason: "source_binding_required") }
        return .persist
    }
}

public struct WorkflowHandoff: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let taskID: String
    public let matterID: String
    public let recordID: String
    public let recordVersion: Int
    public let budgetDigest: String
    public let sourceReferences: [WorkflowSourceReference]
    public let outcomeDigest: String

    public init(taskID: String, matterID: String, recordID: String, recordVersion: Int, budgetDigest: String, sourceReferences: [WorkflowSourceReference], outcomeDigest: String) {
        schemaVersion = Self.currentSchemaVersion
        self.taskID = taskID
        self.matterID = matterID
        self.recordID = recordID
        self.recordVersion = recordVersion
        self.budgetDigest = budgetDigest
        self.sourceReferences = sourceReferences
        self.outcomeDigest = outcomeDigest
    }
}
