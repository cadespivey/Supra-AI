import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

/// WP-1.1 matter-context enforcement. Canonical IDs may authorize a resolved
/// legal scope even when legacy text is useless, while recognizable legacy text
/// may not authorize anything when the canonical state is unresolved.
///
/// Expected RED: `GlobalChatController` derives its matter authority scope from
/// `MatterRecord.jurisdiction/court`, and document grounding still turns legacy
/// `clientNames` into party anchors.
@MainActor
final class ArchitectureUXTDataIdentityChatContextEnforcementTests: XCTestCase {
    func testResolvedCanonicalIDsNotLegacyTextAuthorizeMatterLegalScope() throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "chat-resolved")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.resolvedMatterID,
            state: .court,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.legacyJurisdictionCanary,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.legacyCourtCanary
        )
        XCTAssertEqual(resolvedSnapshot.courtResolutionState, .court)
        XCTAssertEqual(
            resolvedSnapshot.canonicalCourtID,
            ArchitectureUXIdentityEnforcementWire.courtID
        )
        let controller = makeGlobalChatController(
            store: fixture.store,
            runtimeClient: StubRuntimeClient(),
            scope: .matter(id: ArchitectureUXIdentityEnforcementWire.resolvedMatterID)
        )
        controller.loadChats()
        let routed = ModelRouter(
            configuration: LegalModelConfiguration(jurisdictionRequired: true)
        ).routePrompt("/research synthetic renewal notice identity wire 839")

        XCTAssertTrue(routed.route.requiresJurisdiction)
        XCTAssertTrue(
            controller.requiresRuntimeModel(for: routed),
            "the exact canonical IDs resolve the scope even though legacy strings do not"
        )
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.legacyJurisdictionCanary
        ))
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.legacyCourtCanary
        ))
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.legacyClientCanary
        ))
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.forbiddenDefault
        ))
    }

    func testUnresolvedCanonicalStateRejectsRecognizableLegacyMatterScope() throws {
        let fixture = try makeArchitectureUXIdentityEnforcementStore(prefix: "chat-unresolved")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unresolvedSnapshot = try seedArchitectureUXIdentityMatter(
            store: fixture.store,
            matterID: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID,
            state: .unresolved,
            legacyJurisdiction: ArchitectureUXIdentityEnforcementWire.recognizableLegacyJurisdiction,
            legacyCourt: ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        )
        XCTAssertEqual(unresolvedSnapshot.courtResolutionState, .unresolved)
        XCTAssertNil(unresolvedSnapshot.canonicalCourtID)
        let controller = makeGlobalChatController(
            store: fixture.store,
            runtimeClient: StubRuntimeClient(),
            scope: .matter(id: ArchitectureUXIdentityEnforcementWire.unresolvedMatterID)
        )
        controller.loadChats()
        let routed = ModelRouter(
            configuration: LegalModelConfiguration(jurisdictionRequired: true)
        ).routePrompt("/research synthetic renewal notice identity wire 853")

        XCTAssertTrue(routed.route.requiresJurisdiction)
        XCTAssertFalse(
            controller.requiresRuntimeModel(for: routed),
            "recognizable legacy Florida text cannot satisfy the unresolved court gate"
        )
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.recognizableLegacyCourt
        ))
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.legacyClientCanary
        ))
        XCTAssertFalse(String(describing: routed).contains(
            ArchitectureUXIdentityEnforcementWire.forbiddenDefault
        ))
    }

    func testMatterChatAndOutputControllersDoNotReadLegacyLegalIdentityAsTruth() throws {
        let chat = try sessionsSource("GlobalChatController.swift")
        for forbidden in [
            "jurisdiction: matter.jurisdiction",
            "court: matter.court",
        ] {
            XCTAssertFalse(chat.contains(forbidden), "matter Chat legacy bypass: \(forbidden)")
        }
        for contract in [
            "store.matterIdentity.fetchSnapshot(matterID:",
            "MatterCourtPresentationBuilder",
        ] {
            XCTAssertTrue(chat.contains(contract), "Expected RED: matter Chat missing \(contract)")
        }

        let grounding = try sessionsSource("MatterChatDocumentGrounding.swift")
        XCTAssertFalse(
            grounding.contains("clientNames: $0.clientNames"),
            "legacy clientNames cannot become a document-routing party anchor"
        )
        XCTAssertTrue(
            grounding.contains("store.matterIdentity.fetchSnapshot(matterID:"),
            "document grounding must read structured parties from one identity snapshot"
        )
        XCTAssertTrue(
            grounding.contains("snapshot.parties"),
            "structured display/caption names, not legacy clientNames, own party anchors"
        )

        let outputs = try sessionsSource("StructuredOutputController.swift")
        XCTAssertTrue(
            outputs.contains("store.matterIdentity.fetchSnapshot(matterID:"),
            "Outputs must own its canonical matter-context prefix beneath the UI"
        )
        XCTAssertTrue(outputs.contains("MatterCourtPresentationBuilder"))
        XCTAssertTrue(outputs.contains("DraftPartyDefaultsBuilder"))
        for source in [chat, grounding, outputs] {
            XCTAssertFalse(source.contains(ArchitectureUXIdentityEnforcementWire.forbiddenDefault))
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
