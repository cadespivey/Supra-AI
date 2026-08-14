import Foundation
import GRDB
import SupraCore
import SupraResearch
import SupraRuntimeInterface
import SupraStore
@testable import SupraSessions
import XCTest

/// Shared non-default wire for T-PUB-WORK-01 and T-AUTH-02. These values are
/// conspicuous by design: every terminal identity is asserted exactly and the
/// unrelated default canary is asserted absent from the scoped output element.
enum ArchitectureUXStructuredWorkWire {
    static let canonicalWire = "T_PUB_WORK_01_WIRE_731"
    static let forbiddenDefault = "DEFAULT-000"
    static let matterID = "record-713"
    static let version = 7
    static let nextVersion = 8
    static let outputID = "structured-work-output-719"
    static let initialKey = "structured-work-initial-727"
    static let repairKey = "structured-work-repair-733"
    static let controllerKey = "structured-work-controller-739"
    static let initialSourceSetID = "structured-work-source-set-743"
    static let repairSourceSetID = "structured-work-source-set-751"
    static let initialSourceID = "structured-work-source-757"
    static let repairSourceID = "structured-work-source-761"
    static let initialGenerationID = "structured-work-generation-769"
    static let repairGenerationID = "structured-work-generation-773"
    static let initialAuditID = "structured-work-audit-787"
    static let repairAuditID = "structured-work-audit-797"
    static let initialContent = "# T_PUB_WORK_01_WIRE_731\n\nRetained synthetic analysis at version 7."
    static let repairContent = "# T_PUB_WORK_01_WIRE_731 REPAIR\n\nRepaired synthetic analysis at version 8."
    static let alteredContent = "# ALTERED_T_PUB_WORK_01_821\n\nThis retry must be rejected."
    static let controllerInput = "T_PUB_WORK_01_WIRE_731 RETAINED INSTRUCTIONS 823"
    static let publicationEvent = "structured_work_product_published"
    static let promptBuilderVersion = "structured-work-builder-v7"
    static let initialTitle = "T_PUB_WORK_01_WIRE_731 Synthetic structured work"
    static let injectedFailurePrefix = "T_PUB_WORK_01_FAILURE"
    static let timestamp = Date(timeIntervalSince1970: 1_946_420_713)
}

/// T-PUB-WORK-01 — both an initial work product and every repaired version use
/// the existing `createVersionWithSourceSetAtomically` repository boundary.
/// The output/version, source set/rows, terminal generation, active selection,
/// normative audit, and content-free idempotency receipt are one transaction.
///
/// Expected RED: the existing overload accepts loose version fields and returns
/// only `StructuredOutputVersionRecord`; it has no typed aggregate command,
/// terminal generation/audit members, publication receipt/digest, or exact
/// retry identity. `StructuredOutputController` still creates the output,
/// source set, version, and audit in separate writes and swallows audit failure.
@MainActor
final class ArchitectureUXTPubWork01Tests: XCTestCase {
    func testInitialPublicationFaultAtEveryBoundaryLeavesNoPartialAggregate() throws {
        for boundary in AggregateWriteBoundary.allCases {
            let fixture = try ArchitectureUXStructuredWorkFixture.make()
            let before = try snapshot(fixture, command: fixture.initialCommand)
            try installFailureTrigger(
                boundary,
                fixture: fixture,
                command: fixture.initialCommand
            )

            XCTAssertThrowsError(
                try fixture.store.structuredOutputs.createVersionWithSourceSetAtomically(
                    fixture.initialCommand
                ),
                "T-PUB-WORK-01 must observe the injected initial \(boundary.rawValue) failure"
            ) { error in
                XCTAssertNotNil(
                    error as? StructuredWorkProductPublicationError,
                    "the repository must surface a typed publication failure"
                )
            }
            XCTAssertEqual(
                try snapshot(fixture, command: fixture.initialCommand),
                before,
                "initial \(boundary.rawValue) failure must roll back every aggregate owner"
            )
            try assertNoPublication(fixture, command: fixture.initialCommand)
        }
    }

