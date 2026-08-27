import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

public enum ScratchPadBillingFidelityTimeoutError: Error, Equatable, Sendable {
    case timedOut
}

private actor ScratchPadBillingFidelityTimeoutGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(
        _ result: Result<Value, any Error>,
        beforeResume: @Sendable () -> Void = {}
    ) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        beforeResume()
        continuation.resume(with: result)
        return true
    }
}

public enum ScratchPadBillingFidelityTimeout {
    public nonisolated static func value<Value: Sendable>(
        after duration: Duration,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ScratchPadBillingFidelityTimeoutGate(continuation)
            let operationTask = Task { @MainActor in
                try await operation()
            }
            let timeoutTask = Task.detached {
                try await Task.sleep(for: duration)
            }
            Task.detached {
                do {
                    let value = try await operationTask.value
                    if await gate.resolve(.success(value)) {
                        timeoutTask.cancel()
                    }
                } catch {
                    if await gate.resolve(.failure(error)) {
                        timeoutTask.cancel()
                    }
                }
            }
            Task.detached {
                do {
                    try await timeoutTask.value
                } catch {
                    return
                }
                _ = await gate.resolve(
                    .failure(ScratchPadBillingFidelityTimeoutError.timedOut),
                    beforeResume: { operationTask.cancel() }
                )
            }
        }
    }
}

public enum ScratchPadBillingMatterBasis: String, Codable, Sendable {
    case tagged
    case untaggedInference
}

public enum ScratchPadBillingTimeBasis: String, Codable, Sendable {
    case explicitWritten
    case inferredTimestampGap
}

struct ScratchPadBillingFidelityExpectation: Sendable {
    let id: String
    let sourceEntryIDs: [String]
    let expectedMatterID: String
    let matterBasis: ScratchPadBillingMatterBasis
    let narrativeTermGroups: [[String]]
    let expectedHours: Double
    let timeBasis: ScratchPadBillingTimeBasis
    let expectedTaskCode: String?
    let expectedActivityCode: String?
    let acceptableTaskCodes: Set<String>
    let acceptableActivityCodes: Set<String>
    let allowsBlankTaskCode: Bool
    let allowsBlankActivityCode: Bool
    let codeRationale: String
}

struct ScratchPadBillingFidelityFixture: Sendable {
    let id: String
    let dayDate: String
    let entries: [ScratchPadEntryRecord]
    let attachments: [ScratchPadAttachmentRecord]
    let matters: [MatterRecord]
    let matterRules: [MatterBillingRules]
    let expectations: [ScratchPadBillingFidelityExpectation]
    let autoTimestamp: Bool
}

public struct ScratchPadBillingFidelityLineScore: Codable, Sendable {
    public let expectationID: String
    public let sourceEntryIDs: [String]
    public let expectedMatterID: String
    public let matterBasis: ScratchPadBillingMatterBasis
    public let narrativeTermGroups: [[String]]
    public let billingCodeSet: String
    public let timeBasis: ScratchPadBillingTimeBasis
    public let expectedHours: Double
    public let expectedTaskCode: String?
    public let expectedActivityCode: String?
    public let acceptableTaskCodes: [String]
    public let acceptableActivityCodes: [String]
    public let allowsBlankTaskCode: Bool
    public let allowsBlankActivityCode: Bool
    public let codeRationale: String
    public let matchedOutputIndex: Int?
    public let actualMatterID: String?
    public let actualNarrative: String?
    public let actualHours: Double?
    public let actualTaskCode: String?
    public let actualActivityCode: String?
    public let actualConfidence: String?
    public let actualEvidence: String?
    public let actualCodeNote: String?
    public let actualSourceEntryIDs: [String]
    public let sourceAttributionCorrect: Bool
    public let matterCorrect: Bool
    public let narrativeSubjectCorrect: Bool
    public let timeCorrect: Bool
    public let taskCodeCorrect: Bool
    public let activityCodeCorrect: Bool
    public let taskCodeCanonical: Bool
    public let activityCodeCanonical: Bool
    public let taskCodeReasonable: Bool
    public let activityCodeReasonable: Bool
    public let abstentionJustified: Bool
    public let hasDurationEvidence: Bool
}

public struct ScratchPadBillingFidelityOutputLine: Codable, Sendable {
    public let outputIndex: Int
    public let matchedExpectationID: String?
    public let matterID: String?
    public let narrative: String
    public let hours: Double
    public let workDate: String
    public let taskCode: String?
    public let activityCode: String?
    public let confidence: String
    public let evidence: String?
    public let codeNote: String?
    public let sourceEntryIDs: [String]
}

public struct ScratchPadBillingFidelityOutcome: Codable, Sendable {
    public let fixtureID: String
    public let systemPrompt: String
    public let userPrompt: String
    public let rawModelText: String
    public let firstPassJSONValid: Bool
    public let strictJSONObjectOnly: Bool
    public let generationError: String?
    public let durationSeconds: Double
    public let rawOutputLineCount: Int
    public let outputLineCount: Int
    public let rawUnexpectedOutputLineCount: Int
    public let unexpectedOutputLineCount: Int
    public let normalizedOutputLines: [ScratchPadBillingFidelityOutputLine]
    public let rawModelLineScores: [ScratchPadBillingFidelityLineScore]
    public let lineScores: [ScratchPadBillingFidelityLineScore]
    public let authorizationRejected: Bool

    private enum CodingKeys: String, CodingKey {
        case fixtureID
        case systemPrompt
        case userPrompt
        case rawModelText
        case firstPassJSONValid
        case strictJSONObjectOnly
        case generationError
        case durationSeconds
        case rawOutputLineCount
        case outputLineCount
        case rawUnexpectedOutputLineCount
        case unexpectedOutputLineCount
        case normalizedOutputLines
        case rawModelLineScores
        case lineScores
        case authorizationRejected
    }

    public init(
        fixtureID: String,
        systemPrompt: String,
        userPrompt: String,
        rawModelText: String,
        firstPassJSONValid: Bool,
        strictJSONObjectOnly: Bool,
        generationError: String?,
        durationSeconds: Double,
        rawOutputLineCount: Int,
        outputLineCount: Int,
        rawUnexpectedOutputLineCount: Int,
        unexpectedOutputLineCount: Int,
        normalizedOutputLines: [ScratchPadBillingFidelityOutputLine],
        rawModelLineScores: [ScratchPadBillingFidelityLineScore],
        lineScores: [ScratchPadBillingFidelityLineScore],
        authorizationRejected: Bool
    ) {
        self.fixtureID = fixtureID
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.rawModelText = rawModelText
        self.firstPassJSONValid = firstPassJSONValid
        self.strictJSONObjectOnly = strictJSONObjectOnly
        self.generationError = generationError
        self.durationSeconds = durationSeconds
        self.rawOutputLineCount = rawOutputLineCount
        self.outputLineCount = outputLineCount
        self.rawUnexpectedOutputLineCount = rawUnexpectedOutputLineCount
        self.unexpectedOutputLineCount = unexpectedOutputLineCount
        self.normalizedOutputLines = normalizedOutputLines
        self.rawModelLineScores = rawModelLineScores
        self.lineScores = lineScores
        self.authorizationRejected = authorizationRejected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixtureID = try container.decode(String.self, forKey: .fixtureID)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        userPrompt = try container.decode(String.self, forKey: .userPrompt)
        rawModelText = try container.decode(String.self, forKey: .rawModelText)
        firstPassJSONValid = try container.decode(Bool.self, forKey: .firstPassJSONValid)
        strictJSONObjectOnly = try container.decode(Bool.self, forKey: .strictJSONObjectOnly)
        generationError = try container.decodeIfPresent(String.self, forKey: .generationError)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        rawOutputLineCount = try container.decode(Int.self, forKey: .rawOutputLineCount)
        outputLineCount = try container.decode(Int.self, forKey: .outputLineCount)
        unexpectedOutputLineCount = try container.decode(Int.self, forKey: .unexpectedOutputLineCount)
        rawUnexpectedOutputLineCount = try container.decodeIfPresent(
            Int.self,
            forKey: .rawUnexpectedOutputLineCount
        ) ?? unexpectedOutputLineCount
        normalizedOutputLines = try container.decode(
            [ScratchPadBillingFidelityOutputLine].self,
            forKey: .normalizedOutputLines
        )
        lineScores = try container.decode([ScratchPadBillingFidelityLineScore].self, forKey: .lineScores)
        rawModelLineScores = try container.decodeIfPresent(
            [ScratchPadBillingFidelityLineScore].self,
            forKey: .rawModelLineScores
        ) ?? lineScores
        authorizationRejected = try container.decodeIfPresent(Bool.self, forKey: .authorizationRejected) ?? false
    }
}

