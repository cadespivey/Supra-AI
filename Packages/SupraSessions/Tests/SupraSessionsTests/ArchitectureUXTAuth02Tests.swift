import CryptoKit
import Foundation
import GRDB
import SupraCore
import SupraResearch
import SupraRuntimeInterface
import SupraStore
@testable import SupraSessions
import XCTest

/// T-AUTH-02 — authority-asserting work accepts exactly one immutable accepted
/// research-packet version. The same exact packet identity, ordered authority
/// IDs, reviewed excerpts, and provider/review provenance must reach the model
/// prompt and the atomically published work-product binding. Missing, altered,
/// and revoked packet references stop before model, Store mutation, or transport.
/// An explicitly provisional issue outline is labeled and remains technically
/// nonexportable and nonpromotable through generic repository backdoors.
///
/// Expected RED: R0 currently blocks every authority-asserting type even when a
/// valid accepted packet exists. There is no governed creation request/router,
/// packet preflight reference, prompt packet builder, atomic packet binding in
/// structured-output publication, retained blocked request, or durable
/// provisional publication class. The provider gate also returns no content-free
/// consumption receipt, and Sessions has no dependency-safe registrar that can
/// validate that receipt before Store records an executed research packet.
@MainActor
final class ArchitectureUXTAuth02Tests: XCTestCase {
    func testOneExactAcceptedVersionFlowsAuthoritiesExcerptsAndProvenanceIntoPublication() async throws {
        let fixture = try ArchitectureUXAuthorityWorkFixture.make(prefix: "exact")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.executeReviewAndAccept()
        let second = try await fixture.executeReviewAndAcceptSecondVersion()
        XCTAssertEqual(first.versionIndex, 1)
        XCTAssertEqual(second.versionIndex, 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.aggregateDigestSHA256, second.aggregateDigestSHA256)
        XCTAssertNotEqual(first.egressGrantID, second.egressGrantID)
        XCTAssertEqual(first.providerID, "provider-713")
        XCTAssertEqual(first.egressGrantVersion, 7)
        XCTAssertEqual(
            first.exactQuerySHA256,
            ArchitectureUXAuthorityWorkWire.rawDigest("QUERY-CANARY-719")
        )

        let contract = try XCTUnwrap(StructuredOutputContracts.contract(for: .ruleSynthesis))
        let generated = contract.requiredHeadings
            .map { "\($0)\n\nT_AUTH_02_GENERATED_RULE_1013 [A17]." }
            .joined(separator: "\n\n")
        let probe = ArchitectureUXAuthorityRuntimeProbe(response: generated)
        let controller = StructuredOutputController(
            store: fixture.store,
            runtimeClient: probe.runtime,
            matterID: fixture.matterID
        )
        let reference = AcceptedResearchPacketReference(
            versionID: first.id,
            versionIndex: first.versionIndex,
            expectedAggregateDigestSHA256: first.aggregateDigestSHA256
        )
        let request = StructuredWorkProductCreationRequest(
            idempotencyKey: ArchitectureUXAuthorityWorkWire.publicationKey,
            type: .ruleSynthesis,
            instructionsAndFacts: ArchitectureUXAuthorityWorkWire.instructions,
            publicationMode: .governedAuthority,
            acceptedResearchPacket: reference
        )
        let beforeNetworkCount = try fixture.store.networkRequests.fetchRecent(limit: 10_000).count

        let result = await controller.createWorkProduct(
            request,
            modelID: ModelID(),
            route: nil
        )

        XCTAssertTrue(result.didPublish)
        XCTAssertNil(result.blocker)
        XCTAssertNil(result.failure)
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.publicationMode, .governedAuthority)
        XCTAssertEqual(receipt.idempotencyKey, ArchitectureUXAuthorityWorkWire.publicationKey)
        XCTAssertEqual(receipt.acceptedResearchPacketVersionID, first.id)
        XCTAssertEqual(receipt.acceptedResearchPacketVersionIndex, first.versionIndex)
        XCTAssertEqual(
            receipt.acceptedResearchPacketAggregateDigestSHA256,
            first.aggregateDigestSHA256
        )
        XCTAssertNotEqual(receipt.acceptedResearchPacketVersionID, second.id)
        XCTAssertNotEqual(
            receipt.acceptedResearchPacketAggregateDigestSHA256,
            second.aggregateDigestSHA256
        )

        let prompts = probe.prompts
        XCTAssertEqual(prompts.count, 1)
        let prompt = try XCTUnwrap(prompts.first)
        let packetBlock = try XCTUnwrap(
            prompt.components(separatedBy: "REVIEWED AUTHORITY PACKET — EXACT ACCEPTED VERSION")
                .last
        )
        XCTAssertTrue(packetBlock.contains(first.id))
        XCTAssertTrue(packetBlock.contains("version_index: \(first.versionIndex)"))
        XCTAssertTrue(packetBlock.contains(first.aggregateDigestSHA256))
        XCTAssertTrue(packetBlock.contains(first.providerID))
        XCTAssertTrue(packetBlock.contains(first.egressGrantID))
        XCTAssertTrue(packetBlock.contains(first.exactQuerySHA256))
        XCTAssertTrue(packetBlock.contains(ArchitectureUXAuthorityWorkWire.authorityID))
        XCTAssertTrue(packetBlock.contains(ArchitectureUXAuthorityWorkWire.resultID))
        XCTAssertTrue(packetBlock.contains(ArchitectureUXAuthorityWorkWire.providerResultID))
        XCTAssertTrue(packetBlock.contains(ArchitectureUXAuthorityWorkWire.excerpt))
        XCTAssertTrue(packetBlock.contains(fixture.reviewedProposition.bindingSHA256))
        XCTAssertTrue(packetBlock.contains(AuthorityReviewedPropositionGround.failureToStateClaim.rawValue))
        XCTAssertTrue(packetBlock.contains(ArchitectureUXAuthorityWorkWire.instructions))
        XCTAssertFalse(packetBlock.contains(second.id))
        XCTAssertFalse(packetBlock.contains(second.egressGrantID))
        XCTAssertFalse(packetBlock.contains("DEFAULT-BODY-000"))

