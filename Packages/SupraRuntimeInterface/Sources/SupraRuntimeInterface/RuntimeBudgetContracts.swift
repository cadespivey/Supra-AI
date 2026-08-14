import Foundation
import SupraCore

public enum RuntimeBudgetDimension: String, Codable, Equatable, Sendable {
    case encodedRequestBytes
    case encodedResponseBytes
    case batchCount
    case stringUTF8Bytes
    case aggregateStringUTF8Bytes
    case generationHistoryTurnCount
    case generationHistoryTurnUTF8Bytes
    case generationHistoryUTF8Bytes
    case tokensPerText
    case aggregateInputTokens
    case embeddingPaddedElements
    case generationEventCount
    case generationOutputUTF8Bytes
    case encodedEventBytes
    case tokenCountResponseCount
    case embeddingVectorCount
    case embeddingDimension
    case embeddingScalarCount
    case embeddingScalarBytes
}

public struct RuntimeBudgetViolation: Error, LocalizedError, Equatable, Sendable {
    public let dimension: RuntimeBudgetDimension
    public let limit: Int
    public let actual: Int

    public init(dimension: RuntimeBudgetDimension, limit: Int, actual: Int) {
        self.dimension = dimension
        self.limit = limit
        self.actual = actual
    }

    public var errorDescription: String? {
        "Runtime budget exceeded for \(dimension.rawValue): \(actual) exceeds \(limit)."
    }
}

public struct RuntimeBudgetPolicy: Equatable, Sendable {
    public var maxEncodedRequestBytes: Int
    public var maxEncodedResponseBytes: Int
    public var maxBatchCount: Int
    public var maxStringUTF8Bytes: Int
    public var maxAggregateStringUTF8Bytes: Int
    public var maxGenerationHistoryTurnCount: Int
    public var maxGenerationHistoryTurnUTF8Bytes: Int
    public var maxGenerationHistoryUTF8Bytes: Int
    public var maxTokensPerText: Int
    public var maxAggregateInputTokens: Int
    public var maxEmbeddingPaddedElements: Int
    public var maxGenerationEventCount: Int
    public var maxGenerationOutputUTF8Bytes: Int
    public var maxEncodedEventBytes: Int
    public var maxTokenCountResponseCount: Int
    public var maxEmbeddingVectorCount: Int
    public var maxEmbeddingDimension: Int
    public var maxEmbeddingScalarCount: Int
    public var maxEmbeddingScalarBytes: Int

    public init(
        maxEncodedRequestBytes: Int,
        maxEncodedResponseBytes: Int,
        maxBatchCount: Int,
        maxStringUTF8Bytes: Int,
        maxAggregateStringUTF8Bytes: Int,
        maxGenerationHistoryTurnCount: Int,
        maxGenerationHistoryTurnUTF8Bytes: Int,
        maxGenerationHistoryUTF8Bytes: Int,
        maxTokensPerText: Int,
        maxAggregateInputTokens: Int,
        maxEmbeddingPaddedElements: Int,
        maxGenerationEventCount: Int,
        maxGenerationOutputUTF8Bytes: Int,
        maxEncodedEventBytes: Int,
        maxTokenCountResponseCount: Int,
        maxEmbeddingVectorCount: Int,
        maxEmbeddingDimension: Int,
        maxEmbeddingScalarCount: Int,
        maxEmbeddingScalarBytes: Int
    ) {
        self.maxEncodedRequestBytes = maxEncodedRequestBytes
        self.maxEncodedResponseBytes = maxEncodedResponseBytes
        self.maxBatchCount = maxBatchCount
        self.maxStringUTF8Bytes = maxStringUTF8Bytes
        self.maxAggregateStringUTF8Bytes = maxAggregateStringUTF8Bytes
        self.maxGenerationHistoryTurnCount = maxGenerationHistoryTurnCount
        self.maxGenerationHistoryTurnUTF8Bytes = maxGenerationHistoryTurnUTF8Bytes
        self.maxGenerationHistoryUTF8Bytes = maxGenerationHistoryUTF8Bytes
        self.maxTokensPerText = maxTokensPerText
        self.maxAggregateInputTokens = maxAggregateInputTokens
        self.maxEmbeddingPaddedElements = maxEmbeddingPaddedElements
        self.maxGenerationEventCount = maxGenerationEventCount
        self.maxGenerationOutputUTF8Bytes = maxGenerationOutputUTF8Bytes
        self.maxEncodedEventBytes = maxEncodedEventBytes
        self.maxTokenCountResponseCount = maxTokenCountResponseCount
        self.maxEmbeddingVectorCount = maxEmbeddingVectorCount
        self.maxEmbeddingDimension = maxEmbeddingDimension
        self.maxEmbeddingScalarCount = maxEmbeddingScalarCount
        self.maxEmbeddingScalarBytes = maxEmbeddingScalarBytes
    }

