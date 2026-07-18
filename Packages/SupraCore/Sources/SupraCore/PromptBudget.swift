import Foundation

/// Token budgeting for prompt assembly. The runtime caps its KV cache at
/// `maxContextTokens` (a `RotatingKVCache`), so a prompt larger than the window is
/// not rejected — it silently rotates the FRONT of the prompt out as generation
/// proceeds. The front is exactly the system grounding and the highest-ranked
/// sources, so a confident answer can be produced from a prompt whose
/// "answer only from the sources" instructions were evicted. This helper computes
/// the safe prompt budget so callers can trim lower-priority context (oldest
/// conversation history) to fit instead.
public enum PromptBudget {
    /// Small reserve for chat-template special tokens (BOS/role markers) added on
    /// top of the message text the caller can see.
    public static let templateMargin = 256

    /// The number of tokens the prompt may occupy so that prompt + generated output
    /// both fit within `maxContextTokens` without the KV cache evicting the front of
    /// the prompt during generation. Never returns less than a small floor so a
    /// degenerate configuration still attempts a generation.
    public static func promptTokenBudget(maxContextTokens: Int, maxOutputTokens: Int) -> Int {
        // Reserve the output budget + a margin, but NEVER exceed the window itself: on
        // a degenerate/hostile tiny-context config the floor must not produce a budget
        // larger than maxContextTokens, or the trim/overflow check would never fire and
        // the front of the prompt would be evicted without being detected.
        min(max(1, maxContextTokens), max(512, maxContextTokens - maxOutputTokens - templateMargin))
    }
}

public enum TokenCountMethod: String, Codable, Hashable, Sendable {
    case exact
    case conservativeFallback = "conservative_fallback"
}

/// The pre-persistence packing summary used by prompt builders. M8-W2 extends
/// this into candidate-level persisted lineage; this value deliberately records
/// the safety decision now so overflow retries cannot be invisible in memory.
public struct TokenPackingReport: Codable, Equatable, Sendable {
    public var countMethod: TokenCountMethod
    public var availableInputTokens: Int
    public var selectedInputTokens: Int
    public var consideredItemCount: Int
    public var packedItemCount: Int
    public var omittedItemCount: Int
    public var omissionReason: String?
    public var cannotPackReason: String?
    public var overflowRetryCount: Int
    /// Token count for each cumulative serialized prefix considered by the
    /// budgeter. Persisted candidate reports use adjacent deltas for per-item
    /// accounting while retaining the authoritative whole-packet total.
    public var cumulativeInputTokenCounts: [Int]

    public init(
        countMethod: TokenCountMethod,
        availableInputTokens: Int,
        selectedInputTokens: Int,
        consideredItemCount: Int,
        packedItemCount: Int,
        omittedItemCount: Int,
        omissionReason: String? = nil,
        cannotPackReason: String? = nil,
        overflowRetryCount: Int = 0,
        cumulativeInputTokenCounts: [Int] = []
    ) {
        self.countMethod = countMethod
        self.availableInputTokens = availableInputTokens
        self.selectedInputTokens = selectedInputTokens
        self.consideredItemCount = consideredItemCount
        self.packedItemCount = packedItemCount
        self.omittedItemCount = omittedItemCount
        self.omissionReason = omissionReason
        self.cannotPackReason = cannotPackReason
        self.overflowRetryCount = overflowRetryCount
        self.cumulativeInputTokenCounts = cumulativeInputTokenCounts
    }

    public var canPack: Bool {
        consideredItemCount == 0 || packedItemCount > 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        countMethod = try container.decode(TokenCountMethod.self, forKey: .countMethod)
        availableInputTokens = try container.decode(Int.self, forKey: .availableInputTokens)
        selectedInputTokens = try container.decode(Int.self, forKey: .selectedInputTokens)
        consideredItemCount = try container.decode(Int.self, forKey: .consideredItemCount)
        packedItemCount = try container.decode(Int.self, forKey: .packedItemCount)
        omittedItemCount = try container.decode(Int.self, forKey: .omittedItemCount)
        omissionReason = try container.decodeIfPresent(String.self, forKey: .omissionReason)
        cannotPackReason = try container.decodeIfPresent(String.self, forKey: .cannotPackReason)
        overflowRetryCount = try container.decodeIfPresent(Int.self, forKey: .overflowRetryCount) ?? 0
        cumulativeInputTokenCounts = try container.decodeIfPresent(
            [Int].self,
            forKey: .cumulativeInputTokenCounts
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case countMethod
        case availableInputTokens
        case selectedInputTokens
        case consideredItemCount
        case packedItemCount
        case omittedItemCount
        case omissionReason
        case cannotPackReason
        case overflowRetryCount
        case cumulativeInputTokenCounts
    }
}

public enum DocumentPackingDisposition: String, Codable, Hashable, Sendable {
    case considered
    case packed
    case truncated
    case omitted
    case deferred
}

/// Durable accounting for one candidate considered while assembling a grounded
/// evidence packet. `originalTokenCount` is the candidate's contribution before
/// any per-source truncation; `packedTokenCount` is zero when it did not enter
/// the serialized packet.
public struct DocumentPackingCandidate: Codable, Equatable, Sendable {
    public var sourceID: String
    public var label: String
    public var rank: Int
    public var disposition: DocumentPackingDisposition
    public var reason: String
    public var originalTokenCount: Int
    public var packedTokenCount: Int