    func testRepairPublicationFaultAtEveryBoundaryKeepsPriorVersionActive() throws {
        for boundary in AggregateWriteBoundary.allCases where boundary.appliesToRepair {
            let fixture = try ArchitectureUXStructuredWorkFixture.make()
            let initial = try fixture.store.structuredOutputs
                .createVersionWithSourceSetAtomically(fixture.initialCommand)
            let repair = try fixture.repairCommand(parentVersionID: initial.versionID)
            let before = try snapshot(fixture, command: repair)
            try installFailureTrigger(boundary, fixture: fixture, command: repair)

            XCTAssertThrowsError(
                try fixture.store.structuredOutputs.createVersionWithSourceSetAtomically(repair),
                "T-PUB-WORK-01 must observe the injected repair \(boundary.rawValue) failure"
            ) { error in
                XCTAssertNotNil(error as? StructuredWorkProductPublicationError)
            }
            XCTAssertEqual(
                try snapshot(fixture, command: repair),
                before,
                "repair \(boundary.rawValue) failure must preserve the exact prior active version"
            )
            let output = try XCTUnwrap(
                fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                    .first { $0.id == fixture.output.id }
            )
            XCTAssertEqual(output.activeVersionID, initial.versionID)
            XCTAssertFalse(
                try fixture.store.structuredOutputs
                    .fetchVersions(structuredOutputID: fixture.output.id)
                    .contains { $0.contentMarkdown.contains("T_PUB_WORK_01_WIRE_731 REPAIR") }
            )
            try assertNoPublication(fixture, command: repair)
        }
    }

    func testInitialAndRepairPublishExactTerminalAggregatesThroughExistingAPI() throws {
        let fixture = try ArchitectureUXStructuredWorkFixture.make()
        XCTAssertEqual(fixture.matter.id, "record-713")

        let initial: StructuredWorkProductPublicationReceipt = try fixture.store
            .structuredOutputs.createVersionWithSourceSetAtomically(fixture.initialCommand)
        try assertPublished(fixture, command: fixture.initialCommand, receipt: initial)
        XCTAssertEqual(initial.versionIndex, 7)
        XCTAssertNil(initial.acceptedResearchPacketVersionID)
        XCTAssertNil(initial.acceptedResearchPacketAggregateDigestSHA256)

        let repairCommand = try fixture.repairCommand(parentVersionID: initial.versionID)
        let repair: StructuredWorkProductPublicationReceipt = try fixture.store
            .structuredOutputs.createVersionWithSourceSetAtomically(repairCommand)
        try assertPublished(fixture, command: repairCommand, receipt: repair)
        XCTAssertEqual(repair.versionIndex, 8)
        XCTAssertEqual(
            repair.versionIndex,
            initial.versionIndex + 1,
            "the non-default N=7 publication must advance atomically to N+1=8"
        )
        XCTAssertNotEqual(repair.versionID, initial.versionID)
        XCTAssertNotEqual(repair.sourceSetID, initial.sourceSetID)
        XCTAssertNotEqual(repair.generationSessionID, initial.generationSessionID)

        let versions = try fixture.store.structuredOutputs
            .fetchVersions(structuredOutputID: fixture.output.id)
            .sorted { $0.versionIndex < $1.versionIndex }
        XCTAssertEqual(versions.map(\.id), [initial.versionID, repair.versionID])
        XCTAssertEqual(versions.map(\.parentVersionID), [nil, initial.versionID])
        XCTAssertEqual(versions.map(\.contentMarkdown), [
            ArchitectureUXStructuredWorkWire.initialContent,
            ArchitectureUXStructuredWorkWire.repairContent,
        ])
        let persistedInitial = try XCTUnwrap(versions.first { $0.id == initial.versionID })
        let persistedRepair = try XCTUnwrap(versions.first { $0.id == repair.versionID })
        XCTAssertTrue(persistedInitial.contentMarkdown.contains("T_PUB_WORK_01_WIRE_731"))
        XCTAssertFalse(persistedInitial.contentMarkdown.contains("DEFAULT-000"))
        XCTAssertTrue(persistedRepair.contentMarkdown.contains("T_PUB_WORK_01_WIRE_731"))
        XCTAssertFalse(persistedRepair.contentMarkdown.contains("DEFAULT-000"))
        XCTAssertEqual(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                .first { $0.id == fixture.output.id }?.activeVersionID,
            repair.versionID
        )
    }

    func testExactRetryIsIdempotentAndAlteredRetryRejectsWithoutMutation() throws {
        let fixture = try ArchitectureUXStructuredWorkFixture.make()
        let first: StructuredWorkProductPublicationReceipt = try fixture.store
            .structuredOutputs.createVersionWithSourceSetAtomically(fixture.initialCommand)
        let completed = try snapshot(fixture, command: fixture.initialCommand)

        let exactRetry: StructuredWorkProductPublicationReceipt = try fixture.store
            .structuredOutputs.createVersionWithSourceSetAtomically(fixture.initialCommand)
        XCTAssertEqual(exactRetry, first)
        XCTAssertEqual(
            try snapshot(fixture, command: fixture.initialCommand),
            completed,
            "an exact retry must return the stored receipt without another row or timestamp"
        )

        let altered = fixture.command(
            copying: fixture.initialCommand,
            contentMarkdown: ArchitectureUXStructuredWorkWire.alteredContent
        )
        XCTAssertThrowsError(
            try fixture.store.structuredOutputs.createVersionWithSourceSetAtomically(altered)
        ) { error in
            XCTAssertEqual(
                error as? StructuredWorkProductPublicationError,
                .idempotencyConflict(ArchitectureUXStructuredWorkWire.initialKey)
            )
        }
        XCTAssertEqual(
            try snapshot(fixture, command: fixture.initialCommand),
            completed,
            "an altered retry cannot replace or duplicate any terminal member"
        )
        let active = try XCTUnwrap(
            fixture.store.structuredOutputs
                .fetchVersions(structuredOutputID: fixture.output.id)
                .first { $0.id == first.versionID }
        )
        XCTAssertTrue(active.contentMarkdown.contains(ArchitectureUXStructuredWorkWire.canonicalWire))
        XCTAssertFalse(active.contentMarkdown.contains("ALTERED_T_PUB_WORK_01_821"))
        XCTAssertFalse(active.contentMarkdown.contains(ArchitectureUXStructuredWorkWire.forbiddenDefault))
    }

