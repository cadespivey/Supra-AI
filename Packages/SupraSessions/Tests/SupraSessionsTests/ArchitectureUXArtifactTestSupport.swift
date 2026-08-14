import Foundation
import GRDB
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

enum ArchitectureUXArtifactWire {
    static let intentID = "artifact-713"
    static let digestMarker = "digest-719"
    static let collisionSuffix = 7
    static let versionIndex = 7
    static let nextVersionIndex = 8
    static let forbiddenDefault = "DEFAULT-000"
    static let generalExportKind = "structured_output_export"
    static let publicationIntentLinkColumn = "publication_intent_id"
    static let timestamp = Date(timeIntervalSince1970: 1_946_252_713)
}

struct ArchitectureUXArtifactFixture: @unchecked Sendable {
    let testID: String
    let marker: Int
    let root: URL
    let store: SupraStore
    let storage: DocumentStorage
    let matter: MatterRecord
    let output: StructuredOutputRecord
    let version: StructuredOutputVersionRecord

    static func make(testID: String, marker: Int) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(testID)-\(marker)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore(url: root.appendingPathComponent("store.sqlite"))
        let matter = try store.matters.createMatter(
            name: "\(testID) Matter \(marker)"
        )
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "\(testID) WIRE \(marker)",
            outputType: .documentQA,
            status: .complete
        )
        let version = try makeExportableVersion(
            store: store,
            outputID: output.id,
            versionIndex: ArchitectureUXArtifactWire.versionIndex,
            content: "\(testID)_SAVED_WORK_\(marker) \(ArchitectureUXArtifactWire.digestMarker)"
        )
        return Self(
            testID: testID,
            marker: marker,
            root: root,
            store: store,
            storage: DocumentStorage(root: root.appendingPathComponent("managed", isDirectory: true)),
            matter: matter,
            output: output,
            version: version
        )
    }

    func appendExportableVersion(marker: Int) throws -> StructuredOutputVersionRecord {
        try Self.makeExportableVersion(
            store: store,
            outputID: output.id,
            versionIndex: ArchitectureUXArtifactWire.nextVersionIndex,
            content: "T_ART_01_RESAVED_VERSION_\(marker)"
        )
    }

    func legacyReplaceInPlaceURL(format: DocumentExportFormat = .markdown) -> URL {
        storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent(
                "\(testID)-WIRE-\(marker)-v\(version.versionIndex).\(format.fileExtension)"
            )
    }

    func publicURL(for export: DocumentExportRecord) -> URL {
        storage.url(forManagedRelativePath: export.managedRelativePath)
    }

    func completedGeneralIntents() throws -> [DraftArtifactIntentRecord] {
        try store.database.writer.read { db in
            try DraftArtifactIntentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM draft_artifact_intents
                    WHERE matter_id = ? AND artifact_kind = ?
                    ORDER BY created_at, id
                    """,
                arguments: [matter.id, ArchitectureUXArtifactWire.generalExportKind]
            )
        }
    }

    func exportColumns() throws -> Set<String> {
        try store.database.writer.read { db in
            Set(try db.columns(in: DocumentExportRecord.databaseTableName).map(\.name))
        }
    }

    func linkedIntentIDs() throws -> [String] {
        try store.database.writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT publication_intent_id
                    FROM document_exports
                    WHERE structured_output_id = ?
                    ORDER BY publication_intent_id
                    """,
                arguments: [output.id]
            )
        }
    }

    func exportAudits() throws -> [AuditEventRecord] {
        try store.auditEvents.fetchEvents(matterID: matter.id).filter {
            $0.eventType == "export_completed" && $0.relatedID == output.id
        }
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func seedInterruptedGeneralExport(
        intentID: String = ArchitectureUXArtifactWire.intentID,
        fileName: String,
        data: Data
    ) throws -> DraftArtifactIntentRecord {
        let lineage = ArchitectureUXGeneralExportIntentLineage(
            schemaVersion: 1,
            artifactIdentity: intentID,
            digestMarker: ArchitectureUXArtifactWire.digestMarker,
            matterID: matter.id,
            structuredOutputID: output.id,
            structuredOutputVersionID: version.id,
            workProductVersion: version.versionIndex,
            format: DocumentExportFormat.markdown.rawValue,
            outputFileName: fileName,
            outputSHA256: DocumentStorage.sha256Hex(of: data),
            outputByteSize: data.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = try encoder.encode(lineage)
        let metadataJSON = String(decoding: metadata, as: UTF8.self)
        let intent = DraftArtifactIntentRecord(
            id: intentID,
            matterID: matter.id,
            artifactKind: ArchitectureUXArtifactWire.generalExportKind,
            format: .markdown,
            fileName: fileName,
            outputSHA256: lineage.outputSHA256,
            outputByteSize: data.count,
            auditMetadataJSON: metadataJSON,
            auditMetadataSHA256: DocumentStorage.sha256Hex(of: metadata),
            createdAt: ArchitectureUXArtifactWire.timestamp
        )
        try store.database.writer.write { db in
            try intent.insert(db)
        }

        let url = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent(fileName)
        let writer = DurableFileWriter()
        let installedIdentity = try writer.writeNewOwned(
            data,
            to: url,
            containedIn: storage.root
        ) { candidate in
            XCTAssertEqual(candidate, data)
            try DocumentExportValidator.validate(candidate, as: .markdown)
        }
        let observedIdentity = try XCTUnwrap(
            writer.installedFileIdentity(at: url, containedIn: storage.root)
        )
        XCTAssertEqual(observedIdentity, installedIdentity)
        return intent
    }

    private static func makeExportableVersion(
        store: SupraStore,
        outputID: String,
        versionIndex: Int,
        content: String
    ) throws -> StructuredOutputVersionRecord {
        let evidence = SupportEvidence(
            sourceID: "artifact-source-727",
            sourceLabel: "S7",
            locator: "synthetic:artifact:\(versionIndex)",
            retainedExcerpt: "T_ART_SYNTHETIC_EVIDENCE_733",
            verifierName: "ArchitectureUXArtifactFixture",
            verifierVersion: "t-art-v1"
        )
        let support = try PropositionSupportResult(
            propositionID: "artifact-proposition-731",
            status: .supported,
            reasons: [],
            evidence: [evidence],
            timestamp: ArchitectureUXArtifactWire.timestamp
        )
        return try store.structuredOutputs.createVersion(
            structuredOutputID: outputID,
            versionIndex: versionIndex,
            contentMarkdown: content,
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "t-art-v1",
            verificationResults: [support],
            verificationDimensions: VerificationDimensionsMapper.dimensions(
                verificationResults: [support]
            ),
            assuranceState: .propositionSupported,
            outputStatus: .complete,
            makeActive: true
        )
    }
}

private struct ArchitectureUXGeneralExportIntentLineage: Codable {
    let schemaVersion: Int
    let artifactIdentity: String
    let digestMarker: String
    let matterID: String
    let structuredOutputID: String
    let structuredOutputVersionID: String
    let workProductVersion: Int
    let format: String
    let outputFileName: String
    let outputSHA256: String
    let outputByteSize: Int

    private enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case artifactIdentity = "artifact_identity"
        case digestMarker = "digest_marker"
        case matterID = "matter_id"
        case structuredOutputID = "structured_output_id"
        case structuredOutputVersionID = "structured_output_version_id"
        case workProductVersion = "work_product_version"
        case outputFileName = "output_file_name"
        case outputSHA256 = "output_sha256"
        case outputByteSize = "output_byte_size"
    }
}