public struct ScratchPadBillingFidelitySummary: Codable, Sendable {
    public let fixtureCount: Int
    public let expectedLineCount: Int
    public let firstPassJSONValidityRate: Double
    public let parserAcceptanceRate: Double
    public let matterAccuracyRate: Double
    public let taggedMatterAccuracyRate: Double
    public let untaggedMatterAccuracyRate: Double
    public let narrativeSubjectRate: Double
    public let explicitTimeAccuracyRate: Double
    public let inferredTimeToleranceRate: Double
    public let sourceAttributionRate: Double
    public let taskCodeAccuracyRate: Double
    public let activityCodeAccuracyRate: Double
    public let canonicalTaskCodeRate: Double
    public let canonicalActivityCodeRate: Double
    public let reasonableTaskCodeRate: Double
    public let reasonableActivityCodeRate: Double
    public let nonLitigationBlankTaskRate: Double
    public let justifiedAbstentionRate: Double
    public let inferredTimeEvidenceRate: Double
    public let rawUnexpectedOutputLineCount: Int
    public let unexpectedOutputLineCount: Int
    public let rawModelMatterAccuracyRate: Double
    public let rawModelSourceAttributionRate: Double
    public let rawModelReasonableTaskCodeRate: Double
    public let rawModelReasonableActivityCodeRate: Double
    public let authorizationRejectedFixtureCount: Int
    public let passesHardGates: Bool

    private enum CodingKeys: String, CodingKey {
        case fixtureCount
        case expectedLineCount
        case firstPassJSONValidityRate
        case parserAcceptanceRate
        case matterAccuracyRate
        case taggedMatterAccuracyRate
        case untaggedMatterAccuracyRate
        case narrativeSubjectRate
        case explicitTimeAccuracyRate
        case inferredTimeToleranceRate
        case sourceAttributionRate
        case taskCodeAccuracyRate
        case activityCodeAccuracyRate
        case canonicalTaskCodeRate
        case canonicalActivityCodeRate
        case reasonableTaskCodeRate
        case reasonableActivityCodeRate
        case nonLitigationBlankTaskRate
        case justifiedAbstentionRate
        case inferredTimeEvidenceRate
        case rawUnexpectedOutputLineCount
        case unexpectedOutputLineCount
        case rawModelMatterAccuracyRate
        case rawModelSourceAttributionRate
        case rawModelReasonableTaskCodeRate
        case rawModelReasonableActivityCodeRate
        case authorizationRejectedFixtureCount
        case passesHardGates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixtureCount = try container.decode(Int.self, forKey: .fixtureCount)
        expectedLineCount = try container.decode(Int.self, forKey: .expectedLineCount)
        firstPassJSONValidityRate = try container.decode(Double.self, forKey: .firstPassJSONValidityRate)
        parserAcceptanceRate = try container.decode(Double.self, forKey: .parserAcceptanceRate)
        matterAccuracyRate = try container.decode(Double.self, forKey: .matterAccuracyRate)
        taggedMatterAccuracyRate = try container.decode(Double.self, forKey: .taggedMatterAccuracyRate)
        untaggedMatterAccuracyRate = try container.decode(Double.self, forKey: .untaggedMatterAccuracyRate)
        narrativeSubjectRate = try container.decode(Double.self, forKey: .narrativeSubjectRate)
        explicitTimeAccuracyRate = try container.decode(Double.self, forKey: .explicitTimeAccuracyRate)
        inferredTimeToleranceRate = try container.decode(Double.self, forKey: .inferredTimeToleranceRate)
        sourceAttributionRate = try container.decode(Double.self, forKey: .sourceAttributionRate)
        taskCodeAccuracyRate = try container.decode(Double.self, forKey: .taskCodeAccuracyRate)
        activityCodeAccuracyRate = try container.decode(Double.self, forKey: .activityCodeAccuracyRate)
        canonicalTaskCodeRate = try container.decode(Double.self, forKey: .canonicalTaskCodeRate)
        canonicalActivityCodeRate = try container.decode(Double.self, forKey: .canonicalActivityCodeRate)
        reasonableTaskCodeRate = try container.decode(Double.self, forKey: .reasonableTaskCodeRate)
        reasonableActivityCodeRate = try container.decode(Double.self, forKey: .reasonableActivityCodeRate)
        nonLitigationBlankTaskRate = try container.decode(Double.self, forKey: .nonLitigationBlankTaskRate)
        justifiedAbstentionRate = try container.decode(Double.self, forKey: .justifiedAbstentionRate)
        inferredTimeEvidenceRate = try container.decode(Double.self, forKey: .inferredTimeEvidenceRate)
        unexpectedOutputLineCount = try container.decode(Int.self, forKey: .unexpectedOutputLineCount)
        rawUnexpectedOutputLineCount = try container.decodeIfPresent(
            Int.self,
            forKey: .rawUnexpectedOutputLineCount
        ) ?? unexpectedOutputLineCount
        rawModelMatterAccuracyRate = try container.decodeIfPresent(
            Double.self,
            forKey: .rawModelMatterAccuracyRate
        ) ?? matterAccuracyRate
        rawModelSourceAttributionRate = try container.decodeIfPresent(
            Double.self,
            forKey: .rawModelSourceAttributionRate
        ) ?? sourceAttributionRate
        rawModelReasonableTaskCodeRate = try container.decodeIfPresent(
            Double.self,
            forKey: .rawModelReasonableTaskCodeRate
        ) ?? reasonableTaskCodeRate
        rawModelReasonableActivityCodeRate = try container.decodeIfPresent(
            Double.self,
            forKey: .rawModelReasonableActivityCodeRate
        ) ?? reasonableActivityCodeRate
        authorizationRejectedFixtureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .authorizationRejectedFixtureCount
        ) ?? 0
        passesHardGates = try container.decode(Bool.self, forKey: .passesHardGates)
    }

    init(outcomes: [ScratchPadBillingFidelityOutcome]) {
        let lines = outcomes.flatMap(\.lineScores)
        let rawLines = outcomes.flatMap(\.rawModelLineScores)
        let tagged = lines.filter { $0.matterBasis == .tagged }
        let untagged = lines.filter { $0.matterBasis == .untaggedInference }
        let explicit = lines.filter { $0.timeBasis == .explicitWritten }
        let inferred = lines.filter { $0.timeBasis == .inferredTimestampGap }

        fixtureCount = outcomes.count
        expectedLineCount = lines.count
        firstPassJSONValidityRate = Self.rate(outcomes, where: \.strictJSONObjectOnly)
        parserAcceptanceRate = Self.rate(outcomes, where: \.firstPassJSONValid)
        matterAccuracyRate = Self.rate(lines, where: \.matterCorrect)
        taggedMatterAccuracyRate = Self.rate(tagged, where: \.matterCorrect)
        untaggedMatterAccuracyRate = Self.rate(untagged, where: \.matterCorrect)
        narrativeSubjectRate = Self.rate(lines, where: \.narrativeSubjectCorrect)
        explicitTimeAccuracyRate = Self.rate(explicit, where: \.timeCorrect)
        inferredTimeToleranceRate = Self.rate(inferred, where: \.timeCorrect)
        sourceAttributionRate = Self.rate(lines, where: \.sourceAttributionCorrect)
        taskCodeAccuracyRate = Self.rate(lines, where: \.taskCodeCorrect)
        activityCodeAccuracyRate = Self.rate(lines, where: \.activityCodeCorrect)
        canonicalTaskCodeRate = Self.rate(lines, where: \.taskCodeCanonical)
        canonicalActivityCodeRate = Self.rate(lines, where: \.activityCodeCanonical)
        let taskJudgments = lines.filter { !$0.acceptableTaskCodes.isEmpty }
        reasonableTaskCodeRate = Self.rate(taskJudgments, where: \.taskCodeReasonable)
        reasonableActivityCodeRate = Self.rate(lines, where: \.activityCodeReasonable)
        let blankTaskLines = lines.filter { $0.acceptableTaskCodes.isEmpty && $0.allowsBlankTaskCode }
        nonLitigationBlankTaskRate = Self.rate(blankTaskLines, where: \.taskCodeReasonable)
        let abstentions = lines.filter {
            $0.actualTaskCode == nil || $0.actualActivityCode == nil
        }
        justifiedAbstentionRate = Self.rate(abstentions, where: \.abstentionJustified)
        inferredTimeEvidenceRate = Self.rate(inferred, where: \.hasDurationEvidence)
        rawUnexpectedOutputLineCount = outcomes.reduce(0) { $0 + $1.rawUnexpectedOutputLineCount }
        unexpectedOutputLineCount = outcomes.reduce(0) { $0 + $1.unexpectedOutputLineCount }
        rawModelMatterAccuracyRate = Self.rate(rawLines, where: \.matterCorrect)
        rawModelSourceAttributionRate = Self.rate(rawLines, where: \.sourceAttributionCorrect)
        let rawTaskJudgments = rawLines.filter { !$0.acceptableTaskCodes.isEmpty }
        rawModelReasonableTaskCodeRate = Self.rate(rawTaskJudgments, where: \.taskCodeReasonable)
        rawModelReasonableActivityCodeRate = Self.rate(rawLines, where: \.activityCodeReasonable)
        authorizationRejectedFixtureCount = outcomes.filter(\.authorizationRejected).count

        passesHardGates = firstPassJSONValidityRate >= 0.95
            && parserAcceptanceRate >= 0.95
            && matterAccuracyRate >= 0.95
            && untaggedMatterAccuracyRate >= 0.95
            && narrativeSubjectRate >= 0.95
            && explicitTimeAccuracyRate == 1
            && inferredTimeToleranceRate == 1
            && sourceAttributionRate == 1
            && canonicalTaskCodeRate == 1
            && canonicalActivityCodeRate == 1
            && reasonableTaskCodeRate >= 0.80
            && reasonableActivityCodeRate >= 0.80
            && nonLitigationBlankTaskRate == 1
            && justifiedAbstentionRate == 1
            && inferredTimeEvidenceRate == 1
            && unexpectedOutputLineCount == 0
    }

    private static func rate<T>(_ values: [T], where keyPath: KeyPath<T, Bool>) -> Double {
        guard !values.isEmpty else { return 1 }
        return Double(values.filter { $0[keyPath: keyPath] }.count) / Double(values.count)
    }
}