    func testControllerPublicationFailureRetainsInstructionsAndOffersExactRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArchitectureUXTPubWorkController-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SupraStore(url: root.appendingPathComponent("test.sqlite"))
        let identity = try seedArchitectureUXIdentityMatter(
            store: store,
            matterID: ArchitectureUXStructuredWorkWire.matterID,
            state: .court,
            legacyJurisdiction: "LEGACY-WORK-JURISDICTION-829",
            legacyCourt: "LEGACY-WORK-COURT-839"
        )
        XCTAssertEqual(identity.matterID, ArchitectureUXStructuredWorkWire.matterID)
        let contract = try XCTUnwrap(
            StructuredOutputContracts.contract(for: .draftingSkeleton)
        )
        let response = contract.requiredHeadings
            .map { "\($0)\n\nT_PUB_WORK_01_GENERATED_853" }
            .joined(separator: "\n\n")
        let probe = StructuredWorkRuntimeProbe(response: response)
        let controller = StructuredOutputController(
            store: store,
            runtimeClient: probe.runtime,
            matterID: ArchitectureUXStructuredWorkWire.matterID
        )
        let request = StructuredWorkProductCreationRequest(
            idempotencyKey: ArchitectureUXStructuredWorkWire.controllerKey,
            type: .draftingSkeleton,
            instructionsAndFacts: ArchitectureUXStructuredWorkWire.controllerInput,
            publicationMode: .ordinary,
            acceptedResearchPacket: nil
        )
        try await store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER t_pub_work_controller_audit_failure
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = '\(ArchitectureUXStructuredWorkWire.publicationEvent)'
                BEGIN
                    SELECT RAISE(ABORT, 'T_PUB_WORK_01_CONTROLLER_FAILURE_857');
                END
                """)
        }
        let before = try matterMutationSnapshot(
            store,
            matterID: ArchitectureUXStructuredWorkWire.matterID
        )

        let result = await controller.createWorkProduct(
            request,
            modelID: ModelID(),
            route: nil
        )

        XCTAssertFalse(result.didPublish)
        XCTAssertNil(result.receipt)
        XCTAssertEqual(result.retainedRequest, request)
        XCTAssertEqual(controller.retainedWorkProductRequest, request)
        let failure = try XCTUnwrap(result.failure)
        XCTAssertEqual(failure.operation, .structuredWorkProductPublication)
        XCTAssertTrue(failure.userMessage.contains("T_PUB_WORK_01_CONTROLLER_FAILURE_857"))
        XCTAssertFalse(failure.userMessage.contains(ArchitectureUXStructuredWorkWire.forbiddenDefault))
        XCTAssertTrue(failure.recoveryActions.contains(.retry))
        XCTAssertEqual(
            try matterMutationSnapshot(
                store,
                matterID: ArchitectureUXStructuredWorkWire.matterID
            ),
            before,
            "controller failure must not leave an output, version, source set, generation, receipt, or audit"
        )
        let prompts = probe.prompts
        XCTAssertEqual(prompts.count, 1, "the injected failure occurs after one completed model sample")
        let exactPrompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(exactPrompt.contains(ArchitectureUXStructuredWorkWire.controllerInput))
        XCTAssertFalse(exactPrompt.contains(ArchitectureUXStructuredWorkWire.forbiddenDefault))
    }

    // MARK: - Exact aggregate assertions

    private func assertPublished(
        _ fixture: ArchitectureUXStructuredWorkFixture,
        command: StructuredWorkProductPublicationCommand,
        receipt: StructuredWorkProductPublicationReceipt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(receipt.publicationMode, command.publicationMode, file: file, line: line)
        XCTAssertEqual(receipt.idempotencyKey, command.idempotencyKey, file: file, line: line)
        XCTAssertEqual(receipt.matterID, fixture.matter.id, file: file, line: line)
        XCTAssertEqual(receipt.structuredOutputID, fixture.output.id, file: file, line: line)
        XCTAssertEqual(receipt.sourceSetID, command.sourceSet.id, file: file, line: line)
        XCTAssertEqual(receipt.generationSessionID, command.generationSession.id, file: file, line: line)
        XCTAssertEqual(receipt.auditEventID, command.auditEvent.id, file: file, line: line)
        XCTAssertEqual(receipt.aggregateDigestSHA256.count, 64, file: file, line: line)
        XCTAssertNotEqual(receipt.aggregateDigestSHA256, String(repeating: "0", count: 64), file: file, line: line)
        XCTAssertFalse(receipt.aggregateDigestSHA256.contains(ArchitectureUXStructuredWorkWire.forbiddenDefault), file: file, line: line)

        let persistedReceipt = try XCTUnwrap(
            fixture.store.structuredOutputs.fetchWorkProductPublication(
                idempotencyKey: command.idempotencyKey
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(persistedReceipt, receipt, file: file, line: line)
        let output = try XCTUnwrap(
            fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matter.id)
                .first { $0.id == fixture.output.id },
            file: file,
            line: line
        )
        XCTAssertEqual(output.activeVersionID, receipt.versionID, file: file, line: line)
        XCTAssertEqual(output.status, command.outputStatus.rawValue, file: file, line: line)
        let version = try XCTUnwrap(
            fixture.store.structuredOutputs
                .fetchVersions(structuredOutputID: fixture.output.id)
                .first { $0.id == receipt.versionID },
            file: file,
            line: line
        )
        XCTAssertEqual(version.versionIndex, receipt.versionIndex, file: file, line: line)
        XCTAssertEqual(version.versionIndex, command.versionIndex, file: file, line: line)
        XCTAssertEqual(version.parentVersionID, command.parentVersionID, file: file, line: line)
        XCTAssertEqual(version.contentMarkdown, command.contentMarkdown, file: file, line: line)
        XCTAssertEqual(version.generationSessionID, command.generationSession.id, file: file, line: line)
        XCTAssertEqual(version.repairReason, command.repairReason, file: file, line: line)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(version.requiredSectionsJSON.utf8)),
            command.requiredSections,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(version.presentSectionsJSON.utf8)),
            command.presentSections,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(version.missingSectionsJSON.utf8)),
            command.missingSections,
            file: file,
            line: line
        )
        XCTAssertFalse(version.contentMarkdown.contains(ArchitectureUXStructuredWorkWire.forbiddenDefault), file: file, line: line)

        let sourceSet = try XCTUnwrap(
            fixture.store.documentSources.fetchSourceSet(id: command.sourceSet.id),
            file: file,
            line: line
        )
        XCTAssertEqual(sourceSet.status, DocumentSourceSetStatus.attached.rawValue, file: file, line: line)
        XCTAssertEqual(sourceSet.structuredOutputVersionID, receipt.versionID, file: file, line: line)
        let sources = try fixture.store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(sources.map(\.id), command.orderedSources.map(\.id), file: file, line: line)
        XCTAssertTrue(sources.allSatisfy { $0.structuredOutputVersionID == receipt.versionID }, file: file, line: line)

        let generation = try XCTUnwrap(
            fixture.store.generation.fetchGenerationSession(
                generationID: command.generationSession.id
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(generation.status, MessageStatus.completed.rawValue, file: file, line: line)
        XCTAssertEqual(generation.promptBuilderVersion, ArchitectureUXStructuredWorkWire.promptBuilderVersion, file: file, line: line)
        XCTAssertEqual(generation.generatedTokenCount, command.generationSession.generatedTokenCount, file: file, line: line)
        XCTAssertFalse(generation.prompt.contains(ArchitectureUXStructuredWorkWire.forbiddenDefault), file: file, line: line)

        let audits = try fixture.store.auditEvents.fetchEvents(
            relatedTable: "structured_outputs",
            relatedID: fixture.output.id,
            eventType: ArchitectureUXStructuredWorkWire.publicationEvent
        )
        XCTAssertTrue(audits.contains { $0.id == command.auditEvent.id }, file: file, line: line)
        XCTAssertFalse(
            (audits.first { $0.id == command.auditEvent.id }?.metadataJSON ?? "")
                .contains(command.contentMarkdown),
            "normative audit metadata must remain content-free",
            file: file,
            line: line
        )
    }

    private func assertNoPublication(
        _ fixture: ArchitectureUXStructuredWorkFixture,
        command: StructuredWorkProductPublicationCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(
            try fixture.store.structuredOutputs.fetchWorkProductPublication(
                idempotencyKey: command.idempotencyKey
            ),
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.documentSources.fetchSourceSet(id: command.sourceSet.id),
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.generation.fetchGenerationSession(
                generationID: command.generationSession.id
            ),
            file: file,
            line: line
        )
        XCTAssertFalse(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "structured_outputs",
                relatedID: fixture.output.id,
                eventType: ArchitectureUXStructuredWorkWire.publicationEvent
            ).contains { $0.id == command.auditEvent.id },
            file: file,
            line: line
        )
    }

    private enum AggregateWriteBoundary: String, CaseIterable {
        case newOutput = "new-output"
        case sourceSet = "source-set"
        case sourceRow = "source-row"
        case generation = "terminal-generation"
        case version = "version"
        case audit = "normative-audit"
        case activeSelection = "active-selection"
        case receipt = "publication-receipt"

        var appliesToRepair: Bool { self != .newOutput }
    }

    private func installFailureTrigger(
        _ boundary: AggregateWriteBoundary,
        fixture: ArchitectureUXStructuredWorkFixture,
        command: StructuredWorkProductPublicationCommand
    ) throws {
        let marker = "\(ArchitectureUXStructuredWorkWire.injectedFailurePrefix)_\(boundary.rawValue)"
        let trigger = "t_pub_work_\(boundary.rawValue.replacingOccurrences(of: "-", with: "_"))"
        let table: String
        let timing: String
        let condition: String
        switch boundary {
        case .newOutput:
            table = "structured_outputs"
            timing = "BEFORE INSERT"
            condition = "NEW.id = '\(fixture.output.id)'"
        case .sourceSet:
            table = "document_source_sets"
            timing = "BEFORE INSERT"
            condition = "NEW.id = '\(command.sourceSet.id)'"
        case .sourceRow:
            table = "document_output_sources"
            timing = "BEFORE INSERT"
            condition = "NEW.source_set_id = '\(command.sourceSet.id)'"
        case .generation:
            table = "generation_sessions"
            timing = "BEFORE INSERT"
            condition = "NEW.id = '\(command.generationSession.id)'"
        case .version:
            table = "structured_output_versions"
            timing = "BEFORE INSERT"
            condition = "NEW.structured_output_id = '\(fixture.output.id)' AND NEW.content_markdown = '\(sqlLiteral(command.contentMarkdown))'"
        case .audit:
            table = "audit_events"
            timing = "BEFORE INSERT"
            condition = "NEW.id = '\(command.auditEvent.id)'"
        case .activeSelection:
            table = "structured_outputs"
            timing = "BEFORE UPDATE OF active_version_id"
            condition = "OLD.id = '\(fixture.output.id)' AND NEW.active_version_id IS NOT OLD.active_version_id"
        case .receipt:
            table = "structured_work_product_publications"
            timing = "BEFORE INSERT"
            condition = "NEW.idempotency_key = '\(command.idempotencyKey)'"
        }
        try fixture.store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER \(trigger)
                \(timing) ON \(table)
                WHEN \(condition)
                BEGIN
                    SELECT RAISE(ABORT, '\(marker)');
                END
                """)
        }
    }

    private func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - Shared publication fixture

