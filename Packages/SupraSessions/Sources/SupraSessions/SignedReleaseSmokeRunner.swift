import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

/// Values supplied by the protected release process and bound into the signed
/// runtime smoke attestation. The runner accepts no prompt, model path, or output
/// destination from its caller.
public struct SignedReleaseSmokeMetadata: Sendable {
    public let sourceSha: String
    public let appTreeSHA256: String
    public let nonce: String
    public let appBundleIdentifier: String
    public let xpcBundleIdentifier: String
    public let version: String
    public let build: String

    public init(
        sourceSha: String,
        appTreeSHA256: String,
        nonce: String,
        appBundleIdentifier: String,
        xpcBundleIdentifier: String,
        version: String,
        build: String
    ) {
        self.sourceSha = sourceSha
        self.appTreeSHA256 = appTreeSHA256
        self.nonce = nonce
        self.appBundleIdentifier = appBundleIdentifier
        self.xpcBundleIdentifier = xpcBundleIdentifier
        self.version = version
        self.build = build
    }
}

/// Content-free evidence emitted only after the signed app has connected to its
/// XPC service, loaded and exercised the pinned model, unloaded it, and rehashed
/// its exclusive artifact tree.
public struct SignedReleaseSmokeAttestation: Codable, Sendable {
    public struct Verification: Codable, Sendable {
        public let xpcConnected: Bool
        public let modelLoaded: Bool
        public let generationStarted: Bool
        public let generationCompleted: Bool
        public let modelUnloaded: Bool
        public let modelReverified: Bool
    }

    public struct EventCounts: Codable, Sendable {
        public let total: Int
        public let generationStarted: Int
        public let token: Int
        public let metrics: Int
        public let generationCompleted: Int
        public let generationFailed: Int
        public let generationCancelled: Int
        public let reserved: Int
    }

    public struct Timings: Codable, Sendable {
        public let loadTimeMs: Int
        public let firstTokenLatencyMs: Int
        public let tokensPerSecond: Double
    }

    public let schemaVersion: Int
    public let status: String
    public let nonce: String
    public let sourceSha: String
    public let appTreeSHA256: String
    public let modelSHA256: String
    public let appBundleIdentifier: String
    public let xpcBundleIdentifier: String
    public let appVersion: String
    public let appBuild: String
    public let modelRepositoryID: String
    public let modelRevision: String
    public let verification: Verification
    public let eventCounts: EventCounts
    public let generatedTokenCount: Int
    public let timings: Timings
}

public enum SignedReleaseSmokeRunnerError: Error, Sendable {
    case invalidMetadata
    case modelPreflightFailed
    case xpcConnectionFailed
    case loadTransportFailed
    case loadRejected
    case loadedModelIdentityMismatch
    case loadedModelContentMismatch
    case invalidLoadMetrics
    case generationTransportFailed
    case eventContractViolation
    case cancellationTransportFailed
    case cancellationRejected
    case generationQuiescenceFailed
    case unloadTransportFailed
    case unloadRejected
    case modelPostflightFailed
    case internalInvariantFailed
}

/// Executes the single production-shaped generation used to qualify release
/// bytes. Every value that could change model behavior is fixed here.
public struct SignedReleaseSmokeRunner: Sendable {
    private static let appBundleIdentifier = "ai.supra.SupraAI"
    private static let xpcBundleIdentifier = "ai.supra.SupraAI.SupraRuntimeService"
    private static let prompt =
        "Return one short sentence confirming that local model inference is operational."
    private static let systemPrompt =
        "This is a local release validation. Reply briefly and do not repeat sensitive data."
    private static let modelDisplayName = "Protected release smoke model"

    private let runtimeClient: any RuntimeClientProtocol
    private let authorization: SignedReleaseModelAuthorization
    private let metadata: SignedReleaseSmokeMetadata

    public init(
        runtimeClient: any RuntimeClientProtocol,
        authorization: SignedReleaseModelAuthorization,
        metadata: SignedReleaseSmokeMetadata
    ) {
        self.runtimeClient = runtimeClient
        self.authorization = authorization
        self.metadata = metadata
    }