    public static let production = RuntimeBudgetPolicy(
        maxEncodedRequestBytes: 16 * 1_024 * 1_024,
        maxEncodedResponseBytes: 32 * 1_024 * 1_024,
        maxBatchCount: 256,
        maxStringUTF8Bytes: 1 * 1_024 * 1_024,
        maxAggregateStringUTF8Bytes: 8 * 1_024 * 1_024,
        maxGenerationHistoryTurnCount: 256,
        maxGenerationHistoryTurnUTF8Bytes: 1 * 1_024 * 1_024,
        maxGenerationHistoryUTF8Bytes: 8 * 1_024 * 1_024,
        maxTokensPerText: 32_768,
        maxAggregateInputTokens: 262_144,
        maxEmbeddingPaddedElements: 1_048_576,
        maxGenerationEventCount: 32_768,
        maxGenerationOutputUTF8Bytes: 32 * 1_024 * 1_024,
        maxEncodedEventBytes: 1 * 1_024 * 1_024,
        maxTokenCountResponseCount: 4_096,
        maxEmbeddingVectorCount: 256,
        maxEmbeddingDimension: 8_192,
        maxEmbeddingScalarCount: 1_048_576,
        maxEmbeddingScalarBytes: 4 * 1_024 * 1_024
    )
}

public struct RuntimeRequestBudgetValidator: Sendable {
    public let policy: RuntimeBudgetPolicy

    public init(policy: RuntimeBudgetPolicy) {
        self.policy = policy
    }

    public func validate(_ request: CountTokensRequest) throws {
        try validateStrings(request.texts)
    }

    public func validate(_ request: EmbedTextRequest) throws {
        try validateStrings(request.texts)
    }

    public func validate(_ request: GenerateRequest) throws {
        try validateStrings(
            [request.prompt] + (request.systemPrompt.map { [$0] } ?? [])
        )
        try require(
            request.history.count <= policy.maxGenerationHistoryTurnCount,
            .generationHistoryTurnCount,
            policy.maxGenerationHistoryTurnCount,
            request.history.count
        )
        var aggregate = 0
        for turn in request.history {
            let count = turn.content.utf8.count
            try require(
                count <= policy.maxGenerationHistoryTurnUTF8Bytes,
                .generationHistoryTurnUTF8Bytes,
                policy.maxGenerationHistoryTurnUTF8Bytes,
                count
            )
            aggregate = try checkedAdd(
                aggregate,
                count,
                dimension: .generationHistoryUTF8Bytes,
                limit: policy.maxGenerationHistoryUTF8Bytes
            )
        }
        try require(
            aggregate <= policy.maxGenerationHistoryUTF8Bytes,
            .generationHistoryUTF8Bytes,
            policy.maxGenerationHistoryUTF8Bytes,
            aggregate
        )
    }

    public func validateEmbeddingTokenShape(tokenCounts: [Int]) throws {
        var aggregate = 0
        var longest = 0
        for count in tokenCounts {
            try require(
                count >= 0 && count <= policy.maxTokensPerText,
                .tokensPerText,
                policy.maxTokensPerText,
                max(0, count)
            )
            aggregate = try checkedAdd(
                aggregate,
                count,
                dimension: .aggregateInputTokens,
                limit: policy.maxAggregateInputTokens
            )
            longest = max(longest, count)
        }
        try require(
            aggregate <= policy.maxAggregateInputTokens,
            .aggregateInputTokens,
            policy.maxAggregateInputTokens,
            aggregate
        )
        let padded = try checkedMultiply(
            tokenCounts.count,
            longest,
            dimension: .embeddingPaddedElements,
            limit: policy.maxEmbeddingPaddedElements
        )
        try require(
            padded <= policy.maxEmbeddingPaddedElements,
            .embeddingPaddedElements,
            policy.maxEmbeddingPaddedElements,
            padded
        )
    }

    private func validateStrings(_ strings: [String]) throws {
        try require(
            strings.count <= policy.maxBatchCount,
            .batchCount,
            policy.maxBatchCount,
            strings.count
        )
        var aggregate = 0
        for string in strings {
            let count = string.utf8.count
            try require(
                count <= policy.maxStringUTF8Bytes,
                .stringUTF8Bytes,
                policy.maxStringUTF8Bytes,
                count
            )
            aggregate = try checkedAdd(
                aggregate,
                count,
                dimension: .aggregateStringUTF8Bytes,
                limit: policy.maxAggregateStringUTF8Bytes
            )
        }
        try require(
            aggregate <= policy.maxAggregateStringUTF8Bytes,
            .aggregateStringUTF8Bytes,
            policy.maxAggregateStringUTF8Bytes,
            aggregate
        )
    }
}