struct ArchitectureUXStructuredWorkFixture: @unchecked Sendable {
    let store: SupraStore
    let matter: MatterRecord
    let output: StructuredOutputRecord
    let initialCommand: StructuredWorkProductPublicationCommand

    static func make() throws -> Self {
        let store = try SupraStore.inMemory()
        let matter = MatterRecord(
            id: ArchitectureUXStructuredWorkWire.matterID,
            name: "T_PUB_WORK_01_WIRE_731 Matter",
            jurisdiction: "Synthetic Publication Jurisdiction 17",
            notes: "Synthetic publication fixture only.",
            createdAt: ArchitectureUXStructuredWorkWire.timestamp,
            updatedAt: ArchitectureUXStructuredWorkWire.timestamp
        )
        try store.database.writer.write { db in try matter.insert(db) }
        guard matter.id == "record-713" else {
            throw ArchitectureUXStructuredWorkFixtureError.identityMismatch
        }
        let now = ArchitectureUXStructuredWorkWire.timestamp
        let output = StructuredOutputRecord(
            id: ArchitectureUXStructuredWorkWire.outputID,
            matterID: matter.id,
            title: ArchitectureUXStructuredWorkWire.initialTitle,
            outputType: StructuredOutputType.draftingSkeleton.rawValue,
            status: StructuredOutputStatus.draft.rawValue,
            createdAt: now,
            updatedAt: now
        )
        let sourceSet = DocumentSourceSetRecord(
            id: ArchitectureUXStructuredWorkWire.initialSourceSetID,
            matterID: matter.id,
            mode: DocumentSourceSetMode.guided.rawValue,
            scopeJSON: #"{"work_scope":"T_PUB_WORK_01_SCOPE_877"}"#,
            retrievalQuery: "T_PUB_WORK_01_QUERY_881",
            retrievalDepth: "structured-work-depth-7",
            createdAt: now
        )
        let source = DocumentOutputSourceRecord(
            id: ArchitectureUXStructuredWorkWire.initialSourceID,
            sourceSetID: sourceSet.id,
            citationLabel: "W17",
            locatorJSON: #"{"kind":"attorney_instructions","wire":"T_PUB_WORK_01_LOCATOR_883"}"#,
            excerpt: "T_PUB_WORK_01_WIRE_731 SOURCE EXCERPT 887",
            rank: 17,
            warningsJSON: #"{"provenance":"attorney_instruction_wire_17"}"#,
            createdAt: now
        )
        let generation = generationRecord(
            id: ArchitectureUXStructuredWorkWire.initialGenerationID,
            prompt: "T_PUB_WORK_01_WIRE_731 PROMPT 907",
            generatedTokenCount: 97,
            at: now
        )
        let audit = AuditEventRecord(
            id: ArchitectureUXStructuredWorkWire.initialAuditID,
            matterID: matter.id,
            timestamp: now,
            eventType: ArchitectureUXStructuredWorkWire.publicationEvent,
            actor: "runtime",
            summary: "Published T_PUB_WORK_01_WIRE_731 version 7",
            relatedTable: "structured_outputs",
            relatedID: output.id,
            metadataJSON: #"{"policy":"t-pub-work-01-v7","version_index":7}"#
        )
        let command = StructuredWorkProductPublicationCommand(
            publicationMode: .ordinary,
            idempotencyKey: ArchitectureUXStructuredWorkWire.initialKey,
            versionIndex: ArchitectureUXStructuredWorkWire.version,
            structuredOutputID: output.id,
            newOutput: output,
            sourceSet: sourceSet,
            orderedSources: [source],
            contentMarkdown: ArchitectureUXStructuredWorkWire.initialContent,
            requiredSections: ["# T_PUB_WORK_01_WIRE_731", "## Analysis 911"],
            presentSections: ["# T_PUB_WORK_01_WIRE_731"],
            missingSections: ["## Analysis 911"],
            parentVersionID: nil,
            repairReason: nil,
            verificationStatus: .legacyUnverified,
            verificationVersion: "structured-work-verifier-v7",
            verificationResults: [],
            verificationDimensions: nil,
            outputStatus: .needsReview,
            generationSession: generation,
            promptBuilderVersion: ArchitectureUXStructuredWorkWire.promptBuilderVersion,
            assuranceState: .supportNeedsReview,
            acceptedResearchPacket: nil,
            auditEvent: audit
        )
        return Self(store: store, matter: matter, output: output, initialCommand: command)
    }

