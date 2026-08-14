import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraStore
@testable import SupraSessions
import XCTest

/// T-MUTATION-01. Every user-initiated mutation reports one typed outcome.
/// A failed commit keeps the authoritative Store (and any installed file)
/// unchanged, retains the user's non-default working input/selection, suppresses
/// success-dependent navigation, and publishes an actionable failure.
///
/// Expected RED: `UserMutationOutcome` and the controller `attempt…` boundaries
/// do not exist. Several shipping controller paths still use `try?`; additionally,
/// research-plan save and import enqueue span multiple repository writes, so the
/// injected N+1 failure currently leaves a partial aggregate behind.
@MainActor
final class ArchitectureUXTMutation01Tests: XCTestCase {
    private enum Wire {
        static let recordID = "record-713"
        static let siblingID = "record-719"
        static let restoreID = "record-727"
        static let restoreDocumentID = "document-727"
        static let importMatterID = "record-733"
        static let exportMatterID = "record-739"
        static let researchMatterID = "record-743"
        static let version = 7
        static let nextVersion = 8
        static let originalName = "T_MUTATION_ORIGINAL_713"
        static let siblingName = "T_MUTATION_SIBLING_719"
        static let createInput = "T_MUTATION_CREATE_INPUT_731"
        static let editInput = "T_MUTATION_EDIT_INPUT_733"
        static let settingsInput = 0.83
        static let originalTemperature = 0.17
        static let keyInput = "T_MUTATION_KEY_INPUT_751"
        static let importSourceText = "T_MUTATION_IMPORT_INPUT_757"
        static let researchTitle = "T_MUTATION_ROUTE_SAVE_INPUT_761"
        static let researchQuery = "T_MUTATION_QUERY_INPUT_769"
        static let exportTitle = "T Mutation Export 773"
        static let exportCanary = "T_MUTATION_PRIOR_EXPORT_779"
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_252_713)

