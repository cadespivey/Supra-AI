import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Shared, synthetic wire for T-RESEARCH-PACKET-01 / 02. The nondefault values
/// are deliberately conspicuous: the tests assert each exact accepted field and
/// separately prove that an unrelated matter body never enters the packet or
/// its content-free normative audit.
enum ArchitectureUXResearchPacketWire {
    static let packetID = "research-packet-713"
    static let executionID = "research-execution-719"
    static let secondExecutionID = "research-execution-757"
    static let acceptedVersionID = "accepted-research-packet-version-727"
    static let secondAcceptedVersionID = "accepted-research-packet-version-761"
    static let acceptanceKey = "research-packet-acceptance-731"
    static let secondAcceptanceKey = "research-packet-acceptance-763"
    static let providerID = "provider-713"
    static let grantID = "egress-grant-717"
    static let secondGrantID = "egress-grant-759"
    static let grantVersion = 7
    static let exactQuery = "QUERY-CANARY-719"
    static let forbiddenDefault = "DEFAULT-BODY-000"

    static let resultID = "research-result-733"
    static let providerResultID = "provider-result-739"
    static let authorityID = "authority-743"
    static let caseName = "Synthetic Packet Authority 743"
    static let citation = "731 F. Supp. 7th 743"
    static let excerpt =
        "The synthetic panel held that WIRE-751 controls the fictional renewal question."
    static let opinion =
        "Opening synthetic text. \(excerpt) Closing synthetic text unique to authority 743."
    static let packetReviewer = "synthetic-packet-reviewer-751"
    static let propositionReviewer = "synthetic-proposition-reviewer-747"
    static let approvedAction = ResearchPacketReviewerAction.approvedForAuthorityUse

    static let executedAt = Date(timeIntervalSince1970: 1_946_333_719)
    static let propositionReviewedAt = Date(timeIntervalSince1970: 1_946_333_743)
    static let packetReviewedAt = Date(timeIntervalSince1970: 1_946_333_751)
    static let acceptedAt = Date(timeIntervalSince1970: 1_946_333_753)

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

struct ArchitectureUXResearchPacketFixture: @unchecked Sendable {
    let store: SupraStore
    let matter: MatterRecord
    let unrelatedMatter: MatterRecord
    let session: ResearchSessionRecord
    let query: ResearchQueryRecord
    let result: ResearchResultRecord
    let authority: AuthorityRecord
    let reviewedProposition: AuthorityReviewedProposition
    let output: StructuredOutputRecord
    let outputVersion: StructuredOutputVersionRecord

    static func make() throws -> Self {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "T_RESEARCH_PACKET_01_WIRE_731",
            jurisdiction: "Synthetic Federal Jurisdiction 713",
            notes: "Exact local packet matter; no default fallback."
        )
        let unrelatedMatter = try store.matters.createMatter(
            name: "Unrelated synthetic matter 737",
            notes: ArchitectureUXResearchPacketWire.forbiddenDefault
        )
        let approved = try store.research.createApprovedSessionAtomically(
            matterID: matter.id,
            title: "T_RESEARCH_PACKET_01 session 713",
            issueText: "Synthetic renewal issue 717",
            jurisdiction: "Synthetic Federal Jurisdiction 713",
            queries: [
                .init(
                    queryText: ArchitectureUXResearchPacketWire.exactQuery,
                    queryIndex: 7,
                    courtFilter: "synthetic-court-719"
                ),
            ]
        )
        let query = try XCTUnwrap(approved.queries.first)
        try store.research.updateQueryExecution(
            queryID: query.id,
            status: .completed,
            resultCount: 1,
            executedAt: ArchitectureUXResearchPacketWire.executedAt,
            requestMetadataJSON: #"{"wire":"request-727"}"#,
            responseMetadataJSON: #"{"wire":"response-729"}"#
        )
        try store.research.updateSessionStatus(
            sessionID: approved.session.id,
            status: .resultsReady,
            completedAt: ArchitectureUXResearchPacketWire.executedAt
        )

