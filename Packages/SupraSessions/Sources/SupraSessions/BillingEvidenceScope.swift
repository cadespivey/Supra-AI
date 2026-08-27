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
    let inferredMatterAuthorizations: [BillingInferredMatterAuthorization]

    init(
        entries: [ScratchPadEntryRecord],
        attachments: [ScratchPadAttachmentRecord],
        matters: [MatterRecord]
    ) {
        let validMatterIDs = Set(matters.map(\.id))
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
        var inferredAuthorizations: [BillingInferredMatterAuthorization] = []
        for entry in entries {
            let mentioned = Set(entry.mentions.compactMap(Self.normalizedID)).intersection(validMatterIDs)
            let attached = attachmentMattersByEntry[entry.id, default: []]
            let combined = mentioned.union(attached)
            let textResolution = combined.isEmpty
                ? Self.resolveMatterFromText(entry.text, matters: matters)
                : nil
            let allowedMatterIDs = textResolution?.matterIDs ?? combined
            if allowedMatterIDs.count == 1 {
                candidates.formUnion(allowedMatterIDs)
            }
            authorizations[entry.id] = EntryAuthorization(
                allowedMatterIDs: allowedMatterIDs.count == 1 ? allowedMatterIDs : [],
                isAmbiguous: allowedMatterIDs.count > 1
            )
            if let resolution = textResolution,
               resolution.matterIDs.count == 1,
               let matterID = resolution.matterIDs.first,
               let basis = resolution.basis {
                inferredAuthorizations.append(BillingInferredMatterAuthorization(
                    entryID: entry.id,
                    matterID: matterID,
                    basis: basis
                ))
            }
        }
        for attachment in includedAttachments where attachment.entryID == nil {
            guard let matterID = Self.normalizedID(attachment.matterID),
                  validMatterIDs.contains(matterID) else { continue }
            candidates.insert(matterID)
        }

        self.entryAuthorizations = authorizations
        self.candidateMatterIDs = candidates
        self.includedAttachmentIDs = Set(includedAttachments.map(\.id))
        self.inferredMatterAuthorizations = inferredAuthorizations.sorted { $0.entryID < $1.entryID }
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
            if authorization.isAmbiguous,
               Self.normalizedID(rawMatterValue) != nil {
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
            version: inferredMatterAuthorizations.isEmpty ? 1 : 2,
            candidateMatterIDs: candidateMatterIDs.sorted(),
            includedEntryIDs: entryAuthorizations.keys.sorted(),
            includedAttachmentIDs: includedAttachmentIDs.sorted(),
            inferredMatterAuthorizations: inferredMatterAuthorizations.isEmpty ? nil : inferredMatterAuthorizations
        )
    }

    private struct TextResolution {
        let matterIDs: Set<String>
        let basis: String?
    }

    private static func resolveMatterFromText(_ text: String, matters: [MatterRecord]) -> TextResolution {
        let normalizedText = searchable(text)
        let matterNameMatches = Set(matters.compactMap { matter in
            containsBounded(normalizedText, phrase: searchable(matter.name)) ? matter.id : nil
        })
        if !matterNameMatches.isEmpty {
            return TextResolution(
                matterIDs: matterNameMatches,
                basis: matterNameMatches.count == 1 ? "explicitMatterName" : nil
            )
        }

        let clientNameMatches: Set<String> = Set(matters.compactMap { matter in
            guard let clientName = matter.clientNames else { return nil }
            return containsBounded(normalizedText, phrase: searchable(clientName)) ? matter.id : nil
        })
        return TextResolution(
            matterIDs: clientNameMatches,
            basis: clientNameMatches.count == 1 ? "explicitClientName" : nil
        )
    }

    private static func searchable(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " "
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func containsBounded(_ text: String, phrase: String) -> Bool {
        guard phrase.count >= 3 else { return false }
        return " \(text) ".contains(" \(phrase) ")
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
        case fragmentedTimestampInterval(startEntryID: String, endEntryID: String)
    }

    public let lineIndex: Int
    public let reason: Reason

    public init(lineIndex: Int, reason: Reason) {
        self.lineIndex = lineIndex
        self.reason = reason
    }
}