        static let createFailure = "T_MUTATION_CREATE_FAILURE_787"
        static let editFailure = "T_MUTATION_EDIT_FAILURE_797"
        static let deleteFailure = "T_MUTATION_DELETE_FAILURE_809"
        static let pinFailure = "T_MUTATION_PIN_FAILURE_811"
        static let reorderFailure = "T_MUTATION_REORDER_FAILURE_821"
        static let restoreFailure = "T_MUTATION_RESTORE_FAILURE_823"
        static let settingsFailure = "T_MUTATION_SETTINGS_FAILURE_827"
        static let keyFailure = "T_MUTATION_KEY_FAILURE_829"
        static let importFailure = "T_MUTATION_IMPORT_FAILURE_839"
        static let exportFailure = "T_MUTATION_EXPORT_FAILURE_853"
        static let routeSaveFailure = "T_MUTATION_ROUTE_SAVE_FAILURE_857"
    }

    /// Durable catalog for the complete gate. Each row names the feature-owned
    /// controller boundary; this is deliberately not a universal coordinator.
    private static let mutationMatrix: [(
        operation: UserMutationOperation,
        owner: String,
        marker: String
    )] = [
        (.matterCreate, "MattersController", Wire.createFailure),
        (.matterEdit, "MattersController", Wire.editFailure),
        (.matterDelete, "MattersController", Wire.deleteFailure),
        (.matterPin, "MattersController", Wire.pinFailure),
        (.matterReorder, "MattersController", Wire.reorderFailure),
        (.recycleRestore, "RecycleBinController", Wire.restoreFailure),
        (.settingsPersist, "SettingsController", Wire.settingsFailure),
        (.credentialSave, "SettingsController", Wire.keyFailure),
        (.importStart, "MatterDocumentsController", Wire.importFailure),
        (.export, "StructuredOutputController", Wire.exportFailure),
        (.routeDependentSave, "ResearchSessionController", Wire.routeSaveFailure),
    ]

    /// Contract catalog guard. Behavioral assertions for every row live below.
    func testMutationMatrixNamesEveryRequiredClassExactlyOnce() {
        let expected: Set<UserMutationOperation> = [
            .matterCreate,
            .matterEdit,
            .matterDelete,
            .matterPin,
            .matterReorder,
            .recycleRestore,
            .settingsPersist,
            .credentialSave,
            .importStart,
            .export,
            .routeDependentSave,
        ]
        XCTAssertEqual(Set(Self.mutationMatrix.map(\.operation)), expected)
        XCTAssertEqual(Self.mutationMatrix.count, expected.count)
        XCTAssertEqual(Set(Self.mutationMatrix.map(\.marker)).count, expected.count)
        XCTAssertTrue(Self.mutationMatrix.allSatisfy { !$0.owner.isEmpty })
        XCTAssertTrue(Self.mutationMatrix.allSatisfy {
            !$0.marker.contains(Wire.forbiddenDefault)
        })
    }

    /// The five matter-list mutation classes share semantics but retain their
    /// feature-local inputs. Store triggers fail the exact production writes.
    func testMatterCreateEditDeletePinAndReorderFailuresKeepStoreInputAndSelection() throws {
        let store = try SupraStore.inMemory()
        try insertMatter(
            MatterRecord(
                id: Wire.recordID,
                name: Wire.originalName,
                jurisdiction: "Synthetic Jurisdiction 7",
                sortOrder: Wire.version,
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            ),
            into: store
        )
        try insertMatter(
            MatterRecord(
                id: Wire.siblingID,
                name: Wire.siblingName,
                jurisdiction: "Synthetic Jurisdiction 8",
                sortOrder: Wire.nextVersion,
                createdAt: Wire.timestamp.addingTimeInterval(1),
                updatedAt: Wire.timestamp.addingTimeInterval(1)
            ),
            into: store
        )
        let defaults = try makeManualSortDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let controller = MattersController(
            store: store,
            runtimeClient: StubRuntimeClient(),
            defaults: defaults
        )
        controller.loadMatters()
        controller.select(matterID: Wire.recordID)
        let originalVisibleOrder = controller.matters.map(\.id)
        XCTAssertEqual(controller.selectedMatterID, Wire.recordID)
        XCTAssertEqual(controller.sortMode, .manual)
        XCTAssertEqual(
            controller.matters.first { $0.id == Wire.recordID }?.sortOrder,
            Wire.version
        )
        XCTAssertFalse(originalVisibleOrder.contains(Wire.forbiddenDefault))

        try installMatterFailureTriggers(in: store)

        let createDraft = MatterDraft(
            name: Wire.createInput,
            jurisdiction: "Synthetic Create Jurisdiction 11",
            notes: "T_MUTATION_CREATE_NOTES_863"
        )
        let createOutcome = controller.attemptCreateMatter(createDraft)
        try assertRejected(
            createOutcome,
            operation: .matterCreate,
            marker: Wire.createFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, createOutcome.failure)
        XCTAssertEqual(createDraft.name, Wire.createInput)
        XCTAssertEqual(try store.matters.fetchMatters().count, 2)
        XCTAssertTrue(try store.chats.fetchGlobalChats().isEmpty)
        XCTAssertEqual(controller.selectedMatterID, Wire.recordID)

        var editDraft = try XCTUnwrap(controller.draft(forMatter: Wire.recordID))
        editDraft.name = Wire.editInput
        editDraft.notes = "T_MUTATION_EDIT_NOTES_877"
        let editOutcome = controller.attemptUpdateMatter(
            id: Wire.recordID,
            draft: editDraft
        )
        try assertRejected(
            editOutcome,
            operation: .matterEdit,
            marker: Wire.editFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, editOutcome.failure)
        XCTAssertEqual(editDraft.name, Wire.editInput, "the editor draft stays intact")
        XCTAssertEqual(try store.matters.fetchMatter(id: Wire.recordID)?.name, Wire.originalName)
        XCTAssertEqual(controller.selectedMatterID, Wire.recordID)

        let deleteOutcome = controller.attemptDeleteMatter(id: Wire.recordID)
        try assertRejected(
            deleteOutcome,
            operation: .matterDelete,
            marker: Wire.deleteFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, deleteOutcome.failure)
        XCTAssertNotNil(try store.matters.fetchMatter(id: Wire.recordID))
        XCTAssertTrue(controller.matters.contains { $0.id == Wire.recordID })
        XCTAssertEqual(controller.selectedMatterID, Wire.recordID)

        let pinOutcome = controller.attemptSetPinned(
            matterID: Wire.recordID,
            pinned: true
        )
        try assertRejected(
            pinOutcome,
            operation: .matterPin,
            marker: Wire.pinFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, pinOutcome.failure)
        XCTAssertNil(try store.matters.fetchMatter(id: Wire.recordID)?.pinnedAt)
        XCTAssertFalse(
            try XCTUnwrap(controller.matters.first { $0.id == Wire.recordID }).isPinned
        )

        let reorderOutcome = controller.attemptMoveMatters(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 2
        )
        try assertRejected(
            reorderOutcome,
            operation: .matterReorder,
            marker: Wire.reorderFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, reorderOutcome.failure)
        XCTAssertEqual(controller.matters.map(\.id), originalVisibleOrder)
        XCTAssertEqual(try store.matters.fetchMatter(id: Wire.recordID)?.sortOrder, Wire.version)
        XCTAssertEqual(try store.matters.fetchMatter(id: Wire.siblingID)?.sortOrder, Wire.nextVersion)
    }

    /// Restore is one aggregate: a child-row failure must roll the matter row
    /// back too, and the Recycle Bin must retain the user's selected target.
    func testRecycleRestoreFailureKeepsDeletedAggregateAndRetryVisible() throws {
        let store = try SupraStore.inMemory()
        let deletedAt = Wire.timestamp.addingTimeInterval(17)
        try insertMatter(
            MatterRecord(
                id: Wire.restoreID,
                name: "T_MUTATION_RESTORE_INPUT_881",
                jurisdiction: "Synthetic Restore Jurisdiction 13",
                createdAt: Wire.timestamp,
                updatedAt: deletedAt,
                deletedAt: deletedAt
            ),
            into: store
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: String(repeating: "7", count: 64),
            byteSize: Wire.version,
            originalExtension: "txt",
            managedRelativePath: "blobs/t-mutation-restore-727.txt"
        )).blob
        _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: Wire.restoreDocumentID,
            matterID: Wire.restoreID,
            blobID: blob.id,
            displayName: "T_MUTATION_RESTORE_DOCUMENT_883.txt",
            importedAt: Wire.timestamp,
            createdAt: Wire.timestamp,
            updatedAt: deletedAt,
            deletedAt: deletedAt
        ))
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_restore_failure
                BEFORE UPDATE OF deleted_at ON matter_documents
                WHEN OLD.id = '\(Wire.restoreDocumentID)' AND NEW.deleted_at IS NULL
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.restoreFailure)');
                END
                """)
        }
        let controller = RecycleBinController(store: store)
        controller.reload()
        XCTAssertEqual(controller.matters.map(\.id), [Wire.restoreID])

        let outcome = controller.attemptRestoreMatter(id: Wire.restoreID)

        try assertRejected(
            outcome,
            operation: .recycleRestore,
            marker: Wire.restoreFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, outcome.failure)
        XCTAssertEqual(controller.matters.map(\.id), [Wire.restoreID])
        XCTAssertEqual(
            try store.matters.fetchSoftDeletedMatters().map(\.id),
            [Wire.restoreID]
        )
        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: Wire.restoreDocumentID)?.deletedAt,
            deletedAt
        )
    }

    /// Settings autosave retains the candidate value after Store failure, while
    /// authoritative persisted defaults remain at N. Credential failure likewise
    /// cannot synthesize a configured/success state.
    func testSettingsAndCredentialFailuresRetainCandidateWithoutFalseConfiguration() throws {
        let store = try SupraStore.inMemory()
        var original = GenerationOptions()
        original.temperature = Wire.originalTemperature
        original.maxOutputTokens = 731
        try store.appSettings.setSetting(
            SettingsController.generationDefaultsKey,
            value: original
        )
        let controller = SettingsController(
            store: store,
            tokenStore: FailingMutationTokenStore(marker: Wire.keyFailure)
        )
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_settings_failure
                BEFORE UPDATE ON app_settings
                WHEN NEW.key = '\(SettingsController.generationDefaultsKey)'
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.settingsFailure)');
                END
                """)
        }

        let settingsOutcome = controller.attemptSetTemperature(Wire.settingsInput)

        try assertRejected(
            settingsOutcome,
            operation: .settingsPersist,
            marker: Wire.settingsFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, settingsOutcome.failure)
        XCTAssertEqual(controller.temperature, Wire.settingsInput, accuracy: 0.0001)
        let persisted = try XCTUnwrap(store.appSettings.getSetting(
            SettingsController.generationDefaultsKey,
            as: GenerationOptions.self
        ))
        XCTAssertEqual(persisted.temperature, Wire.originalTemperature, accuracy: 0.0001)
        XCTAssertEqual(persisted.maxOutputTokens, 731)

        let keyOutcome = controller.attemptSaveAPIKey(
            Wire.keyInput,
            for: .govInfo
        )

        try assertRejected(
            keyOutcome,
            operation: .credentialSave,
            marker: Wire.keyFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, keyOutcome.failure)
        XCTAssertFalse(controller.hasAPIKey(.govInfo))
        XCTAssertFalse(controller.configuredAPIKeys.contains(.govInfo))
        XCTAssertFalse(keyOutcome.failure?.userMessage.contains(Wire.keyInput) ?? true)
    }

    /// Import enqueue is an aggregate. The injected N+1 job insert failure occurs
    /// after batch/source writes; the whole initiation must compensate or roll back.
    func testImportInitiationFailureLeavesNoPartialBatchAndRetainsFolderSelection() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TMutationImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourceURL = base.appendingPathComponent("T_MUTATION_IMPORT_SOURCE_887.txt")
        try Wire.importSourceText.write(to: sourceURL, atomically: true, encoding: .utf8)

        let store = try SupraStore.inMemory()
        try insertMatter(
            MatterRecord(
                id: Wire.importMatterID,
                name: "T_MUTATION_IMPORT_MATTER_889",
                jurisdiction: "Synthetic Import Jurisdiction 17",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            ),
            into: store
        )
        let folder = try store.documentLibrary.ensureFolder(
            matterID: Wire.importMatterID,
            name: "T_MUTATION_SELECTED_FOLDER_907"
        )
        let storage = DocumentStorage(root: base.appendingPathComponent("Managed"))
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: {
                DocumentIndexingService(store: store, embedder: nil)
            },
            notifier: MutationNoopNotifier()
        )
        let controller = MatterDocumentsController(
            matterID: Wire.importMatterID,
            store: store,
            queue: queue,
            isImportReady: { true },
            storage: storage
        )
        controller.selectedSidebarID = folder.id
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_import_failure
                BEFORE INSERT ON document_processing_jobs
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.importFailure)');
                END
                """)
        }

        let outcome = controller.attemptImportItems(
            [sourceURL],
            targetFolderID: folder.id
        )

        try assertRejected(
            outcome,
            operation: .importStart,
            marker: Wire.importFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, outcome.failure)
        XCTAssertEqual(controller.selectedSidebarID, folder.id)
        XCTAssertEqual(controller.selectedFolderID, folder.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(
            try store.documentJobs.fetchBatches(matterID: Wire.importMatterID).isEmpty
        )
        XCTAssertTrue(
            try store.documentJobs.fetchJobs(matterID: Wire.importMatterID).isEmpty
        )
        XCTAssertTrue(try store.documentLibrary.fetchDocuments(matterID: Wire.importMatterID).isEmpty)
    }

    /// The existing export service supplies the file/Store fault seam. The
    /// controller must convert that failure to the same typed user outcome and
    /// must not announce success for a compensated file installation.
    func testExportFailurePreservesPriorArtifactAndSuppressesSuccess() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TMutationExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try SupraStore.inMemory()
        try insertMatter(
            MatterRecord(
                id: Wire.exportMatterID,
                name: "T_MUTATION_EXPORT_MATTER_911",
                jurisdiction: "Synthetic Export Jurisdiction 19",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            ),
            into: store
        )
        let output = try store.structuredOutputs.createOutput(
            matterID: Wire.exportMatterID,
            title: Wire.exportTitle,
            outputType: .documentQA,
            status: .complete
        )
        _ = try createExportableVersion(store: store, outputID: output.id)
        let storage = DocumentStorage(root: base.appendingPathComponent("Managed"))
        let destination = storage.exportsDirectory(forMatterID: Wire.exportMatterID)
            .appendingPathComponent("T-Mutation-Export-773-v7.md")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let canary = Data(Wire.exportCanary.utf8)
        try canary.write(to: destination)
        let exporter = DocumentExportService(
            store: store,
            storage: storage,
            completionRecorder: { _, _ in
                throw InjectedMutationError(Wire.exportFailure)
            }
        )
        let controller = StructuredOutputController(
            store: store,
            runtimeClient: StubRuntimeClient(),
            matterID: Wire.exportMatterID,
            exportAction: { outputID, format in
                try exporter.export(
                    matterID: Wire.exportMatterID,
                    structuredOutputID: outputID,
                    format: format
                )
            }
        )
        controller.loadOutputs()
        XCTAssertEqual(controller.outputs.map(\.id), [output.id])

        let outcome = controller.attemptExportOutput(
            outputID: output.id,
            format: .markdown
        )

        try assertRejected(
            outcome,
            operation: .export,
            marker: Wire.exportFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, outcome.failure)
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertTrue(
            try store.documentSources.fetchExports(structuredOutputID: output.id).isEmpty
        )
        XCTAssertFalse(
            try store.auditEvents.fetchEvents(matterID: Wire.exportMatterID).contains {
                $0.eventType == "export_completed"
            }
        )
        XCTAssertEqual(controller.outputs.map(\.id), [output.id])
    }

    /// Saving a research plan is route-dependent in the app. An N+1 query write
    /// failure must remove/roll back the preceding session row, keep the exact
    /// draft and planned query, and deny navigation to a nonexistent session.
    func testRouteDependentSaveFailureKeepsPlanAndLeavesNoPartialSession() throws {
        let store = try SupraStore.inMemory()
        try insertMatter(
            MatterRecord(
                id: Wire.researchMatterID,
                name: "T_MUTATION_RESEARCH_MATTER_919",
                jurisdiction: "Synthetic Research Jurisdiction 23",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            ),
            into: store
        )
        try resolveResearchCourtFixture(store: store, matterID: Wire.researchMatterID)
        let controller = ResearchSessionController(
            store: store,
            runtimeClient: StubRuntimeClient(),
            matterID: Wire.researchMatterID
        )
        controller.addQuery()
        let queryID = try XCTUnwrap(controller.plannedQueries.first?.id)
        controller.updateText(Wire.researchQuery, for: queryID)
        let draft = ResearchPlanDraft(
            title: Wire.researchTitle,
            issueText: "T_MUTATION_RESEARCH_ISSUE_929",
            jurisdiction: "Synthetic Research Jurisdiction 23",
            partyPerspective: "synthetic-respondent-931"
        )
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_route_save_failure
                BEFORE INSERT ON research_queries
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.routeSaveFailure)');
                END
                """)
        }

        let outcome = controller.attemptSavePlan(draft: draft)

        try assertRejected(
            outcome,
            operation: .routeDependentSave,
            marker: Wire.routeSaveFailure
        )
        XCTAssertEqual(controller.lastMutationFailure, outcome.failure)
        XCTAssertEqual(controller.plannedQueries.count, 1)
        XCTAssertEqual(controller.plannedQueries.first?.id, queryID)
        XCTAssertEqual(controller.plannedQueries.first?.text, Wire.researchQuery)
        XCTAssertEqual(controller.plannedQueries.first?.approved, true)
        XCTAssertEqual(draft.title, Wire.researchTitle)
        XCTAssertEqual(draft.partyPerspective, "synthetic-respondent-931")
        XCTAssertTrue(try store.research.fetchSessions(matterID: Wire.researchMatterID).isEmpty)
        XCTAssertTrue(controller.sessions.isEmpty)
        XCTAssertNil(outcome.committedValue)
        XCTAssertFalse(outcome.allowsDependentNavigation)
    }

    // MARK: - Assertions and fixtures

    private func resolveResearchCourtFixture(
        store: SupraStore,
        matterID: String
    ) throws {
        let snapshot = try XCTUnwrap(
            try store.matterIdentity.fetchSnapshot(matterID: matterID)
        )
        let catalog = JurisdictionCatalog.shared
        let court = try XCTUnwrap(
            catalog.resolvePersistedCourtIdentity(
                "United States District Court for the Southern District of Florida"
            )
        )
        let jurisdiction = try XCTUnwrap(
            catalog.canonicalJurisdictionOption(forSelectedOptionID: court.id)
        )
        _ = try store.matterIdentity.updateMatter(
            command: MatterIdentityUpdateCommand(
                matterID: matterID,
                expectedIdentityRevision: snapshot.identityRevision,
                legacyJurisdictionText: snapshot.legacyJurisdictionText,
                legacyCourtText: court.displayName,
                legacyPartyPerspective: .neutral,
                legacyClientNames: nil,
                courtResolutionState: .court,
                canonicalCatalogVersion: catalog.catalogVersion,
                canonicalCatalogDigestSHA256: catalog.identityDigestSHA256,
                canonicalJurisdictionID: CanonicalJurisdictionID(rawValue: jurisdiction.id),
                canonicalCourtID: CanonicalCourtID(rawValue: court.id),
                parties: snapshot.parties,
                representations: snapshot.representations
            )
        )
    }

    @discardableResult
    private func assertRejected<Success>(
        _ outcome: UserMutationOutcome<Success>,
        operation: UserMutationOperation,
        marker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UserMutationFailure {
        XCTAssertFalse(outcome.didCommit, file: file, line: line)
        XCTAssertNil(outcome.committedValue, file: file, line: line)
        XCTAssertFalse(outcome.allowsSuccessPresentation, file: file, line: line)
        XCTAssertFalse(outcome.allowsDependentNavigation, file: file, line: line)
        let failure = try XCTUnwrap(outcome.failure, file: file, line: line)
        XCTAssertEqual(failure.operation, operation, file: file, line: line)
        XCTAssertTrue(
            failure.userMessage.contains(marker),
            "the exact non-default injected failure must reach presentation",
            file: file,
            line: line
        )
        XCTAssertFalse(
            failure.userMessage.contains(Wire.forbiddenDefault),
            file: file,
            line: line
        )
        XCTAssertTrue(
            failure.recoveryActions.contains(.retry),
            "the surfaced failure must offer an accessible retry",
            file: file,
            line: line
        )
        return failure
    }

    private var defaultsSuiteName: String {
        "ArchitectureUXTMutation01Tests.manual.\(Wire.recordID)"
    }

    private func makeManualSortDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(MatterSortMode.manual.rawValue, forKey: "supra.matterSortMode")
        return defaults
    }

    private func insertMatter(_ matter: MatterRecord, into store: SupraStore) throws {
        try store.database.writer.write { db in try matter.insert(db) }
    }

    private func installMatterFailureTriggers(in store: SupraStore) throws {
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_matter_create_failure
                BEFORE INSERT ON matters
                WHEN NEW.name = '\(Wire.createInput)'
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.createFailure)');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_matter_edit_failure
                BEFORE UPDATE OF name ON matters
                WHEN OLD.id = '\(Wire.recordID)' AND NEW.name = '\(Wire.editInput)'
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.editFailure)');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_matter_delete_failure
                BEFORE UPDATE OF deleted_at ON matters
                WHEN OLD.id = '\(Wire.recordID)' AND NEW.deleted_at IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.deleteFailure)');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_matter_pin_failure
                BEFORE UPDATE OF pinned_at ON matters
                WHEN OLD.id = '\(Wire.recordID)' AND NEW.pinned_at IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.pinFailure)');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER t_mutation_matter_reorder_failure
                BEFORE UPDATE OF sort_order ON matters
                WHEN NEW.sort_order IS NOT OLD.sort_order
                BEGIN
                    SELECT RAISE(ABORT, '\(Wire.reorderFailure)');
                END
                """)
        }
    }

    private func createExportableVersion(
        store: SupraStore,
        outputID: String
    ) throws -> StructuredOutputVersionRecord {
        let support = try PropositionSupportResult(
            propositionID: "t-mutation-export-proposition-937",
            status: .supported,
            reasons: [],
            evidence: [SupportEvidence(
                sourceID: "t-mutation-export-source-941",
                sourceLabel: "S7",
                locator: "synthetic:t-mutation:7",
                retainedExcerpt: "T_MUTATION_EXPORT_EVIDENCE_947",
                verifierName: "ArchitectureUXTMutation01Tests",
                verifierVersion: "t-mutation-01-v7"
            )],
            timestamp: Wire.timestamp
        )
        return try store.structuredOutputs.createVersion(
            structuredOutputID: outputID,
            versionIndex: Wire.version,
            contentMarkdown: "T_MUTATION_EXPORTED_CONTENT_953 [S7].",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "t-mutation-01-v7",
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

private struct InjectedMutationError: LocalizedError {
    let marker: String

    init(_ marker: String) {
        self.marker = marker
    }

    var errorDescription: String? { marker }
}

private final class FailingMutationTokenStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let marker: String

    init(marker: String) {
        self.marker = marker
    }

    func saveCourtListenerToken(_ token: String) throws {
        throw InjectedMutationError(marker)
    }

    func loadCourtListenerToken() throws -> String? { nil }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { false }

    func saveAPIKey(_ key: String, for service: APIKeyService) throws {
        throw InjectedMutationError(marker)
    }

    func loadAPIKey(for service: APIKeyService) throws -> String? { nil }
    func deleteAPIKey(for service: APIKeyService) throws {}
    func hasAPIKey(for service: APIKeyService) throws -> Bool { false }
}

private final class MutationNoopNotifier: DocumentNotifying, @unchecked Sendable {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {}
}
