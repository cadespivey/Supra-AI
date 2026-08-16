import Foundation
import SupraCore
import SupraRuntimeInterface
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class ExistingUserRevalidationTests: XCTestCase {
    func testJourney4EditedSavedWorkCreatesARecheckedVersionAndPreservesTheOriginal() throws {
        // Journey 4 expected RED: StructuredOutputController has no owner-edit
        // boundary that creates a new immutable version and rechecks the exact
        // retained packet before making that version active.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic Edited Work")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: String(repeating: "e", count: 64),
            byteSize: 31,
            originalExtension: "txt",
            managedRelativePath: "blobs/ee/payment.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "synthetic-payment.txt",
            status: MatterDocumentStatus.ready.rawValue
        ))
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Payment terms",
            outputType: .documentQA,
            status: .complete
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource,
            retrievalQuery: "synthetic payment date"
        )
        try store.documentSources.addOutputSources([DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.id,
            chunkID: nil,
            citationLabel: "S1",
            locatorJSON: #"{"page":1}"#,
            excerpt: "Payment was due March 3, 2025.",
            rank: 0
        )])
        let originalText = "Payment was due March 3, 2025 [S1]."
        let originalSupport = try PropositionSupportResult(
            propositionID: "synthetic-payment-date",
            status: .supported,
            reasons: [],
            evidence: [SupportEvidence(
                sourceID: document.id,
                sourceLabel: "S1",
                locator: "page 1",
                retainedExcerpt: "Payment was due March 3, 2025.",
                verifierName: "ExistingUserRevalidationTests",
                verifierVersion: "journey-4-v1"
            )],
            timestamp: Date(timeIntervalSinceReferenceDate: 4)
        )
        let original = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: originalText,
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            verificationStatus: .allSupported,
            verificationVersion: "journey-4-v1",
            verificationResults: [originalSupport],
            verificationDimensions: VerificationDimensionsMapper.dimensions(
                verificationResults: [originalSupport]
            ),
            sourceSetID: sourceSet.id,
            assuranceState: .propositionSupported,
            outputStatus: .complete
        )
        let controller = StructuredOutputController(
            store: store,
            runtimeClient: StubRuntimeClient { request in
                .events([.event(request, 1, .generationCompleted)])
            },
            matterID: matter.id
        )
        let editedText = "Payment was due March 3, 2025 [S1].\n"

        XCTAssertTrue(
            controller.saveEditedVersion(outputID: output.id, contentMarkdown: editedText),
            controller.message ?? ""
        )

        let versions = try store.structuredOutputs.fetchVersions(
            structuredOutputID: output.id
        )
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.first { $0.id == original.id }?.contentMarkdown, originalText)
        let refreshedOutput = try XCTUnwrap(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).first
        )
        let edited = try XCTUnwrap(
            versions.first { $0.id == refreshedOutput.activeVersionID }
        )
        XCTAssertNotEqual(edited.id, original.id)
        XCTAssertEqual(edited.parentVersionID, original.id)
        XCTAssertEqual(edited.contentMarkdown, editedText)
        XCTAssertEqual(
            edited.verificationStatus,
            OutputVerificationStatus.allSupported.rawValue
        )
        XCTAssertFalse(edited.contentMarkdown == originalText)
        let clonedPacket = try XCTUnwrap(
            store.documentSources.fetchSourceSet(
                structuredOutputVersionID: edited.id
            )
        )
        XCTAssertNotEqual(clonedPacket.id, sourceSet.id)
        XCTAssertEqual(
            try store.documentSources.fetchSources(sourceSetID: clonedPacket.id)
                .map(\.citationLabel),
            ["S1"]
        )
    }

    func testACRRECOVERY005RetainedPacketReverificationPreservesLegacyVersion() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic Retained Packet")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: String(repeating: "a", count: 64),
            byteSize: 10,
            originalExtension: "txt",
            managedRelativePath: "blobs/aa/synthetic.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "synthetic-source.txt",
            status: MatterDocumentStatus.ready.rawValue
        ))
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id, title: "Legacy supported output", outputType: .documentQA,
            status: .needsReview
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matter.id,
            mode: .autoSource,
            retrievalQuery: "synthetic payment date"
        )
        try store.documentSources.addOutputSources([DocumentOutputSourceRecord(
            sourceSetID: sourceSet.id,
            documentID: document.id,
            chunkID: nil,
            citationLabel: "S1",
            locatorJSON: "{\"page\":1}",
            excerpt: "Payment was due March 3, 2025.",
            rank: 0
        )])
        let legacy = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "Payment was due March 3, 2025 [S1].",
            requiredSections: [], presentSections: [], missingSections: [],
            verificationStatus: .legacyUnverified,
            sourceSetID: sourceSet.id,
            outputStatus: .needsReview
        )
        _ = try store.remediationRecovery.requireReview(
            kind: .legacyStructuredOutput, matterID: matter.id,
            relatedTable: "structured_outputs", relatedID: output.id
        )
        let runtime = StubRuntimeClient { request in
            .events([.event(request, 1, .generationCompleted)])
        }
        let controller = StructuredOutputController(
            store: store, runtimeClient: runtime, matterID: matter.id
        )

        XCTAssertTrue(controller.reverifyOutput(output.id), controller.message ?? "")
        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: output.id)
        XCTAssertEqual(versions.count, 2)
        let original = try XCTUnwrap(versions.first { $0.id == legacy.id })
        XCTAssertEqual(original.contentMarkdown, "Payment was due March 3, 2025 [S1].")
        XCTAssertEqual(original.verificationStatus, OutputVerificationStatus.legacyUnverified.rawValue)
        let activeOutput = try XCTUnwrap(try store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        let active = try XCTUnwrap(versions.first { $0.id == activeOutput.activeVersionID })
        XCTAssertEqual(active.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertEqual(activeOutput.status, StructuredOutputStatus.complete.rawValue)
        XCTAssertNil(try store.remediationRecovery.pendingItem(
            kind: .legacyStructuredOutput,
            relatedID: output.id
        ))
    }

    func testACRRECOVERY003LegacyOutputIsVisibleAndCannotExportWithoutVerification() throws {
        // Expected RED: versions do not expose verification state and export is
        // not gated on legacy_unverified.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic Legacy Matter")
        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id, title: "Legacy output", outputType: .documentQA,
            status: .needsReview
        )
        _ = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            contentMarkdown: "Legacy synthetic answer [S1].",
            requiredSections: [], presentSections: [], missingSections: [],
            verificationStatus: .legacyUnverified,
            outputStatus: .needsReview
        )
        _ = try store.remediationRecovery.requireReview(
            kind: .legacyStructuredOutput, matterID: matter.id,
            relatedTable: "structured_outputs", relatedID: output.id
        )
        let runtime = StubRuntimeClient { request in
            .events([.event(request, 1, .generationCompleted)])
        }
        let controller = StructuredOutputController(
            store: store, runtimeClient: runtime, matterID: matter.id
        )

        let version = try XCTUnwrap(controller.versions(forOutput: output.id).first)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.legacyUnverified.rawValue)
        XCTAssertTrue(controller.activeOutputNeedsRevalidation(output.id))
        XCTAssertNil(controller.exportOutput(outputID: output.id, format: .markdown))
        XCTAssertTrue(controller.message?.localizedCaseInsensitiveContains("reverify") == true)
        XCTAssertFalse(controller.reverifyOutput(output.id))
        XCTAssertTrue(controller.message?.localizedCaseInsensitiveContains("fresh sources") == true)
    }

    func testACRRECOVERY004LegacyMultiMatterBillingRequiresExplicitReview() throws {
        // Expected RED: the billing controller does not surface or resolve migrated review items.
        let store = try SupraStore.inMemory()
        let day = try store.scratchPad.fetchOrCreateDay("2026-07-01")
        let draft = try store.billing.createDraft(
            dayID: day.id,
            lineItems: [BillingLineItemInput(
                matterID: nil, narrative: "Synthetic review line", hours: 0.5,
                workDate: "2026-07-01"
            )]
        )
        _ = try store.remediationRecovery.requireReview(
            kind: .multiMatterBillingDraft, matterID: nil,
            relatedTable: "billing_drafts", relatedID: draft.id
        )
        let service = BillingDraftService(store: store) { _, _ in "{\"lineItems\":[]}" }
        let controller = BillingDraftController(
            store: store, service: service,
            timekeeper: BillingTimekeeper(id: "TK", name: "Synthetic", classification: "P", defaultRate: 1, lawFirmID: "F")
        )

        controller.bind(dayID: day.id)
        XCTAssertTrue(controller.requiresLegacyReview)
        XCTAssertFalse(controller.canExport)
        controller.confirmLegacyReview()
        XCTAssertFalse(controller.requiresLegacyReview)
        XCTAssertTrue(controller.canExport)
    }
}
