import Foundation
import SupraResearch
import XCTest

/// Synthetic, non-client fixture shared by the T-EGRESS-03...05 RED gates.
///
/// The non-default values are deliberately unrelated to the product defaults so a
/// future implementation cannot satisfy the wire proofs by ignoring a binding.
struct ArchitectureUXEgressFixture: Sendable {
    let providerID = LegalDataProviderID(rawValue: "provider-713")
    let mismatchedProviderID = LegalDataProviderID(rawValue: "provider-719")
    let matterID = "T_EGRESS_WIRE_731"
    let mismatchedMatterID = "T_EGRESS_WIRE_737"
    let sessionID = "research-session-733"
    let mismatchedSessionID = "research-session-739"
    let query = "QUERY-CANARY-719"
    let alteredQuery = "QUERY-CANARY-719 "
    let purpose = "authority-search-purpose-727"
    let mismatchedPurpose = "authority-search-purpose-729"
    let sourceSetDigest = "source-set-digest-743"
    let mismatchedSourceSetDigest = "source-set-digest-749"
    let grantVersion = 7

    func intent(
        providerID: LegalDataProviderID? = nil,
        origin: LegalQueryEgressOrigin = .formalResearch,
        query: String? = nil,
        purpose: String? = nil,
        matterID: String? = nil,
        sessionID: String? = nil,
        sourceSetDigest: String? = nil,
        classification: LegalQueryEgressClassification = .matterDerived
    ) -> LegalQueryEgressIntent {
        LegalQueryEgressIntent(
            providerID: providerID ?? self.providerID,
            origin: origin,
            queryBytes: Data((query ?? self.query).utf8),
            purpose: purpose ?? self.purpose,
            matterID: matterID ?? self.matterID,
            researchSessionID: sessionID ?? self.sessionID,
            sourceSetDigest: sourceSetDigest ?? self.sourceSetDigest,
            classification: classification
        )
    }

    func request(query: String? = nil) -> CourtListenerSearchRequest {
        CourtListenerSearchRequest(
            query: query ?? self.query,
            orderBy: "score desc",
            courtIDs: ["ca11"]
        )
    }
}

actor ArchitectureUXEgressCourtListenerRecorder: CourtListenerClientProtocol {
    struct Call: Sendable, Equatable {
        let request: CourtListenerSearchRequest
        let relatedResearchSessionID: String?
    }

    private var calls: [Call] = []
    private var citationCalls: [[String]] = []
    private let response: CourtListenerSearchResponse

    init(response: CourtListenerSearchResponse = .init(count: 0, results: [])) {
        self.response = response
    }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        calls.append(Call(request: request, relatedResearchSessionID: relatedResearchSessionID))
        return response
    }

    func recordedCalls() -> [Call] { calls }

    func resolveCitations(_ citations: [String]) async throws -> [CourtListenerCitationLookupDTO] {
        citationCalls.append(citations)
        return []
    }

    func recordedCitationCalls() -> [[String]] { citationCalls }
}

final class ArchitectureUXEgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

extension XCTestCase {
    func assertEgressError(
        _ expected: LegalQueryEgressError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected legal-query egress to fail with \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LegalQueryEgressError, expected, file: file, line: line)
        }
    }
}