    func repairCommand(parentVersionID: String) throws -> StructuredWorkProductPublicationCommand {
        let now = ArchitectureUXStructuredWorkWire.timestamp.addingTimeInterval(17)
        let sourceSet = DocumentSourceSetRecord(
            id: ArchitectureUXStructuredWorkWire.repairSourceSetID,
            matterID: matter.id,
            mode: DocumentSourceSetMode.guided.rawValue,
            scopeJSON: #"{"work_scope":"T_PUB_WORK_01_REPAIR_SCOPE_919"}"#,
            retrievalQuery: "T_PUB_WORK_01_REPAIR_QUERY_929",
            retrievalDepth: "structured-work-repair-depth-8",
            createdAt: now
        )
        let source = DocumentOutputSourceRecord(
            id: ArchitectureUXStructuredWorkWire.repairSourceID,
            sourceSetID: sourceSet.id,
            citationLabel: "W23",
            locatorJSON: #"{"kind":"attorney_instructions","wire":"T_PUB_WORK_01_REPAIR_LOCATOR_937"}"#,
            excerpt: "T_PUB_WORK_01_WIRE_731 REPAIR SOURCE EXCERPT 941",
            rank: 23,
            warningsJSON: #"{"provenance":"attorney_instruction_wire_23"}"#,
            createdAt: now
        )
        let generation = Self.generationRecord(
            id: ArchitectureUXStructuredWorkWire.repairGenerationID,
            prompt: "T_PUB_WORK_01_WIRE_731 REPAIR PROMPT 947",
            generatedTokenCount: 101,
            at: now
        )
        let audit = AuditEventRecord(
            id: ArchitectureUXStructuredWorkWire.repairAuditID,
            matterID: matter.id,
            timestamp: now,
            eventType: ArchitectureUXStructuredWorkWire.publicationEvent,
            actor: "runtime",
            summary: "Published T_PUB_WORK_01_WIRE_731 repair version 8",
            relatedTable: "structured_outputs",
            relatedID: output.id,
            metadataJSON: #"{"policy":"t-pub-work-01-v7","version_index":8,"repair":true}"#
        )
        return StructuredWorkProductPublicationCommand(
            publicationMode: .ordinary,
            idempotencyKey: ArchitectureUXStructuredWorkWire.repairKey,
            versionIndex: ArchitectureUXStructuredWorkWire.nextVersion,
            structuredOutputID: output.id,
            newOutput: nil,
            sourceSet: sourceSet,
            orderedSources: [source],
            contentMarkdown: ArchitectureUXStructuredWorkWire.repairContent,
            requiredSections: ["# T_PUB_WORK_01_WIRE_731 REPAIR", "## Analysis 953"],
            presentSections: ["# T_PUB_WORK_01_WIRE_731 REPAIR", "## Analysis 953"],
            missingSections: [],
            parentVersionID: parentVersionID,
            repairReason: "missing_required_sections_wire_17",
            verificationStatus: .legacyUnverified,
            verificationVersion: "structured-work-verifier-v8",
            verificationResults: [],
            verificationDimensions: nil,
            outputStatus: .needsReview,
            generationSession: generation,
            promptBuilderVersion: ArchitectureUXStructuredWorkWire.promptBuilderVersion,
            assuranceState: .supportNeedsReview,
            acceptedResearchPacket: nil,
            auditEvent: audit
        )
    }