public struct RuntimeResponseBudgetValidator: Sendable {
    public let policy: RuntimeBudgetPolicy

    public init(policy: RuntimeBudgetPolicy) {
        self.policy = policy
    }

    public func validate(
        _ response: CountTokensResponse,
        expectedRequestItemCount: Int
    ) throws {
        try require(
            response.counts.count <= policy.maxTokenCountResponseCount,
            .tokenCountResponseCount,
            policy.maxTokenCountResponseCount,
            response.counts.count
        )
        guard response.counts.count == expectedRequestItemCount,
              response.counts.allSatisfy({ $0 >= 0 }) else {
            throw RuntimeBudgetViolation(
                dimension: .tokenCountResponseCount,
                limit: expectedRequestItemCount,
                actual: response.counts.count
            )
        }
    }

    public func validate(
        _ response: EmbedTextResponse,
        expectedVectorCount: Int
    ) throws {
        let vectorCount = response.vectors.count
        try require(
            vectorCount <= policy.maxEmbeddingVectorCount,
            .embeddingVectorCount,
            policy.maxEmbeddingVectorCount,
            vectorCount
        )
        guard vectorCount == expectedVectorCount else {
            throw RuntimeBudgetViolation(
                dimension: .embeddingVectorCount,
                limit: expectedVectorCount,
                actual: vectorCount
            )
        }

        let declaredDimension = response.dimension ?? response.vectors.first?.count ?? 0
        try require(
            declaredDimension <= policy.maxEmbeddingDimension,
            .embeddingDimension,
            policy.maxEmbeddingDimension,
            declaredDimension
        )
        var scalarCount = 0
        for vector in response.vectors {
            try require(
                vector.count <= policy.maxEmbeddingDimension,
                .embeddingDimension,
                policy.maxEmbeddingDimension,
                vector.count
            )
            guard vector.count == declaredDimension else {
                throw RuntimeBudgetViolation(
                    dimension: .embeddingDimension,
                    limit: declaredDimension,
                    actual: vector.count
                )
            }
            scalarCount = try checkedAdd(
                scalarCount,
                vector.count,
                dimension: .embeddingScalarCount,
                limit: policy.maxEmbeddingScalarCount
            )
        }
        try require(
            scalarCount <= policy.maxEmbeddingScalarCount,
            .embeddingScalarCount,
            policy.maxEmbeddingScalarCount,
            scalarCount
        )
        let scalarBytes = try checkedMultiply(
            scalarCount,
            MemoryLayout<Float>.size,
            dimension: .embeddingScalarBytes,
            limit: policy.maxEmbeddingScalarBytes
        )
        try require(
            scalarBytes <= policy.maxEmbeddingScalarBytes,
            .embeddingScalarBytes,
            policy.maxEmbeddingScalarBytes,
            scalarBytes
        )
    }
}

public struct RuntimeGenerationOutputBudgetTracker: Sendable {
    public let policy: RuntimeBudgetPolicy
    public private(set) var acceptedEventCount = 0
    public private(set) var acceptedTokenUTF8Bytes = 0
    public private(set) var isOverflowed = false
    public private(set) var didAcceptTerminalEvent = false
    private var overflow: RuntimeBudgetViolation?

    public init(policy: RuntimeBudgetPolicy) {
        self.policy = policy
    }

    public var canPublishTerminal: Bool { !isOverflowed }

    public mutating func record(_ event: GenerationEvent) throws {
        if let overflow {
            throw overflow
        }
        do {
            let nextCount = try checkedAdd(
                acceptedEventCount,
                1,
                dimension: .generationEventCount,
                limit: policy.maxGenerationEventCount
            )
            try require(
                nextCount <= policy.maxGenerationEventCount,
                .generationEventCount,
                policy.maxGenerationEventCount,
                nextCount
            )
            let encodedBytes = try RuntimeXPCCodec.encode(event).count
            try require(
                encodedBytes <= policy.maxEncodedEventBytes,
                .encodedEventBytes,
                policy.maxEncodedEventBytes,
                encodedBytes
            )
            let tokenBytes = event.tokenText?.utf8.count ?? 0
            let nextTokenBytes = try checkedAdd(
                acceptedTokenUTF8Bytes,
                tokenBytes,
                dimension: .generationOutputUTF8Bytes,
                limit: policy.maxGenerationOutputUTF8Bytes
            )
            try require(
                nextTokenBytes <= policy.maxGenerationOutputUTF8Bytes,
                .generationOutputUTF8Bytes,
                policy.maxGenerationOutputUTF8Bytes,
                nextTokenBytes
            )
            acceptedEventCount = nextCount
            acceptedTokenUTF8Bytes = nextTokenBytes
            didAcceptTerminalEvent = event.type.isTerminal
        } catch let violation as RuntimeBudgetViolation {
            isOverflowed = true
            overflow = violation
            didAcceptTerminalEvent = false
            throw violation
        }
    }
}

