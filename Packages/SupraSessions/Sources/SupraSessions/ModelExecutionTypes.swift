import Foundation
import SupraCore

/// Stable identity for one feature-owned model invocation.
public struct ModelExecutionTaskID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Exact model content that remains pinned for the lifetime of a permit.
public struct ModelExecutionModelBinding: Equatable, Hashable, Sendable {
    public let modelID: ModelID
    public let repositoryID: String
    public let revision: String
    public let artifactFingerprintSHA256: String

    public init(
        modelID: ModelID,
        repositoryID: String,
        revision: String,
        artifactFingerprintSHA256: String
    ) {
        self.modelID = modelID
        self.repositoryID = repositoryID
        self.revision = revision
        self.artifactFingerprintSHA256 = artifactFingerprintSHA256
    }
}

/// One request for the process-wide physical model-execution lane.
public struct ModelExecutionRequest: Sendable {
    public let taskID: ModelExecutionTaskID
    public let operation: ModelExecutionOperation
    public let priority: ModelExecutionPriority
    public let modelBinding: ModelExecutionModelBinding?
    public let duplicateKey: String?

    public init(
        taskID: ModelExecutionTaskID,
        operation: ModelExecutionOperation,
        priority: ModelExecutionPriority,
        modelBinding: ModelExecutionModelBinding?,
        duplicateKey: String?
    ) {
        self.taskID = taskID
        self.operation = operation
        self.priority = priority
        self.modelBinding = modelBinding
        self.duplicateKey = duplicateKey
    }
}

public enum ModelExecutionLifecycle: String, CaseIterable, Equatable, Sendable {
    case queued
    case preparing
    case running
    case cancelling
    case completed
    case failed
    case recoveryRequired
}

public enum ModelExecutionPrimaryAction: Equatable, Sendable {
    case none
    case cancel
    case retry
    case recoverRuntime
}

public enum ModelExecutionRelaunchDisposition: Equatable, Sendable {
    case retryFromOwnerCheckpoint
    case recoverRuntimeThenRetry
    case preserveTerminal
}

public struct ModelExecutionLifecycleBehavior: Equatable, Sendable {
    public let showsProgress: Bool
    public let primaryAction: ModelExecutionPrimaryAction
    public let relaunchDisposition: ModelExecutionRelaunchDisposition
    public let suppressesDuplicateInvocation: Bool

    public init(
        showsProgress: Bool,
        primaryAction: ModelExecutionPrimaryAction,
        relaunchDisposition: ModelExecutionRelaunchDisposition,
        suppressesDuplicateInvocation: Bool
    ) {
        self.showsProgress = showsProgress
        self.primaryAction = primaryAction
        self.relaunchDisposition = relaunchDisposition
        self.suppressesDuplicateInvocation = suppressesDuplicateInvocation
    }
}

/// One lifecycle policy shared by every model-backed surface.
public enum ModelExecutionLifecycleContract {
    public static func behavior(
        for lifecycle: ModelExecutionLifecycle
    ) -> ModelExecutionLifecycleBehavior {
        switch lifecycle {
        case .queued:
            ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .cancel,
                relaunchDisposition: .retryFromOwnerCheckpoint,
                suppressesDuplicateInvocation: true
            )
        case .preparing, .running:
            ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .cancel,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            )
        case .cancelling:
            ModelExecutionLifecycleBehavior(
                showsProgress: true,
                primaryAction: .none,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            )
        case .completed:
            ModelExecutionLifecycleBehavior(
                showsProgress: false,
                primaryAction: .none,
                relaunchDisposition: .preserveTerminal,
                suppressesDuplicateInvocation: false
            )
        case .failed:
            ModelExecutionLifecycleBehavior(
                showsProgress: false,
                primaryAction: .retry,
                relaunchDisposition: .retryFromOwnerCheckpoint,
                suppressesDuplicateInvocation: false
            )
        case .recoveryRequired:
            ModelExecutionLifecycleBehavior(
                showsProgress: false,
                primaryAction: .recoverRuntime,
                relaunchDisposition: .recoverRuntimeThenRetry,
                suppressesDuplicateInvocation: true
            )
        }
    }
}

public struct ModelExecutionSnapshot: Equatable, Sendable {
    public let taskID: ModelExecutionTaskID
    public let operation: ModelExecutionOperation
    public let priority: ModelExecutionPriority
    public let modelBinding: ModelExecutionModelBinding?
    public let lifecycle: ModelExecutionLifecycle

    public init(
        taskID: ModelExecutionTaskID,
        operation: ModelExecutionOperation,
        priority: ModelExecutionPriority,
        modelBinding: ModelExecutionModelBinding?,
        lifecycle: ModelExecutionLifecycle
    ) {
        self.taskID = taskID
        self.operation = operation
        self.priority = priority
        self.modelBinding = modelBinding
        self.lifecycle = lifecycle
    }
}

public enum ModelExecutionError: Error, Equatable, LocalizedError, Sendable {
    case queueFull(capacity: Int)
    case superseded(taskID: ModelExecutionTaskID, by: ModelExecutionTaskID)
    case cancelled(taskID: ModelExecutionTaskID)
    case recoveryRequired
    case duplicateInvocation(existingTaskID: ModelExecutionTaskID)
    case modelBindingMismatch

    public var errorDescription: String? {
        switch self {
        case let .queueFull(capacity):
            "The local model queue is full (capacity: \(capacity))."
        case let .superseded(taskID, replacementTaskID):
            "Model task \(taskID.rawValue) was superseded by \(replacementTaskID.rawValue)."
        case let .cancelled(taskID):
            "Model task \(taskID.rawValue) was cancelled."
        case .recoveryRequired:
            "The local model runtime requires recovery before more work can start."
        case let .duplicateInvocation(existingTaskID):
            "The same model work is already active as \(existingTaskID.rawValue)."
        case .modelBindingMismatch:
            "The runtime request does not match the model bound to its execution permit."
        }
    }
}