    public func run() async throws -> SignedReleaseSmokeAttestation {
        guard metadata.isValid(
            appBundleIdentifier: Self.appBundleIdentifier,
            xpcBundleIdentifier: Self.xpcBundleIdentifier
        ) else {
            throw SignedReleaseSmokeRunnerError.invalidMetadata
        }

        do {
            try authorization.reverify()
        } catch {
            throw SignedReleaseSmokeRunnerError.modelPreflightFailed
        }

        let modelID = ModelID()
        let loadRequest: LoadModelRequest
        do {
            loadRequest = try authorization.makeLoadRequest(
                modelID: modelID,
                displayName: Self.modelDisplayName
            )
        } catch {
            throw SignedReleaseSmokeRunnerError.modelPreflightFailed
        }

        do {
            try await runtimeClient.connect()
        } catch {
            throw SignedReleaseSmokeRunnerError.xpcConnectionFailed
        }

        var evidence: GenerationEvidence?
        var operationFailure: SignedReleaseSmokeRunnerError?
        var generationIDForCleanup: GenerationID?
        do {
            let loadTimeMs = try await loadModel(
                loadRequest: loadRequest,
                modelID: modelID
            )
            let generationID = GenerationID()
            generationIDForCleanup = generationID
            evidence = try await generateAndValidate(
                modelID: modelID,
                generationID: generationID,
                loadTimeMs: loadTimeMs
            )
            generationIDForCleanup = nil
        } catch let error as SignedReleaseSmokeRunnerError {
            operationFailure = error
        } catch {
            operationFailure = .internalInvariantFailed
        }

        // A load attempt can fail after partially mutating service state. Always
        // issue one defensive unload, even when transport, status, or identity
        // validation failed, then independently rehash the model tree.
        let cleanupFailure = await cleanupAndReverify(
            cancelGenerationID: generationIDForCleanup
        )
        if let cleanupFailure {
            throw cleanupFailure
        }
        if let operationFailure {
            throw operationFailure
        }
        guard let evidence else {
            throw SignedReleaseSmokeRunnerError.internalInvariantFailed
        }

        return SignedReleaseSmokeAttestation(
            schemaVersion: 1,
            status: "passed",
            nonce: metadata.nonce,
            sourceSha: metadata.sourceSha,
            appTreeSHA256: metadata.appTreeSHA256,
            modelSHA256: authorization.modelSHA256,
            appBundleIdentifier: metadata.appBundleIdentifier,
            xpcBundleIdentifier: metadata.xpcBundleIdentifier,
            appVersion: metadata.version,
            appBuild: metadata.build,
            modelRepositoryID: authorization.manifest.repositoryID,
            modelRevision: authorization.manifest.revision,
            verification: SignedReleaseSmokeAttestation.Verification(
                xpcConnected: true,
                modelLoaded: true,
                generationStarted: true,
                generationCompleted: true,
                modelUnloaded: true,
                modelReverified: true
            ),
            eventCounts: SignedReleaseSmokeAttestation.EventCounts(
                total: evidence.totalEvents,
                generationStarted: 1,
                token: evidence.tokenEvents,
                metrics: 1,
                generationCompleted: 1,
                generationFailed: 0,
                generationCancelled: 0,
                reserved: 0
            ),
            generatedTokenCount: evidence.metrics.generatedTokenCount,
            timings: SignedReleaseSmokeAttestation.Timings(
                loadTimeMs: evidence.loadTimeMs,
                firstTokenLatencyMs: evidence.metrics.firstTokenLatencyMs,
                tokensPerSecond: evidence.metrics.tokensPerSecond
            )
        )
    }

    private func loadModel(
        loadRequest: LoadModelRequest,
        modelID: ModelID
    ) async throws -> Int {
        let loadResponse: LoadModelResponse
        do {
            loadResponse = try await runtimeClient.loadModel(loadRequest)
        } catch {
            throw SignedReleaseSmokeRunnerError.loadTransportFailed
        }

        guard loadResponse.status == .loaded else {
            throw SignedReleaseSmokeRunnerError.loadRejected
        }
        guard loadResponse.modelID == modelID else {
            throw SignedReleaseSmokeRunnerError.loadedModelIdentityMismatch
        }
        guard let verifiedModelSHA256 = loadResponse.verifiedModelSHA256,
              Self.constantTimeEqualSHA256(
                  verifiedModelSHA256,
                  authorization.modelSHA256
              ) else {
            throw SignedReleaseSmokeRunnerError.loadedModelContentMismatch
        }
        guard loadResponse.error == nil,
              let loadTimeMs = loadResponse.metrics?.loadTimeMs,
              loadTimeMs >= 0 else {
            throw SignedReleaseSmokeRunnerError.invalidLoadMetrics
        }

        return loadTimeMs
    }