public enum RuntimeResourceField: String, Codable, Equatable, Sendable {
    case weightBytes
    case layerCount
    case keyValueHeadCount
    case headDimension
    case scalarBytes
    case supportedContextTokens
    case nonWeightOverheadBytes
    case activationBytesPerToken
    case unifiedMemoryCeilingBytes
    case appResidentBytes
    case runtimeResidentBytesExcludingModels
    case embeddingResidentBytes
    case rerankerResidentBytes
    case safetyMarginBytes
    case currentPressureReserveBytes
    case contextTokens
}

public enum RuntimeResourceArithmeticOperation: String, Codable, Equatable, Sendable {
    case kvCacheBytesPerToken
    case kvCacheBytes
    case activationBytes
    case fixedResidentBytes
    case totalPeakBytes
    case modelSwitchCurrentModelBytes
    case modelSwitchReplacementModelBytes
    case modelSwitchTransactionalOverlapPeakBytes
    case modelSwitchUnloadPeakBytes
}

/// A fail-closed resource-planning rejection. Invalid or unrepresentable
/// resource facts must never become a defer decision carrying a false estimate.
public enum RuntimeResourcePlanningError: Error, Equatable, Sendable {
    case negativeValue(field: RuntimeResourceField, actual: Int)
    case arithmeticOverflow(operation: RuntimeResourceArithmeticOperation)
}

public struct ModelResourceProfile: Equatable, Sendable {
    public let profileID: String
    public let modelID: ModelID
    public let modelArtifactID: String
    public let modelRevision: String
    public let contentFingerprintSHA256: String
    public let weightBytes: Int
    public let layerCount: Int
    public let keyValueHeadCount: Int
    public let headDimension: Int
    public let scalarBytes: Int
    public let supportedContextTokens: Int
    public let nonWeightOverheadBytes: Int
    public let activationBytesPerToken: Int

    public init(
        profileID: String,
        modelID: ModelID,
        modelArtifactID: String,
        modelRevision: String,
        contentFingerprintSHA256: String,
        weightBytes: Int,
        layerCount: Int,
        keyValueHeadCount: Int,
        headDimension: Int,
        scalarBytes: Int,
        supportedContextTokens: Int,
        nonWeightOverheadBytes: Int,
        activationBytesPerToken: Int
    ) {
        self.profileID = profileID
        self.modelID = modelID
        self.modelArtifactID = modelArtifactID
        self.modelRevision = modelRevision
        self.contentFingerprintSHA256 = contentFingerprintSHA256
        self.weightBytes = weightBytes
        self.layerCount = layerCount
        self.keyValueHeadCount = keyValueHeadCount
        self.headDimension = headDimension
        self.scalarBytes = scalarBytes
        self.supportedContextTokens = supportedContextTokens
        self.nonWeightOverheadBytes = nonWeightOverheadBytes
        self.activationBytesPerToken = activationBytesPerToken
    }

    public var kvCacheBytesPerToken: Int {
        saturatingProduct([
            layerCount,
            keyValueHeadCount,
            headDimension,
            scalarBytes,
            2,
        ])
    }
}

public struct RuntimeMemoryEnvelope: Equatable, Sendable {
    public let unifiedMemoryCeilingBytes: Int
    public let appResidentBytes: Int
    public let runtimeResidentBytesExcludingModels: Int
    public let embeddingResidentBytes: Int
    public let rerankerResidentBytes: Int
    public let safetyMarginBytes: Int
    public let currentPressureReserveBytes: Int

    public init(
        unifiedMemoryCeilingBytes: Int,
        appResidentBytes: Int,
        runtimeResidentBytesExcludingModels: Int,
        embeddingResidentBytes: Int,
        rerankerResidentBytes: Int,
        safetyMarginBytes: Int,
        currentPressureReserveBytes: Int
    ) {
        self.unifiedMemoryCeilingBytes = unifiedMemoryCeilingBytes
        self.appResidentBytes = appResidentBytes
        self.runtimeResidentBytesExcludingModels = runtimeResidentBytesExcludingModels
        self.embeddingResidentBytes = embeddingResidentBytes
        self.rerankerResidentBytes = rerankerResidentBytes
        self.safetyMarginBytes = safetyMarginBytes
        self.currentPressureReserveBytes = currentPressureReserveBytes
    }

    public var fixedResidentBytes: Int {
        saturatingSum([
            appResidentBytes,
            runtimeResidentBytesExcludingModels,
            embeddingResidentBytes,
            rerankerResidentBytes,
            safetyMarginBytes,
            currentPressureReserveBytes,
        ])
    }
}