        let binding = try XCTUnwrap(
            fixture.store.researchPackets.workProductBinding(
                structuredOutputVersionID: receipt.versionID
            )
        )
        XCTAssertEqual(binding.structuredOutputVersionID, receipt.versionID)
        XCTAssertEqual(binding.acceptedPacketVersionID, first.id)
        XCTAssertEqual(binding.packetAggregateDigestSHA256, first.aggregateDigestSHA256)
        XCTAssertNotEqual(binding.acceptedPacketVersionID, second.id)
        let publishedPacket = try XCTUnwrap(
            fixture.store.researchPackets.acceptedVersion(id: binding.acceptedPacketVersionID)
        )
        XCTAssertEqual(publishedPacket, first)
        XCTAssertEqual(publishedPacket.sources.count, 1)
        let source = try XCTUnwrap(publishedPacket.sources.first)
        XCTAssertEqual(source.sourceIndex, 0)
        XCTAssertEqual(source.authorityID, ArchitectureUXAuthorityWorkWire.authorityID)
        XCTAssertEqual(source.researchResultID, ArchitectureUXAuthorityWorkWire.resultID)
        XCTAssertEqual(source.providerResultID, ArchitectureUXAuthorityWorkWire.providerResultID)
        XCTAssertEqual(source.excerpt, ArchitectureUXAuthorityWorkWire.excerpt)
        XCTAssertEqual(source.excerptSHA256, ArchitectureUXAuthorityWorkWire.rawDigest(ArchitectureUXAuthorityWorkWire.excerpt))
        XCTAssertEqual(source.reviewedPropositionBindingSHA256, fixture.reviewedProposition.bindingSHA256)
        XCTAssertFalse(source.excerpt.contains("DEFAULT-BODY-000"))

