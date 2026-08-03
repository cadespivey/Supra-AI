import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class AuthorityReviewedPropositionTests: XCTestCase {
    private let fixedReviewDate = Date(timeIntervalSince1970: 1_785_513_600)
    private let opinion = "Before the question presented. A complaint fails to state a claim when it omits an essential element. After the holding."
    private let excerpt = "A complaint fails to state a claim when it omits an essential element."
    private let citation = "321 So. 3d 456 (Fla. 4th DCA 2021)"
    private let court = "Florida Fourth District Court of Appeal"
    private let courtID = "fladistctapp4"

    func testTARP01V070AddsNullableEvidenceWithoutBackfill() throws {
        // T-ARP-01 expected RED: the migration registry ends at v069 and the
        // authorities table has no reviewed_proposition_json column.
        let migrator = SupraMigrator.makeMigrator()
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v069_add_verification_dimensions")

        let matter = try MattersRepository(writer: queue).createMatter(name: "Synthetic v070 authority matter")
        let research = ResearchRepository(writer: queue)
        let session = try research.createSession(
            matterID: matter.id,
            title: "Synthetic authority review",
            issueText: "Whether a fictional complaint states a claim",
            jurisdiction: "Florida",
            status: .complete
        )
        let query = try research.createQuery(
            researchSessionID: session.id,
            queryText: "fictional Florida pleading standard",
            queryIndex: 0,
            status: .completed
        )
        let result = try research.insertResult(ResearchResultRecord(
            researchQueryID: query.id,
            caseName: "Harbor LLC v. Palmetto Inc.",
            citationJSON: #"["321 So. 3d 456 (Fla. 4th DCA 2021)"]"#,
            preferredCitation: citation,
            court: court,
            courtID: courtID,
            reviewState: ResearchResultReviewState.notAdverse.rawValue
        ))
        let authorityID = "legacy-v069-authority"
        try queue.write { db in
            XCTAssertFalse(try db.columns(in: "authorities").contains { $0.name == "reviewed_proposition_json" })
            try db.execute(
                sql: """
                INSERT INTO authorities (
                    id, matter_id, research_session_id, research_result_id,
                    case_name, citation_json, preferred_citation, court, court_id,
                    review_state, use_status, opinion_text, raw_metadata_json,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}', ?, ?)
                """,
                arguments: [
                    authorityID, matter.id, session.id, result.id,
                    result.caseName, result.citationJSON, citation, court, courtID,
                    ResearchResultReviewState.notAdverse.rawValue,
                    AuthorityUseStatus.userMarkedVerified.rawValue,
                    opinion, fixedReviewDate, fixedReviewDate,
                ]
            )
        }

        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v070_add_authority_reviewed_proposition")
            let column = try XCTUnwrap(db.columns(in: "authorities").first {
                $0.name == "reviewed_proposition_json"
            })
            XCTAssertFalse(column.isNotNull)
            XCTAssertNil(try String.fetchOne(
                db,
                sql: "SELECT reviewed_proposition_json FROM authorities WHERE id = ?",
                arguments: [authorityID]
            ))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT opinion_text FROM authorities WHERE id = ?", arguments: [authorityID]),
                opinion
            )
        }
    }

    func testTARP02ReviewBindsUniqueOpinionBytesAndWritesContentFreeAudit() throws {
        // T-ARP-02 expected RED: no typed reviewed-proposition envelope or audited
        // reviewProposition repository transaction exists.
        let fixture = try makeFixture()
        let reviewed = try fixture.store.authorities.reviewProposition(
            authorityID: fixture.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: excerpt,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )

        let expectedStart = try XCTUnwrap(Data(opinion.utf8).range(of: Data(excerpt.utf8))).lowerBound
        XCTAssertEqual(reviewed.schemaVersion, 1)
        XCTAssertEqual(reviewed.authorityID, fixture.authority.id)
        XCTAssertEqual(reviewed.groundKey.rawValue, "mtd.failureToStateClaim")
        XCTAssertEqual(reviewed.sourceKind.rawValue, "stored_opinion_text")
        XCTAssertEqual(reviewed.excerpt, excerpt)
        XCTAssertEqual(reviewed.excerptByteStart, expectedStart)
        XCTAssertEqual(reviewed.excerptByteLength, excerpt.utf8.count)
        XCTAssertEqual(reviewed.opinionSHA256, sha256(opinion))
        XCTAssertEqual(reviewed.excerptSHA256, sha256(excerpt))
        XCTAssertEqual(reviewed.effectiveCitationSHA256, sha256(citation))
        XCTAssertEqual(reviewed.courtSHA256, sha256("\(courtID)\u{0}\(court)"))
        XCTAssertEqual(reviewed.reviewedBy, "synthetic-reviewer")
        XCTAssertEqual(reviewed.reviewedAt, fixedReviewDate)
        XCTAssertTrue(isSHA256(reviewed.bindingSHA256))
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .ready(reviewed)
        )
        XCTAssertNotNil(try fixture.store.authorities.fetchAuthority(id: fixture.authority.id)?.reviewedPropositionJSON)

        let audit = try XCTUnwrap(try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_reviewed"
        ).single)
        XCTAssertEqual(audit.actor, "synthetic-reviewer")
        let metadata = try jsonObject(try XCTUnwrap(audit.metadataJSON))
        XCTAssertEqual(Set(metadata.keys), Set([
            "schema_version", "ground_key", "source_kind", "excerpt_byte_start",
            "excerpt_byte_length", "opinion_sha256", "excerpt_sha256",
            "effective_citation_sha256", "court_sha256", "binding_sha256",
        ]))
        XCTAssertEqual(metadata["ground_key"] as? String, "mtd.failureToStateClaim")
        XCTAssertFalse(try XCTUnwrap(audit.metadataJSON).contains(excerpt))
        XCTAssertFalse(try XCTUnwrap(audit.metadataJSON).contains(opinion))
        XCTAssertFalse(try XCTUnwrap(audit.metadataJSON).contains(citation))
        XCTAssertFalse(try XCTUnwrap(audit.metadataJSON).contains(court))
    }

    func testTARP03ReviewUsesUTF8OffsetsAndRejectsNonUniqueOrOversizedEvidence() throws {
        // T-ARP-03 expected RED: review has no exact UTF-8 byte range, uniqueness,
        // or 2,000-byte evidence boundary.
        let unicodePrefix = "§🙂 — "
        let unicodeFixture = try makeFixture(opinion: unicodePrefix + excerpt + " Tail.")
        let unicodeReview = try unicodeFixture.store.authorities.reviewProposition(
            authorityID: unicodeFixture.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: excerpt,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )
        XCTAssertEqual(unicodeReview.excerptByteStart, unicodePrefix.utf8.count)
        XCTAssertEqual(unicodeReview.excerptByteLength, excerpt.utf8.count)

        let duplicate = try makeFixture(opinion: "\(excerpt) Between. \(excerpt)")
        XCTAssertThrowsError(try duplicate.store.authorities.reviewProposition(
            authorityID: duplicate.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: excerpt,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .excerptNotUnique)
        }

        let absent = try makeFixture()
        XCTAssertThrowsError(try absent.store.authorities.reviewProposition(
            authorityID: absent.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: "This exact proposition does not occur in the stored opinion.",
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .excerptNotFound)
        }

        let oversizedText = String(repeating: "x", count: 2_001)
        let oversized = try makeFixture(opinion: oversizedText)
        XCTAssertThrowsError(try oversized.store.authorities.reviewProposition(
            authorityID: oversized.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: oversizedText,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .excerptTooLong(maximumUTF8Bytes: 2_000))
        }

        let empty = try makeFixture()
        XCTAssertThrowsError(try empty.store.authorities.reviewProposition(
            authorityID: empty.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: "",
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .excerptEmpty)
        }
    }

    func testTARP04ReviewRequiresLiveNotAdverseAndUserVerifiedAuthority() throws {
        // T-ARP-04 expected RED: proposition review does not enforce the live,
        // not-adverse, and user-verified preconditions in the writer transaction.
        let adverse = try makeFixture(reviewState: .potentiallyAdverse)
        XCTAssertThrowsError(tryReview(adverse)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .reviewRequiresNotAdverse)
        }

        let unverified = try makeFixture(useStatus: .needsCitatorCheck)
        XCTAssertThrowsError(tryReview(unverified)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .reviewRequiresUserMarkedVerified)
        }

        let missingOpinion = try makeFixtureWithoutOpinion()
        XCTAssertThrowsError(tryReview(missingOpinion)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .opinionTextUnavailable)
        }

        let deleted = try makeFixture()
        XCTAssertTrue(try deleted.store.authorities.softDeleteAuthority(id: deleted.authority.id))
        XCTAssertThrowsError(tryReview(deleted)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .reviewRequiresLiveAuthority)
        }
    }

    func testTARP05UnknownMalformedForgedAndStaleEvidenceFailClosedAtReadTime() throws {
        // T-ARP-05 expected RED: raw evidence is neither versioned nor recomputed
        // against live authority bytes, citation, court, and binding at read time.
        let fixture = try makeFixture()
        _ = try tryReview(fixture)
        let originalJSON = try XCTUnwrap(try fixture.store.authorities.fetchAuthority(id: fixture.authority.id)?.reviewedPropositionJSON)

        try setEvidenceJSON("{", authorityID: fixture.authority.id, store: fixture.store)
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.malformedEvidence)
        )

        var unsupported = try jsonObject(originalJSON)
        unsupported["schema_version"] = 99
        try setEvidenceJSON(try jsonString(unsupported), authorityID: fixture.authority.id, store: fixture.store)
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.unsupportedEvidence)
        )

        var forged = try jsonObject(originalJSON)
        forged["binding_sha256"] = String(repeating: "0", count: 64)
        try setEvidenceJSON(try jsonString(forged), authorityID: fixture.authority.id, store: fixture.store)
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.forgedEvidence)
        )

        try setEvidenceJSON(originalJSON, authorityID: fixture.authority.id, store: fixture.store)
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE authorities SET court_id = ? WHERE id = ?",
                arguments: ["fladistctapp5", fixture.authority.id]
            )
        }
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.staleEvidence)
        )
        XCTAssertNotNil(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store))
    }

    func testTARP06BoundMutationsClearAndAuditWhileUnboundOrIdenticalUpdatesRetain() throws {
        // T-ARP-06 expected RED: authority mutations do not distinguish bound
        // opinion/citation bytes from identical, notes, or summary updates.
        let fixture = try makeFixture()
        let reviewed = try tryReview(fixture)
        let originalJSON = try XCTUnwrap(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store))

        try fixture.store.authorities.updateUserNotes(authorityID: fixture.authority.id, userNotes: "Synthetic non-content note")
        try fixture.store.authorities.updateCaseSummary(authorityID: fixture.authority.id, summary: "Synthetic non-authoritative summary")
        try fixture.store.authorities.updateOpinionText(authorityID: fixture.authority.id, text: opinion)
        try fixture.store.authorities.updatePreferredCitation(authorityID: fixture.authority.id, preferredCitation: citation)
        XCTAssertEqual(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store), originalJSON)
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_review_invalidated"
        ).isEmpty)

        let changedCitation = "999 So. 3d 111 (Fla. 4th DCA 2026)"
        try fixture.store.authorities.updatePreferredCitation(
            authorityID: fixture.authority.id,
            preferredCitation: changedCitation
        )
        XCTAssertNil(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store))
        let citationAudit = try XCTUnwrap(try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_review_invalidated"
        ).first)
        let citationMetadata = try jsonObject(try XCTUnwrap(citationAudit.metadataJSON))
        XCTAssertEqual(citationMetadata["reason"] as? String, "effective_citation_changed")
        XCTAssertEqual(citationMetadata["previous_binding_sha256"] as? String, reviewed.bindingSHA256)
        XCTAssertFalse(try XCTUnwrap(citationAudit.metadataJSON).contains(changedCitation))

        _ = try fixture.store.authorities.reviewProposition(
            authorityID: fixture.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: excerpt,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate.addingTimeInterval(1)
        )
        let changedOpinion = opinion + " A later synthetic paragraph."
        try fixture.store.authorities.updateOpinionText(authorityID: fixture.authority.id, text: changedOpinion)
        XCTAssertNil(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store))
        let invalidations = try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_review_invalidated"
        )
        XCTAssertEqual(invalidations.count, 2)
        XCTAssertEqual(
            try jsonObject(try XCTUnwrap(invalidations.first?.metadataJSON))["reason"] as? String,
            "opinion_bytes_changed"
        )
        XCTAssertFalse(try XCTUnwrap(invalidations.first?.metadataJSON).contains(changedOpinion))
    }

    func testTARP07ReviewAndBoundMutationRollbackWhenTheirAuditCannotCommit() throws {
        // T-ARP-07 expected RED: evidence writes and their content-free audit rows
        // are not guaranteed to share one database transaction.
        let reviewFixture = try makeFixture()
        try installAuditFailureTrigger(eventType: "authority_proposition_reviewed", store: reviewFixture.store)
        XCTAssertThrowsError(try tryReview(reviewFixture))
        XCTAssertNil(try rawEvidenceJSON(authorityID: reviewFixture.authority.id, store: reviewFixture.store))

        let invalidationFixture = try makeFixture()
        _ = try tryReview(invalidationFixture)
        let before = try XCTUnwrap(try invalidationFixture.store.authorities.fetchAuthority(id: invalidationFixture.authority.id))
        try installAuditFailureTrigger(eventType: "authority_proposition_review_invalidated", store: invalidationFixture.store)
        XCTAssertThrowsError(try invalidationFixture.store.authorities.updateOpinionText(
            authorityID: invalidationFixture.authority.id,
            text: opinion + " Mutation that must roll back."
        ))
        let after = try XCTUnwrap(try invalidationFixture.store.authorities.fetchAuthority(id: invalidationFixture.authority.id))
        XCTAssertEqual(after.opinionText, before.opinionText)
        XCTAssertEqual(after.reviewedPropositionJSON, before.reviewedPropositionJSON)
    }

    func testTARP08StatusDowngradeBlocksUseWithoutErasingEvidence() throws {
        // T-ARP-08 expected RED: use-time state does not recheck current adverse
        // and citator statuses independently from the retained review envelope.
        let fixture = try makeFixture()
        let reviewed = try tryReview(fixture)
        let raw = try XCTUnwrap(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store))

        try fixture.store.authorities.updateUseStatus(
            authorityID: fixture.authority.id,
            useStatus: .needsCitatorCheck
        )
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.authorityEligibilityChanged)
        )
        XCTAssertEqual(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store), raw)

        try fixture.store.authorities.updateUseStatus(
            authorityID: fixture.authority.id,
            useStatus: .userMarkedVerified
        )
        try fixture.store.authorities.updateReviewState(
            authorityID: fixture.authority.id,
            reviewState: .potentiallyAdverse
        )
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.authorityEligibilityChanged)
        )
        XCTAssertEqual(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store), raw)

        try fixture.store.authorities.updateReviewState(
            authorityID: fixture.authority.id,
            reviewState: .notAdverse
        )
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .ready(reviewed)
        )
    }

    func testTARP09ExplicitRevocationClearsEvidenceAndAuditsWithoutContent() throws {
        // T-ARP-09 expected RED: no explicit, audited proposition-review
        // revocation API exists.
        let fixture = try makeFixture()
        let reviewed = try tryReview(fixture)
        try fixture.store.authorities.revokePropositionReview(
            authorityID: fixture.authority.id,
            revokedBy: "synthetic-revoker",
            revokedAt: fixedReviewDate.addingTimeInterval(10)
        )
        XCTAssertNil(try rawEvidenceJSON(authorityID: fixture.authority.id, store: fixture.store))
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .notReviewed
        )

        let audit = try XCTUnwrap(try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_review_revoked"
        ).single)
        XCTAssertEqual(audit.actor, "synthetic-revoker")
        let metadata = try jsonObject(try XCTUnwrap(audit.metadataJSON))
        XCTAssertEqual(metadata["ground_key"] as? String, "mtd.failureToStateClaim")
        XCTAssertEqual(metadata["previous_binding_sha256"] as? String, reviewed.bindingSHA256)
        XCTAssertFalse(try XCTUnwrap(audit.metadataJSON).contains(excerpt))
        XCTAssertThrowsError(try fixture.store.authorities.revokePropositionReview(
            authorityID: fixture.authority.id,
            revokedBy: "synthetic-revoker",
            revokedAt: fixedReviewDate.addingTimeInterval(11)
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .propositionReviewNotFound)
        }
    }

    private struct Fixture {
        let store: SupraStore
        let authority: AuthorityRecord
    }

    private func makeFixture(
        opinion: String? = nil,
        reviewState: ResearchResultReviewState = .notAdverse,
        useStatus: AuthorityUseStatus = .userMarkedVerified
    ) throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "Harbor LLC v. Palmetto Inc.",
            jurisdiction: "Florida",
            partyPerspective: .defendant,
            court: court
        )
        let session = try store.research.createSession(
            matterID: matter.id,
            title: "Synthetic motion authority",
            issueText: "Whether a fictional complaint states a claim",
            jurisdiction: "Florida",
            preferredCourts: [courtID],
            status: .complete
        )
        let query = try store.research.createQuery(
            researchSessionID: session.id,
            queryText: "fictional Florida pleading standard",
            queryIndex: 0,
            status: .completed
        )
        let result = try store.research.insertResult(ResearchResultRecord(
            researchQueryID: query.id,
            caseName: "Harbor LLC v. Palmetto Inc.",
            citationJSON: try JSONCoding.encode([citation]),
            preferredCitation: citation,
            court: court,
            courtID: courtID,
            reviewState: reviewState.rawValue,
            rawResultJSON: #"{"source":"synthetic"}"#
        ))
        let authority = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id,
            researchSessionID: session.id,
            researchResultID: result.id,
            caseName: result.caseName,
            citationJSON: result.citationJSON,
            preferredCitation: citation,
            court: court,
            courtID: courtID,
            reviewState: reviewState.rawValue,
            useStatus: useStatus.rawValue,
            opinionText: opinion ?? self.opinion,
            rawMetadataJSON: result.rawResultJSON
        ))
        return Fixture(store: store, authority: authority)
    }

    private func makeFixtureWithoutOpinion(
        reviewState: ResearchResultReviewState = .notAdverse,
        useStatus: AuthorityUseStatus = .userMarkedVerified
    ) throws -> Fixture {
        let fixture = try makeFixture(reviewState: reviewState, useStatus: useStatus)
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE authorities SET opinion_text = NULL WHERE id = ?",
                arguments: [fixture.authority.id]
            )
        }
        return fixture
    }

    private func tryReview(_ fixture: Fixture) throws -> AuthorityReviewedProposition {
        try fixture.store.authorities.reviewProposition(
            authorityID: fixture.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: excerpt,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )
    }

    private func rawEvidenceJSON(authorityID: String, store: SupraStore) throws -> String? {
        try store.database.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT reviewed_proposition_json FROM authorities WHERE id = ?",
                arguments: [authorityID]
            )
        }
    }

    private func setEvidenceJSON(_ json: String, authorityID: String, store: SupraStore) throws {
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE authorities SET reviewed_proposition_json = ? WHERE id = ?",
                arguments: [json, authorityID]
            )
        }
    }

    private func installAuditFailureTrigger(eventType: String, store: SupraStore) throws {
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER synthetic_authority_audit_failure
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = '\(eventType)'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic authority audit failure');
                END
                """)
        }
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        ))
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
