import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraStore
import XCTest
@testable import SupraSessions

private struct PropositionReviewTokenStore: APIKeyStoreProtocol, Sendable {
    var token: String? = "test-token"

    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { token }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { token != nil }
}

private final class PropositionReviewOpinionClient: CourtListenerClientProtocol, @unchecked Sendable {
    enum Outcome: Sendable {
        case detail(CourtListenerOpinionDetailDTO)
        case failure(CourtListenerError)
    }

    private let outcome: Outcome
    private let lock = NSLock()
    private var fetchedIDsStorage: [Int] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    var fetchedIDs: [Int] {
        lock.withLock { fetchedIDsStorage }
    }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        CourtListenerSearchResponse(count: 0, results: [])
    }

    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        lock.withLock { fetchedIDsStorage.append(id) }
        switch outcome {
        case .detail(let detail): return detail
        case .failure(let error): throw error
        }
    }
}

@MainActor
final class AuthoritiesControllerReviewedPropositionTests: XCTestCase {
    func testRecordFetchesAndPersistsExactOpinionBytesBeforeReview() async throws {
        let opinion = "  Opening line.\nThe court’s exact holding survives byte-for-byte.\nClosing line.  "
        let excerpt = "The court’s exact holding survives byte-for-byte."
        let fixture = try makeFixture(opinionID: "42")
        var profile = AssistantProfile()
        profile.fullName = "  Avery Quinn  \n"
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        let client = PropositionReviewOpinionClient(.detail(.init(id: 42, plainText: opinion)))
        let controller = makeController(fixture: fixture, client: client)
        controller.load()

        let message = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: excerpt
        )

