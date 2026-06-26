import Foundation
import SupraDraftingCore

public enum DraftKindRegistryError: Error, Equatable {
    case unsupported(DraftKindID)
}

public protocol DraftKindRegistryProtocol: Sendable {
    func definition(for kind: DraftKindID) throws -> DraftKindDefinition
}

public struct DefaultDraftKindRegistry: DraftKindRegistryProtocol, Sendable {
    private let definitions: [DraftKindID: DraftKindDefinition]

    public init(definitions: [DraftKindID: DraftKindDefinition]? = nil) {
        self.definitions = definitions ?? Self.defaultDefinitions
    }

    public func definition(for kind: DraftKindID) throws -> DraftKindDefinition {
        guard let definition = definitions[kind] else {
            throw DraftKindRegistryError.unsupported(kind)
        }
        return definition
    }

    public static let defaultDefinitions: [DraftKindID: DraftKindDefinition] = [
        .noticeAppearance: DraftKindDefinition(
            id: .noticeAppearance,
            renderShell: .courtFL,
            defaultSkeleton: .none,
            blockType: .servicePipeline,
            groundingPolicy: .noMatterFacts,
            assertsLegalAuthority: false,
            slotSpecs: NoticeAppearanceSlots.specs,
            headingContract: HeadingContract(required: [.caption, .title, .body, .signature, .certificateOfService])
        ),
        .motionToDismiss: DraftKindDefinition(
            id: .motionToDismiss,
            renderShell: .courtFL,
            defaultSkeleton: .houseMotionFL,
            blockType: .contract,
            groundingPolicy: .authorityAndFacts,
            assertsLegalAuthority: true,
            slotSpecs: MotionToDismissSlots.specs,
            headingContract: HeadingContract(required: [.caption, .title, .introduction, .statementOfFacts, .memorandumOfLaw, .argument, .conclusion, .signature, .certificateOfService])
        ),
        .letterDemand: DraftKindDefinition(
            id: .letterDemand,
            renderShell: .letterhead,
            defaultSkeleton: .none,
            blockType: .routedSkill,
            groundingPolicy: .matterFactsRequired,
            assertsLegalAuthority: false,
            slotSpecs: LetterDemandSlots.specs,
            headingContract: HeadingContract(required: [.wholeLetter])
        )
    ]
}

public enum NoticeAppearanceSlots {
    public static let specs: [SlotSpec] = [
        SlotSpec(key: "courtHeader", type: .text, source: .matterMetadata, requirement: .required, validator: .none),
        SlotSpec(key: "parties", type: .list(.partyRef), source: .partyModel, requirement: .required, validator: .none),
        SlotSpec(key: "caseNumber", type: .text, source: .matterMetadata, requirement: .required, validator: .caseNumberFormat),
        SlotSpec(key: "division", type: .text, source: .matterMetadata, requirement: .optional, validator: .none),
        SlotSpec(key: "partyRepresented", type: .text, source: .matterMetadata, requirement: .required, validator: .none),
        SlotSpec(key: "firm", type: .text, source: .assistantProfile, requirement: .required, validator: .none),
        SlotSpec(key: "signingAttorney", type: .text, source: .assistantProfile, requirement: .required, validator: .none),
        SlotSpec(key: "barNumber", type: .text, source: .assistantProfile, requirement: .required, validator: .none),
        SlotSpec(key: "office", type: .officeBlock, source: .assistantProfile, requirement: .required, validator: .none),
        SlotSpec(key: "primaryEmail", type: .email, source: .assistantProfile, requirement: .required, validator: .emailFormat),
        SlotSpec(key: "secondaryEmails", type: .list(.email), source: .assistantProfile, requirement: .optional, validator: .none),
        SlotSpec(key: "recipients", type: .serviceRecipientList, source: .matterMetadata, requirement: .required, validator: .none),
        SlotSpec(key: "serviceDate", type: .date, source: .matterMetadata, requirement: .required, validator: .none)
    ]
}

public enum MotionToDismissSlots {
    public static let specs: [SlotSpec] = NoticeAppearanceSlots.specs + [
        SlotSpec(key: "grounds", type: .list(.text), source: .userPrompt, requirement: .required, validator: .none),
        SlotSpec(key: "reliefSought", type: .text, source: .userPrompt, requirement: .optional, validator: .none),
        SlotSpec(key: "respondingTo", type: .text, source: .matterMetadata, requirement: .required, validator: .none)
    ]
}

public enum LetterDemandSlots {
    public static let specs: [SlotSpec] = [
        SlotSpec(key: "recipient", type: .addressBlock, source: .matterMetadata, requirement: .required, validator: .none),
        SlotSpec(key: "reSubject", type: .text, source: .userPrompt, requirement: .required, validator: .none),
        SlotSpec(key: "demandAmount", type: .money, source: .userPrompt, requirement: .required, validator: .none),
        SlotSpec(key: "responseDeadline", type: .date, source: .userPrompt, requirement: .required, validator: .none),
        SlotSpec(key: "tone", type: .enumValue(["firm", "measured", "final"]), source: .userPrompt, requirement: .optional, validator: .none),
        SlotSpec(key: "letterhead", type: .officeBlock, source: .assistantProfile, requirement: .required, validator: .none),
        SlotSpec(key: "signerName", type: .text, source: .assistantProfile, requirement: .required, validator: .none)
    ]
}

public struct MotionGroundSpec: Sendable, Equatable {
    public var key: String
    public var displayName: String
    public var elementKeys: [String]
    public var authorityQueries: [ScrubbedProposition]

    public init(key: String, displayName: String, elementKeys: [String], authorityQueries: [ScrubbedProposition]) {
        self.key = key
        self.displayName = displayName
        self.elementKeys = elementKeys
        self.authorityQueries = authorityQueries
    }

    public static func knownGround(for userText: String) throws -> MotionGroundSpec {
        let normalized = userText.lowercased()
        if normalized.contains("failure") && normalized.contains("state") && normalized.contains("claim") {
            return failureToStateClaim
        }
        throw DraftKindRegistryError.unsupported(.motionToDismiss)
    }

    public static func propositions(for grounds: [String], section: Section) -> [ScrubbedProposition] {
        guard section == .argument || section == .memorandumOfLaw else { return [] }
        return grounds.flatMap { (try? knownGround(for: $0).authorityQueries) ?? [] }
    }

    public static let failureToStateClaim = MotionGroundSpec(
        key: "mtd.failureToStateClaim",
        displayName: "Failure to state a claim",
        elementKeys: ["mtd.failureToStateClaim"],
        authorityQueries: [
            ScrubbedProposition(text: "Florida Rule of Civil Procedure 1.140(b)(6) motion to dismiss failure to state a cause of action legal standard"),
            ScrubbedProposition(text: "Florida court accepts well pleaded allegations as true on motion to dismiss but conclusory allegations insufficient")
        ]
    )
}

public struct ScrubbedProposition: Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}