        let result = try store.research.insertResult(ResearchResultRecord(
            id: ArchitectureUXResearchPacketWire.resultID,
            researchQueryID: query.id,
            courtlistenerID: ArchitectureUXResearchPacketWire.providerResultID,
            clusterID: "provider-cluster-733",
            opinionID: "provider-opinion-737",
            caseName: ArchitectureUXResearchPacketWire.caseName,
            citationJSON: "[\"\(ArchitectureUXResearchPacketWire.citation)\"]",
            preferredCitation: ArchitectureUXResearchPacketWire.citation,
            court: "Synthetic Packet Court 739",
            courtID: "synthetic-packet-court-739",
            snippet: "Provider summary WIRE-741",
            absoluteURL: "/synthetic/opinion/737/",
            reviewState: ResearchResultReviewState.notAdverse.rawValue,
            rawResultJSON: #"{"provider_wire":"result-739"}"#,
            createdAt: ArchitectureUXResearchPacketWire.executedAt,
            updatedAt: ArchitectureUXResearchPacketWire.executedAt
        ))
        let authority = try store.authorities.insertAuthority(AuthorityRecord(
            id: ArchitectureUXResearchPacketWire.authorityID,
            matterID: matter.id,
            researchSessionID: approved.session.id,
            researchResultID: result.id,
            courtlistenerID: ArchitectureUXResearchPacketWire.providerResultID,
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
            opinionText: ArchitectureUXResearchPacketWire.opinion,
            rawMetadataJSON: #"{"provider_wire":"authority-743"}"#,
            createdAt: ArchitectureUXResearchPacketWire.executedAt,
            updatedAt: ArchitectureUXResearchPacketWire.executedAt
        ))
        let reviewed = try store.authorities.reviewProposition(
            authorityID: authority.id,
            groundKey: .failureToStateClaim,
            excerpt: ArchitectureUXResearchPacketWire.excerpt,
            reviewedBy: ArchitectureUXResearchPacketWire.propositionReviewer,
            reviewedAt: ArchitectureUXResearchPacketWire.propositionReviewedAt
        )