        let output = try XCTUnwrap(
            fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matterID)
                .first { $0.id == receipt.structuredOutputID }
        )
        XCTAssertEqual(output.activeVersionID, receipt.versionID)
        let version = try XCTUnwrap(
            fixture.store.structuredOutputs
                .fetchVersions(structuredOutputID: output.id)
                .first { $0.id == receipt.versionID }
        )
        XCTAssertEqual(version.contentMarkdown, generated)
        XCTAssertFalse(version.contentMarkdown.contains("DEFAULT-BODY-000"))
        let transmitted = fixture.transport.requests
        XCTAssertEqual(transmitted.count, 2)
        XCTAssertEqual(transmitted.first?.query, "QUERY-CANARY-719")
        XCTAssertEqual(transmitted.last?.query, "QUERY-CANARY-719")
        XCTAssertTrue(transmitted.allSatisfy { !$0.query.contains("DEFAULT-BODY-000") })
        XCTAssertEqual(
            try fixture.store.networkRequests.fetchRecent(limit: 10_000).count,
            beforeNetworkCount,
            "governed creation consumes retained reviewed evidence and performs no provider transport"
        )
    }

    func testMissingAlteredAndRevokedPacketStopBeforeModelStoreAndTransport() async throws {
        for invalidity in InvalidPacketCase.allCases {
            let fixture = try ArchitectureUXAuthorityWorkFixture.make(prefix: invalidity.rawValue)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let accepted = try await fixture.executeReviewAndAccept()
            let reference: AcceptedResearchPacketReference
            switch invalidity {
            case .missing:
                reference = AcceptedResearchPacketReference(
                    versionID: "missing-accepted-packet-version-1031",
                    versionIndex: 17,
                    expectedAggregateDigestSHA256: String(repeating: "7", count: 64)
                )
            case .altered:
                reference = AcceptedResearchPacketReference(
                    versionID: accepted.id,
                    versionIndex: accepted.versionIndex,
                    expectedAggregateDigestSHA256: String(repeating: "a", count: 64)
                )
                XCTAssertNotEqual(
                    reference.expectedAggregateDigestSHA256,
                    accepted.aggregateDigestSHA256
                )
            case .revoked:
                let disposition = try fixture.store.researchPackets.recordDisposition(
                    ResearchPacketVersionDispositionCommand(
                        idempotencyKey: "t-auth-02-revocation-1033",
                        packetVersionID: accepted.id,
                        kind: .revoked,
                        replacementPacketVersionID: nil,
                        actor: ArchitectureUXAuthorityWorkWire.packetReviewer,
                        reason: "Synthetic authority packet revocation 1039",
                        occurredAt: ArchitectureUXAuthorityWorkWire.acceptedAt
                            .addingTimeInterval(17)
                    )
                )
                XCTAssertEqual(disposition.packetVersionID, accepted.id)
                XCTAssertEqual(disposition.kind, .revoked)
                reference = AcceptedResearchPacketReference(
                    versionID: accepted.id,
                    versionIndex: accepted.versionIndex,
                    expectedAggregateDigestSHA256: accepted.aggregateDigestSHA256
                )
            }

            let contract = try XCTUnwrap(
                StructuredOutputContracts.contract(for: .argumentOutline)
            )
            let generated = contract.requiredHeadings
                .map { "\($0)\n\nTHIS_MUST_NEVER_GENERATE_1049" }
                .joined(separator: "\n\n")
            let probe = ArchitectureUXAuthorityRuntimeProbe(response: generated)
            let controller = StructuredOutputController(
                store: fixture.store,
                runtimeClient: probe.runtime,
                matterID: fixture.matterID
            )
            let request = StructuredWorkProductCreationRequest(
                idempotencyKey: "t-auth-02-blocked-\(invalidity.rawValue)-1051",
                type: .argumentOutline,
                instructionsAndFacts: "T_AUTH_02_BLOCKED_INPUT_1057_\(invalidity.rawValue)",
                publicationMode: .governedAuthority,
                acceptedResearchPacket: reference
            )
            let before = try authoritySideEffectSnapshot(
                fixture.store,
                egressReceiptID: accepted.egressGrantID
            )

            let result = await controller.createWorkProduct(
                request,
                modelID: ModelID(),
                route: nil
            )

            XCTAssertFalse(result.didPublish, "\(invalidity.rawValue) packet must fail closed")
            XCTAssertNil(result.receipt)
            XCTAssertNil(result.failure)
            XCTAssertEqual(result.retainedRequest, request)
            XCTAssertEqual(controller.retainedWorkProductRequest, request)
            let blocker = try XCTUnwrap(result.blocker)
            XCTAssertEqual(blocker.reason, .reviewedAuthorityPacketUnavailable)
            XCTAssertEqual(
                blocker.recoverySurfaces,
                Swift.Set<WorkSurface>([.research, .authorities])
            )
            XCTAssertTrue(blocker.userMessage.contains("Formal Research"))
            XCTAssertTrue(blocker.userMessage.contains("Authorities"))
            XCTAssertFalse(blocker.userMessage.contains("DEFAULT-BODY-000"))
            XCTAssertTrue(probe.prompts.isEmpty, "\(invalidity.rawValue) packet must make zero model calls")
            XCTAssertEqual(
                try authoritySideEffectSnapshot(
                    fixture.store,
                    egressReceiptID: accepted.egressGrantID
                ),
                before,
                "\(invalidity.rawValue) packet must make zero Store mutations and zero transport records"
            )
            XCTAssertFalse(
                try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matterID)
                    .contains { $0.outputType == StructuredOutputType.argumentOutline.rawValue }
            )
        }
    }

    func testAlteredReceiptAndUnconsumedGrantCannotCreatePacketOrReachWorkRouter() async throws {
        let alteredFixture = try ArchitectureUXAuthorityWorkFixture.make(prefix: "altered-egress")
        defer { try? FileManager.default.removeItem(at: alteredFixture.root) }
        let consumed = try await alteredFixture.consumeEgress(
            grantVersion: ArchitectureUXAuthorityWorkWire.firstGrantVersion,
            timeOffset: 0
        )
        let encodedReceipt = String(
            decoding: try JSONEncoder().encode(consumed),
            as: UTF8.self
        )
        let alteredQueryDigest = ArchitectureUXAuthorityWorkWire.rawDigest(
            "QUERY-CANARY-719-ALTERED"
        )
        XCTAssertTrue(encodedReceipt.contains(consumed.querySHA256))
        XCTAssertNotEqual(alteredQueryDigest, consumed.querySHA256)
        let alteredReceiptJSON = encodedReceipt.replacingOccurrences(
            of: consumed.querySHA256,
            with: alteredQueryDigest
        )
        XCTAssertNotEqual(alteredReceiptJSON, encodedReceipt)
        let alteredReceipt = try JSONDecoder().decode(
            LegalQueryEgressConsumptionReceipt.self,
            from: Data(alteredReceiptJSON.utf8)
        )
        XCTAssertEqual(alteredReceipt.id, consumed.id)
        XCTAssertEqual(alteredReceipt.querySHA256, alteredQueryDigest)
        XCTAssertEqual(alteredReceipt.bindingDigestSHA256, consumed.bindingDigestSHA256)
        XCTAssertFalse(alteredReceiptJSON.contains("QUERY-CANARY-719"))
        XCTAssertFalse(
            alteredReceiptJSON.contains(ArchitectureUXAuthorityWorkWire.unrelatedMatterBody)
        )
        let alteredBefore = try authoritySideEffectSnapshot(
            alteredFixture.store,
            egressReceiptID: consumed.id
        )
        let alteredTransportBefore = alteredFixture.transport.requests
        XCTAssertEqual(alteredTransportBefore.count, 1)
        XCTAssertEqual(alteredTransportBefore.first?.query, "QUERY-CANARY-719")
        XCTAssertFalse(
            alteredTransportBefore.first?.query.contains(
                ArchitectureUXAuthorityWorkWire.unrelatedMatterBody
            ) == true
        )
        let registrar = ResearchPacketEgressReceiptRegistrar(store: alteredFixture.store)

        XCTAssertThrowsError(
            try registrar.register(.consumed(alteredReceipt))
        ) { error in
            XCTAssertEqual(
                error as? ResearchPacketEgressReceiptRegistrationError,
                .bindingDigestMismatch
            )
        }
        XCTAssertNil(
            alteredFixture.store.researchPackets.egressConsumptionRegistration(
                id: consumed.id
            )
        )
        try await assertBlockedWorkRouterHasNoEffects(
            fixture: alteredFixture,
            idempotencyKey: "t-auth-02-altered-egress-work-1039",
            missingPacketVersionID: "t-auth-02-altered-egress-never-accepted-1049"
        )
        XCTAssertEqual(
            try authoritySideEffectSnapshot(
                alteredFixture.store,
                egressReceiptID: consumed.id
            ),
            alteredBefore,
            "an altered consumed receipt must leave every Store row unchanged"
        )
        XCTAssertEqual(
            alteredFixture.transport.requests,
            alteredTransportBefore,
            "rejected receipt use and governed-work preflight must make no additional transport call"
        )

        let unconsumedFixture = try ArchitectureUXAuthorityWorkFixture.make(prefix: "unconsumed-egress")
        defer { try? FileManager.default.removeItem(at: unconsumedFixture.root) }
        let unconsumedGrant = try await unconsumedFixture.issueUnconsumedGrant(
            grantVersion: ArchitectureUXAuthorityWorkWire.firstGrantVersion,
            timeOffset: 0
        )
        XCTAssertEqual(unconsumedGrant.version, 7)
        XCTAssertTrue(unconsumedFixture.transport.requests.isEmpty)
        let unconsumedBefore = try authoritySideEffectSnapshot(
            unconsumedFixture.store,
            egressReceiptID: nil
        )
        let registrar = ResearchPacketEgressReceiptRegistrar(store: unconsumedFixture.store)

        XCTAssertThrowsError(
            try registrar.register(.unconsumed(unconsumedGrant))
        ) { error in
            XCTAssertEqual(
                error as? ResearchPacketEgressReceiptRegistrationError,
                .unconsumedGrant
            )
        }
        try await assertBlockedWorkRouterHasNoEffects(
            fixture: unconsumedFixture,
            idempotencyKey: "t-auth-02-unconsumed-egress-work-1051",
            missingPacketVersionID: "t-auth-02-unconsumed-never-accepted-1057"
        )
        XCTAssertEqual(
            try authoritySideEffectSnapshot(
                unconsumedFixture.store,
                egressReceiptID: nil
            ),
            unconsumedBefore,
            "an approved but unconsumed grant must create no packet, receipt registration, audit, or work product"
        )
        XCTAssertTrue(
            unconsumedFixture.transport.requests.isEmpty,
            "registering or routing an unconsumed grant must make zero provider calls"
        )
    }

    func testExplicitProvisionalIssueOutlineIsLabeledNonexportableAndNonpromotable() async throws {
        let fixture = try ArchitectureUXAuthorityWorkFixture.make(prefix: "provisional")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let contract = try XCTUnwrap(
            StructuredOutputContracts.contract(for: .legalIssueSpotting)
        )
        let generated = contract.requiredHeadings
            .map { "\($0)\n\nT_AUTH_02_PROVISIONAL_ANALYSIS_1061" }
            .joined(separator: "\n\n")
        let runtimeProbe = ArchitectureUXAuthorityRuntimeProbe(response: generated)
        let exportProbe = StructuredWorkExportProbe()
        let controller = StructuredOutputController(
            store: fixture.store,
            runtimeClient: runtimeProbe.runtime,
            matterID: fixture.matterID,
            exportAction: exportProbe.action
        )
        let request = StructuredWorkProductCreationRequest(
            idempotencyKey: ArchitectureUXAuthorityWorkWire.provisionalKey,
            type: .legalIssueSpotting,
            instructionsAndFacts: ArchitectureUXAuthorityWorkWire.provisionalInstructions,
            publicationMode: .provisionalIssueOutline,
            acceptedResearchPacket: nil
        )

        let result = await controller.createWorkProduct(
            request,
            modelID: ModelID(),
            route: nil
        )

        XCTAssertTrue(result.didPublish)
        XCTAssertNil(result.blocker)
        XCTAssertNil(result.failure)
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.publicationMode, .provisionalIssueOutline)
        XCTAssertNil(receipt.acceptedResearchPacketVersionID)
        XCTAssertNil(receipt.acceptedResearchPacketVersionIndex)
        XCTAssertNil(receipt.acceptedResearchPacketAggregateDigestSHA256)
        let eligibility = try XCTUnwrap(result.eligibility)
        XCTAssertFalse(eligibility.canExport)
        XCTAssertFalse(eligibility.canPromote)
        XCTAssertEqual(eligibility.reason, .provisionalIssueOutline)

        let output = try XCTUnwrap(
            fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matterID)
                .first { $0.id == receipt.structuredOutputID }
        )
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        let versions = try fixture.store.structuredOutputs
            .fetchVersions(structuredOutputID: output.id)
            .sorted { $0.versionIndex < $1.versionIndex }
        let active = try XCTUnwrap(versions.first { $0.id == receipt.versionID })
        XCTAssertEqual(active.assuranceState, OutputAssuranceState.preliminary.rawValue)
        XCTAssertNotEqual(active.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        XCTAssertTrue(
            active.contentMarkdown.contains(
                "> ⚠️ **PROVISIONAL ISSUE OUTLINE — NOT AUTHORITY-GROUNDED.**"
            )
        )
        XCTAssertTrue(active.contentMarkdown.contains(ArchitectureUXAuthorityWorkWire.provisionalInstructions))
        XCTAssertFalse(active.contentMarkdown.contains(ArchitectureUXAuthorityWorkWire.unrelatedMatterBody))
        XCTAssertNil(
            try fixture.store.researchPackets.workProductBinding(
                structuredOutputVersionID: active.id
            )
        )

        let export = controller.attemptExportOutput(outputID: output.id, format: .markdown)
        XCTAssertFalse(export.didCommit)
        XCTAssertNil(export.committedValue)
        XCTAssertEqual(exportProbe.callCount, 0, "provisional output must stop before file installation")
        XCTAssertTrue(export.failure?.recoveryActions.contains(.correctInput) == true)

        let support = try PropositionSupportResult(
            propositionID: "t-auth-02-provisional-proposition-1063",
            status: .supported,
            reasons: [],
            evidence: [
                SupportEvidence(
                    sourceID: "t-auth-02-provisional-source-1069",
                    sourceLabel: "A17",
                    locator: "synthetic:t-auth-02:1069",
                    retainedExcerpt: "T_AUTH_02_PROVISIONAL_EVIDENCE_1069",
                    verifierName: "ArchitectureUXTAuth02Tests",
                    verifierVersion: "t-auth-02-v7"
                ),
            ],
            timestamp: ArchitectureUXAuthorityWorkWire.acceptedAt
        )
        let beforePromotionAttempt = try authoritySideEffectSnapshot(
            fixture.store,
            egressReceiptID: nil
        )
        let activeBefore = output.activeVersionID
        let versionCountBefore = versions.count

        XCTAssertThrowsError(
            try fixture.store.structuredOutputs.createVersion(
                structuredOutputID: output.id,
                contentMarkdown: "T_AUTH_02_FORBIDDEN_PROMOTION_1087 [A17].",
                requiredSections: [],
                presentSections: [],
                missingSections: [],
                parentVersionID: active.id,
                repairReason: "forbidden_provisional_promotion",
                verificationStatus: .allSupported,
                verificationVersion: "t-auth-02-v7",
                verificationResults: [support],
                verificationDimensions: VerificationDimensionsMapper.dimensions(
                    verificationResults: [support]
                ),
                assuranceState: .propositionSupported,
                outputStatus: .complete,
                makeActive: true
            ),
            "generic version creation cannot promote a provisional outline"
        )
        XCTAssertThrowsError(
            try fixture.store.structuredOutputs.updateStatus(
                outputID: output.id,
                status: .complete
            ),
            "generic status mutation cannot claim terminal authority for a provisional outline"
        )
        XCTAssertEqual(
            try fixture.store.structuredOutputs
                .fetchVersions(structuredOutputID: output.id).count,
            versionCountBefore
        )
        XCTAssertEqual(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.matterID)
                .first { $0.id == output.id }?.activeVersionID,
            activeBefore
        )
        XCTAssertEqual(
            try authoritySideEffectSnapshot(fixture.store, egressReceiptID: nil),
            beforePromotionAttempt,
            "promotion attempts cannot mutate the provisional publication aggregate"
        )
    }

    private enum InvalidPacketCase: String, CaseIterable {
        case missing
        case altered
        case revoked
    }

    private func assertBlockedWorkRouterHasNoEffects(
        fixture: ArchitectureUXAuthorityWorkFixture,
        idempotencyKey: String,
        missingPacketVersionID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let contract = try XCTUnwrap(
            StructuredOutputContracts.contract(for: .ruleSynthesis),
            file: file,
            line: line
        )
        let response = contract.requiredHeadings
            .map { "\($0)\n\nT_AUTH_02_EGRESS_BLOCK_MUST_NOT_GENERATE_1061" }
            .joined(separator: "\n\n")
        let runtimeProbe = ArchitectureUXAuthorityRuntimeProbe(response: response)
        let controller = StructuredOutputController(
            store: fixture.store,
            runtimeClient: runtimeProbe.runtime,
            matterID: fixture.matterID
        )
        let request = StructuredWorkProductCreationRequest(
            idempotencyKey: idempotencyKey,
            type: .ruleSynthesis,
            instructionsAndFacts: "T_AUTH_02_WIRE_731 EGRESS-BLOCKED INSTRUCTIONS 1063",
            publicationMode: .governedAuthority,
            acceptedResearchPacket: AcceptedResearchPacketReference(
                versionID: missingPacketVersionID,
                versionIndex: 17,
                expectedAggregateDigestSHA256: String(repeating: "b", count: 64)
            )
        )

        let result = await controller.createWorkProduct(
            request,
            modelID: ModelID(),
            route: nil
        )

        XCTAssertFalse(result.didPublish, file: file, line: line)
        XCTAssertNil(result.receipt, file: file, line: line)
        XCTAssertNil(result.failure, file: file, line: line)
        XCTAssertEqual(result.retainedRequest, request, file: file, line: line)
        let blocker = try XCTUnwrap(result.blocker, file: file, line: line)
        XCTAssertEqual(
            blocker.reason,
            .reviewedAuthorityPacketUnavailable,
            file: file,
            line: line
        )
        XCTAssertEqual(
            blocker.recoverySurfaces,
            Swift.Set<WorkSurface>([.research, .authorities]),
            file: file,
            line: line
        )
        XCTAssertTrue(runtimeProbe.prompts.isEmpty, file: file, line: line)
    }
}