    func command(
        copying command: StructuredWorkProductPublicationCommand,
        contentMarkdown: String
    ) -> StructuredWorkProductPublicationCommand {
        StructuredWorkProductPublicationCommand(
            publicationMode: command.publicationMode,
            idempotencyKey: command.idempotencyKey,
            versionIndex: command.versionIndex,
            structuredOutputID: command.structuredOutputID,
            newOutput: command.newOutput,
            sourceSet: command.sourceSet,
            orderedSources: command.orderedSources,
            contentMarkdown: contentMarkdown,
            requiredSections: command.requiredSections,
            presentSections: command.presentSections,
            missingSections: command.missingSections,
            parentVersionID: command.parentVersionID,
            repairReason: command.repairReason,
            verificationStatus: command.verificationStatus,
            verificationVersion: command.verificationVersion,
            verificationResults: command.verificationResults,
            verificationDimensions: command.verificationDimensions,
            outputStatus: command.outputStatus,
            generationSession: command.generationSession,
            promptBuilderVersion: command.promptBuilderVersion,
            assuranceState: command.assuranceState,
            acceptedResearchPacket: command.acceptedResearchPacket,
            auditEvent: command.auditEvent
        )
    }

    private static func generationRecord(
        id: String,
        prompt: String,
        generatedTokenCount: Int,
        at date: Date
    ) -> GenerationSessionRecord {
        GenerationSessionRecord(
            id: id,
            modelID: "structured-work-runtime-model-17",
            modelRepository: "synthetic/structured-work-model",
            modelRevision: "structured-work-revision-23",
            promptBuilderVersion: ArchitectureUXStructuredWorkWire.promptBuilderVersion,
            prompt: prompt,
            systemPrompt: "T_PUB_WORK_01_SYSTEM_967",
            optionsJSON: #"{"maxContextTokens":4097,"maxOutputTokens":977,"temperature":0.17}"#,
            status: MessageStatus.completed.rawValue,
            startedAt: date.addingTimeInterval(-3),
            firstTokenAt: date.addingTimeInterval(-2),
            completedAt: date,
            loadTimeMs: 317,
            firstTokenLatencyMs: 419,
            tokensPerSecond: 17.23,
            peakMemoryMb: 1_937,
            generatedTokenCount: generatedTokenCount,
            createdAt: date.addingTimeInterval(-3),
            updatedAt: date
        )
    }
}

