import Foundation
import SupraCore
import SupraResearch
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

private final class LegalHydrationClient: CourtListenerClientProtocol, @unchecked Sendable {
    private let response: CourtListenerSearchResponse
    private let failingIDs: Set<Int>
    private let concurrencyProbe: Bool
    private let lock = NSLock()
    private var _fetchedIDs: [Int] = []
    private var activeFetches = 0
    private var _peakActiveFetches = 0
    private var waitingProbeContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        response: CourtListenerSearchResponse,
        failingIDs: Set<Int> = [],
        concurrencyProbe: Bool = false
    ) {
        self.response = response
        self.failingIDs = failingIDs
        self.concurrencyProbe = concurrencyProbe
    }

    var fetchedIDs: [Int] { lock.withLock { _fetchedIDs } }
    var peakActiveFetches: Int { lock.withLock { _peakActiveFetches } }

    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        response
    }

    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        lock.withLock {
            _fetchedIDs.append(id)
            activeFetches += 1
            _peakActiveFetches = max(_peakActiveFetches, activeFetches)
        }
        defer { lock.withLock { activeFetches -= 1 } }
        if concurrencyProbe, id > 4 {
            await withCheckedContinuation { continuation in
                let batch = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    waitingProbeContinuations.append(continuation)
                    guard waitingProbeContinuations.count == 4 else { return [] }
                    defer { waitingProbeContinuations.removeAll(keepingCapacity: true) }
                    return waitingProbeContinuations
                }
                batch.forEach { $0.resume() }
            }
        }
        if failingIDs.contains(id) {
            throw CourtListenerError.serverError(statusCode: 503)
        }
        let body = String(
            repeating: "The court requires meaningful notice before entering default judgment and gives the affected party an opportunity to respond. ",
            count: 4
        )
        return CourtListenerOpinionDetailDTO(id: id, plainText: body)
    }
}

private final class LegalAnswerScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var _answerCalls = 0

    init(answers: [String]) {
        self.answers = answers
    }

    var answerCalls: Int { lock.withLock { _answerCalls } }

    func outcome(for request: GenerateRequest) -> GenerationOutcome {
        guard request.prompt.contains("SOURCE PACKET") else {
            return events(request, token: "no parseable planner queries")
        }
        let token = lock.withLock { () -> String in
            let index = min(_answerCalls, max(answers.count - 1, 0))
            _answerCalls += 1
            return answers[index]
        }
        return events(request, token: token)
    }

    private func events(_ request: GenerateRequest, token: String) -> GenerationOutcome {
        .events([
            .event(request, 1, .token, token: token),
            .event(request, 2, .generationCompleted),
        ])
    }
}

@MainActor
final class LegalHydrationFailClosedTests: XCTestCase {
    func testLowerRankedCitedAuthorityBeyondTopFourIsHydratedBeforeVerification() async throws {
        // ACR-HYDRATE-01 expected RED: only opinion IDs 1...4 are currently
        // hydrated; the cited lower-ranked [A12] remains a short snippet.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Hydration Matter", jurisdiction: "California")
        let client = LegalHydrationClient(response: response(count: 12))
        let script = LegalAnswerScript(answers: [
            "The court requires meaningful notice before entering default judgment [A12]."
        ])
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient(outcome: script.outcome(for:)),
            scope: .matter(id: matter.id),
            courtListenerClient: client
        )
        controller.loadChats()

        await sendResearch(controller)

