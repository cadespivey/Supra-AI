import Foundation
import GRDB
import SupraCore

/// The transaction-local provenance boundary shared by ordinary source writes
/// and atomic structured-output publication. Keeping this free of repository
/// writes lets callers reuse it inside an existing GRDB transaction.
enum DocumentSourceIntegrityValidator {
    static func prepare(
        _ source: DocumentOutputSourceRecord,
        preserveUnknownRevision: Bool,
        db: Database
    ) throws -> DocumentOutputSourceRecord {
        guard let sourceSet = try DocumentSourceSetRecord.fetchOne(db, key: source.sourceSetID) else {
            throw DocumentSourceRepositoryError.sourceSetNotFound(source.sourceSetID)
        }

        var prepared = source
        var citedDocument: MatterDocumentRecord?
        if let documentID = source.documentID {
            guard let document = try MatterDocumentRecord.fetchOne(db, key: documentID) else {
                throw DocumentSourceRepositoryError.documentNotFound(documentID)
            }
            guard document.deletedAt == nil else {
                throw DocumentSourceRepositoryError.sourceDocumentDeleted(documentID)
            }
            guard document.matterID == sourceSet.matterID else {
                throw DocumentSourceRepositoryError.sourceMatterMismatch(documentID)
            }
            citedDocument = document
        }

        var citedChunk: DocumentChunkRecord?
        if let chunkID = source.chunkID {
            guard let chunk = try DocumentChunkRecord.fetchOne(db, key: chunkID),
                  let documentID = source.documentID,
                  chunk.documentID == documentID else {
                throw DocumentSourceRepositoryError.chunkScopeMismatch(chunkID)
            }
            if prepared.revisionID == nil, !preserveUnknownRevision {
                prepared.revisionID = chunk.revisionID
            }
            citedChunk = chunk
        }

        var citedRevision: DocumentPartRevisionRecord?
        let integrityRevisionID = prepared.revisionID ?? citedChunk?.revisionID
        if let revisionID = integrityRevisionID {
            guard let documentID = prepared.documentID,
                  let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                  revision.documentID == documentID else {
                throw DocumentSourceRepositoryError.revisionScopeMismatch(revisionID)
            }
            if let suppliedRevisionID = prepared.revisionID,
               let chunkRevisionID = citedChunk?.revisionID,
               chunkRevisionID != suppliedRevisionID {
                throw DocumentSourceRepositoryError.revisionScopeMismatch(suppliedRevisionID)
            }
            citedRevision = revision
        }

        if let citedChunk {
            guard let locator = StoredSourceLocator.decode(source.locatorJSON),
                  locatorMatches(locator, chunk: citedChunk, revision: citedRevision) else {
                throw DocumentSourceRepositoryError.sourceLocatorMismatch(source.id)
            }
            guard source.excerpt == storedExcerpt(for: citedChunk) else {
                throw DocumentSourceRepositoryError.sourceExcerptMismatch(source.id)
            }
        } else if let citedRevision {
            guard let locator = StoredSourceLocator.decode(source.locatorJSON),
                  revisionOnlyLocatorMatches(
                      locator,
                      revision: citedRevision,
                      document: citedDocument
                  ) else {
                throw DocumentSourceRepositoryError.sourceLocatorMismatch(source.id)
            }
            guard let rangeText = text(in: locator, revision: citedRevision),
                  isGrounded(source.excerpt, in: rangeText) else {
                throw DocumentSourceRepositoryError.sourceExcerptMismatch(source.id)
            }
        }
        return prepared
    }

