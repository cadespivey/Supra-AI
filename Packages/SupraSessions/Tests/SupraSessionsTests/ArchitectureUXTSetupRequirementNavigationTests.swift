import Foundation
import SupraSessions
import XCTest

/// Package contract supporting T-UX-SETUP-01. The hosted native test proves
/// these typed targets reach and focus the shipping AI Setup / Settings rows.
///
/// Expected RED: `SetupRequirement`, its exact row targets,
/// `SetupNavigationRequest`, and the compact `WorkContext` do not exist. The
/// current app instead emits destination prose and broadcasts a bare AppRoute,
/// so it cannot preserve this non-default return context.
final class ArchitectureUXTSetupRequirementNavigationTests: XCTestCase {
    private enum Wire {
        static let requestID = "wire-731"
        static let matterID = "matter-713"
        static let sourceSetID = "source-719"
        static let sourceSetVersion = 7
        static let authorityPacketID = "packet-727"
        static let authorityPacketVersion = 11
        static let checkpointID = "checkpoint-733"
        static let forbiddenDefault = "DEFAULT-000"
    }

    func testLocalAssistantAndDocumentSearchRequirementsTargetExactAISetupRows() {
        let expectations: [(SetupRequirement, SetupNavigationTarget, String)] = [
            (
                .localAssistant(role: .drafting),
                .aiSetup(row: .localAssistant(role: .drafting)),
                "aiSetup.requirement.localAssistant.drafting"
            ),
            (
                .documentSearch(step: .embeddingModel),
                .aiSetup(row: .documentSearch(step: .embeddingModel)),
                "aiSetup.requirement.documentSearch.embeddingModel"
            ),
            (
                .documentSearch(step: .extractionToolchain),
                .aiSetup(row: .documentSearch(step: .extractionToolchain)),
                "aiSetup.requirement.documentSearch.extractionToolchain"
            ),
            (
                .documentSearch(step: .storage),
                .aiSetup(row: .documentSearch(step: .storage)),
                "aiSetup.requirement.documentSearch.storage"
            ),
        ]

        for (requirement, target, rowIdentifier) in expectations {
            XCTAssertEqual(requirement.navigationTarget, target, requirement.id)
            XCTAssertEqual(target.rowAccessibilityIdentifier, rowIdentifier, requirement.id)
            XCTAssertTrue(target.isAISetup, requirement.id)
            XCTAssertFalse(target.isSettings, requirement.id)
            XCTAssertFalse(requirement.id.contains(Wire.forbiddenDefault), requirement.id)
            XCTAssertFalse(rowIdentifier.contains(Wire.forbiddenDefault), requirement.id)
        }

        XCTAssertEqual(
            Set(expectations.map { $0.0.id }).count,
            expectations.count,
            "each requirement needs one stable identity"
        )
        XCTAssertEqual(
            Set(expectations.map { $0.2 }).count,
            expectations.count,
            "each missing requirement must focus a distinct visible row"
        )
    }

    func testProviderConnectionAndBackupTargetExactSettingsRows() {
        let provider = SetupRequirement.providerConnection(provider: .courtListener)
        XCTAssertEqual(
            provider.navigationTarget,
            .settings(row: .providerConnection(provider: .courtListener))
        )
        XCTAssertEqual(
            provider.navigationTarget.rowAccessibilityIdentifier,
            "settings.requirement.provider.courtListener"
        )
        XCTAssertTrue(provider.navigationTarget.isSettings)
        XCTAssertFalse(provider.navigationTarget.isAISetup)

        let backup = SetupRequirement.backupDestination
        XCTAssertEqual(backup.navigationTarget, .settings(row: .backup))
        XCTAssertEqual(
            backup.navigationTarget.rowAccessibilityIdentifier,
            "settings.requirement.backup"
        )
        XCTAssertTrue(backup.navigationTarget.isSettings)
        XCTAssertFalse(backup.navigationTarget.isAISetup)

        XCTAssertFalse(provider.id.contains(Wire.forbiddenDefault))
        XCTAssertFalse(backup.id.contains(Wire.forbiddenDefault))
    }