// MARK: - Synthetic accepted-packet fixture

private enum ArchitectureUXAuthorityWorkWire {
    static let packetID = "t-auth-02-packet-1091"
    static let firstExecutionID = "t-auth-02-execution-1093"
    static let secondExecutionID = "t-auth-02-execution-1097"
    static let firstAcceptedVersionID = "t-auth-02-accepted-version-1099"
    static let secondAcceptedVersionID = "t-auth-02-accepted-version-1103"
    static let firstAcceptanceKey = "t-auth-02-acceptance-1109"
    static let secondAcceptanceKey = "t-auth-02-acceptance-1117"
    static let publicationKey = "t-auth-02-publication-1123"
    static let provisionalKey = "t-auth-02-provisional-1129"
    static let matterID = "T_AUTH_02_WIRE_731"
    static let unrelatedMatterBody = "DEFAULT-BODY-000"
    static let providerID = "provider-713"
    static let firstGrantVersion = 7
    static let secondGrantVersion = 8
    static let exactQuery = "QUERY-CANARY-719"
    static let resultID = "t-auth-02-research-result-1181"
    static let providerResultID = "t-auth-02-provider-result-1187"
    static let authorityID = "t-auth-02-authority-1193"
    static let caseName = "Synthetic Authority Packet Case 1193"
    static let citation = "1193 F. Supp. 17th 1199"
    static let excerpt =
        "The synthetic court held that T_AUTH_02_REVIEWED_PROPOSITION_1201 governs the fictional notice issue."
    static let opinion =
        "Opening synthetic opinion text. \(excerpt) Closing synthetic text 1213."
    static let packetReviewer = "t-auth-02-packet-reviewer-1217"
    static let propositionReviewer = "t-auth-02-proposition-reviewer-1223"
    static let instructions = "T_AUTH_02_INSTRUCTIONS_AND_FACTS_1229"
    static let provisionalInstructions = "T_AUTH_02_PROVISIONAL_INSTRUCTIONS_1231"
    static let executedAt = Date(timeIntervalSince1970: 1_946_421_091)
    static let propositionReviewedAt = Date(timeIntervalSince1970: 1_946_421_193)
    static let reviewedAt = Date(timeIntervalSince1970: 1_946_421_217)
    static let acceptedAt = Date(timeIntervalSince1970: 1_946_421_223)

