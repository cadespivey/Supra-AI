import Foundation

/// The local-assistant capability that must be configured before work can
/// continue. Keeping the role in the requirement makes the destination row
/// precise even as AI Setup grows to support more than one local model.
public enum LocalAssistantRole: String, Codable, Hashable, Sendable {
    case drafting
}

/// A concrete prerequisite of local document search.
public enum DocumentSearchSetupStep: String, Codable, Hashable, Sendable {
    case embeddingModel
    case extractionToolchain
    case storage
}

/// An external provider whose connection is managed in Settings.
public enum SetupProvider: String, Codable, Hashable, Sendable {
    case courtListener
}

/// A missing prerequisite that blocks a user action.
///
/// Each case has one stable identifier and one exact navigation target. The
/// requirement is intentionally free of presentation prose so callers can
/// render it in the context of the action that is unavailable.
public enum SetupRequirement: Codable, Hashable, Sendable {
    case localAssistant(role: LocalAssistantRole)
    case documentSearch(step: DocumentSearchSetupStep)
    case providerConnection(provider: SetupProvider)
    case backupDestination

    /// Stable identity used by launch fixtures, accessibility hooks, and
    /// persisted navigation requests.
    public var id: String {
        switch self {
        case let .localAssistant(role):
            return "localAssistant.\(role.rawValue)"
        case let .documentSearch(step):
            return "documentSearch.\(step.rawValue)"
        case let .providerConnection(provider):
            return "providerConnection.\(provider.rawValue)"
        case .backupDestination:
            return "backupDestination"
        }
    }

    /// Resolves a stable requirement identifier without inventing a default.
    public init?(id: String) {
        switch id {
        case "localAssistant.drafting":
            self = .localAssistant(role: .drafting)
        case "documentSearch.embeddingModel":
            self = .documentSearch(step: .embeddingModel)
        case "documentSearch.extractionToolchain":
            self = .documentSearch(step: .extractionToolchain)
        case "documentSearch.storage":
            self = .documentSearch(step: .storage)
        case "providerConnection.courtListener":
            self = .providerConnection(provider: .courtListener)
        case "backupDestination":
            self = .backupDestination
        default:
            return nil
        }
    }

    public var navigationTarget: SetupNavigationTarget {
        switch self {
        case let .localAssistant(role):
            return .aiSetup(row: .localAssistant(role: role))
        case let .documentSearch(step):
            return .aiSetup(row: .documentSearch(step: step))
        case let .providerConnection(provider):
            return .settings(row: .providerConnection(provider: provider))
        case .backupDestination:
            return .settings(row: .backup)
        }
    }
}

/// An exact focus target within AI Setup.
public enum AISetupRequirementRow: Codable, Hashable, Sendable {
    case localAssistant(role: LocalAssistantRole)
    case documentSearch(step: DocumentSearchSetupStep)
}

/// An exact focus target within Settings.
public enum SettingsRequirementRow: Codable, Hashable, Sendable {
    case providerConnection(provider: SetupProvider)
    case backup
}

/// A typed destination for correcting a setup blocker.
public enum SetupNavigationTarget: Codable, Hashable, Sendable {
    case aiSetup(row: AISetupRequirementRow)
    case settings(row: SettingsRequirementRow)

    public var rowAccessibilityIdentifier: String {
        switch self {
        case let .aiSetup(row):
            switch row {
            case let .localAssistant(role):
                return "aiSetup.requirement.localAssistant.\(role.rawValue)"
            case let .documentSearch(step):
                return "aiSetup.requirement.documentSearch.\(step.rawValue)"
            }
        case let .settings(row):
            switch row {
            case let .providerConnection(provider):
                return "settings.requirement.provider.\(provider.rawValue)"
            case .backup:
                return "settings.requirement.backup"
            }
        }
    }

    public var isAISetup: Bool {
        if case .aiSetup = self { return true }
        return false
    }

    public var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }
}

/// A durable reference to an input or output whose revision affects the work
/// the user intends to resume.
public struct VersionedWorkReference: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }
}

/// The work operation that was blocked by a missing setup requirement.
public enum WorkIntent: String, Codable, Hashable, Sendable {
    case draftMotion
    case importDocuments
}

/// The exact destination to restore after setup is complete or cancelled.
public enum WorkReturnDestination: Codable, Hashable, Sendable {
    case matterTask(matterID: String, intent: WorkIntent)
}

/// Compact, versioned inputs needed to resume a blocked action without
/// substituting the current matter, a current source set, or another default.
public struct WorkContext: Codable, Hashable, Sendable {
    public let matterID: String
    public let intent: WorkIntent
    public let sourceSet: VersionedWorkReference?
    public let authorityPacket: VersionedWorkReference?
    public let workProduct: VersionedWorkReference?
    public let returnDestination: WorkReturnDestination
    public let checkpointID: String?

    public init(
        matterID: String,
        intent: WorkIntent,
        sourceSet: VersionedWorkReference?,
        authorityPacket: VersionedWorkReference?,
        workProduct: VersionedWorkReference?,
        returnDestination: WorkReturnDestination,
        checkpointID: String?
    ) {
        self.matterID = matterID
        self.intent = intent
        self.sourceSet = sourceSet
        self.authorityPacket = authorityPacket
        self.workProduct = workProduct
        self.returnDestination = returnDestination
        self.checkpointID = checkpointID
    }
}

/// A request to correct a setup blocker while retaining the exact work that
/// should be restored on return.
public struct SetupNavigationRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let requirement: SetupRequirement
    public let returnContext: WorkContext

    public init(
        id: String,
        requirement: SetupRequirement,
        returnContext: WorkContext
    ) {
        self.id = id
        self.requirement = requirement
        self.returnContext = returnContext
    }

    public var navigationTarget: SetupNavigationTarget {
        requirement.navigationTarget
    }
}

/// A named application surface that can participate in a workflow handoff.
/// These are stable internal identities, not user-facing navigation labels.
public enum WorkSurface: String, Codable, CaseIterable, Hashable, Sendable {
    case documents
    case ask
    case chat
    case research
    case authorities
    case newWorkProduct
    case quickAttachment
    case savedWork
    case checkSources
    case publicRecords
}

/// One exact transfer of a version-bound work context between product surfaces.
/// The destination receives this value as-is and may not replace any member from
/// process-global selection or a newly fetched "current" version.
public struct WorkHandoffRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let origin: WorkSurface
    public let destination: WorkSurface
    public let context: WorkContext

    public init(
        id: String,
        origin: WorkSurface,
        destination: WorkSurface,
        context: WorkContext
    ) {
        precondition(Self.isExactIdentity(id), "A handoff requires an exact identity")
        self.id = id
        self.origin = origin
        self.destination = destination
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case origin
        case destination
        case context
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        guard Self.isExactIdentity(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: values,
                debugDescription: "A handoff requires an exact nonempty identity."
            )
        }
        self.id = id
        self.origin = try values.decode(WorkSurface.self, forKey: .origin)
        self.destination = try values.decode(WorkSurface.self, forKey: .destination)
        self.context = try values.decode(WorkContext.self, forKey: .context)
    }

    private static func isExactIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