    public init(
        sourceID: String,
        label: String,
        rank: Int,
        disposition: DocumentPackingDisposition,
        reason: String,
        originalTokenCount: Int,
        packedTokenCount: Int
    ) {
        self.sourceID = sourceID
        self.label = label
        self.rank = rank
        self.disposition = disposition
        self.reason = reason
        self.originalTokenCount = originalTokenCount
        self.packedTokenCount = packedTokenCount
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case label
        case rank
        case disposition
        case reason
        case originalTokenCount = "original_token_count"
        case packedTokenCount = "packed_token_count"
    }
}

/// Canonical, queryable record of every candidate in a grounded packet. This is
/// stored on `document_source_sets`; prompt text retains only the visible
/// truncation marker needed by the verifier.
public struct DocumentPackingReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var countMethod: TokenCountMethod
    public var availableInputTokens: Int
    public var selectedInputTokens: Int
    public var overflowRetryCount: Int
    public var candidates: [DocumentPackingCandidate]

    public init(
        schemaVersion: Int = 1,
        countMethod: TokenCountMethod,
        availableInputTokens: Int,
        selectedInputTokens: Int,
        overflowRetryCount: Int = 0,
        candidates: [DocumentPackingCandidate]
    ) {
        self.schemaVersion = schemaVersion
        self.countMethod = countMethod
        self.availableInputTokens = availableInputTokens
        self.selectedInputTokens = selectedInputTokens
        self.overflowRetryCount = overflowRetryCount
        self.candidates = candidates
    }

    public var packedSourceIDs: [String] {
        candidates.compactMap { candidate in
            switch candidate.disposition {
            case .packed, .truncated:
                candidate.sourceID
            case .considered, .omitted, .deferred:
                nil
            }
        }
    }

    public func canonicalJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case countMethod = "count_method"
        case availableInputTokens = "available_input_tokens"
        case selectedInputTokens = "selected_input_tokens"
        case overflowRetryCount = "overflow_retry_count"
        case candidates
    }
}

/// Shared prompt-packet budgeting. Callers serialize each cumulative prefix
/// exactly as it would cross the runtime boundary, request one batched exact
/// count for those packets, and fall back here if the runtime is unavailable.
public enum TokenBudgeter {
    /// The previous preflight assumed four UTF-8 bytes per token. Two is a
    /// deliberately tighter safety divisor for the no-runtime path; the runtime's
    /// exact overflow signal remains authoritative for retry/refusal behavior.
    public static let fallbackBytesPerToken = 2
    public static let defaultSafetyMargin = PromptBudget.templateMargin

    public static func fallbackTokenCount(_ text: String) -> Int {
        let byteCount = text.utf8.count
        let quotient = byteCount / fallbackBytesPerToken
        return quotient + (byteCount.isMultiple(of: fallbackBytesPerToken) ? 0 : 1)
    }

    public static func inputTokenLimit(
        maxContextTokens: Int,
        outputReserveTokens: Int,
        safetyMargin: Int = defaultSafetyMargin
    ) -> Int {
        max(0, maxContextTokens - max(0, outputReserveTokens) - max(0, safetyMargin))
    }

    public static func chooseLargestFittingPrefix(
        serializedPackets: [String],
        exactCounts: [Int]? = nil,
        maxContextTokens: Int,
        outputReserveTokens: Int,
        safetyMargin: Int = defaultSafetyMargin
    ) -> TokenPackingReport {
        let hasValidExactCounts = exactCounts?.count == serializedPackets.count
            && exactCounts?.allSatisfy({ $0 >= 0 }) == true
        let counts = hasValidExactCounts
            ? exactCounts!
            : serializedPackets.map(fallbackTokenCount)
        let method: TokenCountMethod = hasValidExactCounts ? .exact : .conservativeFallback
        let available = inputTokenLimit(
            maxContextTokens: maxContextTokens,
            outputReserveTokens: outputReserveTokens,
            safetyMargin: safetyMargin
        )

        var packedCount = 0
        var selectedTokens = 0
        for (index, count) in counts.enumerated() {
            guard count <= available else { break }
            packedCount = index + 1
            selectedTokens = count
        }
        let omittedCount = serializedPackets.count - packedCount
        return TokenPackingReport(
            countMethod: method,
            availableInputTokens: available,
            selectedInputTokens: selectedTokens,
            consideredItemCount: serializedPackets.count,
            packedItemCount: packedCount,
            omittedItemCount: omittedCount,
            omissionReason: omittedCount > 0 ? "context_budget" : nil,
            cannotPackReason: serializedPackets.isEmpty || packedCount > 0
                ? nil
                : "required_packet_exceeds_context",
            cumulativeInputTokenCounts: counts
        )
    }
}
