import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

/// RED: these contracts intentionally do not compile until the repository owns a
/// signed-release runner and a strict, content-free source/app/model attestation.
final class SignedReleaseSmokeRunnerTests: XCTestCase {
    private static let fixedPrompt =
        "Return one short sentence confirming that local model inference is operational."
    private static let fixedSystemPrompt =
        "This is a local release validation. Reply briefly and do not repeat sensitive data."
    private static let generatedTokenCanary =
        "PRIVATE-GENERATED-TOKEN-CANARY-DO-NOT-ATTEST"
    private static let generatedTokenCount = 7
    private static let loadTimeMs = 123
    private static let firstTokenLatencyMs = 45
    private static let tokensPerSecond = 12.5

    private let expectedModelSHA256 =
        "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"
    private let sourceSha = String(repeating: "1", count: 40)
    private let appTreeSHA256 = String(repeating: "2", count: 64)
    private let nonce = String(repeating: "3", count: 64)

    func testRunUsesExactProductionSequenceAndReturnsStrictContentFreeAttestation() async throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let client = SignedSmokeRuntimeClientFake(
            stream: { request in
                Self.stream(events: Self.validEvents(for: request))
            }
        )
        let runner = SignedReleaseSmokeRunner(
            runtimeClient: client,
            authorization: authorization,
            metadata: metadata
        )

        let attestation: SignedReleaseSmokeAttestation = try await runner.run()

        XCTAssertEqual(client.calls, ["connect", "load", "generate", "unload"])
        XCTAssertEqual(client.connectCallCount, 1)
        XCTAssertEqual(client.loadCallCount, 1)
        XCTAssertEqual(client.generateCallCount, 1)
        XCTAssertEqual(client.unloadCallCount, 1)

        let request = try XCTUnwrap(client.generateRequests.first)
        let loadRequest = try XCTUnwrap(client.loadRequests.first)
        XCTAssertEqual(request.modelID, loadRequest.modelID)
        XCTAssertEqual(request.prompt, Self.fixedPrompt)
        XCTAssertEqual(request.systemPrompt, Self.fixedSystemPrompt)
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

