import Foundation
import SupraCore

public struct ModelRoleAssignments: Codable, Equatable, Sendable {
    public static let settingsKey = "models.roleAssignments.v1"

    public var legalReasoningModelID: String?
    public var legalReasoningHighQualityModelID: String?
    public var draftingModelID: String?
    public var critiqueModelID: String?

    public init(
        legalReasoningModelID: String? = nil,
        legalReasoningHighQualityModelID: String? = nil,
        draftingModelID: String? = nil,
        critiqueModelID: String? = nil
    ) {
        self.legalReasoningModelID = legalReasoningModelID
        self.legalReasoningHighQualityModelID = legalReasoningHighQualityModelID
        self.draftingModelID = draftingModelID
        self.critiqueModelID = critiqueModelID
    }

    public func modelID(for role: ModelRole) -> String? {
        switch role {
        case .legalReasoning:
            legalReasoningModelID
        case .legalReasoningHighQuality:
            legalReasoningHighQualityModelID
        case .drafting:
            draftingModelID
        case .critique:
            critiqueModelID
        }
    }

    public mutating func setModelID(_ modelID: String?, for role: ModelRole) {
        switch role {
        case .legalReasoning:
            legalReasoningModelID = modelID
        case .legalReasoningHighQuality:
            legalReasoningHighQualityModelID = modelID
        case .drafting:
            draftingModelID = modelID
        case .critique:
            critiqueModelID = modelID
        }
    }
}

public enum ModelRouteResolutionIssue: Error, Equatable, Sendable {
    case noRegisteredModels(role: ModelRole)
    case roleUnassigned(role: ModelRole, configuredIdentifier: String)
    case assignedModelMissing(role: ModelRole, modelID: String)
    case assignedModelLoadFailed(role: ModelRole, displayName: String, message: String)

    public var message: String {
        switch self {
        case let .noRegisteredModels(role):
            "Add or download an MLX model before running \(role.displayName)."
        case let .roleUnassigned(role, configuredIdentifier):
            "Assign a \(role.displayName) model in the Models tab. No registered model matches \(configuredIdentifier)."
        case let .assignedModelMissing(role, _):
            "The model assigned to \(role.displayName) is no longer registered. Choose another model in the Models tab."
        case let .assignedModelLoadFailed(role, displayName, message):
            "The \(role.displayName) model \(displayName) failed to load: \(message)"
        }
    }
}
