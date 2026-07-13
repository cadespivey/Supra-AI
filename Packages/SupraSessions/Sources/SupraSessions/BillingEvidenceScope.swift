import Foundation
import SupraCore
import SupraStore

/// Deterministic authorization graph for one billing-generation request.
///
/// Matter identity is derived only from included, billable evidence. A line may
/// cite only included entries, and an automatic matter assignment is authorized
/// only when every cited entry resolves unambiguously to that matter.
struct BillingEvidenceScope: Sendable, Equatable {
    struct EntryAuthorization: Sendable, Equatable {
        let allowedMatterIDs: Set<String>
        let isAmbiguous: Bool
    }

    let entryAuthorizations: [String: EntryAuthorization]
    let candidateMatterIDs: Set<String>
    let includedAttachmentIDs: Set<String>

    init(
        entries: [ScratchPadEntryRecord],
        attachments: [ScratchPadAttachmentRecord],
        validMatterIDs: Set<String>
    ) {
        let includedEntryIDs = Set(entries.map(\.id))
        let includedAttachments = attachments.filter { attachment in
            guard let entryID = attachment.entryID else { return true }
            return includedEntryIDs.contains(entryID)
        }

        var attachmentMattersByEntry: [String: Set<String>] = [:]
        for attachment in includedAttachments {
            guard let entryID = attachment.entryID,
                  let matterID = Self.normalizedID(attachment.matterID),
                  validMatterIDs.contains(matterID) else { continue }
            attachmentMattersByEntry[entryID, default: []].insert(matterID)
        }

        var authorizations: [String: EntryAuthorization] = [:]
        var candidates = Set<String>()
        for entry in entries {
            let mentioned = Set(entry.mentions.compactMap(Self.normalizedID)).intersection(validMatterIDs)
            let attached = attachmentMattersByEntry[entry.id, default: []]
            let combined = mentioned.union(attached)
            candidates.formUnion(combined)
            authorizations[entry.id] = EntryAuthorization(
                allowedMatterIDs: combined.count == 1 ? combined : [],
                isAmbiguous: combined.count > 1
            )
        }
        for attachment in includedAttachments {
            guard let matterID = Self.normalizedID(attachment.matterID),
                  validMatterIDs.contains(matterID) else { continue }
            candidates.insert(matterID)
        }

        self.entryAuthorizations = authorizations
        self.candidateMatterIDs = candidates
        self.includedAttachmentIDs = Set(includedAttachments.map(\.id))
    }

    static func rawCandidateMatterIDs(
        entries: [ScratchPadEntryRecord],
        attachments: [ScratchPadAttachmentRecord]
    ) -> Set<String> {
        Set(entries.flatMap(\.mentions).compactMap(normalizedID))
            .union(attachments.compactMap { normalizedID($0.matterID) })
    }

    func validate(
        sourceEntryIDs rawSourceEntryIDs: [String]?,
        selectedMatter: MatterRecord?,
        rawMatterValue: String?,
        lineIndex: Int
    ) throws -> [String] {
        let sources = (rawSourceEntryIDs ?? []).compactMap(Self.normalizedID)
        guard !sources.isEmpty else {
            throw BillingEvidenceScopeViolation(lineIndex: lineIndex, reason: .missingSources)
        }
        let uniqueSources = Array(Set(sources)).sorted()
        for sourceID in uniqueSources {
            guard let authorization = entryAuthorizations[sourceID] else {
                throw BillingEvidenceScopeViolation(
                    lineIndex: lineIndex,
                    reason: .unknownSourceEntry(sourceID)
                )
            }
            if authorization.isAmbiguous, selectedMatter != nil {
                throw BillingEvidenceScopeViolation(
                    lineIndex: lineIndex,
                    reason: .ambiguousSourceEntry(sourceID)
                )
            }
        }

        if let requested = Self.normalizedID(rawMatterValue), selectedMatter == nil {
            throw BillingEvidenceScopeViolation(lineIndex: lineIndex, reason: .unknownMatter(requested))
        }
        if let matterID = selectedMatter?.id {
            for sourceID in uniqueSources {
                guard entryAuthorizations[sourceID]?.allowedMatterIDs.contains(matterID) == true else {
                    throw BillingEvidenceScopeViolation(
                        lineIndex: lineIndex,
                        reason: .matterNotAllowed(matterID: matterID, sourceEntryID: sourceID)
                    )
                }
            }
        }
        return uniqueSources
    }

    var persistedSummary: BillingEvidenceValidationSummary {
        BillingEvidenceValidationSummary(
            version: 1,
            candidateMatterIDs: candidateMatterIDs.sorted(),
            includedEntryIDs: entryAuthorizations.keys.sorted(),
            includedAttachmentIDs: includedAttachmentIDs.sorted()
        )
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct BillingEvidenceScopeViolation: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case missingSources
        case unknownSourceEntry(String)
        case unknownMatter(String)
        case ambiguousSourceEntry(String)
        case matterNotAllowed(matterID: String, sourceEntryID: String)
    }

    public let lineIndex: Int
    public let reason: Reason

    public init(lineIndex: Int, reason: Reason) {
        self.lineIndex = lineIndex
        self.reason = reason
    }
}