public struct ScratchPadBillingFidelityRunRecord: Codable, Sendable {
    public let status: String
    public let fixtureVersion: String
    public let sourceCommitSHA: String
    public let modelID: String
    public let modelRepositoryID: String?
    public let modelRevision: String?
    public let modelManifestSHA256: String?
    public let modelContentBindingAlgorithm: String?
    public let modelContentBindingSchemaVersion: Int?
    public let modelArtifactFingerprintSHA256: String?
    public let modelName: String
    public let startedAt: Date
    public let completedAt: Date
    public let outcomes: [ScratchPadBillingFidelityOutcome]
    public let summary: ScratchPadBillingFidelitySummary
}

@MainActor
enum ScratchPadBillingFidelityScorer {
    static func score(
        fixture: ScratchPadBillingFidelityFixture,
        rawModelText: String,
        normalizedModelText: String? = nil,
        systemPrompt: String? = nil,
        userPrompt: String? = nil,
        generationError: String? = nil,
        durationSeconds: Double = 0,
        authorizationRejected: Bool = false,
        includeRawDiagnostics: Bool = true
    ) -> ScratchPadBillingFidelityOutcome {
        let answer = ReasoningContent.answer(from: rawModelText)
        let parserPayload = BillingDraftService.parse(answer)
        let rawOutputLineCount = parserPayload?.lineItems.count ?? 0
        let scoringText = normalizedModelText ?? answer
        let payload = BillingDraftService.parse(scoringText)
        let strictPayload = try? JSONDecoder().decode(
            BillingDraftPayload.self,
            from: Data(rawModelText.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        )
        let outputs = payload?.lineItems ?? []
        var unused = Set(outputs.indices)
        var scores: [ScratchPadBillingFidelityLineScore] = []
        var matchedExpectationsByOutput: [Int: String] = [:]

        for expectation in fixture.expectations {
            let expectedSources = Set(expectation.sourceEntryIDs)
            let candidate = unused
                .map { index -> (index: Int, exactSources: Bool, matter: Bool, subjectTerms: Int) in
                    let output = outputs[index]
                    let actualSources = Set(output.sourceEntryIDs ?? [])
                    let narrative = output.narrative
                    let subjectTerms = expectation.narrativeTermGroups.filter { alternatives in
                        alternatives.contains { narrative.localizedCaseInsensitiveContains($0) }
                    }.count
                    return (
                        index,
                        actualSources == expectedSources,
                        output.matterID == expectation.expectedMatterID,
                        subjectTerms
                    )
                }
                .filter(\.exactSources)
                .sorted {
                    if $0.matter != $1.matter { return $0.matter && !$1.matter }
                    if $0.subjectTerms != $1.subjectTerms { return $0.subjectTerms > $1.subjectTerms }
                    return $0.index < $1.index
                }
                .first

            let output = candidate.map { outputs[$0.index] }
            if let candidate {
                unused.remove(candidate.index)
                matchedExpectationsByOutput[candidate.index] = expectation.id
            }
            let rawOutput = parserPayload?.lineItems
                .enumerated()
                .filter { Set($0.element.sourceEntryIDs ?? []) == expectedSources }
                .sorted { lhs, rhs in
                    let lhsMatter = lhs.element.matterID == expectation.expectedMatterID
                    let rhsMatter = rhs.element.matterID == expectation.expectedMatterID
                    if lhsMatter != rhsMatter { return lhsMatter && !rhsMatter }
                    let lhsTerms = expectation.narrativeTermGroups.filter { alternatives in
                        alternatives.contains { term in lhs.element.narrative.localizedCaseInsensitiveContains(term) }
                    }.count
                    let rhsTerms = expectation.narrativeTermGroups.filter { alternatives in
                        alternatives.contains { term in rhs.element.narrative.localizedCaseInsensitiveContains(term) }
                    }.count
                    if lhsTerms != rhsTerms { return lhsTerms > rhsTerms }
                    return lhs.offset < rhs.offset
                }
                .first?
                .element
            let actualSources = output?.sourceEntryIDs ?? []
            let sourceCorrect = expectedSources == Set(actualSources)
            let actualNarrative = output?.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
            let subjectCorrect = sourceCorrect && expectation.narrativeTermGroups.allSatisfy { alternatives in
                alternatives.contains { term in
                    actualNarrative?.localizedCaseInsensitiveContains(term) == true
                }
            }
            let actualHours = output?.hours
            let tolerance = expectation.timeBasis == .explicitWritten ? 0.000_1 : 0.100_1
            let timeCorrect = sourceCorrect
                && actualHours.map { abs($0 - expectation.expectedHours) <= tolerance } == true
            let rawTaskCode = Self.normalized(rawOutput?.taskCode)
            let actualTaskCode = Self.normalized(output?.taskCode)
            let expectedTaskCode = Self.normalized(expectation.expectedTaskCode)
            let rawActivityCode = Self.normalized(rawOutput?.activityCode)
            let actualActivityCode = Self.normalized(output?.activityCode)
            let expectedActivityCode = Self.normalized(expectation.expectedActivityCode)
            let codeSet = fixture.matterRules.first { $0.matterID == expectation.expectedMatterID }?.codeSet ?? .none
            let taskCodeDropped = rawTaskCode != nil && actualTaskCode == nil
            let activityCodeDropped = rawActivityCode != nil && actualActivityCode == nil
            let taskCodeCanonical = !taskCodeDropped && (actualTaskCode.map {
                UTBMSCodes.normalizedTaskCode($0, codeSet: codeSet) == $0
            } ?? expectation.allowsBlankTaskCode)
            let activityCodeCanonical = !activityCodeDropped && (actualActivityCode.map {
                UTBMSCodes.normalizedActivityCode($0) == $0
            } ?? expectation.allowsBlankActivityCode)
            let taskCodeReasonable = !taskCodeDropped && (actualTaskCode.map(expectation.acceptableTaskCodes.contains)
                ?? expectation.allowsBlankTaskCode)
            let activityCodeReasonable = !activityCodeDropped && (actualActivityCode.map(expectation.acceptableActivityCodes.contains)
                ?? expectation.allowsBlankActivityCode)
            let codeNote = output?.codeNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usefulCodeNote = codeNote.map {
                $0.count >= 12 && $0.split(whereSeparator: \.isWhitespace).count >= 3
            } ?? false
            let requiresAbstentionNote = actualTaskCode == nil || actualActivityCode == nil
            let abstentionJustified = !requiresAbstentionNote || usefulCodeNote

            scores.append(ScratchPadBillingFidelityLineScore(
                expectationID: expectation.id,
                sourceEntryIDs: expectation.sourceEntryIDs,
                expectedMatterID: expectation.expectedMatterID,
                matterBasis: expectation.matterBasis,
                narrativeTermGroups: expectation.narrativeTermGroups,
                billingCodeSet: codeSet.rawValue,
                timeBasis: expectation.timeBasis,
                expectedHours: expectation.expectedHours,
                expectedTaskCode: expectation.expectedTaskCode,
                expectedActivityCode: expectation.expectedActivityCode,
                acceptableTaskCodes: expectation.acceptableTaskCodes.sorted(),
                acceptableActivityCodes: expectation.acceptableActivityCodes.sorted(),
                allowsBlankTaskCode: expectation.allowsBlankTaskCode,
                allowsBlankActivityCode: expectation.allowsBlankActivityCode,
                codeRationale: expectation.codeRationale,
                matchedOutputIndex: candidate?.index,
                actualMatterID: output?.matterID,
                actualNarrative: actualNarrative,
                actualHours: actualHours,
                actualTaskCode: actualTaskCode,
                actualActivityCode: actualActivityCode,
                actualConfidence: output?.confidence,
                actualEvidence: output?.evidence,
                actualCodeNote: codeNote,
                actualSourceEntryIDs: actualSources,
                sourceAttributionCorrect: sourceCorrect,
                matterCorrect: sourceCorrect && output?.matterID == expectation.expectedMatterID,
                narrativeSubjectCorrect: subjectCorrect,
                timeCorrect: timeCorrect,
                taskCodeCorrect: sourceCorrect && actualTaskCode == expectedTaskCode,
                activityCodeCorrect: sourceCorrect && actualActivityCode == expectedActivityCode,
                taskCodeCanonical: taskCodeCanonical,
                activityCodeCanonical: activityCodeCanonical,
                taskCodeReasonable: sourceCorrect && taskCodeReasonable,
                activityCodeReasonable: sourceCorrect && activityCodeReasonable,
                abstentionJustified: sourceCorrect && abstentionJustified,
                hasDurationEvidence: sourceCorrect
                    && !(output?.evidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ))
        }

        let normalizedOutputLines = outputs.indices.map { index in
            let output = outputs[index]
            return ScratchPadBillingFidelityOutputLine(
                outputIndex: index,
                matchedExpectationID: matchedExpectationsByOutput[index],
                matterID: output.matterID,
                narrative: output.narrative,
                hours: output.hours ?? 0,
                workDate: output.workDate ?? "",
                taskCode: Self.normalized(output.taskCode),
                activityCode: Self.normalized(output.activityCode),
                confidence: output.confidence ?? "",
                evidence: output.evidence,
                codeNote: output.codeNote,
                sourceEntryIDs: output.sourceEntryIDs ?? []
            )
        }

        let rawUnexpectedOutputLineCount = max(
            0,
            rawOutputLineCount - fixture.expectations.count
        )
        let rawModelLineScores: [ScratchPadBillingFidelityLineScore]
        if includeRawDiagnostics, normalizedModelText != nil {
            rawModelLineScores = score(
                fixture: fixture,
                rawModelText: rawModelText,
                normalizedModelText: nil,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                generationError: nil,
                durationSeconds: durationSeconds,
                includeRawDiagnostics: false
            ).lineScores
        } else {
            rawModelLineScores = scores
        }

        return ScratchPadBillingFidelityOutcome(
            fixtureID: fixture.id,
            systemPrompt: systemPrompt ?? BillingDraftPrompt.system(),
            userPrompt: userPrompt ?? BillingDraftPrompt.user(context(for: fixture)),
            rawModelText: rawModelText,
            firstPassJSONValid: parserPayload != nil,
            strictJSONObjectOnly: strictPayload != nil,
            generationError: generationError,
            durationSeconds: durationSeconds,
            rawOutputLineCount: rawOutputLineCount,
            outputLineCount: outputs.count,
            rawUnexpectedOutputLineCount: rawUnexpectedOutputLineCount,
            unexpectedOutputLineCount: unused.count,
            normalizedOutputLines: normalizedOutputLines,
            rawModelLineScores: rawModelLineScores,
            lineScores: scores,
            authorizationRejected: authorizationRejected
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.uppercased()
    }

    static func context(for fixture: ScratchPadBillingFidelityFixture) -> BillingDraftPrompt.Context {
        let entries = fixture.entries.filter { !$0.isNonBillable }
        let includedEntryIDs = Set(entries.map(\.id))
        let attachments = fixture.attachments.filter { attachment in
            guard let entryID = attachment.entryID else { return true }
            return includedEntryIDs.contains(entryID)
        }
        return BillingDraftPrompt.Context(
            dayDate: fixture.dayDate,
            entries: entries,
            attachments: attachments,
            matters: fixture.matters,
            matterRules: fixture.matterRules,
            sensitivity: 0.5,
            increment: 0.1,
            globalInstructions: "Use contemporaneous notes only. Do not block bill.",
            autoCoding: true,
            autoTimestamp: fixture.autoTimestamp
        )
    }
}

public enum ScratchPadBillingFidelityHarness {
    public static let fixtureVersion = "scratchpad-billing-fidelity-v3"

    @MainActor
    public static func run(
        modelID: ModelID,
        modelName: String,
        modelRepositoryID: String? = nil,
        modelRevision: String? = nil,
        modelManifestSHA256: String? = nil,
        modelContentBindingAlgorithm: String? = nil,
        modelContentBindingSchemaVersion: Int? = nil,
        modelArtifactFingerprintSHA256: String? = nil,
        sourceCommitSHA: String,
        modelExecutionGateway: any ModelExecutionGateway
    ) async -> ScratchPadBillingFidelityRunRecord {
        let startedAt = Date()
        let timekeeper = BillingTimekeeper(
            id: "synthetic-timekeeper",
            name: "Synthetic Timekeeper",
            classification: "PARTNER",
            defaultRate: 500,
            lawFirmID: "synthetic-firm"
        )
        var outcomes: [ScratchPadBillingFidelityOutcome] = []
        for fixture in standardFixtures() {
            let outcome = await runFixture(fixture, timekeeper: timekeeper) { systemPrompt, userPrompt in
                let request = GenerateRequest(
                    generationID: GenerationID(),
                    modelID: modelID,
                    prompt: userPrompt,
                    systemPrompt: systemPrompt,
                    contextWorkload: .groundedExactEvidence,
                    options: GenerationOptions(
                        preset: .extractive,
                        temperature: 0,
                        topP: 1,
                        maxOutputTokens: 3000,
                        thinkingBudget: .off
                    )
                )
                return try await modelExecutionGateway.collectGeneratedText(request)
            }
            outcomes.append(outcome)
        }
        let summary = ScratchPadBillingFidelitySummary(outcomes: outcomes)
        return ScratchPadBillingFidelityRunRecord(
            status: summary.passesHardGates ? "passed" : "failed",
            fixtureVersion: fixtureVersion,
            sourceCommitSHA: sourceCommitSHA,
            modelID: modelID.rawValue.uuidString,
            modelRepositoryID: modelRepositoryID,
            modelRevision: modelRevision,
            modelManifestSHA256: modelManifestSHA256,
            modelContentBindingAlgorithm: modelContentBindingAlgorithm,
            modelContentBindingSchemaVersion: modelContentBindingSchemaVersion,
            modelArtifactFingerprintSHA256: modelArtifactFingerprintSHA256,
            modelName: modelName,
            startedAt: startedAt,
            completedAt: Date(),
            outcomes: outcomes,
            summary: summary
        )
    }

    @MainActor
    static func runFixture(
        _ fixture: ScratchPadBillingFidelityFixture,
        timekeeper: BillingTimekeeper,
        generate: @escaping BillingDraftService.Generate
    ) async -> ScratchPadBillingFidelityOutcome {
        let startedAt = Date()
        var capturedSystemPrompt = ""
        var capturedUserPrompt = ""
        var capturedRaw = ""
        do {
            let store = try SupraStore.inMemory()
            let day = try store.scratchPad.fetchOrCreateDay(fixture.dayDate)
            for matter in fixture.matters {
                try await store.database.writer.write { db in
                    try matter.insert(db)
                }
                let codeSet = fixture.matterRules.first { $0.matterID == matter.id }?.codeSet ?? .none
                let override = fixture.matterRules.first { $0.matterID == matter.id }?.overrideInstructions
                try store.billing.upsertBillingProfile(
                    matterID: matter.id,
                    overrideInstructions: override,
                    billingCodeSet: codeSet
                )
            }
            for entry in fixture.entries {
                try await store.database.writer.write { db in
                    try ScratchPadEntryRecord(
                        id: entry.id,
                        dayID: day.id,
                        seq: entry.seq,
                        text: entry.text,
                        mentionsJSON: entry.mentionsJSON,
                        tagsJSON: entry.tagsJSON,
                        createdAt: entry.createdAt,
                        updatedAt: entry.updatedAt
                    ).insert(db)
                }
            }
            for attachment in fixture.attachments {
                try await store.database.writer.write { db in
                    try ScratchPadAttachmentRecord(
                        id: attachment.id,
                        dayID: day.id,
                        entryID: attachment.entryID,
                        matterDocumentID: attachment.matterDocumentID,
                        matterID: attachment.matterID,
                        evidenceKind: BillingEvidenceKind(rawValue: attachment.evidenceKind) ?? .other,
                        evidenceSignalsJSON: attachment.evidenceSignalsJSON,
                        createdAt: attachment.createdAt,
                        updatedAt: attachment.updatedAt
                    ).insert(db)
                }
            }

            let service = BillingDraftService(store: store) { systemPrompt, userPrompt in
                capturedSystemPrompt = systemPrompt
                capturedUserPrompt = userPrompt
                capturedRaw = try await generate(systemPrompt, userPrompt)
                return ReasoningContent.answer(from: capturedRaw)
            }
            let result = try await service.generateDraft(
                dayID: day.id,
                sensitivity: 0.5,
                timekeeper: timekeeper,
                invoiceDate: fixture.dayDate,
                globalInstructions: "Use contemporaneous notes only. Do not block bill.",
                increment: 0.1,
                autoCoding: true,
                autoTimestamp: fixture.autoTimestamp
            )
            let persistedLines = try store.billing.lineItems(draftID: result.draftID)
            return ScratchPadBillingFidelityScorer.score(
                fixture: fixture,
                rawModelText: capturedRaw,
                normalizedModelText: normalizedJSON(for: persistedLines),
                systemPrompt: capturedSystemPrompt,
                userPrompt: capturedUserPrompt,
                durationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch {
            let authorizationRejected: Bool
            if let billingError = error as? BillingDraftError,
               case .invalidEvidenceScope = billingError {
                authorizationRejected = true
            } else {
                authorizationRejected = false
            }
            return ScratchPadBillingFidelityScorer.score(
                fixture: fixture,
                rawModelText: capturedRaw,
                normalizedModelText: "{\"lineItems\":[]}",
                systemPrompt: capturedSystemPrompt.isEmpty ? nil : capturedSystemPrompt,
                userPrompt: capturedUserPrompt.isEmpty ? nil : capturedUserPrompt,
                generationError: String(describing: error),
                authorizationRejected: authorizationRejected
            )
        }
    }

    private static func normalizedJSON(for lines: [BillingLineItemRecord]) -> String {
        let payload: [[String: Any]] = lines.map { line in
            [
                "matterID": line.matterID ?? NSNull(),
                "narrative": line.narrative,
                "hours": line.hours,
                "workDate": line.workDate,
                "taskCode": line.utbmsTaskCode ?? NSNull(),
                "activityCode": line.utbmsActivityCode ?? NSNull(),
                "confidence": line.confidence,
                "evidence": line.evidenceJSON ?? "",
                "codeNote": line.codeNote ?? NSNull(),
                "sourceEntryIDs": line.sourceEntryIDs,
            ]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["lineItems": payload], options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"lineItems\":[]}"
    }

    static func canonicalJSON(for fixture: ScratchPadBillingFidelityFixture) -> String {
        let lines: [[String: Any]] = fixture.expectations.map { expectation in
            var line: [String: Any] = [
                "matterID": expectation.expectedMatterID,
                "narrative": "Completed " + expectation.narrativeTermGroups.compactMap(\.first).joined(separator: " ") + ".",
                "hours": expectation.expectedHours,
                "workDate": fixture.dayDate,
                "activityCode": expectation.expectedActivityCode ?? NSNull(),
                "confidence": expectation.timeBasis == .explicitWritten ? "high" : "medium",
                "evidence": expectation.timeBasis == .explicitWritten ? "explicit written time" : "timestamp gap",
                "codeNote": expectation.codeRationale,
                "sourceEntryIDs": expectation.sourceEntryIDs,
            ]
            line["taskCode"] = expectation.expectedTaskCode ?? NSNull()
            return line
        }
        let data = try? JSONSerialization.data(withJSONObject: ["lineItems": lines], options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func standardFixtures() -> [ScratchPadBillingFidelityFixture] {
        var fixtures: [ScratchPadBillingFidelityFixture] = []
        fixtures.append(singleFixture(
            number: 1, day: "2026-07-01", matterName: "Northstar Foods v. Harbor Transit",
            client: "Northstar Foods", text: "Spent exactly 1.2 hours drafting a motion to compel missing shipment records.",
            terms: [["motion"], ["compel"]], hours: 1.2, task: "L310", activity: "A103"
        ))
        fixtures.append(singleFixture(
            number: 2, day: "2026-07-02", matterName: "Aster Labs v. Meridian Systems",
            client: "Aster Labs", text: "Spent exactly 0.8 hours researching personal jurisdiction for a motion to dismiss.",
            terms: [["personal jurisdiction", "jurisdiction"], ["dismiss"]], hours: 0.8, task: "L120", activity: "A102"
        ))
        fixtures.append(singleFixture(
            number: 3, day: "2026-07-03", matterName: "Brightline Solar v. Oak Energy",
            client: "Brightline Solar", text: "Spent exactly 0.6 hours reviewing responses to requests for production for deficiencies.",
            terms: [["review"], ["production", "discovery"]], hours: 0.6, task: "L310", activity: "A104",
            overrideInstructions: "Synthetic client guideline: document-production response review must use L310 and A104."
        ))
        fixtures.append(singleFixture(
            number: 4, day: "2026-07-04", matterName: "Cedar Health v. Nimbus Billing",
            client: "Cedar Health", text: "Spent exactly 0.4 hours in a telephone conference with the client about initial case strategy.",
            terms: [["telephone", "conference"], ["strategy"]], hours: 0.4, task: "L120", activity: "A106"
        ))
        fixtures.append(singleFixture(
            number: 5, day: "2026-07-05", matterName: "Delta Works v. Granite Supply",
            client: "Delta Works", text: "Spent exactly 1.5 hours preparing interrogatories concerning product defects.",
            terms: [["interrogator"], ["defect"]], hours: 1.5, task: "L310", activity: "A103"
        ))
        fixtures.append(singleFixture(
            number: 6, day: "2026-07-06", matterName: "Elm Aviation v. Vector Parts",
            client: "Elm Aviation", text: "Spent exactly 0.3 hours analyzing appellate jurisdiction and briefing deadlines after a notice of appeal.",
            terms: [["appeal", "appellate"], ["jurisdiction"]], hours: 0.3, task: "L510", activity: "A104",
            acceptableTasks: Set(["L500", "L510"])
        ))
        fixtures.append(singleFixture(
            number: 7, day: "2026-07-07", matterName: "Fable Retail Contract Review",
            client: "Fable Retail", text: "Spent exactly 0.7 hours revising a pre-suit demand letter regarding unpaid invoices.",
            terms: [["demand"], ["invoice"]], hours: 0.7, task: nil, activity: "A103", codeSet: .none
        ))
        fixtures.append(singleFixture(
            number: 8, day: "2026-07-08", matterName: "Grove Media Licensing",
            client: "Grove Media", text: "Spent exactly 1.1 hours on the attached agreement review.",
            terms: [["licens"], ["indemn"]], hours: 1.1, task: nil, activity: "A104", codeSet: .none
        ))
        fixtures.append(singleFixture(
            number: 9, day: "2026-07-09", matterName: "Helix Farms v. Ion Equipment",
            client: "Helix Farms", text: "Spent exactly 0.2 hours emailing opposing counsel about mediation dates.",
            terms: [["email", "correspond"], ["mediat"]], hours: 0.2, task: "L160", activity: "A107"
        ))
        fixtures.append(singleFixture(
            number: 10, day: "2026-07-10", matterName: "Indigo Hotels v. Juniper Design",
            client: "Indigo Hotels", text: "Spent exactly 0.9 hours working on motion-in-limine follow-up; this note does not say whether the work was drafting, review, or communication.",
            terms: [["limine"], ["follow-up", "follow up"]], hours: 0.9, task: "L250", activity: nil,
            allowsBlankActivity: true,
            codeRationale: "A motion in limine is a non-dispositive written motion; the evidence does not identify a single reasonable activity, so blank plus explanation is preferred."
        ))

        fixtures.append(inferredFixture(
            number: 11, day: "2026-07-11", matterName: "Kestrel Finance v. Lattice Group", client: "Kestrel Finance",
            start: (9, 0, "Began reviewing the amended complaint for damages allegations."),
            end: (9, 40, "Completed review of the amended complaint."),
            terms: [["review"], ["complaint"]], hours: 0.7, task: "L120", activity: "A104",
            acceptableTasks: Set(["L120", "L210"])
        ))
        fixtures.append(inferredFixture(
            number: 12, day: "2026-07-12", matterName: "Monarch Transit v. Nova Freight", client: "Monarch Transit",
            start: (10, 0, "Began researching federal preemption of the cargo claim."),
            end: (10, 48, "Completed federal preemption research."),
            terms: [["research"], ["preemption"]], hours: 0.8, task: "L120", activity: "A102"
        ))
        fixtures.append(inferredFixture(
            number: 13, day: "2026-07-13", matterName: "Orchid Medical v. Pine Analytics", client: "Orchid Medical",
            start: (13, 0, "Began drafting the opposition to the motion to dismiss."),
            end: (14, 12, "Completed the first opposition draft."),
            terms: [["opposition"], ["dismiss"]], hours: 1.2, task: "L250", activity: "A103",
            acceptableTasks: Set(["L210", "L250"])
        ))
        fixtures.append(inferredFixture(
            number: 14, day: "2026-07-14", matterName: "Quartz Homes v. River Masonry", client: "Quartz Homes",
            start: (15, 0, "Began preparing the project manager for deposition."),
            end: (15, 30, "Completed deposition preparation session."),
            terms: [["deposition"], ["prepar"]], hours: 0.5, task: "L330", activity: "A101"
        ))
        fixtures.append(inferredFixture(
            number: 15, day: "2026-07-15", matterName: "Summit Telecom v. Tidal Networks", client: "Summit Telecom",
            start: (16, 0, "Began reviewing the opposing party's document production."),
            end: (16, 54, "Completed review of the document production."),
            terms: [["review"], ["production"]], hours: 0.9, task: "L320", activity: "A104"
        ))

        fixtures.append(multiMatterFixture(
            number: 16, day: "2026-07-16",
            first: ("Umbra Foods v. Vale Shipping", "Umbra Foods", "Spent exactly 0.3 hours drafting a status report.", [["status"], ["report"]], 0.3, "L110", "A103"),
            second: ("Willow Health v. Xenon Data", "Willow Health", "Spent exactly 0.2 hours attending the scheduling conference.", [["scheduling"], ["conference"]], 0.2, "L110", "A105"),
            untaggedText: "For Umbra Foods, spent exactly 0.6 hours researching carrier liability defenses.",
            untaggedMatter: .first, untaggedTerms: [["research"], ["carrier", "liability"]], untaggedHours: 0.6, untaggedTask: "L120", untaggedActivity: "A102"
        ))
        fixtures.append(multiMatterFixture(
            number: 17, day: "2026-07-17",
            first: ("Yarrow Labs v. Zenith Devices", "Yarrow Labs", "Spent exactly 0.4 hours preparing a discovery plan.", [["discovery"], ["plan"]], 0.4, "L120", "A103"),
            second: ("Aurora Bank v. Beacon Title", "Aurora Bank", "Spent exactly 0.5 hours analyzing witness interview notes.", [["witness"], ["interview"]], 0.5, "L320", "A104"),
            untaggedText: "For Aurora Bank, spent exactly 0.3 hours emailing the client about witness availability.",
            untaggedMatter: .second, untaggedTerms: [["email", "correspond"], ["witness"]], untaggedHours: 0.3, untaggedTask: "L320", untaggedActivity: "A106"
        ))
        fixtures.append(multiMatterFixture(
            number: 18, day: "2026-07-18",
            first: ("Cobalt Stores v. Drift Logistics", "Cobalt Stores", "Spent exactly 0.6 hours revising requests for admission.", [["admission"], ["revis"]], 0.6, "L310", "A103"),
            second: ("Evergreen Clinic v. Fathom Software", "Evergreen Clinic", "Spent exactly 0.4 hours researching damages standards.", [["research"], ["damage"]], 0.4, "L120", "A102"),
            untaggedText: "For Cobalt Stores, spent exactly 0.2 hours organizing and indexing Drift Logistics' production files.",
            untaggedMatter: .first, untaggedTerms: [["organiz"], ["production"], ["file"]], untaggedHours: 0.2, untaggedTask: "L320", untaggedActivity: "A110"
        ))
        fixtures.append(multiMatterFixture(
            number: 19, day: "2026-07-19",
            first: ("Glacier Energy v. Harbor Controls", "Glacier Energy", "Spent exactly 0.7 hours drafting a mediation statement.", [["mediation"], ["statement"]], 0.7, "L160", "A103"),
            second: ("Iris Schools v. Keystone Learning", "Iris Schools", "Spent exactly 0.3 hours reviewing expert disclosures.", [["expert"], ["disclosure"]], 0.3, "L340", "A104"),
            untaggedText: "For Iris Schools, spent exactly 0.5 hours preparing questions for the education expert.",
            untaggedMatter: .second, untaggedTerms: [["question"], ["expert"]], untaggedHours: 0.5, untaggedTask: "L340", untaggedActivity: "A103"
        ))
        fixtures.append(multiMatterFixture(
            number: 20, day: "2026-07-20",
            first: ("Juniper Foods v. Kinetic Packaging", "Juniper Foods", "Spent exactly 0.5 hours analyzing settlement terms.", [["settlement"], ["term"]], 0.5, "L160", "A104"),
            second: ("Lunar Transit v. Metro Signals", "Lunar Transit", "Spent exactly 0.8 hours drafting a motion for protective order.", [["protective"], ["order"]], 0.8, "L310", "A103"),
            untaggedText: "For Juniper Foods, spent exactly 0.4 hours conferencing with the client about settlement authority.",
            untaggedMatter: .first, untaggedTerms: [["conference"], ["settlement"]], untaggedHours: 0.4, untaggedTask: "L160", untaggedActivity: "A106"
        ))
        return fixtures
    }

    private static func singleFixture(
        number: Int,
        day: String,
        matterName: String,
        client: String,
        text: String,
        terms: [[String]],
        hours: Double,
        task: String?,
        activity: String?,
        codeSet: BillingCodeSet = .litigation,
        acceptableTasks: Set<String>? = nil,
        allowsBlankActivity: Bool = false,
        codeRationale: String = "Reasonable UTBMS interpretation of the generated narrative and cited source evidence.",
        overrideInstructions: String? = nil
    ) -> ScratchPadBillingFidelityFixture {
        let prefix = "f\(number)"
        let matter = MatterRecord(id: "\(prefix)-matter", name: matterName, clientNames: client)
        let entry = makeEntry(id: "\(prefix)-e1", day: day, seq: 1, time: (9, 0), text: text, mentions: [matter.id])
        var entries = [entry]
        var attachments: [ScratchPadAttachmentRecord] = []
        if number == 8 {
            let excluded = makeEntry(
                id: "\(prefix)-note",
                day: day,
                seq: 2,
                time: (9, 30),
                text: "#Note BILLING_CANARY_DO_NOT_USE",
                mentions: [matter.id]
            )
            entries.append(excluded)
            attachments = [
                makeAttachment(
                    id: "\(prefix)-a1",
                    entry: entry,
                    matterID: matter.id,
                    fileName: "licensing-risk-review.txt",
                    excerpt: "Reviewed indemnity and limitation-of-liability provisions in the software license."
                ),
                makeAttachment(
                    id: "\(prefix)-a2",
                    entry: excluded,
                    matterID: matter.id,
                    fileName: "excluded-canary.txt",
                    excerpt: "BILLING_CANARY_DO_NOT_USE"
                ),
            ]
        }
        return makeFixture(
            id: prefix,
            day: day,
            matters: [(matter, codeSet)],
            entries: entries,
            attachments: attachments,
            expectations: [expectation(
                id: "\(prefix)-x1",
                sources: [entry.id],
                matter: matter.id,
                basis: .tagged,
                terms: terms,
                hours: hours,
                time: .explicitWritten,
                task: task,
                activity: activity,
                acceptableTasks: acceptableTasks ?? (number == 1 ? Set(["L310", "L350"]) : nil),
                allowsBlankActivity: allowsBlankActivity,
                codeRationale: codeRationale
            )],
            autoTimestamp: number != 10,
            overrideInstructionsByMatter: overrideInstructions.map { [matter.id: $0] } ?? [:]
        )
    }

    private static func inferredFixture(
        number: Int,
        day: String,
        matterName: String,
        client: String,
        start: (Int, Int, String),
        end: (Int, Int, String),
        terms: [[String]],
        hours: Double,
        task: String?,
        activity: String?,
        acceptableTasks: Set<String>? = nil
    ) -> ScratchPadBillingFidelityFixture {
        let prefix = "f\(number)"
        let matter = MatterRecord(id: "\(prefix)-matter", name: matterName, clientNames: client)
        let first = makeEntry(id: "\(prefix)-e1", day: day, seq: 1, time: (start.0, start.1), text: start.2, mentions: [matter.id])
        let second = makeEntry(id: "\(prefix)-e2", day: day, seq: 2, time: (end.0, end.1), text: end.2, mentions: [matter.id])
        return makeFixture(
            id: prefix, day: day, matters: [(matter, .litigation)], entries: [first, second],
            expectations: [expectation(id: "\(prefix)-x1", sources: [first.id, second.id], matter: matter.id, basis: .tagged, terms: terms, hours: hours, time: .inferredTimestampGap, task: task, activity: activity, acceptableTasks: acceptableTasks)]
        )
    }

    private enum MatterChoice { case first, second }
    private typealias MultiMatterSpec = (name: String, client: String, text: String, terms: [[String]], hours: Double, task: String?, activity: String?)

    private static func multiMatterFixture(
        number: Int,
        day: String,
        first: MultiMatterSpec,
        second: MultiMatterSpec,
        untaggedText: String,
        untaggedMatter: MatterChoice,
        untaggedTerms: [[String]],
        untaggedHours: Double,
        untaggedTask: String?,
        untaggedActivity: String?
    ) -> ScratchPadBillingFidelityFixture {
        let prefix = "f\(number)"
        let firstMatter = MatterRecord(id: "\(prefix)-matter-a", name: first.name, clientNames: first.client)
        let secondMatter = MatterRecord(id: "\(prefix)-matter-b", name: second.name, clientNames: second.client)
        let firstEntry = makeEntry(id: "\(prefix)-e1", day: day, seq: 1, time: (9, 0), text: first.text, mentions: [firstMatter.id])
        let secondEntry = makeEntry(id: "\(prefix)-e2", day: day, seq: 2, time: (10, 0), text: second.text, mentions: [secondMatter.id])
        let untaggedEntry = makeEntry(id: "\(prefix)-e3", day: day, seq: 3, time: (11, 0), text: untaggedText, mentions: [])
        let inferredMatter = untaggedMatter == .first ? firstMatter : secondMatter
        return makeFixture(
            id: prefix,
            day: day,
            matters: [(firstMatter, .litigation), (secondMatter, .litigation)],
            entries: [firstEntry, secondEntry, untaggedEntry],
            expectations: [
                expectation(id: "\(prefix)-x1", sources: [firstEntry.id], matter: firstMatter.id, basis: .tagged, terms: first.terms, hours: first.hours, time: .explicitWritten, task: first.task, activity: first.activity),
                expectation(id: "\(prefix)-x2", sources: [secondEntry.id], matter: secondMatter.id, basis: .tagged, terms: second.terms, hours: second.hours, time: .explicitWritten, task: second.task, activity: second.activity),
                expectation(id: "\(prefix)-x3", sources: [untaggedEntry.id], matter: inferredMatter.id, basis: .untaggedInference, terms: untaggedTerms, hours: untaggedHours, time: .explicitWritten, task: untaggedTask, activity: untaggedActivity),
            ]
        )
    }

    private static func makeFixture(
        id: String,
        day: String,
        matters: [(MatterRecord, BillingCodeSet)],
        entries: [ScratchPadEntryRecord],
        attachments: [ScratchPadAttachmentRecord] = [],
        expectations: [ScratchPadBillingFidelityExpectation],
        autoTimestamp: Bool = true,
        overrideInstructionsByMatter: [String: String] = [:]
    ) -> ScratchPadBillingFidelityFixture {
        ScratchPadBillingFidelityFixture(
            id: id,
            dayDate: day,
            entries: entries,
            attachments: attachments,
            matters: matters.map(\.0),
            matterRules: matters.map { matter, codeSet in
                MatterBillingRules(
                    matterID: matter.id,
                    matterName: matter.name,
                    clientName: matter.clientNames,
                    codeSet: codeSet,
                    overrideInstructions: overrideInstructionsByMatter[matter.id],
                    guidelineExcerpts: []
                )
            },
            expectations: expectations,
            autoTimestamp: autoTimestamp
        )
    }

    private static func expectation(
        id: String,
        sources: [String],
        matter: String,
        basis: ScratchPadBillingMatterBasis,
        terms: [[String]],
        hours: Double,
        time: ScratchPadBillingTimeBasis,
        task: String?,
        activity: String?,
        acceptableTasks: Set<String>? = nil,
        acceptableActivities: Set<String>? = nil,
        allowsBlankTask: Bool? = nil,
        allowsBlankActivity: Bool = false,
        codeRationale: String = "Reasonable UTBMS interpretation of the generated narrative and cited source evidence."
    ) -> ScratchPadBillingFidelityExpectation {
        ScratchPadBillingFidelityExpectation(
            id: id,
            sourceEntryIDs: sources,
            expectedMatterID: matter,
            matterBasis: basis,
            narrativeTermGroups: terms,
            expectedHours: hours,
            timeBasis: time,
            expectedTaskCode: task,
            expectedActivityCode: activity,
            acceptableTaskCodes: acceptableTasks ?? Set([task].compactMap { $0 }),
            acceptableActivityCodes: acceptableActivities ?? Set([activity].compactMap { $0 }),
            allowsBlankTaskCode: allowsBlankTask ?? (task == nil),
            allowsBlankActivityCode: allowsBlankActivity,
            codeRationale: codeRationale
        )
    }

    private static func makeAttachment(
        id: String,
        entry: ScratchPadEntryRecord,
        matterID: String,
        fileName: String,
        excerpt: String
    ) -> ScratchPadAttachmentRecord {
        let evidence = AttachmentEvidence(
            kind: BillingEvidenceKind.workProduct.rawValue,
            fileName: fileName,
            byteSize: excerpt.utf8.count,
            wordCount: excerpt.split(whereSeparator: \.isWhitespace).count,
            partCount: 1,
            attachmentCount: 0,
            extractionMethod: "synthetic-fixture",
            needsOCR: false,
            subject: "Synthetic billing fidelity evidence",
            metadataCreatedAt: entry.createdAt,
            metadataModifiedAt: entry.updatedAt,
            warnings: [],
            textExcerpt: excerpt
        )
        return ScratchPadAttachmentRecord(
            id: id,
            dayID: entry.dayID,
            entryID: entry.id,
            matterID: matterID,
            evidenceKind: .workProduct,
            evidenceSignalsJSON: AttachmentEvidence.encode(evidence),
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt
        )
    }

    private static func makeEntry(
        id: String,
        day: String,
        seq: Int,
        time: (Int, Int),
        text: String,
        mentions: [String]
    ) -> ScratchPadEntryRecord {
        let timestamp = localDate(day: day, hour: time.0, minute: time.1)
        return ScratchPadEntryRecord(
            id: id,
            dayID: "\(id)-day",
            seq: seq,
            text: text,
            mentionsJSON: ScratchPadJSON.encodeStrings(mentions),
            tagsJSON: text.localizedCaseInsensitiveContains("#Note")
                ? ScratchPadJSON.encodeStrings([ScratchPadEntryRecord.nonBillableTag])
                : nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private static func localDate(day: String, hour: Int, minute: Int) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
