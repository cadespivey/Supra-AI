import Foundation
import SupraCore
import SupraDocuments
import SupraDraftingCore
@testable import SupraSessions
import SupraStore
import XCTest

/// WP-1.1 controller enforcement — canonical identity must remain the authority
/// after the editor closes. Public matter and drafting entry points may not
/// revive legacy free text or accept a caller-assembled legal identity.
///
/// Expected RED: `MattersController` still calls the legacy repository directly;
/// Notice drafting reads `MatterRecord.court` and trusts caller-supplied party
/// strings without consulting the snapshot or Store-issued override receipts.
@MainActor
final class ArchitectureUXTDataIdentityDraftingEnforcementTests: XCTestCase {
    func testLegacyMatterControllerEntryPointsUseTheCanonicalIdentityAggregate() throws {
        let source = try sessionsSource("MattersController.swift")

        XCTAssertFalse(
            source.contains("store.matters.createMatter("),
            "legacy create must be unavailable or route through matterIdentity.createMatter"
        )
        XCTAssertFalse(
            source.contains("store.matters.updateMatter("),
            "legacy update must be unavailable or route through matterIdentity.updateMatter"
        )
        XCTAssertTrue(source.contains("store.matterIdentity.createMatter("))
        XCTAssertTrue(source.contains("store.matterIdentity.updateMatter("))
        XCTAssertFalse(source.contains(ArchitectureUXIdentityEnforcementWire.forbiddenDefault))
    }

    func testUnresolvedCourtBlocksNoticeBeforeFileOrAuditEffects() async throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "draft-unresolved")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unresolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            state: .unresolved,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        )
        XCTAssertEqual(unresolvedSnapshot.courtResolutionState, .unresolved)
        XCTAssertEqual(
            unresolvedSnapshot.matterID,
            ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        )
        try fixture.store.appSettings.setSetting(
            AssistantProfile.profileKey,
            value: architectureUXIdentityProfile()
        )
        let storage = DocumentStorage(
            root: fixture.root.appendingPathComponent("managed", isDirectory: true)
        )
        let controller = MatterDraftingController(store: fixture.store, storage: storage)
        let defaults = try controller.draftPartyDefaults(
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
        )

        let result = await controller.draftNoticeOfAppearance(
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            parties: defaults.captionParties,
            partyRepresented: defaults.representedDesignation,
            representedPartyName: defaults.representedClientName,
            recipients: [defaults.serviceRecipient],
            serviceDate: DateOnly(year: 2031, month: 7, day: 13)
        )

        assertDraftRejected(result, reason: "recognizable legacy court text is unresolved")
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
            ).filter { $0.eventType == "draft_generated" }.isEmpty
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.exportsDirectory(
                    forMatterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID
                ).path
            )
        )
        XCTAssertFalse(String(describing: result).contains(
            ArchitectureUXIdentityEnforcementWire.forbiddenDefault
        ))
    }

    func testConflictingRepresentedPartyRequiresStoreIssuedOverrideBeforeEffects() async throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "draft-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID,
            state: .court,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        )
        XCTAssertEqual(resolvedSnapshot.courtResolutionState, .court)
        XCTAssertEqual(
            resolvedSnapshot.matterID,
            ArchitectureUXIdentityEnforcementWire.resolvedMatterID
        )
        try fixture.store.appSettings.setSetting(
            AssistantProfile.profileKey,
            value: architectureUXIdentityProfile()
        )
        let storage = DocumentStorage(
            root: fixture.root.appendingPathComponent("managed", isDirectory: true)
        )
        let controller = MatterDraftingController(store: fixture.store, storage: storage)
        let defaults = try controller.draftPartyDefaults(
            matterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID
        )
        XCTAssertEqual(
            defaults.representedClientID,
            ArchitectureUXIdentityEnforcementWire.representedPartyID
        )

        let result = await controller.draftNoticeOfAppearance(
            matterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID,
            parties: defaults.captionParties,
            partyRepresented: defaults.opposingDesignation,
            representedPartyName: defaults.opposingPartyName,
            recipients: [defaults.serviceRecipient],
            serviceDate: DateOnly(year: 2031, month: 7, day: 19)
        )

        assertDraftRejected(result, reason: "the requested defendant conflicts with the represented plaintiff")
        XCTAssertTrue(
            try fixture.store.matterIdentity.fetchPartyConflictConfirmations(
                matterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID
            ).isEmpty,
            "the controller cannot manufacture its own attorney confirmation"
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                matterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID
            ).filter { $0.eventType == "draft_generated" }.isEmpty
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.exportsDirectory(
                    forMatterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID
                ).path
            )
        )
        XCTAssertFalse(String(describing: result).contains(
            ArchitectureUXIdentityEnforcementWire.forbiddenDefault
        ))
    }

    func testDraftingBoundaryValidatesStoreReceiptRatherThanCallerStrings() throws {
        let source = try sessionsSource("MatterDraftingController.swift")

        for contract in [
            "store.matterIdentity.fetchSnapshot(matterID:",
            "DraftPartyDefaultsBuilder",
            "selectionDecision(",
            "fetchPartyConflictConfirmations(matterID:",
            "confirmationReceipt",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: drafting boundary is missing identity contract \(contract)"
            )
        }
        for forbiddenLegacyDerivation in [
            "Self.courtHeader(for: matter)",
            "matter.court ?? matter.jurisdiction",
            "[matter.court, matter.jurisdiction, courtHeader]",
        ] {
            XCTAssertFalse(
                source.contains(forbiddenLegacyDerivation),
                "legacy legal identity remains authoritative: \(forbiddenLegacyDerivation)"
            )
        }
        XCTAssertFalse(source.contains(ArchitectureUXIdentityEnforcementWire.forbiddenDefault))
    }

    private func assertDraftRejected(
        _ result: Result<
            MatterDraftingController.DraftArtifact,
            MatterDraftingController.DraftError
        >,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .success(artifact) = result {
            XCTFail(
                "draft must fail before publication because \(reason); wrote \(artifact.fileURL.path)",
                file: file,
                line: line
            )
        }
    }

    private func sessionsSource(_ name: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/SupraSessions")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