        XCTAssertNil(message)
        XCTAssertEqual(client.fetchedIDs, [42])
        let persisted = try XCTUnwrap(fixture.store.authorities.fetchAuthority(id: fixture.authority.id)?.opinionText)
        XCTAssertEqual(Data(persisted.utf8), Data(opinion.utf8))
        guard case .ready(let reviewed)? = controller.authorities.first?.failureToStateClaimReviewState else {
            return XCTFail("Controller did not publish ready proposition evidence")
        }
        XCTAssertEqual(reviewed.excerpt, excerpt)
        XCTAssertEqual(reviewed.reviewedBy, "Avery Quinn")
    }

    func testPreparationUsesStoredOpinionWithoutFetching() async throws {
        let opinion = "Persisted opinion text."
        let fixture = try makeFixture(opinionID: "42", opinionText: opinion)
        let client = PropositionReviewOpinionClient(.failure(.invalidResponse))
        let controller = makeController(fixture: fixture, client: client)

        let preparation = await controller.prepareOpinionForPropositionReview(authorityID: fixture.authority.id)

        XCTAssertEqual(preparation, .ready(text: opinion, fetchedDetail: nil))
        XCTAssertTrue(client.fetchedIDs.isEmpty)
    }

    func testBlankProfileUsesLiteralLocalUserActor() async throws {
        let opinion = "The unique proposition appears here."
        let fixture = try makeFixture(opinionText: opinion)
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: AssistantProfile.empty)
        let controller = makeController(fixture: fixture)
        controller.load()

        let message = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: opinion
        )
        XCTAssertNil(message)

        guard case .ready(let reviewed)? = controller.authorities.first?.failureToStateClaimReviewState else {
            return XCTFail("Controller did not publish ready proposition evidence")
        }
        XCTAssertEqual(reviewed.reviewedBy, "Local user")
    }

    func testRecordReturnsLiteralExcerptAndEligibilityErrors() async throws {
        let fixture = try makeFixture(opinionText: "Repeat passage. Repeat passage.")
        let controller = makeController(fixture: fixture)

        let empty = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: ""
        )
        XCTAssertEqual(empty, "Enter an exact excerpt from the stored opinion.")
        let missing = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: "Missing passage."
        )
        XCTAssertEqual(missing, "That exact excerpt was not found in the stored opinion.")
        let duplicate = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: "Repeat passage."
        )
        XCTAssertEqual(duplicate, "That excerpt appears more than once. Select a longer unique excerpt.")
        let tooLong = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: String(repeating: "é", count: 1_001)
        )
        XCTAssertEqual(tooLong, "The excerpt must be 2,000 UTF-8 bytes or fewer.")

        try fixture.store.authorities.updateReviewState(
            authorityID: fixture.authority.id,
            reviewState: .needsLaterReview
        )
        let adverse = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: "Repeat passage. Repeat passage."
        )
        XCTAssertEqual(adverse, "Mark this authority not adverse before recording proposition support.")
        try fixture.store.authorities.updateReviewState(authorityID: fixture.authority.id, reviewState: .notAdverse)
        try fixture.store.authorities.updateUseStatus(authorityID: fixture.authority.id, useStatus: .needsCitatorCheck)
        let unverified = await controller.recordFailureToStateClaimReview(
            authorityID: fixture.authority.id,
            excerpt: "Repeat passage. Repeat passage."
        )
        XCTAssertEqual(unverified, "Mark this authority verified before recording proposition support.")
    }

    func testLoadExposesBlockedStateAndRevokeClearsIt() throws {
        let opinion = "The unique proposition appears here."
        let fixture = try makeFixture(opinionText: opinion)
        _ = try fixture.store.authorities.reviewProposition(
            authorityID: fixture.authority.id,
            groundKey: .failureToStateClaim,
            excerpt: opinion,
            reviewedBy: "Original Reviewer"
        )
        try fixture.store.authorities.updateUseStatus(authorityID: fixture.authority.id, useStatus: .doNotUse)
        var profile = AssistantProfile()
        profile.fullName = "  Revoking Reviewer  "
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        let controller = makeController(fixture: fixture)
        controller.load()

        XCTAssertEqual(
            controller.authorities.first?.failureToStateClaimReviewState,
            .blocked(.authorityEligibilityChanged)
        )
        XCTAssertNil(controller.revokeFailureToStateClaimReview(authorityID: fixture.authority.id))
        XCTAssertEqual(controller.authorities.first?.failureToStateClaimReviewState, .notReviewed)
        let revoke = try XCTUnwrap(
            fixture.store.auditEvents.fetchEvents(matterID: fixture.matterID)
                .first { $0.eventType == "authority_proposition_review_revoked" }
        )
        XCTAssertEqual(revoke.actor, "Revoking Reviewer")
    }

    func testPreparationReturnsLiteralUnavailableMessages() async throws {
        let noOpinion = try makeFixture()
        let noOpinionController = makeController(fixture: noOpinion)
        let noOpinionPreparation = await noOpinionController.prepareOpinionForPropositionReview(
            authorityID: noOpinion.authority.id
        )
        XCTAssertEqual(
            noOpinionPreparation,
            .unavailable(message: "No opinion text is available for this authority.")
        )

        let fetchFailure = try makeFixture(opinionID: "42")
        let failureController = makeController(
            fixture: fetchFailure,
            client: PropositionReviewOpinionClient(.failure(.invalidResponse))
        )
        let failedPreparation = await failureController.prepareOpinionForPropositionReview(
            authorityID: fetchFailure.authority.id
        )
        XCTAssertEqual(
            failedPreparation,
            .unavailable(message: "Couldn't fetch the opinion from CourtListener. Try again.")
        )

        let blankBody = try makeFixture(opinionID: "43")
        let blankController = makeController(
            fixture: blankBody,
            client: PropositionReviewOpinionClient(.detail(.init(id: 43, plainText: " \n ")))
        )
        let blankPreparation = await blankController.prepareOpinionForPropositionReview(
            authorityID: blankBody.authority.id
        )
        XCTAssertEqual(
            blankPreparation,
            .unavailable(message: "CourtListener did not return readable opinion text.")
        )
    }

    private struct Fixture {
        let store: SupraStore
        let matterID: String
        let authority: AuthorityRecord
    }

    private func makeFixture(
        opinionID: String? = nil,
        opinionText: String? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthorityReviewController-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "Synthetic matter")
        let session = try store.research.createSession(
            matterID: matter.id,
            title: "Synthetic authority review",
            issueText: "Failure to state a claim",
            jurisdiction: "Florida",
            status: .approved
        )
        let query = try store.research.createQuery(
            researchSessionID: session.id,
            queryText: "synthetic query",
            queryIndex: 0,
            status: .approved
        )
        let result = try store.research.insertResult(ResearchResultRecord(
            researchQueryID: query.id,
            caseName: "Fictional Review Authority"
        ))
        let authority = try store.authorities.insertAuthority(AuthorityRecord(
            matterID: matter.id,
            researchSessionID: session.id,
            researchResultID: result.id,
            opinionID: opinionID,
            caseName: "Fictional Review Authority",
            citationJSON: #"["999 So. 3d 1"]"#,
            preferredCitation: "999 So. 3d 1",
            court: "Florida District Court of Appeal",
            courtID: "fladistctapp",
            reviewState: ResearchResultReviewState.notAdverse.rawValue,
            useStatus: AuthorityUseStatus.userMarkedVerified.rawValue,
            opinionText: opinionText
        ))
        return Fixture(store: store, matterID: matter.id, authority: authority)
    }

    private func makeController(
        fixture: Fixture,
        client: PropositionReviewOpinionClient = PropositionReviewOpinionClient(.failure(.invalidResponse))
    ) -> AuthoritiesController {
        AuthoritiesController(
            store: fixture.store,
            matterID: fixture.matterID,
            tokenStore: PropositionReviewTokenStore(),
            courtListenerClient: client
        )
    }
}