        let output = try store.structuredOutputs.createOutput(
            matterID: matter.id,
            title: "Synthetic downstream work 757",
            outputType: .ruleSynthesis,
            researchSessionID: approved.session.id
        )
        let outputVersion = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id,
            versionIndex: 7,
            contentMarkdown: "T_RESEARCH_PACKET_02_DOWNSTREAM_757",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            makeActive: true
        )
        return Self(
            store: store,
            matter: matter,
            unrelatedMatter: unrelatedMatter,
            session: approved.session,
            query: query,
            result: result,
            authority: authority,
            reviewedProposition: reviewed,
            output: output,
            outputVersion: outputVersion
        )
    }

    func executionCommand(
        executionID: String = ArchitectureUXResearchPacketWire.executionID,
        grantID: String = ArchitectureUXResearchPacketWire.grantID,
        grantVersion: Int = ArchitectureUXResearchPacketWire.grantVersion,
        executedAt: Date = ArchitectureUXResearchPacketWire.executedAt
    ) -> ResearchPacketExecutionCommand {
        ResearchPacketExecutionCommand(
            packetID: ArchitectureUXResearchPacketWire.packetID,
            executionID: executionID,
            matterID: matter.id,
            researchSessionID: session.id,
            researchQueryID: query.id,
            providerID: ArchitectureUXResearchPacketWire.providerID,
            egressAuthority: .approvedGrant(id: grantID, version: grantVersion),
            exactQueryBytes: Data(ArchitectureUXResearchPacketWire.exactQuery.utf8),
            orderedResults: [
                ResearchPacketExecutedResult(
                    researchResultID: result.id,
                    providerResultID: ArchitectureUXResearchPacketWire.providerResultID
                ),
            ],
            executedAt: executedAt
        )
    }

    func reviewCommand(
        executionID: String = ArchitectureUXResearchPacketWire.executionID,
        expectedExecutionDigestSHA256: String,
        reviewedAt: Date = ArchitectureUXResearchPacketWire.packetReviewedAt
    ) -> ResearchPacketReviewCommand {
        ResearchPacketReviewCommand(
            executionID: executionID,
            expectedExecutionDigestSHA256: expectedExecutionDigestSHA256,
            reviewerID: ArchitectureUXResearchPacketWire.packetReviewer,
            action: ArchitectureUXResearchPacketWire.approvedAction,
            orderedAuthorities: [
                ResearchPacketAuthoritySelection(
                    researchResultID: result.id,
                    providerResultID: ArchitectureUXResearchPacketWire.providerResultID,
                    authorityID: authority.id,
                    groundKey: .failureToStateClaim,
                    expectedReviewedPropositionBindingSHA256:
                        reviewedProposition.bindingSHA256
                ),
            ],
            expectedSourceDigestSHA256: ArchitectureUXResearchPacketWire.sourceDigest(
                reviewedBindingSHA256: reviewedProposition.bindingSHA256
            ),
            reviewedAt: reviewedAt
        )
    }

    func acceptanceCommand(
        executionID: String = ArchitectureUXResearchPacketWire.executionID,
        versionID: String = ArchitectureUXResearchPacketWire.acceptedVersionID,
        idempotencyKey: String = ArchitectureUXResearchPacketWire.acceptanceKey,
        expectedReviewDigestSHA256: String,
        acceptedAt: Date = ArchitectureUXResearchPacketWire.acceptedAt
    ) -> ResearchPacketAcceptanceCommand {
        ResearchPacketAcceptanceCommand(
            acceptedVersionID: versionID,
            idempotencyKey: idempotencyKey,
            executionID: executionID,
            expectedReviewDigestSHA256: expectedReviewDigestSHA256,
            acceptedAt: acceptedAt
        )
    }

    func executeAndReview(
        executionID: String = ArchitectureUXResearchPacketWire.executionID,
        grantID: String = ArchitectureUXResearchPacketWire.grantID,
        grantVersion: Int = ArchitectureUXResearchPacketWire.grantVersion,
        executedAt: Date = ArchitectureUXResearchPacketWire.executedAt,
        reviewedAt: Date = ArchitectureUXResearchPacketWire.packetReviewedAt
    ) throws -> ResearchPacketReviewedReceipt {
        let executed = try store.researchPackets.recordExecuted(
            executionCommand(
                executionID: executionID,
                grantID: grantID,
                grantVersion: grantVersion,
                executedAt: executedAt
            )
        )
        return try store.researchPackets.recordReviewed(
            reviewCommand(
                executionID: executionID,
                expectedExecutionDigestSHA256: executed.executionDigestSHA256,
                reviewedAt: reviewedAt
            )
        )
    }

    func executeReviewAndAccept() throws -> AcceptedResearchPacketVersion {
        let reviewed = try executeAndReview()
        return try store.researchPackets.accept(
            acceptanceCommand(expectedReviewDigestSHA256: reviewed.reviewDigestSHA256)
        )
    }
}