public struct RuntimeResourceEstimate: Equatable, Sendable {
    public let modelWeightBytes: Int
    public let kvCacheBytes: Int
    public let activationBytes: Int
    public let modelNonWeightOverheadBytes: Int
    public let totalPeakBytes: Int
}

public enum RuntimeResourceAdmissionDisposition: Equatable, Sendable {
    case admit
    case `defer`
}

public enum RuntimeResourceCorrectiveAction: Equatable, Sendable {
    case none
    case freeMemoryOrReduceContext
}

public struct RuntimeResourceAdmissionDecision: Equatable, Sendable {
    public let disposition: RuntimeResourceAdmissionDisposition
    public let estimatedPeakBytes: Int
    public let ceilingBytes: Int
    public let modelID: ModelID
    public let profileID: String
    public let modelArtifactID: String
    public let modelRevision: String
    public let modelFingerprintSHA256: String
    public let correctiveAction: RuntimeResourceCorrectiveAction
}

public struct RuntimeResourceAdmissionPlanner: Sendable {
    public let envelope: RuntimeMemoryEnvelope

    public init(envelope: RuntimeMemoryEnvelope) {
        self.envelope = envelope
    }

    public func estimate(
        profile: ModelResourceProfile,
        contextTokens: Int
    ) throws -> RuntimeResourceEstimate {
        try validateResourceProfile(profile)
        try validateRuntimeMemoryEnvelope(envelope)
        try requireNonnegative(contextTokens, field: .contextTokens)

        let kvBytesPerToken = try checkedResourceProduct(
            [
                profile.layerCount,
                profile.keyValueHeadCount,
                profile.headDimension,
                profile.scalarBytes,
                2,
            ],
            operation: .kvCacheBytesPerToken
        )
        let kvBytes = try checkedResourceMultiply(
            kvBytesPerToken,
            contextTokens,
            operation: .kvCacheBytes
        )
        let activationBytes = try checkedResourceMultiply(
            profile.activationBytesPerToken,
            contextTokens,
            operation: .activationBytes
        )
        let fixedResidentBytes = try checkedResourceSum(
            [
                envelope.appResidentBytes,
                envelope.runtimeResidentBytesExcludingModels,
                envelope.embeddingResidentBytes,
                envelope.rerankerResidentBytes,
                envelope.safetyMarginBytes,
                envelope.currentPressureReserveBytes,
            ],
            operation: .fixedResidentBytes
        )
        let total = try checkedResourceSum(
            [
                fixedResidentBytes,
                profile.weightBytes,
                kvBytes,
                activationBytes,
                profile.nonWeightOverheadBytes,
            ],
            operation: .totalPeakBytes
        )
        return RuntimeResourceEstimate(
            modelWeightBytes: profile.weightBytes,
            kvCacheBytes: kvBytes,
            activationBytes: activationBytes,
            modelNonWeightOverheadBytes: profile.nonWeightOverheadBytes,
            totalPeakBytes: total
        )
    }

    public func evaluate(
        profile: ModelResourceProfile,
        contextTokens: Int
    ) throws -> RuntimeResourceAdmissionDecision {
        let estimate = try estimate(profile: profile, contextTokens: contextTokens)
        let admitted = contextTokens <= profile.supportedContextTokens
            && estimate.totalPeakBytes <= envelope.unifiedMemoryCeilingBytes
        return RuntimeResourceAdmissionDecision(
            disposition: admitted ? .admit : .defer,
            estimatedPeakBytes: estimate.totalPeakBytes,
            ceilingBytes: envelope.unifiedMemoryCeilingBytes,
            modelID: profile.modelID,
            profileID: profile.profileID,
            modelArtifactID: profile.modelArtifactID,
            modelRevision: profile.modelRevision,
            modelFingerprintSHA256: profile.contentFingerprintSHA256,
            correctiveAction: admitted ? .none : .freeMemoryOrReduceContext
        )
    }

}

public enum RuntimeContextWorkload: String, Codable, Equatable, Sendable {
    case groundedExactEvidence
    case ordinaryConversation
}

public struct RuntimeContextAdmissionRequest: Equatable, Sendable {
    public let wireID: String
    public let modelID: ModelID
    public let modelArtifactID: String
    public let modelRevision: String
    public let expectedModelSHA256: String
    public let requestedContextTokens: Int
    public let actualPromptTokens: Int
    public let workload: RuntimeContextWorkload
    public let allowsExactSourceRepacking: Bool