private enum ArchitectureUXStructuredWorkFixtureError: Error {
    case identityMismatch
}

private struct ArchitectureUXWorkAggregateSnapshot: Equatable {
    var outputCount: Int
    var activeVersionID: String?
    var outputStatus: String?
    var outputUpdatedAt: Date?
    var versionCount: Int
    var versionIDs: [String]
    var versionContents: [String]
    var sourceSetCount: Int
    var sourceCount: Int
    var generationCount: Int
    var generationStatus: String?
    var auditCount: Int
    var receiptCount: Int
    var bindingCount: Int
}

private func snapshot(
    _ fixture: ArchitectureUXStructuredWorkFixture,
    command: StructuredWorkProductPublicationCommand
) throws -> ArchitectureUXWorkAggregateSnapshot {
    try fixture.store.database.writer.read { db in
        let output = try Row.fetchOne(
            db,
            sql: "SELECT active_version_id, status, updated_at FROM structured_outputs WHERE id = ?",
            arguments: [fixture.output.id]
        )
        return ArchitectureUXWorkAggregateSnapshot(
            outputCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM structured_outputs WHERE id = ?",
                arguments: [fixture.output.id]
            ) ?? -1,
            activeVersionID: output?["active_version_id"],
            outputStatus: output?["status"],
            outputUpdatedAt: output?["updated_at"],
            versionCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM structured_output_versions WHERE structured_output_id = ?",
                arguments: [fixture.output.id]
            ) ?? -1,
            versionIDs: try String.fetchAll(
                db,
                sql: "SELECT id FROM structured_output_versions WHERE structured_output_id = ? ORDER BY version_index, id",
                arguments: [fixture.output.id]
            ),
            versionContents: try String.fetchAll(
                db,
                sql: "SELECT content_markdown FROM structured_output_versions WHERE structured_output_id = ? ORDER BY version_index, id",
                arguments: [fixture.output.id]
            ),
            sourceSetCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_source_sets WHERE id = ?",
                arguments: [command.sourceSet.id]
            ) ?? -1,
            sourceCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_output_sources WHERE source_set_id = ?",
                arguments: [command.sourceSet.id]
            ) ?? -1,
            generationCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM generation_sessions WHERE id = ?",
                arguments: [command.generationSession.id]
            ) ?? -1,
            generationStatus: try String.fetchOne(
                db,
                sql: "SELECT status FROM generation_sessions WHERE id = ?",
                arguments: [command.generationSession.id]
            ),
            auditCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM audit_events WHERE id = ?",
                arguments: [command.auditEvent.id]
            ) ?? -1,
            receiptCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM structured_work_product_publications WHERE idempotency_key = ?",
                arguments: [command.idempotencyKey]
            ) ?? -1,
            bindingCount: try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM research_packet_work_product_bindings AS binding
                    JOIN structured_output_versions AS version
                      ON version.id = binding.structured_output_version_id
                    WHERE version.structured_output_id = ?
                    """,
                arguments: [fixture.output.id]
            ) ?? -1
        )
    }
}

struct ArchitectureUXMatterMutationSnapshot: Equatable {
    var outputs: Int
    var versions: Int
    var sourceSets: Int
    var sources: Int
    var generations: Int
    var audits: Int
    var publications: Int
    var bindings: Int
    var networkRequests: Int
}

func matterMutationSnapshot(
    _ store: SupraStore,
    matterID: String
) throws -> ArchitectureUXMatterMutationSnapshot {
    try store.database.writer.read { db in
        ArchitectureUXMatterMutationSnapshot(
            outputs: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM structured_outputs WHERE matter_id = ?",
                arguments: [matterID]
            ) ?? -1,
            versions: try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM structured_output_versions AS version
                    JOIN structured_outputs AS output ON output.id = version.structured_output_id
                    WHERE output.matter_id = ?
                    """,
                arguments: [matterID]
            ) ?? -1,
            sourceSets: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_source_sets WHERE matter_id = ?",
                arguments: [matterID]
            ) ?? -1,
            sources: try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM document_output_sources AS source
                    JOIN document_source_sets AS source_set ON source_set.id = source.source_set_id
                    WHERE source_set.matter_id = ?
                    """,
                arguments: [matterID]
            ) ?? -1,
            generations: try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM generation_sessions
                    WHERE id IN (
                        SELECT generation_session_id FROM structured_output_versions AS version
                        JOIN structured_outputs AS output ON output.id = version.structured_output_id
                        WHERE output.matter_id = ?
                    )
                    """,
                arguments: [matterID]
            ) ?? -1,
            audits: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM audit_events WHERE matter_id = ? AND event_type = ?",
                arguments: [matterID, ArchitectureUXStructuredWorkWire.publicationEvent]
            ) ?? -1,
            publications: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM structured_work_product_publications WHERE matter_id = ?",
                arguments: [matterID]
            ) ?? -1,
            bindings: try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM research_packet_work_product_bindings AS binding
                    JOIN structured_output_versions AS version
                      ON version.id = binding.structured_output_version_id
                    JOIN structured_outputs AS output
                      ON output.id = version.structured_output_id
                    WHERE output.matter_id = ?
                    """,
                arguments: [matterID]
            ) ?? -1,
            networkRequests: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM network_requests") ?? -1
        )
    }
}

final class StructuredWorkRuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPrompts: [String] = []
    let response: String

    init(response: String) {
        self.response = response
    }

    var prompts: [String] { lock.withLock { recordedPrompts } }

    var runtime: StubRuntimeClient {
        StubRuntimeClient { [self] request in
            lock.withLock { recordedPrompts.append(request.prompt) }
            return .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: response),
                .event(
                    request,
                    3,
                    .generationCompleted,
                    metrics: RuntimeMetrics(
                        loadTimeMs: 317,
                        firstTokenLatencyMs: 419,
                        tokensPerSecond: 17.23,
                        peakMemoryMb: 1_937,
                        generatedTokenCount: 101
                    )
                ),
            ])
        }
    }
}