    static func sourceDigest(reviewedBindingSHA256: String) -> String {
        digest(lengthPrefixed: [
            "accepted-research-packet-sources-v1",
            "0",
            resultID,
            providerResultID,
            authorityID,
            reviewedBindingSHA256,
            excerpt,
        ])
    }

    static func digest(lengthPrefixed values: [String]) -> String {
        let canonical = values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func rawDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct ArchitectureUXAuthorityWorkFixture: @unchecked Sendable {
    let root: URL
    let store: SupraStore
    let matterID: String
    let unrelatedMatter: MatterRecord
    let session: ResearchSessionRecord
    let query: ResearchQueryRecord
    let result: ResearchResultRecord
    let authority: AuthorityRecord
    let reviewedProposition: AuthorityReviewedProposition
    let transport: ArchitectureUXAuthorityTransportProbe

    static func make(prefix: String) throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArchitectureUXTAuth02-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore(url: root.appendingPathComponent("test.sqlite"))
        let matterID = ArchitectureUXAuthorityWorkWire.matterID
        let identity = try seedArchitectureUXIdentityMatter(
            store: store,
            matterID: matterID,
            state: .court,
            legacyJurisdiction: "LEGACY-T-AUTH-02-JURISDICTION-1259",
            legacyCourt: "LEGACY-T-AUTH-02-COURT-1277"
        )
        guard identity.matterID == matterID else {
            throw ArchitectureUXAuthorityFixtureError.identityMismatch
        }
        let unrelatedMatter = try store.matters.createMatter(
            name: "Unrelated T-AUTH-02 matter \(prefix)",
            jurisdiction: "Synthetic unrelated jurisdiction",
            notes: ArchitectureUXAuthorityWorkWire.unrelatedMatterBody
        )
        guard unrelatedMatter.notes == ArchitectureUXAuthorityWorkWire.unrelatedMatterBody else {
            throw ArchitectureUXAuthorityFixtureError.unrelatedMatterMismatch
        }
        let approved = try store.research.createApprovedSessionAtomically(
            matterID: matterID,
            title: "T_AUTH_02_RESEARCH_SESSION_1279",
            issueText: "Synthetic accepted authority issue 1283",
            jurisdiction: ArchitectureUXIdentityEnforcementWire.jurisdictionName,
            queries: [
                .init(
                    queryText: ArchitectureUXAuthorityWorkWire.exactQuery,
                    queryIndex: 17,
                    courtFilter: ArchitectureUXIdentityEnforcementWire.courtID.rawValue
                ),
            ]
        )
        let query = try XCTUnwrap(approved.queries.first)
        try store.research.updateQueryExecution(
            queryID: query.id,
            status: .completed,
            resultCount: 1,
            executedAt: ArchitectureUXAuthorityWorkWire.executedAt,
            requestMetadataJSON: #"{"wire":"t-auth-02-request-1289"}"#,
            responseMetadataJSON: #"{"wire":"t-auth-02-response-1291"}"#
        )
        try store.research.updateSessionStatus(
            sessionID: approved.session.id,
            status: .resultsReady,
            completedAt: ArchitectureUXAuthorityWorkWire.executedAt
        )
        let result = try store.research.insertResult(ResearchResultRecord(
            id: ArchitectureUXAuthorityWorkWire.resultID,
            researchQueryID: query.id,
            courtlistenerID: ArchitectureUXAuthorityWorkWire.providerResultID,
            clusterID: "t-auth-02-cluster-1297",
            opinionID: "t-auth-02-opinion-1301",
            caseName: ArchitectureUXAuthorityWorkWire.caseName,
            citationJSON: "[\"\(ArchitectureUXAuthorityWorkWire.citation)\"]",
            preferredCitation: ArchitectureUXAuthorityWorkWire.citation,
            court: ArchitectureUXIdentityEnforcementWire.courtName,
            courtID: ArchitectureUXIdentityEnforcementWire.courtID.rawValue,
            snippet: "Synthetic reviewed summary 1303",
            absoluteURL: "/synthetic/t-auth-02/opinion/1307/",
            reviewState: ResearchResultReviewState.notAdverse.rawValue,
            rawResultJSON: #"{"provider_wire":"t-auth-02-result-1319"}"#,
            createdAt: ArchitectureUXAuthorityWorkWire.executedAt,
            updatedAt: ArchitectureUXAuthorityWorkWire.executedAt
        ))
        let authority = try store.authorities.insertAuthority(AuthorityRecord(
            id: ArchitectureUXAuthorityWorkWire.authorityID,
            matterID: matterID,
            researchSessionID: approved.session.id,
            researchResultID: result.id,
            courtlistenerID: ArchitectureUXAuthorityWorkWire.providerResultID,
            clusterID: result.clusterID,
            opinionID: result.opinionID,
            caseName: result.caseName,
            citationJSON: result.citationJSON,
            preferredCitation: result.preferredCitation,
            court: result.court,
            courtID: result.courtID,
            absoluteURL: result.absoluteURL,
            precedentialStatus: "Published",
            reviewState: ResearchResultReviewState.notAdverse.rawValue,
            useStatus: AuthorityUseStatus.userMarkedVerified.rawValue,
            opinionText: ArchitectureUXAuthorityWorkWire.opinion,
            rawMetadataJSON: #"{"provider_wire":"t-auth-02-authority-1321"}"#,
            createdAt: ArchitectureUXAuthorityWorkWire.executedAt,
            updatedAt: ArchitectureUXAuthorityWorkWire.executedAt
        ))
        let reviewed = try store.authorities.reviewProposition(
            authorityID: authority.id,
            groundKey: .failureToStateClaim,
            excerpt: ArchitectureUXAuthorityWorkWire.excerpt,
            reviewedBy: ArchitectureUXAuthorityWorkWire.propositionReviewer,
            reviewedAt: ArchitectureUXAuthorityWorkWire.propositionReviewedAt
        )
        let transport = ArchitectureUXAuthorityTransportProbe(
            response: CourtListenerSearchResponse(
                count: 1,
                results: [
                    CourtListenerSearchResultDTO(
                        absoluteURL: result.absoluteURL,
                        caseName: result.caseName,
                        citation: [ArchitectureUXAuthorityWorkWire.citation],
                        clusterID: 1_307,
                        court: result.court,
                        courtID: result.courtID,
                        dateFiled: "2031-07-17",
                        opinions: [
                            CourtListenerOpinionDTO(
                                id: 1_311,
                                snippet: ArchitectureUXAuthorityWorkWire.excerpt
                            ),
                        ],
                        status: "Published"
                    ),
                ]
            )
        )
        return Self(
            root: root,
            store: store,
            matterID: matterID,
            unrelatedMatter: unrelatedMatter,
            session: approved.session,
            query: query,
            result: result,
            authority: authority,
            reviewedProposition: reviewed,
            transport: transport
        )
    }

    func executeReviewAndAccept() async throws -> AcceptedResearchPacketVersion {
        try await executeReviewAndAccept(
            executionID: ArchitectureUXAuthorityWorkWire.firstExecutionID,
            grantVersion: ArchitectureUXAuthorityWorkWire.firstGrantVersion,
            acceptedVersionID: ArchitectureUXAuthorityWorkWire.firstAcceptedVersionID,
            acceptanceKey: ArchitectureUXAuthorityWorkWire.firstAcceptanceKey,
            timeOffset: 0
        )
    }

    func executeReviewAndAcceptSecondVersion() async throws -> AcceptedResearchPacketVersion {
        try await executeReviewAndAccept(
            executionID: ArchitectureUXAuthorityWorkWire.secondExecutionID,
            grantVersion: ArchitectureUXAuthorityWorkWire.secondGrantVersion,
            acceptedVersionID: ArchitectureUXAuthorityWorkWire.secondAcceptedVersionID,
            acceptanceKey: ArchitectureUXAuthorityWorkWire.secondAcceptanceKey,
            timeOffset: 17
        )
    }

    private func executeReviewAndAccept(
        executionID: String,
        grantVersion: Int,
        acceptedVersionID: String,
        acceptanceKey: String,
        timeOffset: TimeInterval
    ) async throws -> AcceptedResearchPacketVersion {
        let egress = try await consumeAndRegisterEgress(
            grantVersion: grantVersion,
            timeOffset: timeOffset
        )
        let consumption = egress.receipt
        let registeredAuthority = egress.authority

        let executed = try store.researchPackets.recordExecuted(
            ResearchPacketExecutionCommand(
                packetID: ArchitectureUXAuthorityWorkWire.packetID,
                executionID: executionID,
                matterID: matterID,
                researchSessionID: session.id,
                researchQueryID: query.id,
                providerID: ArchitectureUXAuthorityWorkWire.providerID,
                egressAuthority: registeredAuthority,
                exactQueryBytes: Data(ArchitectureUXAuthorityWorkWire.exactQuery.utf8),
                orderedResults: [
                    ResearchPacketExecutedResult(
                        researchResultID: result.id,
                        providerResultID: ArchitectureUXAuthorityWorkWire.providerResultID
                    ),
                ],
                executedAt: ArchitectureUXAuthorityWorkWire.executedAt
                    .addingTimeInterval(timeOffset)
            )
        )
        XCTAssertEqual(executed.egressGrantID, consumption.id)
        XCTAssertEqual(executed.egressGrantVersion, grantVersion)
        let consumedRegistration = try XCTUnwrap(
            store.researchPackets.egressConsumptionRegistration(id: consumption.id)
        )
        XCTAssertEqual(consumedRegistration.usedByExecutionID, executionID)
        let reviewed = try store.researchPackets.recordReviewed(
            ResearchPacketReviewCommand(
                executionID: executionID,
                expectedExecutionDigestSHA256: executed.executionDigestSHA256,
                reviewerID: ArchitectureUXAuthorityWorkWire.packetReviewer,
                action: .approvedForAuthorityUse,
                orderedAuthorities: [
                    ResearchPacketAuthoritySelection(
                        researchResultID: result.id,
                        providerResultID: ArchitectureUXAuthorityWorkWire.providerResultID,
                        authorityID: authority.id,
                        groundKey: .failureToStateClaim,
                        expectedReviewedPropositionBindingSHA256:
                            reviewedProposition.bindingSHA256
                    ),
                ],
                expectedSourceDigestSHA256: ArchitectureUXAuthorityWorkWire.sourceDigest(
                    reviewedBindingSHA256: reviewedProposition.bindingSHA256
                ),
                reviewedAt: ArchitectureUXAuthorityWorkWire.reviewedAt
                    .addingTimeInterval(timeOffset)
            )
        )
        return try store.researchPackets.accept(
            ResearchPacketAcceptanceCommand(
                acceptedVersionID: acceptedVersionID,
                idempotencyKey: acceptanceKey,
                executionID: executionID,
                expectedReviewDigestSHA256: reviewed.reviewDigestSHA256,
                acceptedAt: ArchitectureUXAuthorityWorkWire.acceptedAt
                    .addingTimeInterval(timeOffset)
            )
        )
    }

    func consumeAndRegisterEgress(
        grantVersion: Int,
        timeOffset: TimeInterval
    ) async throws -> (
        authority: ResearchPacketEgressAuthority,
        receipt: LegalQueryEgressConsumptionReceipt
    ) {
        let consumption = try await consumeEgress(
            grantVersion: grantVersion,
            timeOffset: timeOffset
        )
        let registrar = ResearchPacketEgressReceiptRegistrar(store: store)
        let registeredAuthority = try registrar.register(.consumed(consumption))
        let registration = try XCTUnwrap(
            store.researchPackets.egressConsumptionRegistration(id: consumption.id)
        )
        XCTAssertEqual(registration.receiptID, consumption.id)
        XCTAssertEqual(registration.providerID, "provider-713")
        XCTAssertEqual(registration.grantVersion, grantVersion)
        XCTAssertEqual(registration.querySHA256, consumption.querySHA256)
        XCTAssertEqual(registration.bindingDigestSHA256, consumption.bindingDigestSHA256)
        XCTAssertNil(registration.usedByExecutionID)
        return (registeredAuthority, consumption)
    }

    func consumeEgress(
        grantVersion: Int,
        timeOffset: TimeInterval
    ) async throws -> LegalQueryEgressConsumptionReceipt {
        let now = ArchitectureUXAuthorityWorkWire.executedAt.addingTimeInterval(timeOffset)
        let intent = LegalQueryEgressIntent(
            providerID: LegalDataProviderID(rawValue: ArchitectureUXAuthorityWorkWire.providerID),
            origin: .formalResearch,
            queryBytes: Data(ArchitectureUXAuthorityWorkWire.exactQuery.utf8),
            purpose: "T_AUTH_02_WIRE_731 accepted research packet execution",
            matterID: matterID,
            researchSessionID: session.id,
            sourceSetDigest: nil,
            classification: .userApprovedQuery
        )
        let gate = LegalQueryEgressGate(
            providerID: LegalDataProviderID(rawValue: ArchitectureUXAuthorityWorkWire.providerID),
            courtListenerClient: transport,
            grantVersion: grantVersion,
            now: { now }
        )
        let preview = try await gate.preview(for: intent)
        XCTAssertEqual(preview.displayedQuery, "QUERY-CANARY-719")
        XCTAssertEqual(preview.queryBytes, Data("QUERY-CANARY-719".utf8))
        XCTAssertEqual(preview.providerID.rawValue, "provider-713")
        XCTAssertEqual(preview.matterID, "T_AUTH_02_WIRE_731")
        XCTAssertFalse(preview.displayedQuery.contains(ArchitectureUXAuthorityWorkWire.unrelatedMatterBody))
        let grant = try await gate.approve(
            preview: preview,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(grant.version, grantVersion)
        let providerExecution = try await gate.searchOpinionsWithConsumptionReceipt(
            CourtListenerSearchRequest(
                query: ArchitectureUXAuthorityWorkWire.exactQuery,
                courtIDs: [ArchitectureUXIdentityEnforcementWire.courtID.rawValue]
            ),
            intent: intent,
            authorization: .grant(grant),
            relatedResearchSessionID: session.id
        )
        XCTAssertEqual(providerExecution.response.count, 1)
        let consumption = providerExecution.consumptionReceipt
        XCTAssertEqual(consumption.providerID.rawValue, "provider-713")
        XCTAssertEqual(consumption.grantVersion, grantVersion)
        XCTAssertEqual(consumption.origin, .formalResearch)
        XCTAssertEqual(consumption.matterID, "T_AUTH_02_WIRE_731")
        XCTAssertEqual(consumption.researchSessionID, session.id)
        XCTAssertEqual(consumption.classification, .userApprovedQuery)
        XCTAssertEqual(
            consumption.querySHA256,
            ArchitectureUXAuthorityWorkWire.rawDigest("QUERY-CANARY-719")
        )
        XCTAssertEqual(consumption.bindingDigestSHA256.count, 64)
        let encodedConsumption = String(
            decoding: try JSONEncoder().encode(consumption),
            as: UTF8.self
        )
        XCTAssertFalse(encodedConsumption.contains("QUERY-CANARY-719"))
        XCTAssertFalse(encodedConsumption.contains(ArchitectureUXAuthorityWorkWire.unrelatedMatterBody))
        return consumption
    }

    func issueUnconsumedGrant(
        grantVersion: Int,
        timeOffset: TimeInterval
    ) async throws -> LegalQueryEgressGrant {
        let now = ArchitectureUXAuthorityWorkWire.executedAt.addingTimeInterval(timeOffset)
        let intent = LegalQueryEgressIntent(
            providerID: LegalDataProviderID(rawValue: ArchitectureUXAuthorityWorkWire.providerID),
            origin: .formalResearch,
            queryBytes: Data(ArchitectureUXAuthorityWorkWire.exactQuery.utf8),
            purpose: "T_AUTH_02_WIRE_731 unconsumed grant negative",
            matterID: matterID,
            researchSessionID: session.id,
            sourceSetDigest: nil,
            classification: .userApprovedQuery
        )
        let gate = LegalQueryEgressGate(
            providerID: LegalDataProviderID(rawValue: ArchitectureUXAuthorityWorkWire.providerID),
            courtListenerClient: transport,
            grantVersion: grantVersion,
            now: { now }
        )
        let preview = try await gate.preview(for: intent)
        return try await gate.approve(
            preview: preview,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
    }
}

private enum ArchitectureUXAuthorityFixtureError: Error {
    case identityMismatch
    case unrelatedMatterMismatch
}

private struct ArchitectureUXAuthoritySideEffectSnapshot: Equatable {
    var tableRowCounts: [String: Int]
    var receiptID: String?
    var receiptProviderID: String?
    var receiptGrantVersion: Int?
    var receiptQuerySHA256: String?
    var receiptBindingDigestSHA256: String?
    var receiptUsedByExecutionID: String?
}

private func authoritySideEffectSnapshot(
    _ store: SupraStore,
    egressReceiptID: String?
) throws -> ArchitectureUXAuthoritySideEffectSnapshot {
    let registration = try egressReceiptID.flatMap {
        try store.researchPackets.egressConsumptionRegistration(id: $0)
    }
    let tableRowCounts = try store.database.writer.read { db in
        let tableNames = try String.fetchAll(
            db,
            sql: """
                SELECT name FROM sqlite_schema
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
        )
        var counts: [String: Int] = [:]
        for tableName in tableNames {
            let quotedName = "\"\(tableName.replacingOccurrences(of: "\"", with: "\"\""))\""
            counts[tableName] = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(quotedName)"
            ) ?? -1
        }
        return counts
    }
    return ArchitectureUXAuthoritySideEffectSnapshot(
        tableRowCounts: tableRowCounts,
        receiptID: registration?.receiptID,
        receiptProviderID: registration?.providerID,
        receiptGrantVersion: registration?.grantVersion,
        receiptQuerySHA256: registration?.querySHA256,
        receiptBindingDigestSHA256: registration?.bindingDigestSHA256,
        receiptUsedByExecutionID: registration?.usedByExecutionID
    )
}

private final class ArchitectureUXAuthorityTransportProbe:
    CourtListenerClientProtocol, @unchecked Sendable
{
    private let lock = NSLock()
    private let response: CourtListenerSearchResponse
    private var recordedRequests: [CourtListenerSearchRequest] = []

    init(response: CourtListenerSearchResponse) {
        self.response = response
    }

    var requests: [CourtListenerSearchRequest] {
        lock.withLock { recordedRequests }
    }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        lock.withLock { recordedRequests.append(request) }
        return response
    }

    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        CourtListenerOpinionDetailDTO(
            id: id,
            plainText: ArchitectureUXAuthorityWorkWire.opinion
        )
    }
}

private final class ArchitectureUXAuthorityRuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPrompts: [String] = []
    private let response: String

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
                        loadTimeMs: 313,
                        firstTokenLatencyMs: 419,
                        tokensPerSecond: 17.19,
                        peakMemoryMb: 1_931,
                        generatedTokenCount: 103
                    )
                ),
            ])
        }
    }
}

private final class StructuredWorkExportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    var action: StructuredOutputController.ExportAction {
        { [self] _, _ in
            lock.withLock { calls += 1 }
            return URL(fileURLWithPath: "/tmp/T_AUTH_02_EXPORT_MUST_NOT_EXIST_1361.md")
        }
    }
}
