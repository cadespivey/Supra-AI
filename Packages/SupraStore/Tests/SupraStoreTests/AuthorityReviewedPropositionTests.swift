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
            XCTAssertEqual(try appliedMigrations(db).last, "v075_create_grounded_chat_publications")
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

        let audits = try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_reviewed"
        )
        XCTAssertEqual(audits.count, 1)
        let audit = try XCTUnwrap(audits.first)
        XCTAssertEqual(audit.matterID, fixture.authority.matterID)
        XCTAssertEqual(audit.timestamp, fixedReviewDate)
        XCTAssertEqual(audit.actor, "synthetic-reviewer")
        XCTAssertEqual(audit.relatedTable, AuthorityRecord.databaseTableName)
        XCTAssertEqual(audit.relatedID, fixture.authority.id)
        let auditMetadataJSON = try XCTUnwrap(audit.metadataJSON)
        let metadata = try jsonObject(auditMetadataJSON)
        XCTAssertEqual(Set(metadata.keys), Set([
            "schema_version", "ground_key", "source_kind", "excerpt_byte_start",
            "excerpt_byte_length", "opinion_sha256", "excerpt_sha256",
            "effective_citation_sha256", "court_sha256", "binding_sha256",
        ]))
        XCTAssertEqual(metadata["schema_version"] as? Int, 1)
        XCTAssertEqual(metadata["ground_key"] as? String, "mtd.failureToStateClaim")
        XCTAssertEqual(metadata["source_kind"] as? String, "stored_opinion_text")
        XCTAssertEqual(metadata["excerpt_byte_start"] as? Int, expectedStart)
        XCTAssertEqual(metadata["excerpt_byte_length"] as? Int, excerpt.utf8.count)
        XCTAssertEqual(metadata["opinion_sha256"] as? String, reviewed.opinionSHA256)
        XCTAssertEqual(metadata["excerpt_sha256"] as? String, reviewed.excerptSHA256)
        XCTAssertEqual(
            metadata["effective_citation_sha256"] as? String,
            reviewed.effectiveCitationSHA256
        )
        XCTAssertEqual(metadata["court_sha256"] as? String, reviewed.courtSHA256)
        XCTAssertEqual(metadata["binding_sha256"] as? String, reviewed.bindingSHA256)
        XCTAssertFalse(auditMetadataJSON.contains(excerpt))
        XCTAssertFalse(auditMetadataJSON.contains(opinion))
        XCTAssertFalse(auditMetadataJSON.contains(citation))
        XCTAssertFalse(auditMetadataJSON.contains(court))
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

        // Standing boundary guard: exactly 2,000 UTF-8 bytes remain valid even
        // when the character count is much smaller.
        let exactBoundaryText = String(repeating: "🙂", count: 500)
        let exactBoundary = try makeFixture(opinion: "Prefix " + exactBoundaryText + " suffix.")
        let exactBoundaryReview = try exactBoundary.store.authorities.reviewProposition(
            authorityID: exactBoundary.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: exactBoundaryText,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )
        XCTAssertEqual(exactBoundaryText.utf8.count, 2_000)
        XCTAssertEqual(exactBoundaryReview.excerptByteLength, 2_000)

        // Standing UTF-8 wire proof: a character-count implementation would
        // incorrectly accept these 501 characters even though they are 2,004 bytes.
        let multibyteOversizedText = String(repeating: "🙂", count: 501)
        let multibyteOversized = try makeFixture(opinion: multibyteOversizedText)
        XCTAssertThrowsError(try multibyteOversized.store.authorities.reviewProposition(
            authorityID: multibyteOversized.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: multibyteOversizedText,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .excerptTooLong(maximumUTF8Bytes: 2_000))
        }

        let whitespaceOnly = "\n\t\n"
        let whitespace = try makeFixture(opinion: "Lead." + whitespaceOnly + "Tail.")
        XCTAssertThrowsError(try whitespace.store.authorities.reviewProposition(
            authorityID: whitespace.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: whitespaceOnly,
            reviewedBy: "synthetic-reviewer",
            reviewedAt: fixedReviewDate
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .excerptEmpty)
        }

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
        XCTAssertThrowsError(try tryReview(adverse)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .reviewRequiresNotAdverse)
        }

        let unverified = try makeFixture(useStatus: .needsCitatorCheck)
        XCTAssertThrowsError(try tryReview(unverified)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .reviewRequiresUserMarkedVerified)
        }

        let missingOpinion = try makeFixtureWithoutOpinion()
        XCTAssertThrowsError(try tryReview(missingOpinion)) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .opinionTextUnavailable)
        }

        let deleted = try makeFixture()
        XCTAssertTrue(try deleted.store.authorities.softDeleteAuthority(id: deleted.authority.id))
        XCTAssertThrowsError(try tryReview(deleted)) { error in
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

        // Standing transaction guards for the other two audited clearing paths.
        let revocationFixture = try makeFixture()
        _ = try tryReview(revocationFixture)
        let revocationBefore = try XCTUnwrap(try rawEvidenceJSON(
            authorityID: revocationFixture.authority.id,
            store: revocationFixture.store
        ))
        try installAuditFailureTrigger(
            eventType: "authority_proposition_review_revoked",
            store: revocationFixture.store
        )
        XCTAssertThrowsError(try revocationFixture.store.authorities.revokePropositionReview(
            authorityID: revocationFixture.authority.id,
            matterID: revocationFixture.authority.matterID,
            revokedBy: "synthetic-revoker",
            revokedAt: fixedReviewDate.addingTimeInterval(2)
        ))
        XCTAssertEqual(
            try rawEvidenceJSON(authorityID: revocationFixture.authority.id, store: revocationFixture.store),
            revocationBefore
        )

        let citationFixture = try makeFixture()
        _ = try tryReview(citationFixture)
        let citationBefore = try XCTUnwrap(try citationFixture.store.authorities.fetchAuthority(
            id: citationFixture.authority.id
        ))
        try installAuditFailureTrigger(
            eventType: "authority_proposition_review_invalidated",
            store: citationFixture.store
        )
        XCTAssertThrowsError(try citationFixture.store.authorities.updatePreferredCitation(
            authorityID: citationFixture.authority.id,
            preferredCitation: "998 So. 3d 222 (Fla. 4th DCA 2026)"
        ))
        let citationAfter = try XCTUnwrap(try citationFixture.store.authorities.fetchAuthority(
            id: citationFixture.authority.id
        ))
        XCTAssertEqual(citationAfter.preferredCitation, citationBefore.preferredCitation)
        XCTAssertEqual(citationAfter.reviewedPropositionJSON, citationBefore.reviewedPropositionJSON)
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
            matterID: fixture.authority.matterID,
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

        let audits = try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_proposition_review_revoked"
        )
        XCTAssertEqual(audits.count, 1)
        let audit = try XCTUnwrap(audits.first)
        XCTAssertEqual(audit.actor, "synthetic-revoker")
        let auditMetadataJSON = try XCTUnwrap(audit.metadataJSON)
        let metadata = try jsonObject(auditMetadataJSON)
        XCTAssertEqual(metadata["ground_key"] as? String, "mtd.failureToStateClaim")
        XCTAssertEqual(metadata["previous_binding_sha256"] as? String, reviewed.bindingSHA256)
        XCTAssertFalse(auditMetadataJSON.contains(excerpt))
        XCTAssertThrowsError(try fixture.store.authorities.revokePropositionReview(
            authorityID: fixture.authority.id,
            matterID: fixture.authority.matterID,
            revokedBy: "synthetic-revoker",
            revokedAt: fixedReviewDate.addingTimeInterval(11)
        )) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .propositionReviewNotFound)
        }
    }

    func testTARP10BindingCoversReviewerAndDateAndUntrustedSchemaFailsClosed() throws {
        // T-ARP-10 expected RED: self-consistent blank/padded reviewer evidence,
        // whitespace-only proposition text, and non-ASCII digest text can pass
        // the current untrusted read boundary.
        let fixture = try makeFixture()
        let reviewed = try tryReview(fixture)

        let reviewerTamper = try replacingReview(
            reviewed,
            reviewedBy: "different-synthetic-reviewer"
        )
        try setEvidenceJSON(
            try evidenceJSON(reviewerTamper),
            authorityID: fixture.authority.id,
            store: fixture.store
        )
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.forgedEvidence),
            "reviewed_by must participate in the binding digest"
        )

        let dateTamper = try replacingReview(
            reviewed,
            reviewedAt: reviewed.reviewedAt.addingTimeInterval(1)
        )
        try setEvidenceJSON(
            try evidenceJSON(dateTamper),
            authorityID: fixture.authority.id,
            store: fixture.store
        )
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.forgedEvidence),
            "reviewed_at must participate in the binding digest"
        )

        for invalidReviewer in ["   ", " synthetic-reviewer "] {
            let invalid = try replacingReview(
                reviewed,
                reviewedBy: invalidReviewer,
                recomputeBinding: true
            )
            try setEvidenceJSON(
                try evidenceJSON(invalid),
                authorityID: fixture.authority.id,
                store: fixture.store
            )
            XCTAssertEqual(
                try fixture.store.authorities.reviewedPropositionState(
                    authorityID: fixture.authority.id,
                    groundKey: .failureToStateClaim
                ),
                .blocked(.malformedEvidence),
                "reviewed_by must be nonblank and stored in canonical trimmed form"
            )
        }

        let fullwidthDigest = String(repeating: "ａ", count: 64)
        let nonASCIIDigest = try replacingReview(
            reviewed,
            opinionSHA256: fullwidthDigest,
            recomputeBinding: true
        )
        try setEvidenceJSON(
            try evidenceJSON(nonASCIIDigest),
            authorityID: fixture.authority.id,
            store: fixture.store
        )
        XCTAssertEqual(
            try fixture.store.authorities.reviewedPropositionState(
                authorityID: fixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.malformedEvidence),
            "SHA-256 text must be exactly 64 lowercase ASCII hex bytes"
        )

        let whitespaceOnly = "\n\t\n"
        let whitespaceOpinion = "Lead." + whitespaceOnly + excerpt
        let whitespaceFixture = try makeFixture(opinion: whitespaceOpinion)
        let whitespaceBase = try tryReview(whitespaceFixture)
        let whitespaceStart = try XCTUnwrap(
            Data(whitespaceOpinion.utf8).range(of: Data(whitespaceOnly.utf8))
        ).lowerBound
        let whitespaceEvidence = try replacingReview(
            whitespaceBase,
            excerpt: whitespaceOnly,
            excerptByteStart: whitespaceStart,
            excerptByteLength: whitespaceOnly.utf8.count,
            excerptSHA256: sha256(whitespaceOnly),
            recomputeBinding: true
        )
        try setEvidenceJSON(
            try evidenceJSON(whitespaceEvidence),
            authorityID: whitespaceFixture.authority.id,
            store: whitespaceFixture.store
        )
        XCTAssertEqual(
            try whitespaceFixture.store.authorities.reviewedPropositionState(
                authorityID: whitespaceFixture.authority.id,
                groundKey: .failureToStateClaim
            ),
            .blocked(.malformedEvidence)
        )
    }

    func testTARP11ForgedPriorBindingFallsBackToExactRawEvidenceHashInAudit() throws {
        // T-ARP-11 expected RED: the prior-evidence audit path copies any decoded
        // binding string without checking its shape or recomputing it.
        let contentFixture = try makeFixture()
        let contentReview = try tryReview(contentFixture)
        let contentForged = try replacingReview(
            contentReview,
            bindingSHA256: excerpt
        )
        let contentRaw = try evidenceJSON(contentForged)
        try setEvidenceJSON(
            contentRaw,
            authorityID: contentFixture.authority.id,
            store: contentFixture.store
        )
        try contentFixture.store.authorities.revokePropositionReview(
            authorityID: contentFixture.authority.id,
            matterID: contentFixture.authority.matterID,
            revokedBy: "synthetic-revoker",
            revokedAt: fixedReviewDate.addingTimeInterval(20)
        )
        let revocationAudit = try XCTUnwrap(try contentFixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: contentFixture.authority.id,
            eventType: "authority_proposition_review_revoked"
        ).first)
        let revocationMetadataJSON = try XCTUnwrap(revocationAudit.metadataJSON)
        let revocationMetadata = try jsonObject(revocationMetadataJSON)
        XCTAssertNil(revocationMetadata["previous_binding_sha256"])
        XCTAssertEqual(revocationMetadata["previous_evidence_sha256"] as? String, sha256(contentRaw))
        XCTAssertEqual(revocationMetadata["ground_key"] as? String, "unknown")
        XCTAssertFalse(revocationMetadataJSON.contains(excerpt))

        let digestFixture = try makeFixture()
        let digestReview = try tryReview(digestFixture)
        let digestForged = try replacingReview(
            digestReview,
            bindingSHA256: String(repeating: "0", count: 64)
        )
        let digestRaw = try evidenceJSON(digestForged)
        try setEvidenceJSON(
            digestRaw,
            authorityID: digestFixture.authority.id,
            store: digestFixture.store
        )
        try digestFixture.store.authorities.updatePreferredCitation(
            authorityID: digestFixture.authority.id,
            preferredCitation: "997 So. 3d 333 (Fla. 4th DCA 2026)"
        )
        let invalidationAudit = try XCTUnwrap(try digestFixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: digestFixture.authority.id,
            eventType: "authority_proposition_review_invalidated"
        ).first)
        let invalidationMetadata = try jsonObject(try XCTUnwrap(invalidationAudit.metadataJSON))
        XCTAssertNil(invalidationMetadata["previous_binding_sha256"])
        XCTAssertEqual(invalidationMetadata["previous_evidence_sha256"] as? String, sha256(digestRaw))
        XCTAssertEqual(invalidationMetadata["ground_key"] as? String, "unknown")
        XCTAssertEqual(invalidationMetadata["reason"] as? String, "effective_citation_changed")
    }

    func testTARP12GeneralAuthorityInsertRejectsRawReviewedEvidence() throws {
        // T-ARP-12 expected RED: the general public AuthorityRecord/insert path
        // currently persists proposition evidence without the required review audit.
        let fixture = try makeFixture()
        _ = try tryReview(fixture)
        let raw = try XCTUnwrap(try rawEvidenceJSON(
            authorityID: fixture.authority.id,
            store: fixture.store
        ))
        try fixture.store.database.writer.write { db in
            _ = try AuthorityRecord.deleteOne(db, key: fixture.authority.id)
        }

        var injected = fixture.authority
        injected.reviewedPropositionJSON = raw
        XCTAssertThrowsError(try fixture.store.authorities.insertAuthority(injected)) { error in
            XCTAssertEqual(String(describing: error), "untrustedPropositionEvidenceOnInsert")
        }
        XCTAssertNil(try fixture.store.authorities.fetchAuthority(id: fixture.authority.id))
    }

    func testTARP13InsertRejectsAuthorityWhoseResearchLineageDoesNotReachMatter() throws {
        // Expected RED: authorities currently trust three independent foreign keys.
        // A caller can combine a matter, session, and result that do not form the
        // result -> query -> session -> matter chain represented by the authority.
        let fixture = try makeFixture()
        let foreign = try makeResearchLineage(
            store: fixture.store,
            matterName: "Foreign synthetic authority matter"
        )
        let forgedAuthorities: [AuthorityRecord] = [
            {
                var forged = fixture.authority
                forged.id = "foreign-result-authority"
                forged.researchResultID = foreign.result.id
                return forged
            }(),
            {
                var forged = fixture.authority
                forged.id = "foreign-session-authority"
                forged.researchSessionID = foreign.session.id
                return forged
            }(),
            {
                var forged = fixture.authority
                forged.id = "foreign-lineage-authority"
                forged.researchSessionID = foreign.session.id
                forged.researchResultID = foreign.result.id
                return forged
            }(),
        ]

        for forged in forgedAuthorities {
            XCTAssertThrowsError(try fixture.store.authorities.insertAuthority(forged)) { error in
                XCTAssertEqual(
                    error as? AuthorityRepositoryError,
                    .authorityProvenanceMismatch
                )
            }
            XCTAssertNil(try fixture.store.authorities.fetchAuthority(id: forged.id))
        }
    }

    func testTARP14ConflictingInsertNeverReturnsPhantomCallerRecord() throws {
        // Expected RED: INSERT OR IGNORE currently returns the caller's transient
        // value even when SQLite kept a different persisted authority.
        let fixture = try makeFixture()
        var duplicateSource = fixture.authority
        duplicateSource.id = "phantom-authority-id"

        XCTAssertThrowsError(
            try fixture.store.authorities.insertAuthority(duplicateSource)
        ) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .authorityConflict)
        }
        XCTAssertNil(try fixture.store.authorities.fetchAuthority(id: duplicateSource.id))
        XCTAssertEqual(
            try fixture.store.authorities.fetchAuthority(
                researchResultID: fixture.authority.researchResultID
            )?.id,
            fixture.authority.id
        )

        // A primary-key collision with a different, otherwise valid source chain
        // is also a conflict; it must not be reported as the caller's record.
        let secondResult = try appendResult(
            store: fixture.store,
            researchSessionID: fixture.authority.researchSessionID,
            queryIndex: 1,
            caseName: "Second Synthetic Authority"
        )
        var primaryKeyConflict = fixture.authority
        primaryKeyConflict.researchResultID = secondResult.id
        primaryKeyConflict.caseName = secondResult.caseName
        primaryKeyConflict.citationJSON = secondResult.citationJSON

        XCTAssertThrowsError(
            try fixture.store.authorities.insertAuthority(primaryKeyConflict)
        ) { error in
            XCTAssertEqual(error as? AuthorityRepositoryError, .authorityConflict)
        }
        XCTAssertNil(try fixture.store.authorities.fetchAuthority(researchResultID: secondResult.id))
        XCTAssertEqual(
            try fixture.store.authorities.fetchAuthority(id: fixture.authority.id)?.researchResultID,
            fixture.authority.researchResultID
        )

        // The exact idempotent retry returns the row SQLite actually persisted.
        XCTAssertEqual(
            try fixture.store.authorities.insertAuthority(fixture.authority).id,
            fixture.authority.id
        )
    }

    func testTARP15MarkNotAdverseRollsBackWhenLinkedResultOrAuditWriteFails() throws {
        // Expected RED: the UI currently performs three best-effort writes. A
        // linked-result or audit failure can leave split review state with no audit.
        let resultFailure = try makeFixture(reviewState: .needsLaterReview)
        try installResultReviewFailureTrigger(store: resultFailure.store)

        XCTAssertThrowsError(try resultFailure.store.authorities.markNotAdverse(
            authorityID: resultFailure.authority.id,
            matterID: resultFailure.authority.matterID,
            actor: "synthetic-reviewer",
            markedAt: fixedReviewDate
        ))
        try assertReviewStateRolledBack(resultFailure)

        let auditFailure = try makeFixture(reviewState: .needsLaterReview)
        try installAuditFailureTrigger(
            eventType: "authority_review_state_changed",
            store: auditFailure.store
        )

        XCTAssertThrowsError(try auditFailure.store.authorities.markNotAdverse(
            authorityID: auditFailure.authority.id,
            matterID: auditFailure.authority.matterID,
            actor: "synthetic-reviewer",
            markedAt: fixedReviewDate
        ))
        try assertReviewStateRolledBack(auditFailure)
    }

    func testTARP16MarkNotAdverseAtomicallyMirrorsResultAndAuditsOnce() throws {
        let fixture = try makeFixture(reviewState: .needsLaterReview)

        XCTAssertTrue(try fixture.store.authorities.markNotAdverse(
            authorityID: fixture.authority.id,
            matterID: fixture.authority.matterID,
            actor: "synthetic-reviewer",
            markedAt: fixedReviewDate
        ))
        XCTAssertEqual(
            try fixture.store.authorities.fetchAuthority(id: fixture.authority.id)?.reviewState,
            ResearchResultReviewState.notAdverse.rawValue
        )
        XCTAssertEqual(
            try fixture.store.research.fetchResult(
                resultID: fixture.authority.researchResultID
            )?.reviewState,
            ResearchResultReviewState.notAdverse.rawValue
        )
        let audits = try fixture.store.auditEvents.fetchEvents(
            relatedTable: AuthorityRecord.databaseTableName,
            relatedID: fixture.authority.id,
            eventType: "authority_review_state_changed"
        )
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits.first?.matterID, fixture.authority.matterID)
        XCTAssertEqual(audits.first?.actor, "synthetic-reviewer")
        XCTAssertEqual(audits.first?.timestamp, fixedReviewDate)

        XCTAssertFalse(try fixture.store.authorities.markNotAdverse(
            authorityID: fixture.authority.id,
            matterID: fixture.authority.matterID,
            actor: "synthetic-reviewer",
            markedAt: fixedReviewDate.addingTimeInterval(1)
        ))
        XCTAssertEqual(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: AuthorityRecord.databaseTableName,
                relatedID: fixture.authority.id,
                eventType: "authority_review_state_changed"
            ).count,
            1
        )
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

    private func makeResearchLineage(
        store: SupraStore,
        matterName: String
    ) throws -> (session: ResearchSessionRecord, result: ResearchResultRecord) {
        let matter = try store.matters.createMatter(
            name: matterName,
            jurisdiction: "Florida",
            partyPerspective: .defendant,
            court: court
        )
        let session = try store.research.createSession(
            matterID: matter.id,
            title: "Foreign synthetic research",
            issueText: "Whether another fictional complaint states a claim",
            jurisdiction: "Florida",
            status: .complete
        )
        let result = try appendResult(
            store: store,
            researchSessionID: session.id,
            queryIndex: 0,
            caseName: "Foreign Synthetic Authority"
        )
        return (session, result)
    }

    private func appendResult(
        store: SupraStore,
        researchSessionID: String,
        queryIndex: Int,
        caseName: String
    ) throws -> ResearchResultRecord {
        let query = try store.research.createQuery(
            researchSessionID: researchSessionID,
            queryText: "synthetic provenance query \(queryIndex)",
            queryIndex: queryIndex,
            status: .completed
        )
        return try store.research.insertResult(ResearchResultRecord(
            researchQueryID: query.id,
            caseName: caseName,
            citationJSON: try JSONCoding.encode([citation]),
            preferredCitation: citation,
            court: court,
            courtID: courtID,
            reviewState: ResearchResultReviewState.needsLaterReview.rawValue,
            rawResultJSON: #"{"source":"synthetic"}"#
        ))
    }

    private func assertReviewStateRolledBack(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try fixture.store.authorities.fetchAuthority(id: fixture.authority.id)?.reviewState,
            ResearchResultReviewState.needsLaterReview.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try fixture.store.research.fetchResult(
                resultID: fixture.authority.researchResultID
            )?.reviewState,
            ResearchResultReviewState.needsLaterReview.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: AuthorityRecord.databaseTableName,
                relatedID: fixture.authority.id,
                eventType: "authority_review_state_changed"
            ).isEmpty,
            file: file,
            line: line
        )
    }

    private func installResultReviewFailureTrigger(store: SupraStore) throws {
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER synthetic_authority_result_review_failure
                BEFORE UPDATE OF review_state ON research_results
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic result review failure');
                END
                """)
        }
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
        value.utf8.count == 64 && value.utf8.allSatisfy {
            switch $0 {
            case 48...57, 97...102: true
            default: false
            }
        }
    }

    private struct TestBindingPayload: Encodable {
        let schemaVersion: Int
        let authorityID: String
        let groundKey: String
        let sourceKind: String
        let excerpt: String
        let excerptByteStart: Int
        let excerptByteLength: Int
        let opinionSHA256: String
        let excerptSHA256: String
        let effectiveCitationSHA256: String
        let courtSHA256: String
        let reviewedBy: String
        let reviewedAtBitPattern: UInt64
    }

    private func bindingSHA256(_ reviewed: AuthorityReviewedProposition) throws -> String {
        let payload = TestBindingPayload(
            schemaVersion: reviewed.schemaVersion,
            authorityID: reviewed.authorityID,
            groundKey: reviewed.groundKey.rawValue,
            sourceKind: reviewed.sourceKind.rawValue,
            excerpt: reviewed.excerpt,
            excerptByteStart: reviewed.excerptByteStart,
            excerptByteLength: reviewed.excerptByteLength,
            opinionSHA256: reviewed.opinionSHA256,
            excerptSHA256: reviewed.excerptSHA256,
            effectiveCitationSHA256: reviewed.effectiveCitationSHA256,
            courtSHA256: reviewed.courtSHA256,
            reviewedBy: reviewed.reviewedBy,
            reviewedAtBitPattern: reviewed.reviewedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func replacingReview(
        _ original: AuthorityReviewedProposition,
        excerpt: String? = nil,
        excerptByteStart: Int? = nil,
        excerptByteLength: Int? = nil,
        opinionSHA256: String? = nil,
        excerptSHA256: String? = nil,
        reviewedBy: String? = nil,
        reviewedAt: Date? = nil,
        bindingSHA256: String? = nil,
        recomputeBinding: Bool = false
    ) throws -> AuthorityReviewedProposition {
        let candidate = AuthorityReviewedProposition(
            schemaVersion: original.schemaVersion,
            authorityID: original.authorityID,
            groundKey: original.groundKey,
            sourceKind: original.sourceKind,
            excerpt: excerpt ?? original.excerpt,
            excerptByteStart: excerptByteStart ?? original.excerptByteStart,
            excerptByteLength: excerptByteLength ?? original.excerptByteLength,
            opinionSHA256: opinionSHA256 ?? original.opinionSHA256,
            excerptSHA256: excerptSHA256 ?? original.excerptSHA256,
            effectiveCitationSHA256: original.effectiveCitationSHA256,
            courtSHA256: original.courtSHA256,
            bindingSHA256: bindingSHA256 ?? original.bindingSHA256,
            reviewedBy: reviewedBy ?? original.reviewedBy,
            reviewedAt: reviewedAt ?? original.reviewedAt
        )
        guard recomputeBinding else { return candidate }
        return AuthorityReviewedProposition(
            schemaVersion: candidate.schemaVersion,
            authorityID: candidate.authorityID,
            groundKey: candidate.groundKey,
            sourceKind: candidate.sourceKind,
            excerpt: candidate.excerpt,
            excerptByteStart: candidate.excerptByteStart,
            excerptByteLength: candidate.excerptByteLength,
            opinionSHA256: candidate.opinionSHA256,
            excerptSHA256: candidate.excerptSHA256,
            effectiveCitationSHA256: candidate.effectiveCitationSHA256,
            courtSHA256: candidate.courtSHA256,
            bindingSHA256: try self.bindingSHA256(candidate),
            reviewedBy: candidate.reviewedBy,
            reviewedAt: candidate.reviewedAt
        )
    }

    private func evidenceJSON(_ reviewed: AuthorityReviewedProposition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(reviewed), as: UTF8.self)
    }
}
