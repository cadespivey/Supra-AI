import Foundation

/// The user-facing mutation classes that require an explicit commit outcome.
/// Feature controllers remain responsible for their own writes and inputs; this
/// value only gives their presentation semantics one small common vocabulary.
public enum UserMutationOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case matterCreate
    case matterEdit
    case matterDelete
    case matterPin
    case matterReorder
    case recycleRestore
    case settingsPersist
    case credentialSave
    case importStart
    case export
    case routeDependentSave
}

/// An action the presentation layer can expose after a failed mutation.
public enum UserMutationRecoveryAction: String, Codable, CaseIterable, Hashable, Sendable {
    case retry
    case correctInput
}

/// A content-safe failure suitable for visible and accessibility presentation.
/// Callers must describe the error without including secrets or document bodies.
public struct UserMutationFailure: Error, LocalizedError, Equatable, Sendable {
    public let operation: UserMutationOperation
    public let userMessage: String
    public let recoveryActions: Set<UserMutationRecoveryAction>

    public init(
        operation: UserMutationOperation,
        userMessage: String,
        recoveryActions: Set<UserMutationRecoveryAction> = [.retry]
    ) {
        self.operation = operation
        self.userMessage = userMessage
        self.recoveryActions = recoveryActions
    }

    public var errorDescription: String? { userMessage }
}

/// A typed commit boundary. Success-dependent presentation and navigation are
/// permitted only when an authoritative write returned its committed value.
public enum UserMutationOutcome<Success> {
    case committed(Success)
    case failed(UserMutationFailure)

    public var committedValue: Success? {
        guard case let .committed(value) = self else { return nil }
        return value
    }

    public var failure: UserMutationFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }

    public var didCommit: Bool {
        if case .committed = self { return true }
        return false
    }

    public var allowsSuccessPresentation: Bool { didCommit }
    public var allowsDependentNavigation: Bool { didCommit }
}

extension UserMutationOutcome: Sendable where Success: Sendable {}