/// T-RESEARCH-PACKET-01 — an executed provider result is not legal authority.
/// The Store aggregate must advance through executed → reviewed → accepted,
/// validate the exact egress/query/result/review wire, and commit the immutable
/// version, sources, receipt, terminal candidate state, and normative audit in
/// one transaction.
///
/// Expected RED: `SupraStore.researchPackets`, the typed transition commands,
/// records/errors, and the additive v077 accepted-packet schema do not exist.
/// The current research tables expose freely assignable session/query/result
/// statuses and cannot produce one accepted, exact-version packet aggregate.
final class ArchitectureUXTResearchPacket01Tests: XCTestCase {
    func testV077AppendsAcceptedPacketSchemaAfterArtifactV076() throws {
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertEqual(migrator.migrations.count, 77)
        XCTAssertEqual(Array(migrator.migrations.suffix(3)), [
            "v075_create_grounded_chat_publications",
            "v076_link_export_publication_intents",
            "v077_create_accepted_research_packets",
        ])

        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v075_create_grounded_chat_publications")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO matters (
                    id, name, jurisdiction, party_perspective, notes,
                    created_at, updated_at
                ) VALUES (
                    'legacy-packet-matter-701', 'Legacy packet matter 701',
                    'Synthetic legacy jurisdiction', 'neutral',
                    'LEGACY-RESEARCH-BODY-703',
                    '2031-09-03T12:00:00Z', '2031-09-03T12:00:00Z'
                )
                """)
            try db.execute(sql: """
                INSERT INTO research_sessions (
                    id, matter_id, title, issue_text, jurisdiction,
                    preferred_courts_json, excluded_courts_json, status,
                    created_at, updated_at
                ) VALUES (
                    'legacy-session-705', 'legacy-packet-matter-701',
                    'Legacy session 705', 'Legacy issue 707',
                    'Synthetic legacy jurisdiction', '[]', '[]', 'complete',
                    '2031-09-03T12:00:00Z', '2031-09-03T12:00:00Z'
                )
                """)
            try db.execute(sql: """
                INSERT INTO research_queries (
                    id, research_session_id, query_text, query_index, status,
                    created_at, updated_at
                ) VALUES (
                    'legacy-query-709', 'legacy-session-705',
                    'LEGACY-QUERY-711', 0, 'completed',
                    '2031-09-03T12:00:00Z', '2031-09-03T12:00:00Z'
                )
                """)
            try db.execute(sql: """
                INSERT INTO research_results (
                    id, research_query_id, courtlistener_id, case_name,
                    citation_json, review_state, raw_result_json,
                    created_at, updated_at
                ) VALUES (
                    'legacy-result-713', 'legacy-query-709',
                    'legacy-provider-result-715', 'Legacy synthetic authority 713',
                    '[]', 'saved', '{}',
                    '2031-09-03T12:00:00Z', '2031-09-03T12:00:00Z'
                )
                """)
        }
        try queue.read { db in
            for table in Self.packetTables {
                XCTAssertFalse(try db.tableExists(table), "\(table) must be additive after v075")
            }
        }

        try migrator.migrate(queue)
        try queue.read { db in
            for table in Self.packetTables {
                XCTAssertTrue(try db.tableExists(table), "v077 must create \(table)")
            }
            XCTAssertTrue(
                Set(try db.columns(in: "accepted_research_packet_versions").map(\.name))
                    .isSuperset(of: [
                        "id", "packet_id", "execution_id", "version_index", "state",
                        "matter_id", "research_session_id", "research_query_id",
                        "provider_id", "egress_grant_id", "egress_grant_version",
                        "exact_query_sha256", "source_digest_sha256",
                        "review_digest_sha256", "reviewer_id", "reviewer_action",
                        "aggregate_digest_sha256", "audit_event_id", "accepted_at",
                    ])
            )
            XCTAssertTrue(
                Set(try db.columns(in: "accepted_research_packet_sources").map(\.name))
                    .isSuperset(of: [
                        "packet_version_id", "source_index", "research_result_id",
                        "provider_result_id", "authority_id", "excerpt",
                        "excerpt_sha256", "reviewed_proposition_binding_sha256",
                    ])
            )
            XCTAssertTrue(
                Set(try db.columns(in: "research_packet_work_product_bindings").map(\.name))
                    .isSuperset(of: [
                        "structured_output_version_id", "packet_version_id",
                        "packet_aggregate_digest_sha256", "created_at",
                    ])
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT query_text FROM research_queries WHERE id = 'legacy-query-709'"
                ),
                "LEGACY-QUERY-711"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT review_state FROM research_results WHERE id = 'legacy-result-713'"
                ),
                ResearchResultReviewState.saved.rawValue
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM research_packet_candidates"),
                0,
                "v077 cannot fabricate executed/reviewed/accepted state for legacy rows"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM accepted_research_packet_versions"
                ),
                0,
                "v077 cannot fabricate accepted legal authority from legacy status tokens"
            )
        }
    }

    func testExecutedReviewedAcceptedIsExactAndInvalidSkipCannotMutate() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let executed: ResearchPacketExecutedReceipt = try fixture.store.researchPackets
            .recordExecuted(fixture.executionCommand())
        XCTAssertEqual(executed.packetID, ArchitectureUXResearchPacketWire.packetID)
        XCTAssertEqual(executed.executionID, ArchitectureUXResearchPacketWire.executionID)
        XCTAssertEqual(executed.state, .executed)
        XCTAssertEqual(executed.matterID, fixture.matter.id)
        XCTAssertEqual(executed.researchSessionID, fixture.session.id)
        XCTAssertEqual(executed.researchQueryID, fixture.query.id)
        XCTAssertEqual(executed.providerID, ArchitectureUXResearchPacketWire.providerID)
        XCTAssertEqual(executed.egressGrantID, ArchitectureUXResearchPacketWire.grantID)
        XCTAssertEqual(
            executed.egressGrantVersion,
            ArchitectureUXResearchPacketWire.grantVersion
        )
        XCTAssertEqual(
            executed.exactQuerySHA256,
            ArchitectureUXResearchPacketWire.rawDigest(
                ArchitectureUXResearchPacketWire.exactQuery
            )
        )
        XCTAssertEqual(executed.orderedResearchResultIDs, [fixture.result.id])
        XCTAssertEqual(
            executed.orderedProviderResultIDs,
            [ArchitectureUXResearchPacketWire.providerResultID]
        )
        XCTAssertEqual(executed.executionDigestSHA256.count, 64)
        XCTAssertNotEqual(executed.executionDigestSHA256, String(repeating: "0", count: 64))

        let beforeInvalidSkip = try Self.snapshot(fixture.store)
        XCTAssertThrowsError(
            try fixture.store.researchPackets.accept(
                fixture.acceptanceCommand(
                    expectedReviewDigestSHA256: String(repeating: "7", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ResearchPacketRepositoryError,
                .invalidTransition(expected: .reviewed, actual: .executed)
            )
        }
        XCTAssertEqual(try Self.snapshot(fixture.store), beforeInvalidSkip)

        let reviewed: ResearchPacketReviewedReceipt = try fixture.store.researchPackets
            .recordReviewed(
                fixture.reviewCommand(
                    expectedExecutionDigestSHA256: executed.executionDigestSHA256
                )
            )
        XCTAssertEqual(reviewed.state, .reviewed)
        XCTAssertEqual(reviewed.reviewerID, ArchitectureUXResearchPacketWire.packetReviewer)
        XCTAssertEqual(reviewed.reviewerAction, ArchitectureUXResearchPacketWire.approvedAction)
        XCTAssertEqual(
            reviewed.sourceDigestSHA256,
            ArchitectureUXResearchPacketWire.sourceDigest(
                reviewedBindingSHA256: fixture.reviewedProposition.bindingSHA256
            )
        )
        XCTAssertEqual(reviewed.reviewDigestSHA256.count, 64)
        XCTAssertNotEqual(reviewed.reviewDigestSHA256, executed.executionDigestSHA256)

        let accepted: AcceptedResearchPacketVersion = try fixture.store.researchPackets.accept(
            fixture.acceptanceCommand(
                expectedReviewDigestSHA256: reviewed.reviewDigestSHA256
            )
        )
        Self.assertAcceptedWire(accepted, fixture: fixture)
        XCTAssertEqual(
            try fixture.store.researchPackets.candidate(
                executionID: ArchitectureUXResearchPacketWire.executionID
            )?.state,
            .accepted
        )
    }

    func testCancellationRejectsReviewAndAcceptanceWithoutMutation() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let executed = try fixture.store.researchPackets.recordExecuted(
            fixture.executionCommand()
        )
        let cancelled: ResearchPacketCandidateRecord = try fixture.store.researchPackets.cancel(
            executionID: executed.executionID,
            expectedExecutionDigestSHA256: executed.executionDigestSHA256,
            cancelledBy: "synthetic-canceller-769",
            cancelledAt: ArchitectureUXResearchPacketWire.packetReviewedAt
        )
        XCTAssertEqual(cancelled.state, .cancelled)
        let afterCancellation = try Self.snapshot(fixture.store)

        XCTAssertThrowsError(
            try fixture.store.researchPackets.recordReviewed(
                fixture.reviewCommand(
                    expectedExecutionDigestSHA256: executed.executionDigestSHA256
                )
            )
        ) { error in
            XCTAssertEqual(error as? ResearchPacketRepositoryError, .cancelled)
        }
        XCTAssertEqual(try Self.snapshot(fixture.store), afterCancellation)

        XCTAssertThrowsError(
            try fixture.store.researchPackets.accept(
                fixture.acceptanceCommand(
                    expectedReviewDigestSHA256: String(repeating: "7", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? ResearchPacketRepositoryError, .cancelled)
        }
        XCTAssertEqual(try Self.snapshot(fixture.store), afterCancellation)
    }

    func testExecutionAndReviewAuditFailuresCannotAdvancePacketState() throws {
        do {
            let fixture = try ArchitectureUXResearchPacketFixture.make()
            let before = try Self.snapshot(fixture.store)
            try Self.installTransitionAuditFailure(
                eventType: "research_packet_executed",
                marker: 771,
                store: fixture.store
            )

            XCTAssertThrowsError(
                try fixture.store.researchPackets.recordExecuted(
                    fixture.executionCommand()
                )
            )
            XCTAssertEqual(try Self.snapshot(fixture.store), before)
            XCTAssertNil(
                try fixture.store.researchPackets.candidate(
                    executionID: ArchitectureUXResearchPacketWire.executionID
                )
            )
        }

        do {
            let fixture = try ArchitectureUXResearchPacketFixture.make()
            let executed = try fixture.store.researchPackets.recordExecuted(
                fixture.executionCommand()
            )
            let before = try Self.snapshot(fixture.store)
            try Self.installTransitionAuditFailure(
                eventType: "research_packet_reviewed",
                marker: 773,
                store: fixture.store
            )

            XCTAssertThrowsError(
                try fixture.store.researchPackets.recordReviewed(
                    fixture.reviewCommand(
                        expectedExecutionDigestSHA256: executed.executionDigestSHA256
                    )
                )
            )
            XCTAssertEqual(try Self.snapshot(fixture.store), before)
            XCTAssertEqual(
                try fixture.store.researchPackets.candidate(
                    executionID: ArchitectureUXResearchPacketWire.executionID
                )?.state,
                .executed
            )
        }
    }

    func testAcceptanceBindsEveryExactWireAndNormativeAuditInOneTransaction() throws {
        let fixture = try ArchitectureUXResearchPacketFixture.make()
        let accepted = try fixture.executeReviewAndAccept()
        Self.assertAcceptedWire(accepted, fixture: fixture)

        let source = try XCTUnwrap(accepted.sources.first)
        XCTAssertEqual(source.sourceIndex, 0)
        XCTAssertEqual(source.researchResultID, fixture.result.id)
        XCTAssertEqual(
            source.providerResultID,
            ArchitectureUXResearchPacketWire.providerResultID
        )
        XCTAssertEqual(source.authorityID, fixture.authority.id)
        XCTAssertEqual(source.excerpt, ArchitectureUXResearchPacketWire.excerpt)
        XCTAssertEqual(
            source.excerptSHA256,
            ArchitectureUXResearchPacketWire.rawDigest(
                ArchitectureUXResearchPacketWire.excerpt
            )
        )
        XCTAssertEqual(
            source.reviewedPropositionBindingSHA256,
            fixture.reviewedProposition.bindingSHA256
        )

        let fetched = try XCTUnwrap(
            fixture.store.researchPackets.acceptedVersion(id: accepted.id)
        )
        XCTAssertEqual(fetched, accepted)
        let packetBytes = try JSONEncoder().encode(fetched)
        let packetJSON = String(decoding: packetBytes, as: UTF8.self)
        XCTAssertTrue(packetJSON.contains(ArchitectureUXResearchPacketWire.providerID))
        XCTAssertTrue(packetJSON.contains(ArchitectureUXResearchPacketWire.providerResultID))
        XCTAssertTrue(packetJSON.contains(ArchitectureUXResearchPacketWire.excerpt))
        XCTAssertFalse(packetJSON.contains(ArchitectureUXResearchPacketWire.forbiddenDefault))

        let packetAudits = try fixture.store.auditEvents.fetchEvents(
            matterID: fixture.matter.id
        )
        let acceptedID = accepted.id
        let matchingAudit: AuditEventRecord? = packetAudits.first { event in
            event.eventType == "research_packet_accepted" && event.relatedID == acceptedID
        }
        let audit: AuditEventRecord = try XCTUnwrap(matchingAudit)
        XCTAssertEqual(audit.actor, ArchitectureUXResearchPacketWire.packetReviewer)
        let metadata = try XCTUnwrap(audit.metadataJSON)
        XCTAssertTrue(metadata.contains(ArchitectureUXResearchPacketWire.grantID))
        XCTAssertTrue(metadata.contains(accepted.sourceDigestSHA256))
        XCTAssertTrue(metadata.contains(accepted.aggregateDigestSHA256))
        XCTAssertFalse(metadata.contains(ArchitectureUXResearchPacketWire.exactQuery))
        XCTAssertFalse(metadata.contains(ArchitectureUXResearchPacketWire.excerpt))
        XCTAssertFalse(metadata.contains(ArchitectureUXResearchPacketWire.forbiddenDefault))
    }

    func testFaultAtEveryAcceptanceWriteBoundaryRollsBackEntireAggregate() throws {
        for boundary in AcceptanceWriteBoundary.allCases {
            let fixture = try ArchitectureUXResearchPacketFixture.make()
            let reviewed = try fixture.executeAndReview()
            let before = try Self.snapshot(fixture.store)
            try Self.installFailureTrigger(boundary, store: fixture.store)

            XCTAssertThrowsError(
                try fixture.store.researchPackets.accept(
                    fixture.acceptanceCommand(
                        expectedReviewDigestSHA256: reviewed.reviewDigestSHA256
                    )
                ),
                "T-RESEARCH-PACKET-01 must observe the injected \(boundary.rawValue) failure"
            )
            XCTAssertEqual(
                try Self.snapshot(fixture.store),
                before,
                "\(boundary.rawValue) must not expose a partial accepted packet"
            )
            XCTAssertEqual(
                try fixture.store.researchPackets.candidate(
                    executionID: ArchitectureUXResearchPacketWire.executionID
                )?.state,
                .reviewed
            )
            XCTAssertNil(
                try fixture.store.researchPackets.acceptedVersion(
                    id: ArchitectureUXResearchPacketWire.acceptedVersionID
                )
            )
        }
    }

    static func assertAcceptedWire(
        _ accepted: AcceptedResearchPacketVersion,
        fixture: ArchitectureUXResearchPacketFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            accepted.id,
            ArchitectureUXResearchPacketWire.acceptedVersionID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.packetID,
            ArchitectureUXResearchPacketWire.packetID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.executionID,
            ArchitectureUXResearchPacketWire.executionID,
            file: file,
            line: line
        )
        XCTAssertEqual(accepted.versionIndex, 1, file: file, line: line)
        XCTAssertEqual(accepted.state, .accepted, file: file, line: line)
        XCTAssertEqual(accepted.matterID, fixture.matter.id, file: file, line: line)
        XCTAssertEqual(
            accepted.researchSessionID,
            fixture.session.id,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.researchQueryID,
            fixture.query.id,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.providerID,
            ArchitectureUXResearchPacketWire.providerID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.egressGrantID,
            ArchitectureUXResearchPacketWire.grantID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.egressGrantVersion,
            ArchitectureUXResearchPacketWire.grantVersion,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.exactQuerySHA256,
            ArchitectureUXResearchPacketWire.rawDigest(
                ArchitectureUXResearchPacketWire.exactQuery
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.sourceDigestSHA256,
            ArchitectureUXResearchPacketWire.sourceDigest(
                reviewedBindingSHA256: fixture.reviewedProposition.bindingSHA256
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.reviewerID,
            ArchitectureUXResearchPacketWire.packetReviewer,
            file: file,
            line: line
        )
        XCTAssertEqual(
            accepted.reviewerAction,
            ArchitectureUXResearchPacketWire.approvedAction,
            file: file,
            line: line
        )
        XCTAssertEqual(accepted.reviewDigestSHA256.count, 64, file: file, line: line)
        XCTAssertEqual(accepted.sources.count, 1, file: file, line: line)
        XCTAssertEqual(accepted.aggregateDigestSHA256.count, 64, file: file, line: line)
        XCTAssertNotEqual(
            accepted.aggregateDigestSHA256,
            String(repeating: "0", count: 64),
            file: file,
            line: line
        )
    }

    static func snapshot(_ store: SupraStore) throws -> PacketDatabaseSnapshot {
        try store.database.writer.read { db in
            PacketDatabaseSnapshot(
                candidates: try canonicalRows("research_packet_candidates", db: db),
                candidateSources: try canonicalRows(
                    "research_packet_candidate_sources",
                    db: db
                ),
                versions: try canonicalRows("accepted_research_packet_versions", db: db),
                versionSources: try canonicalRows(
                    "accepted_research_packet_sources",
                    db: db
                ),
                receipts: try canonicalRows(
                    "research_packet_acceptance_receipts",
                    db: db
                ),
                dispositions: try canonicalRows(
                    "research_packet_version_dispositions",
                    db: db
                ),
                bindings: try canonicalRows(
                    "research_packet_work_product_bindings",
                    db: db
                ),
                audits: try canonicalRows(
                    "audit_events",
                    whereClause: "event_type LIKE 'research_packet_%'",
                    db: db
                )
            )
        }
    }

    private static let packetTables = [
        "research_packet_candidates",
        "research_packet_candidate_sources",
        "accepted_research_packet_versions",
        "accepted_research_packet_sources",
        "research_packet_acceptance_receipts",
        "research_packet_version_dispositions",
        "research_packet_work_product_bindings",
    ]

    private static func canonicalRows(
        _ table: String,
        whereClause: String? = nil,
        db: Database
    ) throws -> [String] {
        let columns = try db.columns(in: table).map(\.name)
        let projection = columns
            .map { "quote(\($0))" }
            .joined(separator: " || '|' || ")
        let filter = whereClause.map { " WHERE \($0)" } ?? ""
        return try String.fetchAll(
            db,
            sql: "SELECT \(projection) FROM \(table)\(filter) ORDER BY 1"
        )
    }

    private static func installFailureTrigger(
        _ boundary: AcceptanceWriteBoundary,
        store: SupraStore
    ) throws {
        try store.database.writer.write { db in
            switch boundary {
            case .version:
                try db.execute(sql: """
                    CREATE TRIGGER fail_research_packet_version_731
                    BEFORE INSERT ON accepted_research_packet_versions
                    BEGIN SELECT RAISE(ABORT, 'wire version failure'); END
                    """)
            case .source:
                try db.execute(sql: """
                    CREATE TRIGGER fail_research_packet_source_733
                    BEFORE INSERT ON accepted_research_packet_sources
                    BEGIN SELECT RAISE(ABORT, 'wire source failure'); END
                    """)
            case .receipt:
                try db.execute(sql: """
                    CREATE TRIGGER fail_research_packet_receipt_739
                    BEFORE INSERT ON research_packet_acceptance_receipts
                    BEGIN SELECT RAISE(ABORT, 'wire receipt failure'); END
                    """)
            case .audit:
                try db.execute(sql: """
                    CREATE TRIGGER fail_research_packet_audit_743
                    BEFORE INSERT ON audit_events
                    WHEN NEW.event_type = 'research_packet_accepted'
                    BEGIN SELECT RAISE(ABORT, 'wire audit failure'); END
                    """)
            case .terminalState:
                try db.execute(sql: """
                    CREATE TRIGGER fail_research_packet_terminal_751
                    BEFORE UPDATE OF state ON research_packet_candidates
                    WHEN NEW.state = 'accepted'
                    BEGIN SELECT RAISE(ABORT, 'wire terminal failure'); END
                    """)
            }
        }
    }

    private static func installTransitionAuditFailure(
        eventType: String,
        marker: Int,
        store: SupraStore
    ) throws {
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_research_packet_transition_\(marker)
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = '\(eventType)'
                BEGIN SELECT RAISE(ABORT, 'wire transition audit failure'); END
                """)
        }
    }
}

struct PacketDatabaseSnapshot: Equatable {
    let candidates: [String]
    let candidateSources: [String]
    let versions: [String]
    let versionSources: [String]
    let receipts: [String]
    let dispositions: [String]
    let bindings: [String]
    let audits: [String]
}

private enum AcceptanceWriteBoundary: String, CaseIterable {
    case version
    case source
    case receipt
    case audit
    case terminalState = "terminal_state"
}