        let encoded = try JSONEncoder().encode(attestation)
        let object = try jsonObject(encoded)
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schemaVersion",
                "status",
                "nonce",
                "sourceSha",
                "appTreeSHA256",
                "modelSHA256",
                "appBundleIdentifier",
                "xpcBundleIdentifier",
                "appVersion",
                "appBuild",
                "modelRepositoryID",
                "modelRevision",
                "verification",
                "eventCounts",
                "generatedTokenCount",
                "timings",
            ])
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["status"] as? String, "passed")
        XCTAssertEqual(object["nonce"] as? String, nonce)
        XCTAssertEqual(object["sourceSha"] as? String, sourceSha)
        XCTAssertEqual(object["appTreeSHA256"] as? String, appTreeSHA256)
        XCTAssertEqual(object["modelSHA256"] as? String, expectedModelSHA256)
        XCTAssertEqual(object["appBundleIdentifier"] as? String, "ai.supra.SupraAI")
        XCTAssertEqual(
            object["xpcBundleIdentifier"] as? String,
            "ai.supra.SupraAI.SupraRuntimeService"
        )
        XCTAssertEqual(object["appVersion"] as? String, "2.2.1")
        XCTAssertEqual(object["appBuild"] as? String, "387")
        XCTAssertEqual(
            object["modelRepositoryID"] as? String,
            "mlx-community/Release-Smoke-4bit"
        )
        XCTAssertEqual(object["modelRevision"] as? String, String(repeating: "a", count: 40))
        XCTAssertEqual(object["generatedTokenCount"] as? Int, Self.generatedTokenCount)

        let verification = try nestedObject(object, key: "verification")
        XCTAssertEqual(
            Set(verification.keys),
            Set([
                "xpcConnected",
                "modelLoaded",
                "generationStarted",
                "generationCompleted",
                "modelUnloaded",
                "modelReverified",
            ])
        )
        for key in verification.keys {
            XCTAssertEqual(verification[key] as? Bool, true, "\(key) must be true")
        }

        let eventCounts = try nestedObject(object, key: "eventCounts")
        XCTAssertEqual(
            Set(eventCounts.keys),
            Set([
                "total",
                "generationStarted",
                "token",
                "metrics",
                "generationCompleted",
                "generationFailed",
                "generationCancelled",
                "reserved",
            ])
        )
        XCTAssertEqual(eventCounts["total"] as? Int, 4)
        XCTAssertEqual(eventCounts["generationStarted"] as? Int, 1)
        XCTAssertEqual(eventCounts["token"] as? Int, 1)
        XCTAssertEqual(eventCounts["metrics"] as? Int, 1)
        XCTAssertEqual(eventCounts["generationCompleted"] as? Int, 1)
        XCTAssertEqual(eventCounts["generationFailed"] as? Int, 0)
        XCTAssertEqual(eventCounts["generationCancelled"] as? Int, 0)
        XCTAssertEqual(eventCounts["reserved"] as? Int, 0)

        let timings = try nestedObject(object, key: "timings")
        XCTAssertEqual(
            Set(timings.keys),
            Set(["loadTimeMs", "firstTokenLatencyMs", "tokensPerSecond"])
        )
        XCTAssertEqual(timings["loadTimeMs"] as? Int, Self.loadTimeMs)
        XCTAssertEqual(timings["firstTokenLatencyMs"] as? Int, Self.firstTokenLatencyMs)
        XCTAssertEqual(timings["tokensPerSecond"] as? Double, Self.tokensPerSecond)

        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbiddenKey in [
            "modelPath",
            "managedRootPath",
            "modelBookmark",
            "modelDirectoryIdentity",
            "device",
            "inode",
            "prompt",
            "systemPrompt",
            "history",
            "tokenText",
            "message",
            "error",
            "technicalDetails",
        ] {
            XCTAssertNil(json.range(of: "\"\(forbiddenKey)\""))
        }
        XCTAssertNil(json.range(of: Self.generatedTokenCanary))
        XCTAssertNil(json.range(of: Self.fixedPrompt))
        XCTAssertNil(json.range(of: Self.fixedSystemPrompt))
        XCTAssertNil(json.range(of: fixture.modelDirectory.path))
        XCTAssertNil(json.range(of: "protected-release-weight-canary"))
        if let bookmark = loadRequest.modelBookmark?.base64EncodedString() {
            XCTAssertNil(json.range(of: bookmark))
        }
    }

    func testMalformedEventSequencesAreRejectedAfterUnload() async throws {
        for malformed in MalformedSequence.allCases {
            let fixture = try makeFixture()
            let authorization = try authorize(fixture)
            let smokeMetadata = metadata
            let client = SignedSmokeRuntimeClientFake(
                stream: { request in
                    Self.stream(events: malformed.events(for: request))
                }
            )
            let runner = SignedReleaseSmokeRunner(
                runtimeClient: client,
                authorization: authorization,
                metadata: smokeMetadata
            )

            let error = await capturedError { try await runner.run() }

            XCTAssertNotNil(error, "\(malformed) must fail closed")
            XCTAssertEqual(client.connectCallCount, 1, "\(malformed) must connect once")
            XCTAssertEqual(client.loadCallCount, 1, "\(malformed) must load once")
            XCTAssertEqual(client.generateCallCount, 1, "\(malformed) must generate once")
            XCTAssertEqual(client.unloadCallCount, 1, "\(malformed) must unload once")
        }
    }

    func testStreamThrowIsRejectedAfterUnload() async throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let client = SignedSmokeRuntimeClientFake(
            stream: { request in
                Self.stream(
                    events: [
                        Self.event(request, sequence: 1, type: .generationStarted),
                        Self.event(
                            request,
                            sequence: 2,
                            type: .token,
                            token: Self.generatedTokenCanary
                        ),
                    ],
                    terminalError: SignedSmokeFakeError.streamFailed
                )
            }
        )
        let runner = SignedReleaseSmokeRunner(
            runtimeClient: client,
            authorization: authorization,
            metadata: metadata
        )

        let error = await capturedError { try await runner.run() }

        XCTAssertNotNil(error)
        XCTAssertEqual(client.calls, ["connect", "load", "generate", "unload"])
        XCTAssertEqual(client.unloadCallCount, 1)
    }

    func testUnloadThrowAndFailedResponseBothRejectAttestation() async throws {
        let throwingFixture = try makeFixture()
        let throwingAuthorization = try authorize(throwingFixture)
        let throwingClient = SignedSmokeRuntimeClientFake(
            stream: { request in Self.stream(events: Self.validEvents(for: request)) },
            unload: { throw SignedSmokeFakeError.unloadFailed }
        )
        let throwingRunner = SignedReleaseSmokeRunner(
            runtimeClient: throwingClient,
            authorization: throwingAuthorization,
            metadata: metadata
        )

        let throwingError = await capturedError { try await throwingRunner.run() }
        XCTAssertNotNil(throwingError)
        XCTAssertEqual(throwingClient.unloadCallCount, 1)

        let failedFixture = try makeFixture()
        let failedAuthorization = try authorize(failedFixture)
        let failedClient = SignedSmokeRuntimeClientFake(
            stream: { request in Self.stream(events: Self.validEvents(for: request)) },
            unload: {
                UnloadModelResponse(
                    status: .failed,
                    error: RuntimeError(category: "test", message: "unload-error-canary")
                )
            }
        )
        let failedRunner = SignedReleaseSmokeRunner(
            runtimeClient: failedClient,
            authorization: failedAuthorization,
            metadata: metadata
        )

        let failedError = await capturedError { try await failedRunner.run() }
        XCTAssertNotNil(failedError)
        XCTAssertEqual(failedClient.unloadCallCount, 1)
    }

    func testLoadThrowFailedResponseAndWrongIdentityNeverGenerateAndStillUnload() async throws {
        let throwingFixture = try makeFixture()
        let throwingAuthorization = try authorize(throwingFixture)
        let throwingClient = SignedSmokeRuntimeClientFake(
            load: { _ in throw SignedSmokeFakeError.loadFailed },
            stream: { request in Self.stream(events: Self.validEvents(for: request)) }
        )
        let throwingRunner = SignedReleaseSmokeRunner(
            runtimeClient: throwingClient,
            authorization: throwingAuthorization,
            metadata: metadata
        )
        let throwingError = await capturedError { try await throwingRunner.run() }
        XCTAssertNotNil(throwingError)
        XCTAssertEqual(throwingClient.generateCallCount, 0)
        XCTAssertEqual(throwingClient.unloadCallCount, 1)

        let failedFixture = try makeFixture()
        let failedAuthorization = try authorize(failedFixture)
        let failedClient = SignedSmokeRuntimeClientFake(
            load: { request in
                LoadModelResponse(
                    status: .failed,
                    modelID: request.modelID,
                    error: RuntimeError(category: "test", message: "load-error-canary")
                )
            },
            stream: { request in Self.stream(events: Self.validEvents(for: request)) }
        )
        let failedRunner = SignedReleaseSmokeRunner(
            runtimeClient: failedClient,
            authorization: failedAuthorization,
            metadata: metadata
        )
        let failedError = await capturedError { try await failedRunner.run() }
        XCTAssertNotNil(failedError)
        XCTAssertEqual(failedClient.generateCallCount, 0)
        XCTAssertEqual(failedClient.unloadCallCount, 1)

        let wrongIdentityFixture = try makeFixture()
        let wrongIdentityAuthorization = try authorize(wrongIdentityFixture)
        let wrongIdentityClient = SignedSmokeRuntimeClientFake(
            load: { _ in
                LoadModelResponse(
                    status: .loaded,
                    modelID: ModelID(),
                    metrics: RuntimeMetrics(loadTimeMs: Self.loadTimeMs)
                )
            },
            stream: { request in Self.stream(events: Self.validEvents(for: request)) }
        )
        let wrongIdentityRunner = SignedReleaseSmokeRunner(
            runtimeClient: wrongIdentityClient,
            authorization: wrongIdentityAuthorization,
            metadata: metadata
        )
        let wrongIdentityError = await capturedError { try await wrongIdentityRunner.run() }
        XCTAssertNotNil(wrongIdentityError)
        XCTAssertEqual(wrongIdentityClient.generateCallCount, 0)
        XCTAssertEqual(wrongIdentityClient.unloadCallCount, 1)
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
        let runner = SignedReleaseSmokeRunner(
            runtimeClient: client,
            authorization: authorization,
            metadata: metadata
        )

        let error = await capturedError { try await runner.run() }

        XCTAssertNotNil(error)
        XCTAssertEqual(client.unloadCallCount, 1)
    }

    private var metadata: SignedReleaseSmokeMetadata {
        SignedReleaseSmokeMetadata(
            sourceSha: sourceSha,
            appTreeSHA256: appTreeSHA256,
            nonce: nonce,
            appBundleIdentifier: "ai.supra.SupraAI",
            xpcBundleIdentifier: "ai.supra.SupraAI.SupraRuntimeService",
            version: "2.2.1",
            build: "387"
        )
    }

    private func capturedError(
        _ operation: () async throws -> SignedReleaseSmokeAttestation
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

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func nestedObject(
        _ object: [String: Any],
        key: String
    ) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any])
    }

    private static func validEvents(for request: GenerateRequest) -> [GenerationEvent] {
        let metrics = validGenerationMetrics()
        return [
            event(request, sequence: 1, type: .generationStarted),
            event(
                request,
                sequence: 2,
                type: .token,
                token: generatedTokenCanary
            ),
            event(request, sequence: 3, type: .metrics, metrics: metrics),
            event(request, sequence: 4, type: .generationCompleted, metrics: metrics),
        ]
    }

    private static func validGenerationMetrics(
        generatedTokenCount: Int? = SignedReleaseSmokeRunnerTests.generatedTokenCount,
        truncated: Bool? = false,
        reasoningActive: Bool? = false,
        contextTrimmed: Bool? = false,
        contextOverflowed: Bool? = false
    ) -> RuntimeMetrics {
        RuntimeMetrics(
            firstTokenLatencyMs: firstTokenLatencyMs,
            tokensPerSecond: tokensPerSecond,
            generatedTokenCount: generatedTokenCount,
            truncated: truncated,
            reasoningActive: reasoningActive,
            contextTrimmed: contextTrimmed,
            contextOverflowed: contextOverflowed
        )
    }

    private static func event(
        _ request: GenerateRequest,
        generationID: GenerationID? = nil,
        sequence: Int,
        type: GenerationEventType,
        token: String? = nil,
        metrics: RuntimeMetrics? = nil
    ) -> GenerationEvent {
        GenerationEvent(
            generationID: generationID ?? request.generationID,
            sequenceNumber: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            type: type,
            tokenText: token,
            metrics: metrics
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
        case sequenceStartsAtZero
        case sequenceGap
        case wrongGenerationID
        case missingStarted
        case duplicateStarted
        case tokenBeforeStarted
        case noToken
        case missingMetrics
        case duplicateMetrics
        case metricsNotImmediatelyBeforeCompletion
        case completionBeforeMetrics
        case completionNonterminal
        case duplicateCompleted
        case reservedEvent
        case generationFailed
        case generationCancelled
        case missingCompleted
        case missingGeneratedTokenCount
        case mismatchedGeneratedTokenCount
        case zeroGeneratedTokenCount
        case truncated
        case reasoningActive
        case contextTrimmed
        case contextOverflowed

        private var generatedTokenCanary: String {
            SignedReleaseSmokeRunnerTests.generatedTokenCanary
        }

        private var generatedTokenCount: Int {
            SignedReleaseSmokeRunnerTests.generatedTokenCount
        }

        func events(for request: GenerateRequest) -> [GenerationEvent] {
            let metrics = SignedReleaseSmokeRunnerTests.validGenerationMetrics()
            switch self {
            case .sequenceStartsAtZero:
                return [
                    event(request, sequence: 0, type: .generationStarted),
                    event(request, sequence: 1, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 2, type: .metrics, metrics: metrics),
                    event(request, sequence: 3, type: .generationCompleted, metrics: metrics),
                ]
            case .sequenceGap:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 3, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 4, type: .metrics, metrics: metrics),
                    event(request, sequence: 5, type: .generationCompleted, metrics: metrics),
                ]
            case .wrongGenerationID:
                return [
                    event(
                        request,
                        generationID: GenerationID(),
                        sequence: 1,
                        type: .generationStarted
                    ),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .metrics, metrics: metrics),
                    event(request, sequence: 4, type: .generationCompleted, metrics: metrics),
                ]
            case .missingStarted:
                return [
                    event(request, sequence: 1, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 2, type: .metrics, metrics: metrics),
                    event(request, sequence: 3, type: .generationCompleted, metrics: metrics),
                ]
            case .duplicateStarted:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .generationStarted),
                    event(request, sequence: 3, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 4, type: .metrics, metrics: metrics),
                    event(request, sequence: 5, type: .generationCompleted, metrics: metrics),
                ]
            case .tokenBeforeStarted:
                return [
                    event(request, sequence: 1, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 2, type: .generationStarted),
                    event(request, sequence: 3, type: .metrics, metrics: metrics),
                    event(request, sequence: 4, type: .generationCompleted, metrics: metrics),
                ]
            case .noToken:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .metrics, metrics: metrics),
                    event(request, sequence: 3, type: .generationCompleted, metrics: metrics),
                ]
            case .missingMetrics:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .generationCompleted, metrics: metrics),
                ]
            case .duplicateMetrics:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .metrics, metrics: metrics),
                    event(request, sequence: 4, type: .metrics, metrics: metrics),
                    event(request, sequence: 5, type: .generationCompleted, metrics: metrics),
                ]
            case .metricsNotImmediatelyBeforeCompletion:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .metrics, metrics: metrics),
                    event(request, sequence: 3, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 4, type: .generationCompleted, metrics: metrics),
                ]
            case .completionBeforeMetrics:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .generationCompleted, metrics: metrics),
                    event(request, sequence: 4, type: .metrics, metrics: metrics),
                ]
            case .completionNonterminal:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .metrics, metrics: metrics),
                    event(request, sequence: 4, type: .generationCompleted, metrics: metrics),
                    event(request, sequence: 5, type: .token, token: generatedTokenCanary),
                ]
            case .duplicateCompleted:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .metrics, metrics: metrics),
                    event(request, sequence: 4, type: .generationCompleted, metrics: metrics),
                    event(request, sequence: 5, type: .generationCompleted, metrics: metrics),
                ]
            case .reservedEvent:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .queued),
                    event(request, sequence: 4, type: .metrics, metrics: metrics),
                    event(request, sequence: 5, type: .generationCompleted, metrics: metrics),
                ]
            case .generationFailed:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .generationFailed),
                ]
            case .generationCancelled:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .generationCancelled),
                ]
            case .missingCompleted:
                return [
                    event(request, sequence: 1, type: .generationStarted),
                    event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                    event(request, sequence: 3, type: .metrics, metrics: metrics),
                ]
            case .missingGeneratedTokenCount:
                let incomplete = SignedReleaseSmokeRunnerTests.validGenerationMetrics(
                    generatedTokenCount: nil
                )
                return validShape(request: request, metrics: incomplete, completion: incomplete)
            case .mismatchedGeneratedTokenCount:
                let completion = SignedReleaseSmokeRunnerTests.validGenerationMetrics(
                    generatedTokenCount: generatedTokenCount + 1
                )
                return validShape(request: request, metrics: metrics, completion: completion)
            case .zeroGeneratedTokenCount:
                let zero = SignedReleaseSmokeRunnerTests.validGenerationMetrics(
                    generatedTokenCount: 0
                )
                return validShape(request: request, metrics: zero, completion: zero)
            case .truncated:
                let unsafe = SignedReleaseSmokeRunnerTests.validGenerationMetrics(truncated: true)
                return validShape(request: request, metrics: unsafe, completion: unsafe)
            case .reasoningActive:
                let unsafe = SignedReleaseSmokeRunnerTests.validGenerationMetrics(reasoningActive: true)
                return validShape(request: request, metrics: unsafe, completion: unsafe)
            case .contextTrimmed:
                let unsafe = SignedReleaseSmokeRunnerTests.validGenerationMetrics(contextTrimmed: true)
                return validShape(request: request, metrics: unsafe, completion: unsafe)
            case .contextOverflowed:
                let unsafe = SignedReleaseSmokeRunnerTests.validGenerationMetrics(contextOverflowed: true)
                return validShape(request: request, metrics: unsafe, completion: unsafe)
            }
        }

        private func validShape(
            request: GenerateRequest,
            metrics: RuntimeMetrics,
            completion: RuntimeMetrics
        ) -> [GenerationEvent] {
            [
                event(request, sequence: 1, type: .generationStarted),
                event(request, sequence: 2, type: .token, token: generatedTokenCanary),
                event(request, sequence: 3, type: .metrics, metrics: metrics),
                event(request, sequence: 4, type: .generationCompleted, metrics: completion),
            ]
        }

        private func event(
            _ request: GenerateRequest,
            generationID: GenerationID? = nil,
            sequence: Int,
            type: GenerationEventType,
            token: String? = nil,
            metrics: RuntimeMetrics? = nil
        ) -> GenerationEvent {
            SignedReleaseSmokeRunnerTests.event(
                request,
                generationID: generationID,
                sequence: sequence,
                type: type,
                token: token,
                metrics: metrics
            )
        }
    }
}

