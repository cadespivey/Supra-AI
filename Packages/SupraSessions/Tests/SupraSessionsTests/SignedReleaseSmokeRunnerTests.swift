import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

/// RED: these contracts intentionally do not compile until the repository owns a
/// signed-release runner and a content-free, source/app/model-bound report.
final class SignedReleaseSmokeRunnerTests: XCTestCase {
    private let expectedModelSHA256 = "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"
    private let tokenCanary = "PRIVATE-GENERATED-TOKEN-CANARY"

    func testRunUsesFixedRequestAndReturnsContentFreeBoundAttestation() async throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let generatedTokenCanary = tokenCanary
        let client = SignedSmokeRuntimeClientFake(
            stream: { request in
                Self.stream(events: Self.validEvents(for: request, token: generatedTokenCanary))
            }
        )
        let runner = SignedReleaseSmokeRunner(runtimeClient: client)

        let report: SignedReleaseSmokeReport = try await runner.run(
            authorization: authorization,
            binding: binding
        )

        let request = try XCTUnwrap(client.generateRequests.first)
        let loadRequest = try XCTUnwrap(client.loadRequests.first)
        XCTAssertEqual(request.modelID, loadRequest.modelID)
        XCTAssertEqual(
            request.prompt,
            "Return one short sentence confirming that local model inference is operational."
        )
        XCTAssertEqual(
            request.systemPrompt,
            "This is a local release validation. Reply briefly and do not repeat sensitive data."
        )
        XCTAssertEqual(request.history.count, 0)
        XCTAssertEqual(
            request.options,
            GenerationOptions(
                preset: .precise,
                temperature: 0,
                topP: 1,
                topK: nil,
                maxContextTokens: 2_048,
                maxOutputTokens: 32,
                thinkingBudget: .off,
                repetitionPenalty: nil
            )
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.status, "passed")
        XCTAssertEqual(report.sourceSHA, binding.sourceSHA)
        XCTAssertEqual(report.appTreeSHA256, binding.appTreeSHA256)
        XCTAssertEqual(report.modelSHA256, expectedModelSHA256)
        XCTAssertEqual(report.nonce, binding.nonce)
        XCTAssertEqual(report.appBundleIdentifier, binding.appBundleIdentifier)
        XCTAssertEqual(report.xpcBundleIdentifier, binding.xpcBundleIdentifier)
        XCTAssertEqual(report.appVersion, binding.appVersion)
        XCTAssertEqual(report.appBuild, binding.appBuild)
        XCTAssertEqual(report.modelRepositoryID, "mlx-community/Release-Smoke-4bit")
        XCTAssertEqual(report.modelRevision, String(repeating: "a", count: 40))
        XCTAssertEqual(report.generationStartedEvents, 1)
        XCTAssertEqual(report.tokenEvents, 1)
        XCTAssertEqual(report.generationCompletedEvents, 1)
        XCTAssertEqual(report.generationFailedEvents, 0)
        XCTAssertEqual(report.generationCancelledEvents, 0)
        XCTAssertEqual(report.generatedTokens, 1)
        XCTAssertTrue(report.modelVerifiedBeforeLoad)
        XCTAssertTrue(report.modelVerifiedAfterUnload)
        XCTAssertTrue(report.unloaded)
        XCTAssertGreaterThanOrEqual(report.durationMilliseconds, 0)
        XCTAssertEqual(client.unloadCallCount, 1)