    public init(
        wireID: String,
        modelID: ModelID,
        modelArtifactID: String,
        modelRevision: String,
        expectedModelSHA256: String,
        requestedContextTokens: Int,
        actualPromptTokens: Int,
        workload: RuntimeContextWorkload,
        allowsExactSourceRepacking: Bool
    ) {
        self.wireID = wireID
        self.modelID = modelID
        self.modelArtifactID = modelArtifactID
        self.modelRevision = modelRevision
        self.expectedModelSHA256 = expectedModelSHA256
        self.requestedContextTokens = requestedContextTokens
        self.actualPromptTokens = actualPromptTokens
        self.workload = workload
        self.allowsExactSourceRepacking = allowsExactSourceRepacking
    }
}

public enum RuntimeContextAdmissionDisposition: Equatable, Sendable {
    case admit
    case repackExactSources
    case trimHistoryWithDisclosure
    case `defer`
}

public enum RuntimeContextCorrectiveAction: Equatable, Sendable {
    case none
    case repackExactSources(maximumContextTokens: Int)
    case reduceExactSourceSetAndRetry
    case trimHistoryWithDisclosure(maximumContextTokens: Int)
}

public struct RuntimeContextAdmissionDecision: Equatable, Sendable {
    public let wireID: String
    public let modelID: ModelID
    public let modelArtifactID: String
    public let modelRevision: String
    public let expectedModelSHA256: String
    public let requestedContextTokens: Int
    public let actualPromptTokens: Int
    public let maximumAdmittedContextTokens: Int
    public let estimatedPeakBytes: Int
    public let disposition: RuntimeContextAdmissionDisposition
    public let correctiveAction: RuntimeContextCorrectiveAction
    public let preservesExactEvidence: Bool
    public let didSilentlyTruncateExactEvidence: Bool
    public let historyTrimDisclosureRequired: Bool
    public let substitutedModelID: ModelID?
}

public struct RuntimeContextAdmissionPlanner: Sendable {
    public let resourcePlanner: RuntimeResourceAdmissionPlanner

    public init(resourcePlanner: RuntimeResourceAdmissionPlanner) {
        self.resourcePlanner = resourcePlanner
    }

    public func evaluate(
        _ request: RuntimeContextAdmissionRequest,
        profile: ModelResourceProfile
    ) throws -> RuntimeContextAdmissionDecision {
        let estimate = try resourcePlanner.estimate(
            profile: profile,
            contextTokens: request.requestedContextTokens
        )
        let maximum = try maximumAdmittedContextTokens(for: profile)
        let fits = request.requestedContextTokens <= maximum
            && request.actualPromptTokens <= request.requestedContextTokens

        let disposition: RuntimeContextAdmissionDisposition
        let action: RuntimeContextCorrectiveAction
        let disclosure: Bool
        if fits {
            disposition = .admit
            action = .none
            disclosure = false
        } else {
            switch request.workload {
            case .groundedExactEvidence where request.allowsExactSourceRepacking:
                disposition = .repackExactSources
                action = .repackExactSources(maximumContextTokens: maximum)
                disclosure = false
            case .groundedExactEvidence:
                disposition = .defer
                action = .reduceExactSourceSetAndRetry
                disclosure = false
            case .ordinaryConversation:
                disposition = .trimHistoryWithDisclosure
                action = .trimHistoryWithDisclosure(maximumContextTokens: maximum)
                disclosure = true
            }
        }

        return RuntimeContextAdmissionDecision(
            wireID: request.wireID,
            modelID: request.modelID,
            modelArtifactID: request.modelArtifactID,
            modelRevision: request.modelRevision,
            expectedModelSHA256: request.expectedModelSHA256,
            requestedContextTokens: request.requestedContextTokens,
            actualPromptTokens: request.actualPromptTokens,
            maximumAdmittedContextTokens: maximum,
            estimatedPeakBytes: estimate.totalPeakBytes,
            disposition: disposition,
            correctiveAction: action,
            preservesExactEvidence: true,
            didSilentlyTruncateExactEvidence: false,
            historyTrimDisclosureRequired: disclosure,
            substitutedModelID: nil
        )
    }