    func testNavigationRequestRoundTripsExactNonDefaultWorkContext() throws {
        let context = WorkContext(
            matterID: Wire.matterID,
            intent: .draftMotion,
            sourceSet: VersionedWorkReference(
                id: Wire.sourceSetID,
                version: Wire.sourceSetVersion
            ),
            authorityPacket: VersionedWorkReference(
                id: Wire.authorityPacketID,
                version: Wire.authorityPacketVersion
            ),
            workProduct: nil,
            returnDestination: .matterTask(
                matterID: Wire.matterID,
                intent: .draftMotion
            ),
            checkpointID: Wire.checkpointID
        )
        let request = SetupNavigationRequest(
            id: Wire.requestID,
            requirement: .localAssistant(role: .drafting),
            returnContext: context
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        let decoded = try JSONDecoder().decode(SetupNavigationRequest.self, from: encoded)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.id, Wire.requestID)
        XCTAssertEqual(decoded.requirement, .localAssistant(role: .drafting))
        XCTAssertEqual(
            decoded.navigationTarget,
            .aiSetup(row: .localAssistant(role: .drafting))
        )
        XCTAssertEqual(decoded.returnContext.matterID, Wire.matterID)
        XCTAssertEqual(decoded.returnContext.intent, .draftMotion)
        XCTAssertEqual(decoded.returnContext.sourceSet?.id, Wire.sourceSetID)
        XCTAssertEqual(decoded.returnContext.sourceSet?.version, Wire.sourceSetVersion)
        XCTAssertEqual(decoded.returnContext.authorityPacket?.id, Wire.authorityPacketID)
        XCTAssertEqual(
            decoded.returnContext.authorityPacket?.version,
            Wire.authorityPacketVersion
        )
        XCTAssertNil(decoded.returnContext.workProduct)
        XCTAssertEqual(
            decoded.returnContext.returnDestination,
            .matterTask(matterID: Wire.matterID, intent: .draftMotion)
        )
        XCTAssertEqual(decoded.returnContext.checkpointID, Wire.checkpointID)

        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for wireValue in [
            Wire.requestID,
            Wire.matterID,
            Wire.sourceSetID,
            Wire.authorityPacketID,
            Wire.checkpointID,
            "draftMotion",
        ] {
            XCTAssertTrue(encodedText.contains(wireValue), wireValue)
        }
        XCTAssertFalse(encodedText.contains(Wire.forbiddenDefault))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("current matter"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("default route"))
    }

    // Owner walkthrough RED (2026-08-15): the Documents import blocker points to
    // Settings and has no working action. Its corrective detour must retain an
    // import-specific intent instead of silently substituting draftMotion.
    func testDocumentImportSetupRequestRoundTripsWithoutDraftIntentSubstitution() throws {
        let context = WorkContext(
            matterID: Wire.matterID,
            intent: .importDocuments,
            sourceSet: nil,
            authorityPacket: nil,
            workProduct: nil,
            returnDestination: .matterTask(
                matterID: Wire.matterID,
                intent: .importDocuments
            ),
            checkpointID: "document-import"
        )
        let request = SetupNavigationRequest(
            id: "document-import-setup-wire",
            requirement: .documentSearch(step: .embeddingModel),
            returnContext: context
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SetupNavigationRequest.self, from: encoded)

        XCTAssertEqual(decoded.returnContext.intent, .importDocuments)
        XCTAssertEqual(
            decoded.returnContext.returnDestination,
            .matterTask(matterID: Wire.matterID, intent: .importDocuments)
        )
        XCTAssertNotEqual(decoded.returnContext.intent, .draftMotion)
        XCTAssertTrue(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("importDocuments"))
    }
}