private enum SignedSmokeFakeError: Error {
    case loadFailed
    case streamFailed
    case unloadFailed
}

private final class SignedSmokeRuntimeClientFake: RuntimeClientProtocol, @unchecked Sendable {
    typealias Connect = @Sendable () throws -> Void
    typealias Load = @Sendable (LoadModelRequest) throws -> LoadModelResponse
    typealias Stream = @Sendable (GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error>
    typealias Unload = @Sendable () throws -> UnloadModelResponse

    private struct State {
        var calls: [String] = []
        var loadRequests: [LoadModelRequest] = []
        var generateRequests: [GenerateRequest] = []
    }

    private let lock = NSLock()
    private var state = State()
    private let connectHandler: Connect
    private let load: Load
    private let stream: Stream
    private let unload: Unload

    init(
        connect: @escaping Connect = {},
        load: @escaping Load = { request in
            LoadModelResponse(
                status: .loaded,
                modelID: request.modelID,
                metrics: RuntimeMetrics(loadTimeMs: 123)
            )
        },
        stream: @escaping Stream,
        unload: @escaping Unload = { UnloadModelResponse(status: .unloaded) }
    ) {
        self.connectHandler = connect
        self.load = load
        self.stream = stream
        self.unload = unload
    }

    var calls: [String] {
        lock.withLock { state.calls }
    }

    var connectCallCount: Int {
        lock.withLock { state.calls.filter { $0 == "connect" }.count }
    }

    var loadCallCount: Int {
        lock.withLock { state.loadRequests.count }
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
        lock.withLock { state.calls.filter { $0 == "unload" }.count }
    }

    func connect() async throws {
        lock.withLock { state.calls.append("connect") }
        try connectHandler()
    }

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        lock.withLock {
            state.calls.append("load")
            state.loadRequests.append(request)
        }
        return try load(request)
    }

    func generate(
        _ request: GenerateRequest
    ) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock {
            state.calls.append("generate")
            state.generateRequests.append(request)
        }
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
        lock.withLock { state.calls.append("unload") }
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