    private func maximumAdmittedContextTokens(
        for profile: ModelResourceProfile
    ) throws -> Int {
        let fixed = try checkedResourceSum(
            [
                resourcePlanner.envelope.appResidentBytes,
                resourcePlanner.envelope.runtimeResidentBytesExcludingModels,
                resourcePlanner.envelope.embeddingResidentBytes,
                resourcePlanner.envelope.rerankerResidentBytes,
                resourcePlanner.envelope.safetyMarginBytes,
                resourcePlanner.envelope.currentPressureReserveBytes,
                profile.weightBytes,
                profile.nonWeightOverheadBytes,
            ],
            operation: .totalPeakBytes
        )
        let kvBytesPerToken = try checkedResourceProduct(
            [
                profile.layerCount,
                profile.keyValueHeadCount,
                profile.headDimension,
                profile.scalarBytes,
                2,
            ],
            operation: .kvCacheBytesPerToken
        )
        let perToken = try checkedResourceAdd(
            kvBytesPerToken,
            profile.activationBytesPerToken,
            operation: .totalPeakBytes
        )
        guard perToken > 0 else {
            return fixed <= resourcePlanner.envelope.unifiedMemoryCeilingBytes
                ? profile.supportedContextTokens
                : 0
        }
        let available = fixed < resourcePlanner.envelope.unifiedMemoryCeilingBytes
            ? resourcePlanner.envelope.unifiedMemoryCeilingBytes - fixed
            : 0
        return min(profile.supportedContextTokens, available / perToken)
    }
}

public struct RuntimeModelSwitchRequest: Equatable, Sendable {
    public let wireID: String
    public let current: ModelResourceProfile
    public let replacement: ModelResourceProfile

    public init(
        wireID: String,
        current: ModelResourceProfile,
        replacement: ModelResourceProfile
    ) {
        self.wireID = wireID
        self.current = current
        self.replacement = replacement
    }
}

public enum RuntimeModelSwitchStrategy: Equatable, Sendable {
    case unloadCurrentThenLoadReplacement
    case transactionalSwap
    case `defer`
}

public struct RuntimeModelSwitchPlan: Equatable, Sendable {
    public let wireID: String
    public let currentModelArtifactID: String
    public let currentModelRevision: String
    public let replacementModelID: ModelID
    public let replacementModelFingerprintSHA256: String
    public let strategy: RuntimeModelSwitchStrategy
    public let unloadsCurrentBeforeReplacementLoad: Bool
    public let keepsCurrentOnReplacementFailure: Bool
    public let overlapsFullModelWeights: Bool
    public let plannedPeakBytes: Int
    public let transactionalOverlapPeakBytes: Int
    public let ceilingBytes: Int
}

public struct RuntimeModelSwitchPlanner: Sendable {
    public let envelope: RuntimeMemoryEnvelope

    public init(envelope: RuntimeMemoryEnvelope) {
        self.envelope = envelope
    }

    public func plan(_ request: RuntimeModelSwitchRequest) throws -> RuntimeModelSwitchPlan {
        try validateRuntimeMemoryEnvelope(envelope)
        try validateResourceProfile(request.current)
        try validateResourceProfile(request.replacement)

        let fixedResidentBytes = try checkedResourceSum(
            [
                envelope.appResidentBytes,
                envelope.runtimeResidentBytesExcludingModels,
                envelope.embeddingResidentBytes,
                envelope.rerankerResidentBytes,
                envelope.safetyMarginBytes,
                envelope.currentPressureReserveBytes,
            ],
            operation: .fixedResidentBytes
        )
        let currentBytes = try checkedResourceAdd(
            request.current.weightBytes,
            request.current.nonWeightOverheadBytes,
            operation: .modelSwitchCurrentModelBytes
        )
        let replacementBytes = try checkedResourceAdd(
            request.replacement.weightBytes,
            request.replacement.nonWeightOverheadBytes,
            operation: .modelSwitchReplacementModelBytes
        )
        let unloadPeak = try checkedResourceAdd(
            fixedResidentBytes,
            max(currentBytes, replacementBytes),
            operation: .modelSwitchUnloadPeakBytes
        )
        let overlapPeak = try checkedResourceSum(
            [fixedResidentBytes, currentBytes, replacementBytes],
            operation: .modelSwitchTransactionalOverlapPeakBytes
        )
        let strategy: RuntimeModelSwitchStrategy
        if overlapPeak <= envelope.unifiedMemoryCeilingBytes {
            strategy = .transactionalSwap
        } else if unloadPeak <= envelope.unifiedMemoryCeilingBytes {
            strategy = .unloadCurrentThenLoadReplacement
        } else {
            strategy = .defer
        }
        return RuntimeModelSwitchPlan(
            wireID: request.wireID,
            currentModelArtifactID: request.current.modelArtifactID,
            currentModelRevision: request.current.modelRevision,
            replacementModelID: request.replacement.modelID,
            replacementModelFingerprintSHA256: request.replacement.contentFingerprintSHA256,
            strategy: strategy,
            unloadsCurrentBeforeReplacementLoad: strategy == .unloadCurrentThenLoadReplacement,
            keepsCurrentOnReplacementFailure: strategy == .transactionalSwap,
            overlapsFullModelWeights: strategy == .transactionalSwap,
            plannedPeakBytes: strategy == .transactionalSwap ? overlapPeak : unloadPeak,
            transactionalOverlapPeakBytes: overlapPeak,
            ceilingBytes: envelope.unifiedMemoryCeilingBytes
        )
    }
}