        let encoded = try JSONEncoder().encode(report)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertNil(json.range(of: generatedTokenCanary))
        XCTAssertNil(json.range(of: request.prompt))
        XCTAssertNil(json.range(of: request.systemPrompt ?? "missing-system-prompt"))
    }

    func testMalformedEventSequencesAreRejectedAfterUnload() async throws {
        for malformed in MalformedSequence.allCases {
            let fixture = try makeFixture()
            let authorization = try authorize(fixture)
            let client = SignedSmokeRuntimeClientFake(
                stream: { request in
                    Self.stream(events: malformed.events(for: request))
                }
            )
            let runner = SignedReleaseSmokeRunner(runtimeClient: client)

            let error = await capturedError {
                try await runner.run(authorization: authorization, binding: self.binding)
            }

            XCTAssertNotNil(error, "\(malformed) must fail closed")
            XCTAssertEqual(client.unloadCallCount, 1, "\(malformed) must unload")
        }
    }

    func testStreamThrowIsRejectedAfterUnload() async throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let client = SignedSmokeRuntimeClientFake(
            stream: { request in
                Self.stream(
                    events: [Self.event(request, sequence: 1, type: .generationStarted)],
                    terminalError: SignedSmokeFakeError.streamFailed
                )
            }
        )
        let runner = SignedReleaseSmokeRunner(runtimeClient: client)

        let error = await capturedError {
            try await runner.run(authorization: authorization, binding: self.binding)
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(client.unloadCallCount, 1)
    }

    func testUnloadThrowAndFailedResponseBothRejectAttestation() async throws {
        let throwingFixture = try makeFixture()
        let throwingAuthorization = try authorize(throwingFixture)
        let throwingClient = SignedSmokeRuntimeClientFake(
            stream: { request in Self.stream(events: Self.validEvents(for: request)) },
            unload: { throw SignedSmokeFakeError.unloadFailed }
        )
        let throwingRunner = SignedReleaseSmokeRunner(runtimeClient: throwingClient)

        let throwingError = await capturedError {
            try await throwingRunner.run(
                authorization: throwingAuthorization,
                binding: self.binding
            )
        }
        XCTAssertNotNil(throwingError)
        XCTAssertEqual(throwingClient.unloadCallCount, 1)

        let failedFixture = try makeFixture()
        let failedAuthorization = try authorize(failedFixture)
        let failedClient = SignedSmokeRuntimeClientFake(
            stream: { request in Self.stream(events: Self.validEvents(for: request)) },
            unload: {
                UnloadModelResponse(
                    status: .failed,
                    error: RuntimeError(category: "test", message: "unload rejected")
                )
            }
        )
        let failedRunner = SignedReleaseSmokeRunner(runtimeClient: failedClient)

        let failedError = await capturedError {
            try await failedRunner.run(
                authorization: failedAuthorization,
                binding: self.binding
            )
        }
        XCTAssertNotNil(failedError)
        XCTAssertEqual(failedClient.unloadCallCount, 1)
    }

    func testPostflightArtifactMutationRejectsAttestation() async throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let weight = fixture.modelDirectory.appendingPathComponent("model.safetensors")
        let byteCount = try Data(contentsOf: weight).count
        let client = SignedSmokeRuntimeClientFake(
            stream: { request in Self.stream(events: Self.validEvents(for: request)) },
            unload: {
                try Data(repeating: 0x5A, count: byteCount).write(to: weight)
                return UnloadModelResponse(status: .unloaded)
            }
        )
        let runner = SignedReleaseSmokeRunner(runtimeClient: client)

        let error = await capturedError {
            try await runner.run(authorization: authorization, binding: self.binding)
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(client.unloadCallCount, 1)
    }

    func testRejectedLoadNeverGeneratesAndStillCleansUp() async throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let client = SignedSmokeRuntimeClientFake(
            load: { request in
                LoadModelResponse(
                    status: .failed,
                    modelID: request.modelID,
                    error: RuntimeError(category: "test", message: "load rejected")
                )
            },
            stream: { request in Self.stream(events: Self.validEvents(for: request)) }
        )
        let runner = SignedReleaseSmokeRunner(runtimeClient: client)

        let error = await capturedError {
            try await runner.run(authorization: authorization, binding: self.binding)
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(client.generateCallCount, 0)
        XCTAssertEqual(client.unloadCallCount, 1)
    }

    private var binding: SignedReleaseSmokeBinding {
        SignedReleaseSmokeBinding(
            sourceSHA: String(repeating: "1", count: 40),
            appTreeSHA256: String(repeating: "2", count: 64),
            nonce: String(repeating: "3", count: 64),
            appBundleIdentifier: "ai.supra.SupraAI",
            xpcBundleIdentifier: "ai.supra.SupraAI.SupraRuntimeService",
            appVersion: "2.2.1",
            appBuild: "387"
        )
    }

    private func capturedError(
        _ operation: () async throws -> SignedReleaseSmokeReport
    ) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func authorize(_ fixture: Fixture) throws -> SignedReleaseModelAuthorization {
        try SignedReleaseModelAuthorization.authorize(
            modelDirectory: fixture.modelDirectory,
            managedRoot: fixture.managedRoot,
            expectedSHA256: expectedModelSHA256
        )
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignedReleaseSmokeRunner-\(UUID().uuidString)", isDirectory: true)
        let managedRoot = base.appendingPathComponent("Models", isDirectory: true)
        let modelDirectory = managedRoot.appendingPathComponent("release-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let payloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data("protected-release-weight-canary".utf8),
        ]
        for (relativePath, data) in payloads {
            try data.write(to: modelDirectory.appendingPathComponent(relativePath))
        }
        let manifest = ModelArtifactManifest(
            repositoryID: "mlx-community/Release-Smoke-4bit",
            revision: String(repeating: "a", count: 40),
            files: payloads.map { relativePath, data in
                ModelArtifactManifest.File(
                    relativePath: relativePath,
                    size: Int64(data.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(data)
                )
            }
        )
        try ManagedModelStorage.writeManifest(
            manifest,
            to: ManagedModelStorage.manifestURL(in: modelDirectory)
        )
        return Fixture(base: base, managedRoot: managedRoot, modelDirectory: modelDirectory)
    }

    private static func validEvents(
        for request: GenerateRequest,
        token: String = "generated-token"
    ) -> [GenerationEvent] {
        [
            event(request, sequence: 1, type: .generationStarted),
            event(request, sequence: 2, type: .token, token: token),
            event(request, sequence: 3, type: .generationCompleted),
        ]
    }

    private static func event(
        _ request: GenerateRequest,
        generationID: GenerationID? = nil,
        sequence: Int,
        type: GenerationEventType,
        token: String? = nil
    ) -> GenerationEvent {
        GenerationEvent(
            generationID: generationID ?? request.generationID,
            sequenceNumber: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: type,
            tokenText: token
        )
    }

    private static func stream(
        events: [GenerationEvent],
        terminalError: Error? = nil
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }
    }

    private struct Fixture {
        let base: URL
        let managedRoot: URL
        let modelDirectory: URL
    }

    private enum MalformedSequence: CaseIterable, Sendable {
        case missingStarted
        case duplicateStarted
        case sequenceGap
        case wrongGenerationID
        case missingCompleted
        case duplicateCompleted
        case generationFailed
        case generationCancelled

        func events(for request: GenerateRequest) -> [GenerationEvent] {
            switch self {
            case .missingStarted:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .token, token: "token"),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .generationCompleted),
                ]
            case .duplicateStarted:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 3, type: .token, token: "token"),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 4, type: .generationCompleted),
                ]
            case .sequenceGap:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 3, type: .token, token: "token"),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 4, type: .generationCompleted),
                ]
            case .wrongGenerationID:
                [
                    SignedReleaseSmokeRunnerTests.event(
                        request,
                        generationID: GenerationID(),
                        sequence: 1,
                        type: .generationStarted
                    ),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .token, token: "token"),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 3, type: .generationCompleted),
                ]
            case .missingCompleted:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .token, token: "token"),
                ]
            case .duplicateCompleted:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .token, token: "token"),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 3, type: .generationCompleted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 4, type: .generationCompleted),
                ]
            case .generationFailed:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .generationFailed),
                ]
            case .generationCancelled:
                [
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 1, type: .generationStarted),
                    SignedReleaseSmokeRunnerTests.event(request, sequence: 2, type: .generationCancelled),
                ]
            }
        }
    }
}

