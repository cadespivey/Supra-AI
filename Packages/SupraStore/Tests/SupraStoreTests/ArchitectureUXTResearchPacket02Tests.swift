import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// T-RESEARCH-PACKET-02 — accepted packet versions and their exact ordered
/// sources are immutable. Acceptance and downstream binding are idempotent only
/// for the byte-exact request; altered retries and altered packet digests fail
/// without mutation. A work-product version binds one accepted packet version
/// forever, even when packet versions are later superseded or revoked.
///
/// Expected RED: there is no accepted packet version, immutable source table,
/// acceptance receipt, version disposition, or exact downstream binding in the
/// Store schema/API. Current work products retain at most a research-session ID,
/// so a later “latest packet” lookup can silently change the authority set.
final class ArchitectureUXTResearchPacket02Tests: XCTestCase {
    private let workProductBindingKey = "research-packet-work-binding-769"
    private let boundAt = Date(timeIntervalSince1970: 1_946_333_769)

    func testAcceptedVersionSourcesAndReceiptRejectUpdateOrDelete() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let accepted = try fixture.executeReviewAndAccept()
        let before = try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store)

        let forbiddenMutations: [(String, String)] = [
            (
                "accepted version provider update",
                """
                UPDATE accepted_research_packet_versions
                SET provider_id = 'ALTERED-PROVIDER-773'
                WHERE id = '\(accepted.id)'
                """
            ),
            (
                "accepted version deletion",
                "DELETE FROM accepted_research_packet_versions WHERE id = '\(accepted.id)'"
            ),
            (
                "accepted excerpt update",
                """
                UPDATE accepted_research_packet_sources
                SET excerpt = 'ALTERED-EXCERPT-777'
                WHERE packet_version_id = '\(accepted.id)'
                """
            ),
            (
                "accepted source deletion",
                """
                DELETE FROM accepted_research_packet_sources
                WHERE packet_version_id = '\(accepted.id)'
                """
            ),
            (
                "acceptance receipt update",
                """
                UPDATE research_packet_acceptance_receipts
                SET request_digest_sha256 = '\(String(repeating: "a", count: 64))'
                WHERE idempotency_key = '\(ArchitectureUXResearchPacketWire.acceptanceKey)'
                """
            ),
            (
                "acceptance receipt deletion",
                """
                DELETE FROM research_packet_acceptance_receipts
                WHERE idempotency_key = '\(ArchitectureUXResearchPacketWire.acceptanceKey)'
                """
            ),
        ]

        for mutation in forbiddenMutations {
            XCTAssertThrowsError(
                try fixture.store.database.writer.write { db in
                    try db.execute(sql: mutation.1)
                },
                "v077 must reject \(mutation.0)"
            )
            XCTAssertEqual(
                try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
                before,
                "\(mutation.0) cannot rewrite or partially delete accepted evidence"
            )
        }
        XCTAssertEqual(
            try fixture.store.researchPackets.acceptedVersion(id: accepted.id),
            accepted
        )
    }

    func testExactAcceptanceRetryIsIdempotentAndAlteredRetryRejects() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let reviewed = try fixture.executeAndReview()
        let command = fixture.acceptanceCommand(
            expectedReviewDigestSHA256: reviewed.reviewDigestSHA256
        )
        let first: AcceptedResearchPacketVersion = try fixture.store.researchPackets
            .accept(command)
        let afterFirst = try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store)

        let exactRetry: AcceptedResearchPacketVersion = try fixture.store.researchPackets
            .accept(command)
        XCTAssertEqual(exactRetry, first)
        XCTAssertEqual(
            try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
            afterFirst,
            "an exact acceptance retry must return the existing read-back without new rows or timestamps"
        )

        let alteredRetry = fixture.acceptanceCommand(
            expectedReviewDigestSHA256: reviewed.reviewDigestSHA256,
            acceptedAt: ArchitectureUXResearchPacketWire.acceptedAt.addingTimeInterval(1)
        )
        XCTAssertThrowsError(
            try fixture.store.researchPackets.accept(alteredRetry)
        ) { error in
            XCTAssertEqual(error as? ResearchPacketRepositoryError, .conflictingRetry)
        }
        XCTAssertEqual(
            try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
            afterFirst
        )
        XCTAssertFalse(
            try XCTUnwrap(fixture.store.researchPackets.acceptedVersion(id: first.id))
                .sources.contains { $0.excerpt.contains("ALTERED") }
        )
    }

    func testReviewedAuthorityAlteredBeforeAcceptanceRejectsWithoutPacketMutation() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let reviewed = try fixture.executeAndReview()
        try fixture.store.authorities.revokePropositionReview(
            authorityID: fixture.authority.id,
            matterID: fixture.matter.id,
            revokedBy: "synthetic-revoker-781",
            revokedAt: ArchitectureUXResearchPacketWire.acceptedAt.addingTimeInterval(-1)
        )
        let afterRevocation = try ArchitectureUXTResearchPacket01Tests.snapshot(
            fixture.store
        )

        XCTAssertThrowsError(
            try fixture.store.researchPackets.accept(
                fixture.acceptanceCommand(
                    expectedReviewDigestSHA256: reviewed.reviewDigestSHA256
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ResearchPacketRepositoryError,
                .reviewEvidenceChanged
            )
        }
        XCTAssertEqual(
            try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
            afterRevocation
        )
        XCTAssertNil(
            try fixture.store.researchPackets.acceptedVersion(
                id: ArchitectureUXResearchPacketWire.acceptedVersionID
            )
        )
        XCTAssertEqual(
            try fixture.store.researchPackets.candidate(
                executionID: ArchitectureUXResearchPacketWire.executionID
            )?.state,
            .reviewed
        )
    }

    func testAlteredPacketUseRejectsThenExactBindingIsImmutableAndIdempotent() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let accepted = try fixture.executeReviewAndAccept()
        let beforeBinding = try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store)

        let alteredDigestCommand = ResearchPacketWorkProductBindingCommand(
            idempotencyKey: workProductBindingKey,
            structuredOutputVersionID: fixture.outputVersion.id,
            acceptedPacketVersionID: accepted.id,
            expectedPacketAggregateDigestSHA256: String(repeating: "b", count: 64),
            boundAt: boundAt
        )
        XCTAssertNotEqual(
            alteredDigestCommand.expectedPacketAggregateDigestSHA256,
            accepted.aggregateDigestSHA256
        )
        XCTAssertThrowsError(
            try fixture.store.researchPackets.bindAcceptedVersion(alteredDigestCommand)
        ) { error in
            XCTAssertEqual(error as? ResearchPacketRepositoryError, .packetDigestMismatch)
        }
        XCTAssertEqual(
            try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
            beforeBinding
        )

        let exactCommand = ResearchPacketWorkProductBindingCommand(
            idempotencyKey: workProductBindingKey,
            structuredOutputVersionID: fixture.outputVersion.id,
            acceptedPacketVersionID: accepted.id,
            expectedPacketAggregateDigestSHA256: accepted.aggregateDigestSHA256,
            boundAt: boundAt
        )
        let first: ResearchPacketWorkProductBinding = try fixture.store.researchPackets
            .bindAcceptedVersion(exactCommand)
        XCTAssertEqual(first.structuredOutputVersionID, fixture.outputVersion.id)
        XCTAssertEqual(first.acceptedPacketVersionID, accepted.id)
        XCTAssertEqual(first.packetAggregateDigestSHA256, accepted.aggregateDigestSHA256)
        XCTAssertNotEqual(
            first.packetAggregateDigestSHA256,
            ArchitectureUXResearchPacketWire.forbiddenDefault
        )
        let afterFirst = try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store)

        let exactRetry = try fixture.store.researchPackets.bindAcceptedVersion(exactCommand)
        XCTAssertEqual(exactRetry, first)
        XCTAssertEqual(
            try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
            afterFirst
        )
    }

    func testSecondVersionAndDispositionNeverRetargetExactDownstreamBinding() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let first = try fixture.executeReviewAndAccept()
        let binding = try fixture.store.researchPackets.bindAcceptedVersion(
            ResearchPacketWorkProductBindingCommand(
                idempotencyKey: workProductBindingKey,
                structuredOutputVersionID: fixture.outputVersion.id,
                acceptedPacketVersionID: first.id,
                expectedPacketAggregateDigestSHA256: first.aggregateDigestSHA256,
                boundAt: boundAt
            )
        )
        XCTAssertEqual(binding.acceptedPacketVersionID, first.id)

        let secondReviewed = try fixture.executeAndReview(
            executionID: ArchitectureUXResearchPacketWire.secondExecutionID,
            grantID: ArchitectureUXResearchPacketWire.secondGrantID,
            grantVersion: ArchitectureUXResearchPacketWire.grantVersion + 1,
            executedAt: ArchitectureUXResearchPacketWire.executedAt.addingTimeInterval(10),
            reviewedAt: ArchitectureUXResearchPacketWire.packetReviewedAt.addingTimeInterval(10)
        )
        let second: AcceptedResearchPacketVersion = try fixture.store.researchPackets.accept(
            fixture.acceptanceCommand(
                executionID: ArchitectureUXResearchPacketWire.secondExecutionID,
                versionID: ArchitectureUXResearchPacketWire.secondAcceptedVersionID,
                idempotencyKey: ArchitectureUXResearchPacketWire.secondAcceptanceKey,
                expectedReviewDigestSHA256: secondReviewed.reviewDigestSHA256,
                acceptedAt: ArchitectureUXResearchPacketWire.acceptedAt.addingTimeInterval(10)
            )
        )
        XCTAssertEqual(second.packetID, first.packetID)
        XCTAssertEqual(second.versionIndex, 2)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNotEqual(second.egressGrantID, first.egressGrantID)
        XCTAssertNotEqual(second.aggregateDigestSHA256, first.aggregateDigestSHA256)

        let superseded: ResearchPacketVersionDisposition = try fixture.store.researchPackets
            .recordDisposition(ResearchPacketVersionDispositionCommand(
                idempotencyKey: "research-packet-disposition-773",
                packetVersionID: first.id,
                kind: .superseded,
                replacementPacketVersionID: second.id,
                actor: ArchitectureUXResearchPacketWire.packetReviewer,
                reason: "Synthetic packet refresh 773",
                occurredAt: boundAt.addingTimeInterval(1)
            ))
        XCTAssertEqual(superseded.packetVersionID, first.id)
        XCTAssertEqual(superseded.replacementPacketVersionID, second.id)

        var stillBound: ResearchPacketWorkProductBinding = try XCTUnwrap(
            fixture.store.researchPackets.workProductBinding(
                structuredOutputVersionID: fixture.outputVersion.id
            )
        )
        XCTAssertEqual(stillBound, binding)
        XCTAssertEqual(stillBound.acceptedPacketVersionID, first.id)
        XCTAssertNotEqual(stillBound.acceptedPacketVersionID, second.id)

        let revoked: ResearchPacketVersionDisposition = try fixture.store.researchPackets
            .recordDisposition(ResearchPacketVersionDispositionCommand(
                idempotencyKey: "research-packet-disposition-779",
                packetVersionID: second.id,
                kind: .revoked,
                replacementPacketVersionID: nil,
                actor: ArchitectureUXResearchPacketWire.packetReviewer,
                reason: "Synthetic later review 779",
                occurredAt: boundAt.addingTimeInterval(2)
            ))
        XCTAssertEqual(revoked.packetVersionID, second.id)
        XCTAssertEqual(revoked.kind, .revoked)
        XCTAssertNil(revoked.replacementPacketVersionID)

        stillBound = try XCTUnwrap(
            fixture.store.researchPackets.workProductBinding(
                structuredOutputVersionID: fixture.outputVersion.id
            )
        )
        XCTAssertEqual(stillBound.acceptedPacketVersionID, first.id)
        XCTAssertEqual(stillBound.packetAggregateDigestSHA256, first.aggregateDigestSHA256)

        let beforeRetargetAttempt = try ArchitectureUXTResearchPacket01Tests.snapshot(
            fixture.store
        )
        XCTAssertThrowsError(
            try fixture.store.researchPackets.bindAcceptedVersion(
                ResearchPacketWorkProductBindingCommand(
                    idempotencyKey: "research-packet-retarget-787",
                    structuredOutputVersionID: fixture.outputVersion.id,
                    acceptedPacketVersionID: second.id,
                    expectedPacketAggregateDigestSHA256: second.aggregateDigestSHA256,
                    boundAt: boundAt.addingTimeInterval(3)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ResearchPacketRepositoryError,
                .workProductAlreadyBound
            )
        }
        XCTAssertEqual(
            try ArchitectureUXTResearchPacket01Tests.snapshot(fixture.store),
            beforeRetargetAttempt
        )

        let versions: [AcceptedResearchPacketVersion] = try fixture.store.researchPackets
            .acceptedVersions(packetID: ArchitectureUXResearchPacketWire.packetID)
        XCTAssertEqual(versions.map(\.id), [first.id, second.id])
        XCTAssertEqual(versions.map(\.versionIndex), [1, 2])
        XCTAssertEqual(try fixture.store.researchPackets.acceptedVersion(id: first.id), first)
        XCTAssertEqual(try fixture.store.researchPackets.acceptedVersion(id: second.id), second)
    }
}