private func validateResourceProfile(_ profile: ModelResourceProfile) throws {
    try requireNonnegative(profile.weightBytes, field: .weightBytes)
    try requireNonnegative(profile.layerCount, field: .layerCount)
    try requireNonnegative(profile.keyValueHeadCount, field: .keyValueHeadCount)
    try requireNonnegative(profile.headDimension, field: .headDimension)
    try requireNonnegative(profile.scalarBytes, field: .scalarBytes)
    try requireNonnegative(profile.supportedContextTokens, field: .supportedContextTokens)
    try requireNonnegative(profile.nonWeightOverheadBytes, field: .nonWeightOverheadBytes)
    try requireNonnegative(profile.activationBytesPerToken, field: .activationBytesPerToken)
}

private func validateRuntimeMemoryEnvelope(_ envelope: RuntimeMemoryEnvelope) throws {
    try requireNonnegative(
        envelope.unifiedMemoryCeilingBytes,
        field: .unifiedMemoryCeilingBytes
    )
    try requireNonnegative(envelope.appResidentBytes, field: .appResidentBytes)
    try requireNonnegative(
        envelope.runtimeResidentBytesExcludingModels,
        field: .runtimeResidentBytesExcludingModels
    )
    try requireNonnegative(envelope.embeddingResidentBytes, field: .embeddingResidentBytes)
    try requireNonnegative(envelope.rerankerResidentBytes, field: .rerankerResidentBytes)
    try requireNonnegative(envelope.safetyMarginBytes, field: .safetyMarginBytes)
    try requireNonnegative(
        envelope.currentPressureReserveBytes,
        field: .currentPressureReserveBytes
    )
}

private func requireNonnegative(
    _ value: Int,
    field: RuntimeResourceField
) throws {
    guard value >= 0 else {
        throw RuntimeResourcePlanningError.negativeValue(field: field, actual: value)
    }
}

private func checkedResourceAdd(
    _ lhs: Int,
    _ rhs: Int,
    operation: RuntimeResourceArithmeticOperation
) throws -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
        throw RuntimeResourcePlanningError.arithmeticOverflow(operation: operation)
    }
    return value
}

private func checkedResourceSum(
    _ values: [Int],
    operation: RuntimeResourceArithmeticOperation
) throws -> Int {
    try values.reduce(0) { partial, value in
        try checkedResourceAdd(partial, value, operation: operation)
    }
}

private func checkedResourceMultiply(
    _ lhs: Int,
    _ rhs: Int,
    operation: RuntimeResourceArithmeticOperation
) throws -> Int {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else {
        throw RuntimeResourcePlanningError.arithmeticOverflow(operation: operation)
    }
    return value
}

private func checkedResourceProduct(
    _ values: [Int],
    operation: RuntimeResourceArithmeticOperation
) throws -> Int {
    try values.reduce(1) { partial, value in
        try checkedResourceMultiply(partial, value, operation: operation)
    }
}

/// The throwing planners remain authoritative. These saturating projections
/// keep legacy diagnostic properties total so malformed public input cannot
/// crash merely by being inspected before the planner rejects it.
private func saturatingSum(_ values: [Int]) -> Int {
    guard values.allSatisfy({ $0 >= 0 }) else { return Int.max }
    return values.reduce(0) { partial, value in
        let (next, overflow) = partial.addingReportingOverflow(value)
        return overflow ? Int.max : next
    }
}

private func saturatingProduct(_ values: [Int]) -> Int {
    guard values.allSatisfy({ $0 >= 0 }) else { return Int.max }
    return values.reduce(1) { partial, value in
        let (next, overflow) = partial.multipliedReportingOverflow(by: value)
        return overflow ? Int.max : next
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ dimension: RuntimeBudgetDimension,
    _ limit: Int,
    _ actual: Int
) throws {
    guard condition() else {
        throw RuntimeBudgetViolation(dimension: dimension, limit: limit, actual: actual)
    }
}

private func checkedAdd(
    _ lhs: Int,
    _ rhs: Int,
    dimension: RuntimeBudgetDimension,
    limit: Int
) throws -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
        throw RuntimeBudgetViolation(dimension: dimension, limit: limit, actual: Int.max)
    }
    return value
}

private func checkedMultiply(
    _ lhs: Int,
    _ rhs: Int,
    dimension: RuntimeBudgetDimension,
    limit: Int
) throws -> Int {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else {
        throw RuntimeBudgetViolation(dimension: dimension, limit: limit, actual: Int.max)
    }
    return value
}

private extension GenerationEventType {
    var isTerminal: Bool {
        self == .generationCompleted || self == .generationCancelled || self == .generationFailed
    }
}