    private static func constantTimeEqualSHA256(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == 64, right.count == 64 else { return false }
        var difference: UInt8 = 0
        for index in 0..<64 {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private func generateAndValidate(
        modelID: ModelID,
        generationID: GenerationID,
        loadTimeMs: Int
    ) async throws -> GenerationEvidence {
        let generationRequest = GenerateRequest(
            generationID: generationID,
            modelID: modelID,
            prompt: Self.prompt,
            systemPrompt: Self.systemPrompt,
            history: [],
            options: GenerationOptions(
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

        let stream: AsyncThrowingStream<GenerationEvent, Error>
        do {
            stream = try runtimeClient.generate(generationRequest)
        } catch {
            throw SignedReleaseSmokeRunnerError.generationTransportFailed
        }

        var validator = EventValidator(generationID: generationRequest.generationID)
        do {
            for try await event in stream {
                try validator.consume(event)
            }
        } catch let error as SignedReleaseSmokeRunnerError {
            throw error
        } catch {
            throw SignedReleaseSmokeRunnerError.generationTransportFailed
        }
        return try validator.finish(loadTimeMs: loadTimeMs)
    }

    private func cleanupAndReverify(
        cancelGenerationID: GenerationID?
    ) async -> SignedReleaseSmokeRunnerError? {
        var cleanupFailure: SignedReleaseSmokeRunnerError?
        if let cancelGenerationID {
            cleanupFailure = await cancelAndAwaitQuiescence(cancelGenerationID)
        }

        do {
            let response = try await runtimeClient.unloadModel()
            if response.status != .unloaded || response.error != nil {
                cleanupFailure = .unloadRejected
            }
        } catch {
            cleanupFailure = .unloadTransportFailed
        }

        do {
            try authorization.reverify()
        } catch {
            if cleanupFailure == nil {
                cleanupFailure = .modelPostflightFailed
            }
        }
        return cleanupFailure
    }

    private func cancelAndAwaitQuiescence(
        _ generationID: GenerationID
    ) async -> SignedReleaseSmokeRunnerError? {
        let cancellationStatus: CancelGenerationStatus
        do {
            let response = try await runtimeClient.cancelGeneration(generationID)
            guard response.generationID == generationID,
                  response.error == nil,
                  response.status == .cancelled || response.status == .notFound else {
                return .cancellationRejected
            }
            cancellationStatus = response.status
        } catch {
            return .cancellationTransportFailed
        }

        // RuntimeClient also requests cancellation when a consumer abandons a
        // stream. If that request wins the race, our explicit request can see
        // `notFound` while the first cancellation is still unwinding. A
        // `.cancelled` reply is issued only after the service task has stopped;
        // otherwise poll bounded status until the reservation disappears.
        guard cancellationStatus == .notFound else {
            return nil
        }
        for attempt in 0..<3_000 {
            do {
                let status = try await runtimeClient.runtimeStatus()
                guard let activeGenerationID = status.activeGenerationID else {
                    return nil
                }
                guard activeGenerationID == generationID else {
                    return .generationQuiescenceFailed
                }
            } catch {
                return .generationQuiescenceFailed
            }
            if attempt < 2_999 {
                do {
                    try await Task<Never, Never>.sleep(for: .milliseconds(10))
                } catch {
                    return .generationQuiescenceFailed
                }
            }
        }
        return .generationQuiescenceFailed
    }

    private struct GenerationEvidence: Sendable {
        let loadTimeMs: Int
        let totalEvents: Int
        let tokenEvents: Int
        let metrics: ValidatedMetrics
    }

    private struct ValidatedMetrics: Equatable, Sendable {
        let generatedTokenCount: Int
        let firstTokenLatencyMs: Int
        let tokensPerSecond: Double
        let truncated: Bool
        let reasoningActive: Bool
        let contextTrimmed: Bool
        let contextOverflowed: Bool

        init(_ metrics: RuntimeMetrics) throws {
            guard let generatedTokenCount = metrics.generatedTokenCount,
                  generatedTokenCount > 0,
                  let firstTokenLatencyMs = metrics.firstTokenLatencyMs,
                  firstTokenLatencyMs >= 0,
                  let tokensPerSecond = metrics.tokensPerSecond,
                  tokensPerSecond.isFinite,
                  tokensPerSecond > 0,
                  metrics.truncated == false,
                  metrics.reasoningActive == false,
                  metrics.contextTrimmed == false,
                  metrics.contextOverflowed == false else {
                throw SignedReleaseSmokeRunnerError.eventContractViolation
            }
            self.generatedTokenCount = generatedTokenCount
            self.firstTokenLatencyMs = firstTokenLatencyMs
            self.tokensPerSecond = tokensPerSecond
            self.truncated = false
            self.reasoningActive = false
            self.contextTrimmed = false
            self.contextOverflowed = false
        }
    }

    private struct EventValidator: Sendable {
        private enum Phase: Sendable {
            case awaitingStart
            case acceptingTokens
            case awaitingCompletion
            case complete
        }

        private let generationID: GenerationID
        private var phase = Phase.awaitingStart
        private var expectedSequenceNumber = 1
        private var totalEvents = 0
        private var tokenEvents = 0
        private var metrics: ValidatedMetrics?

        init(generationID: GenerationID) {
            self.generationID = generationID
        }

        mutating func consume(_ event: GenerationEvent) throws {
            guard phase != .complete,
                  event.generationID == generationID,
                  event.sequenceNumber == expectedSequenceNumber,
                  event.message == nil,
                  event.error == nil else {
                throw SignedReleaseSmokeRunnerError.eventContractViolation
            }
            expectedSequenceNumber += 1
            totalEvents += 1

            switch event.type {
            case .generationStarted:
                guard phase == .awaitingStart,
                      event.tokenText == nil,
                      event.metrics == nil else {
                    throw SignedReleaseSmokeRunnerError.eventContractViolation
                }
                phase = .acceptingTokens

            case .token:
                guard phase == .acceptingTokens,
                      let tokenText = event.tokenText,
                      !tokenText.isEmpty,
                      event.metrics == nil else {
                    throw SignedReleaseSmokeRunnerError.eventContractViolation
                }
                tokenEvents += 1

            case .metrics:
                guard phase == .acceptingTokens,
                      tokenEvents > 0,
                      event.tokenText == nil,
                      let runtimeMetrics = event.metrics else {
                    throw SignedReleaseSmokeRunnerError.eventContractViolation
                }
                metrics = try ValidatedMetrics(runtimeMetrics)
                phase = .awaitingCompletion

            case .generationCompleted:
                guard phase == .awaitingCompletion,
                      event.tokenText == nil,
                      let runtimeMetrics = event.metrics,
                      let metrics,
                      try ValidatedMetrics(runtimeMetrics) == metrics else {
                    throw SignedReleaseSmokeRunnerError.eventContractViolation
                }
                phase = .complete

            case .queued, .modelLoading, .modelLoaded,
                 .generationFailed, .generationCancelled:
                throw SignedReleaseSmokeRunnerError.eventContractViolation
            }
        }

        func finish(loadTimeMs: Int) throws -> GenerationEvidence {
            guard phase == .complete,
                  tokenEvents > 0,
                  let metrics else {
                throw SignedReleaseSmokeRunnerError.eventContractViolation
            }
            return GenerationEvidence(
                loadTimeMs: loadTimeMs,
                totalEvents: totalEvents,
                tokenEvents: tokenEvents,
                metrics: metrics
            )
        }
    }
}

private extension SignedReleaseSmokeMetadata {
    func isValid(
        appBundleIdentifier expectedAppBundleIdentifier: String,
        xpcBundleIdentifier expectedXPCBundleIdentifier: String
    ) -> Bool {
        guard sourceSha.isLowercaseHex(count: 40),
              appTreeSHA256.isLowercaseHex(count: 64),
              nonce.isLowercaseHex(count: 64),
              appBundleIdentifier == expectedAppBundleIdentifier,
              xpcBundleIdentifier == expectedXPCBundleIdentifier,
              version.isSemanticVersion,
              build.isPositiveDecimal else {
            return false
        }
        return true
    }
}

private extension String {
    func isLowercaseHex(count: Int) -> Bool {
        guard self.count == count else { return false }
        return unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    var isSemanticVersion: Bool {
        let components = split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }
    }

    var isPositiveDecimal: Bool {
        guard !isEmpty,
              allSatisfy(\.isNumber),
              let value = Int(self) else {
            return false
        }
        return value > 0
    }
}