    /// Proposition-supported output earns its assurance from these exact source
    /// rows. Corpus-complete output is admitted by the independent frozen-corpus
    /// ledger and therefore does not use this row-level verifier contract.
    static func validateEvidence(
        _ results: [PropositionSupportResult],
        against sources: [DocumentOutputSourceRecord],
        matterID: String,
        db: Database
    ) throws {
        // Assurance describes the retained packet, not merely the subset a
        // verifier happened to cite. Do not let one valid citation carry an
        // unused provenance-free row across the atomic publication boundary.
        for source in sources {
            guard let locator = StoredSourceLocator.decode(source.locatorJSON),
                  try sourceCanEarnPropositionSupport(
                      source,
                      locator: locator,
                      matterID: matterID,
                      db: db
                  ) else {
                throw StructuredOutputRepositoryError.verificationEvidenceMismatch(source.id)
            }
        }
        for evidence in results.flatMap(\.evidence) {
            let evidenceLocator = StoredSourceLocator.decode(evidence.locator)
            var matchCount = 0
            for source in sources where source.citationLabel == evidence.sourceLabel {
                guard let sourceLocator = StoredSourceLocator.decode(source.locatorJSON),
                      sourceLocator.canonicalJSON == evidenceLocator?.canonicalJSON,
                      try sourceCanEarnPropositionSupport(
                          source,
                          locator: sourceLocator,
                          matterID: matterID,
                          db: db
                      ),
                      acceptedEvidenceIDs(for: source, matterID: matterID).contains(evidence.sourceID),
                      try evidenceExcerptIsGrounded(
                          evidence.retainedExcerpt,
                          source: source,
                          locator: sourceLocator,
                          db: db
                      ) else {
                    continue
                }
                matchCount += 1
            }
            guard matchCount == 1 else {
                throw StructuredOutputRepositoryError.verificationEvidenceMismatch(evidence.sourceID)
            }
        }
    }

    private static func sourceCanEarnPropositionSupport(
        _ source: DocumentOutputSourceRecord,
        locator: StoredSourceLocator,
        matterID: String,
        db: Database
    ) throws -> Bool {
        guard let documentID = source.documentID,
              let document = try MatterDocumentRecord.fetchOne(db, key: documentID),
              document.matterID == matterID,
              document.deletedAt == nil else {
            return false
        }

        if let chunkID = source.chunkID {
            guard let chunk = try DocumentChunkRecord.fetchOne(db, key: chunkID),
                  chunk.documentID == documentID,
                  let chunkRevisionID = chunk.revisionID,
                  source.revisionID == chunkRevisionID,
                  let revision = try DocumentPartRevisionRecord.fetchOne(db, key: chunkRevisionID),
                  locatorMatches(locator, chunk: chunk, revision: revision),
                  source.excerpt == storedExcerpt(for: chunk) else {
                return false
            }
            return true
        }

        if let revisionID = source.revisionID {
            guard let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                  revision.documentID == documentID,
                  revisionOnlyLocatorMatches(locator, revision: revision, document: document),
                  let rangeText = text(in: locator, revision: revision),
                  isGrounded(source.excerpt, in: rangeText) else {
                return false
            }
            return true
        }

        // Chronology's one intentional non-revision source is a typed projection
        // of the document's persisted metadata date, not caller-authored prose.
        guard source.chunkID == nil,
              locator.isMetadataDateLocator,
              let metadataCreatedAt = document.metadataCreatedAt,
              source.excerpt == ISO8601DateFormatter().string(from: metadataCreatedAt) else {
            return false
        }
        return true
    }

    private static func acceptedEvidenceIDs(
        for source: DocumentOutputSourceRecord,
        matterID: String
    ) -> Set<String> {
        var ids = Set([source.id])
        if let chunkID = source.chunkID {
            ids.insert("\(matterID)/\(chunkID)")
        }
        if let revisionID = source.revisionID {
            ids.insert(revisionID)
        }
        if source.chunkID == nil, let documentID = source.documentID {
            ids.insert("\(matterID)/\(documentID)#metadata-date")
        }
        return ids
    }