private enum SignedSmokeFakeError: Error {
    case streamFailed
    case unloadFailed
}

private final class SignedSmokeRuntimeClientFake: RuntimeClientProtocol, @unchecked Sendable {
    typealias Load = @Sendable (LoadModelRequest) throws -> LoadModelResponse
    typealias Stream = @Sendable (GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error>
    typealias Unload = @Sendable () throws -> UnloadModelResponse

    private struct State {
        var loadRequests: [LoadModelRequest] = []
        var generateRequests: [GenerateRequest] = []
        var unloadCallCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let load: Load
    private let stream: Stream
    private let unload: Unload

    init(
        load: @escaping Load = { request in
            LoadModelResponse(status: .loaded, modelID: request.modelID)
        },
        stream: @escaping Stream,
        unload: @escaping Unload = { UnloadModelResponse(status: .unloaded) }
    ) {
        self.load = load
        self.stream = stream
        self.unload = unload
    }

    var loadRequests: [LoadModelRequest] {
        lock.withLock { state.loadRequests }
    }

    var generateRequests: [GenerateRequest] {
        lock.withLock { state.generateRequests }
    }

    var generateCallCount: Int {
        lock.withLock { state.generateRequests.count }
    }

    var unloadCallCount: Int {
        lock.withLock { state.unloadCallCount }
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        lock.withLock { state.loadRequests.append(request) }
        return try load(request)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock { state.generateRequests.append(request) }
        return try stream(request)
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .notFound, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        lock.withLock { state.unloadCallCount += 1 }
        return try unload()
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .failed)
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(
            state: .modelUnloaded,
            loadedModelID: nil,
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}
}