        XCTAssertEqual(Set(client.fetchedIDs), Set([1, 2, 3, 4, 12]))
        XCTAssertEqual(script.answerCalls, 1)
        let output = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(output.contains("meaningful notice"), output)
        XCTAssertFalse(output.contains("cannot provide a source-grounded legal answer"), output)
    }

    func testEveryCitedAuthorityHydratesWithConcurrencyBoundedAtFour() async throws {
        // ACR-HYDRATE-02 expected RED: the fixed top-four loop never fetches A5...A12
        // and performs its work sequentially.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Concurrency Matter", jurisdiction: "California")
        let client = LegalHydrationClient(response: response(count: 12), concurrencyProbe: true)
        let labels = (1...12).map { "[A\($0)]" }.joined(separator: " ")
        let script = LegalAnswerScript(answers: [
            "The court requires meaningful notice before entering default judgment \(labels)."
        ])
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient(outcome: script.outcome(for:)),
            scope: .matter(id: matter.id),
            courtListenerClient: client
        )
        controller.loadChats()

        await sendResearch(controller)

        XCTAssertEqual(Set(client.fetchedIDs), Set(1...12))
        XCTAssertGreaterThanOrEqual(client.peakActiveFetches, 2, "the cited-source hydrator should actually issue concurrent work")
        XCTAssertLessThanOrEqual(client.peakActiveFetches, 4, "hydration concurrency must remain bounded at four")
    }

    func testFailedHydrationRepairsOnceThenWithholdsBothRejectedAnswers() async throws {
        // ACR-HYDRATE-03 / ACR-REPAIR-01 expected RED: the short snippet under A1
        // currently passes, so no repair occurs and the first rejected prose is shown.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Failure Matter", jurisdiction: "California")
        let client = LegalHydrationClient(response: response(count: 1), failingIDs: [1])
        let firstCanary = "FIRST_UNVERIFIABLE_RULE"
        let secondCanary = "SECOND_UNVERIFIABLE_RULE"
        let script = LegalAnswerScript(answers: [
            "The court requires \(firstCanary) before entering default judgment [A1].",
            "The court requires \(secondCanary) before entering default judgment [A1].",
        ])
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient(outcome: script.outcome(for:)),
            scope: .matter(id: matter.id),
            courtListenerClient: client
        )
        controller.loadChats()

        await sendResearch(controller)

        XCTAssertEqual(script.answerCalls, 2, "one original answer plus exactly one repair")
        XCTAssertTrue(client.fetchedIDs.contains(1), "the cited opinion must be attempted")
        let output = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(output.contains("cannot provide a source-grounded legal answer"), output)
        XCTAssertFalse(output.contains(firstCanary), output)
        XCTAssertFalse(output.contains(secondCanary), output)
    }

    func testMissingOpinionIDRepairsOnceThenWithholds() async throws {
        // ACR-HYDRATE-03 expected RED: an authority without a fetchable opinion ID
        // currently becomes clean solely because its packet label is in range.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Missing ID Matter", jurisdiction: "California")
        let missingIDResult = CourtListenerSearchResultDTO(
            absoluteURL: "/opinion/missing/synthetic/",
            caseName: "Synthetic Missing v. Identifier",
            citation: ["1 F.4th 1"],
            clusterID: 1,
            court: "California Court of Appeal",
            courtID: "calctapp",
            dateFiled: "2024-01-01",
            opinions: [CourtListenerOpinionDTO(snippet: "A short snippet without a fetchable opinion identifier.")],
            status: "Published"
        )
        let client = LegalHydrationClient(
            response: CourtListenerSearchResponse(count: 1, results: [missingIDResult])
        )
        let script = LegalAnswerScript(answers: [
            "The court requires the missing identifier rule before judgment [A1].",
            "The court requires the still missing identifier rule before judgment [A1].",
        ])
        let controller = makeGlobalChatController(
            store: store,
            runtimeClient: StubRuntimeClient(outcome: script.outcome(for:)),
            scope: .matter(id: matter.id),
            courtListenerClient: client
        )
        controller.loadChats()

        await sendResearch(controller)

        XCTAssertEqual(script.answerCalls, 2)
        XCTAssertTrue(client.fetchedIDs.isEmpty)
        let output = try XCTUnwrap(controller.messages.last?.content)
        XCTAssertTrue(output.contains("cannot provide a source-grounded legal answer"), output)
        XCTAssertFalse(output.contains("still missing identifier rule"), output)
    }

    private func response(count: Int) -> CourtListenerSearchResponse {
        CourtListenerSearchResponse(
            count: count,
            results: (1...count).map { id in
                CourtListenerSearchResultDTO(
                    absoluteURL: "/opinion/\(id)/synthetic-case-\(id)/",
                    caseName: "Synthetic Notice \(id) v. Process \(id)",
                    citation: ["\(id) F.4th \(id)"],
                    clusterID: id,
                    court: "California Court of Appeal",
                    courtID: "calctapp",
                    dateFiled: "2024-01-01",
                    opinions: [CourtListenerOpinionDTO(id: id, snippet: "A short search snippet for synthetic authority \(id).")],
                    status: "Published"
                )
            }
        )
    }

    private func sendResearch(_ controller: GlobalChatController) async {
        let route = ModelRouter(configuration: LegalModelConfiguration()).route(for: .legalResearch)
        await controller.performSend(
            prompt: "Research the notice required before default judgment in California.",
            modelID: ModelID(),
            systemPrompt: route.systemPrompt,
            options: route.options,
            route: route
        )
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegalHydrationFailClosedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }
}