    private static func evidenceExcerptIsGrounded(
        _ excerpt: String,
        source: DocumentOutputSourceRecord,
        locator: StoredSourceLocator,
        db: Database
    ) throws -> Bool {
        if let revisionID = source.revisionID,
           let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID) {
            guard let rangeText = text(in: locator, revision: revision) else {
                return false
            }
            return isGrounded(excerpt, in: rangeText)
        }
        // Metadata sources have no immutable text revision; their stored value
        // must still be present in the verifier sentence (or vice versa).
        return isGrounded(excerpt, in: source.excerpt)
            || isGrounded(source.excerpt, in: excerpt)
    }

    private static func locatorMatches(
        _ locator: StoredSourceLocator,
        chunk: DocumentChunkRecord,
        revision: DocumentPartRevisionRecord?
    ) -> Bool {
        guard locator.sourceKind == chunk.sourceKind else { return false }

        // Revision-bound citations are current provenance and must retain every
        // non-range locator dimension exactly. A revisionless legacy chunk has
        // no immutable coordinate system to prove beyond its source kind.
        if revision != nil {
            guard locator.pageIndex == chunk.pageIndex,
                  locator.pageLabel == chunk.pageLabel,
                  locator.sheetName == chunk.sheetName,
                  locator.cellRange == chunk.cellRange,
                  locator.emailPartPath == chunk.emailPartPath,
                  locator.boundingBoxesJSON == chunk.boundingBoxesJSON else {
                return false
            }
        }
        if let partIndex = locator.partIndex, partIndex != revision?.partIndex {
            return false
        }

        let hasLocatorRange = locator.charStart != nil || locator.charEnd != nil
        guard !hasLocatorRange || (locator.charStart != nil && locator.charEnd != nil) else {
            return false
        }
        if let chunkStart = chunk.charStart, let chunkEnd = chunk.charEnd {
            guard let locatorStart = locator.charStart, let locatorEnd = locator.charEnd,
                  locatorStart <= chunkStart, locatorEnd >= chunkEnd else {
                return false
            }
        }
        if let revision, let start = locator.charStart, let end = locator.charEnd {
            guard start >= 0, end >= start, end <= revision.text.count else { return false }
        }
        return true
    }

    private static func revisionOnlyLocatorMatches(
        _ locator: StoredSourceLocator,
        revision: DocumentPartRevisionRecord,
        document: MatterDocumentRecord?
    ) -> Bool {
        if let sourceKind = document?.sourceKind,
           !sourceKind.isEmpty,
           locator.sourceKind != sourceKind {
            return false
        }
        guard locator.partIndex == nil || locator.partIndex == revision.partIndex,
              let start = locator.charStart,
              let end = locator.charEnd,
              start >= 0,
              end > start,
              end <= revision.text.count else {
            return false
        }
        return true
    }

    private static func storedExcerpt(for chunk: DocumentChunkRecord) -> String {
        if let displayExcerpt = chunk.displayExcerpt { return displayExcerpt }
        let collapsed = chunk.normalizedText
            .split(whereSeparator: { $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
        guard collapsed.count > 220 else { return collapsed }
        return String(collapsed.prefix(220)) + "…"
    }

    private static func text(
        in locator: StoredSourceLocator,
        revision: DocumentPartRevisionRecord
    ) -> String? {
        guard let start = locator.charStart, let end = locator.charEnd,
              start >= 0, end >= start, end <= revision.text.count,
              let lower = revision.text.index(revision.text.startIndex, offsetBy: start, limitedBy: revision.text.endIndex),
              let upper = revision.text.index(revision.text.startIndex, offsetBy: end, limitedBy: revision.text.endIndex) else {
            return nil
        }
        return String(revision.text[lower..<upper])
    }

    private static func isGrounded(_ excerpt: String, in text: String) -> Bool {
        var needle = normalized(excerpt)
        guard !needle.isEmpty else { return false }
        if needle.hasSuffix("…") {
            needle.removeLast()
            needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !needle.isEmpty && normalized(text).contains(needle)
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}

private struct StoredSourceLocator {
    let sourceKind: String
    let partIndex: Int?
    let pageIndex: Int?
    let pageLabel: String?
    let sheetName: String?
    let cellRange: String?
    let emailPartPath: String?
    let charStart: Int?
    let charEnd: Int?
    let boundingBoxesJSON: String?
    let canonicalJSON: String

    var isMetadataDateLocator: Bool {
        sourceKind == DocumentSourceKind.convertedDocument.rawValue
            && partIndex == nil
            && pageIndex == nil
            && pageLabel == nil
            && sheetName == nil
            && cellRange == nil
            && emailPartPath == nil
            && charStart == nil
            && charEnd == nil
            && boundingBoxesJSON == nil
    }

    static func decode(_ json: String) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let locator = object as? [String: Any] else {
            return nil
        }
        let keyMap = [
            "sourceKind": "source_kind",
            "partIndex": "part_index",
            "pageIndex": "page_index",
            "pageLabel": "page_label",
            "sheetName": "sheet_name",
            "cellRange": "cell_range",
            "emailPartPath": "email_part_path",
            "charStart": "char_start",
            "charEnd": "char_end",
            "boundingBoxesJSON": "bounding_boxes_json",
        ]
        let camelKeys = Set(keyMap.keys)
        let snakeKeys = Set(keyMap.values)
        let presentKeys = Set(locator.keys)
        let hasCamel = !presentKeys.isDisjoint(with: camelKeys)
        let hasSnake = !presentKeys.isDisjoint(with: snakeKeys)
        guard hasCamel != hasSnake else { return nil }
        let key: (String, String) -> String = { camel, snake in hasCamel ? camel : snake }

        guard let sourceKind = locator[key("sourceKind", "source_kind")] as? String,
              !sourceKind.isEmpty,
              let partIndex = optionalInt(locator[key("partIndex", "part_index")]),
              let pageIndex = optionalInt(locator[key("pageIndex", "page_index")]),
              let charStart = optionalInt(locator[key("charStart", "char_start")]),
              let charEnd = optionalInt(locator[key("charEnd", "char_end")]),
              let pageLabel = optionalString(locator[key("pageLabel", "page_label")]),
              let sheetName = optionalString(locator[key("sheetName", "sheet_name")]),
              let cellRange = optionalString(locator[key("cellRange", "cell_range")]),
              let emailPartPath = optionalString(locator[key("emailPartPath", "email_part_path")]),
              let boundingBoxesJSON = optionalString(locator[key("boundingBoxesJSON", "bounding_boxes_json")]) else {
            return nil
        }

        var normalizedObject: [String: Any] = [:]
        for (rawKey, value) in locator {
            let normalizedKey = hasCamel ? (keyMap[rawKey] ?? rawKey) : rawKey
            guard normalizedObject[normalizedKey] == nil else { return nil }
            normalizedObject[normalizedKey] = value
        }
        guard JSONSerialization.isValidJSONObject(normalizedObject),
              let canonicalData = try? JSONSerialization.data(
                  withJSONObject: normalizedObject,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return Self(
            sourceKind: sourceKind,
            partIndex: partIndex,
            pageIndex: pageIndex,
            pageLabel: pageLabel,
            sheetName: sheetName,
            cellRange: cellRange,
            emailPartPath: emailPartPath,
            charStart: charStart,
            charEnd: charEnd,
            boundingBoxesJSON: boundingBoxesJSON,
            canonicalJSON: String(decoding: canonicalData, as: UTF8.self)
        )
    }

    /// Optional JSON null/absence is valid and represented by an outer optional;
    /// malformed present values fail by returning a nil outer optional.
    private static func optionalInt(_ value: Any?) -> Int?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let integer = value as? Int else { return nil }
        return .some(integer)
    }

    private static func optionalString(_ value: Any?) -> String?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let string = value as? String else { return nil }
        return .some(string)
    }
}
