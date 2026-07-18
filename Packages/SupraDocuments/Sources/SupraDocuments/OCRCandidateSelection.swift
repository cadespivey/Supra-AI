import Foundation

/// Deterministic, explainable arbitration between embedded text and OCR text.
/// Policy v1 requires OCR confidence plus at least one comparative quality win;
/// text length by itself can never replace embedded text.
public enum OCRCandidateSelection {
    public enum Origin: String, Codable, Equatable, Sendable {
        case parser
        case embeddedPDF = "embedded_pdf"
        case ocr
    }

    public struct RevisionCandidate: Codable, Equatable, Sendable {
        public var id: String
        public var origin: Origin
        public var text: String
        public var confidence: Double?
        public var boundingBoxesJSON: String?

        public init(
            id: String,
            origin: Origin,
            text: String,
            confidence: Double? = nil,
            boundingBoxesJSON: String? = nil
        ) {
            self.id = id
            self.origin = origin
            self.text = text
            self.confidence = confidence
            self.boundingBoxesJSON = boundingBoxesJSON
        }
    }

    public enum Criterion: String, Codable, Equatable, Hashable, Sendable {
        case coverage
        case usableText = "usable_text"
        case confidence
        case scriptConsistency = "script_consistency"
        case duplication
        case lowConfidenceBoxes = "low_confidence_boxes"
    }

    public struct CandidateScores: Codable, Equatable, Sendable {
        public var coverage: Double
        public var usableText: Double
        public var confidence: Double
        public var scriptConsistency: Double
        public var duplication: Double
        public var lowConfidenceBoxFraction: Double
        public var composite: Double
    }

    public struct Thresholds: Codable, Equatable, Sendable {
        public var lowConfidenceThreshold: Double
        public var minimumUsableTextLength: Int
        public var minimumCriteriaWins: Int
        public var minimumComparativeDelta: Double
        public var minimumScriptConsistency: Double
        public var maximumDuplicationRatio: Double
        public var maximumLowConfidenceBoxFraction: Double
        public var pageAreaProxyCharacters: Int

        public init(
            lowConfidenceThreshold: Double = OCRPolicy.lowConfidenceThreshold,
            minimumUsableTextLength: Int = OCRPolicy.minimumUsableTextLength,
            minimumCriteriaWins: Int = 2,
            minimumComparativeDelta: Double = 0.05,
            minimumScriptConsistency: Double = 0.70,
            maximumDuplicationRatio: Double = 0.45,
            maximumLowConfidenceBoxFraction: Double = 0.50,
            pageAreaProxyCharacters: Int = 1_000
        ) {
            self.lowConfidenceThreshold = lowConfidenceThreshold
            self.minimumUsableTextLength = minimumUsableTextLength
            self.minimumCriteriaWins = minimumCriteriaWins
            self.minimumComparativeDelta = minimumComparativeDelta
            self.minimumScriptConsistency = minimumScriptConsistency
            self.maximumDuplicationRatio = maximumDuplicationRatio
            self.maximumLowConfidenceBoxFraction = maximumLowConfidenceBoxFraction
            self.pageAreaProxyCharacters = pageAreaProxyCharacters
        }
    }

    public struct Policy: Codable, Equatable, Sendable {
        public var version: Int
        public var thresholds: Thresholds

        public init(version: Int, thresholds: Thresholds) {
            self.version = version
            self.thresholds = thresholds
        }

        public static let v1 = Policy(version: 1, thresholds: Thresholds())
    }

    public enum Rule: String, Codable, Equatable, Sendable {
        /// Decodable compatibility label only; policy v1 never emits this rule.
        case ocrWinsByLength = "ocr_wins_by_length_v0"
        case ocrWinsMultiCriterion = "ocr_wins_multi_criterion_v1"
        case ocrOnlyCandidate = "ocr_only_candidate_v1"
        case embeddedOCRConfidenceBelowThreshold = "embedded_ocr_confidence_below_threshold_v1"
        case embeddedInsufficientCriteria = "embedded_insufficient_criteria_v1"
        case embeddedOnly = "embedded_only_v1"
    }

    public struct Decision: Codable, Equatable, Sendable {
        public var policyVersion: Int
        public var candidateRevisionIDs: [String]
        public var selectedRevisionID: String
        public var chosenOrigin: Origin
        public var scores: [String: CandidateScores]
        public var thresholds: Thresholds
        public var ocrWinningCriteria: [Criterion]
        public var decidingRule: Rule
        public var needsReview: Bool
        public var reviewReason: String?
        public var selectedConfidence: Double

        public func canonicalJSON() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    public static func select(
        embedded: RevisionCandidate,
        ocr: RevisionCandidate,
        policy: Policy = .v1
    ) -> Decision {
        let thresholds = policy.thresholds
        let embeddedScores = score(embedded, thresholds: thresholds)
        let ocrScores = score(ocr, thresholds: thresholds)
        let scores = [embedded.id: embeddedScores, ocr.id: ocrScores]

        let embeddedIsEmpty = usableCharacterCount(embedded.text) == 0
        let ocrIsEmpty = usableCharacterCount(ocr.text) == 0
        let embeddedPoor = isPoor(embedded, scores: embeddedScores, thresholds: thresholds)
        let ocrPoor = isPoor(ocr, scores: ocrScores, thresholds: thresholds)

        if embeddedIsEmpty, !ocrIsEmpty {
            return makeDecision(
                policy: policy,
                candidates: [embedded, ocr],
                selected: ocr,
                scores: scores,
                winningCriteria: winningCriteria(
                    embedded: embeddedScores,
                    ocr: ocrScores,
                    thresholds: thresholds
                ),
                rule: .ocrOnlyCandidate,
                needsReview: ocrPoor,
                reviewReason: ocrPoor ? "ocr_only_candidate_below_quality_floor" : nil
            )
        }

        let criteria = winningCriteria(
            embedded: embeddedScores,
            ocr: ocrScores,
            thresholds: thresholds
        )
        let comparativeCriteria: Set<Criterion> = [.coverage, .usableText, .scriptConsistency, .duplication]
        let hasComparativeWin = !comparativeCriteria.isDisjoint(with: Set(criteria))
        let confidencePasses = criteria.contains(.confidence)
        let ocrWins = !ocrIsEmpty
            && confidencePasses
            && hasComparativeWin
            && criteria.count >= thresholds.minimumCriteriaWins

        let selected = ocrWins ? ocr : embedded
        let rule: Rule
        if ocrWins {
            rule = .ocrWinsMultiCriterion
        } else if ocr.confidence.map({ $0 < thresholds.lowConfidenceThreshold }) ?? true {
            rule = .embeddedOCRConfidenceBelowThreshold
        } else {
            rule = .embeddedInsufficientCriteria
        }
        let bothPoor = embeddedPoor && ocrPoor
        return makeDecision(
            policy: policy,
            candidates: [embedded, ocr],
            selected: selected,
            scores: scores,
            winningCriteria: criteria,
            rule: rule,
            needsReview: bothPoor,
            reviewReason: bothPoor ? "both_candidates_below_quality_floor" : nil
        )
    }

    public static func selectSingle(
        _ candidate: RevisionCandidate,
        policy: Policy = .v1
    ) -> Decision {
        let candidateScores = score(candidate, thresholds: policy.thresholds)
        return makeDecision(
            policy: policy,
            candidates: [candidate],
            selected: candidate,
            scores: [candidate.id: candidateScores],
            winningCriteria: [],
            rule: .embeddedOnly,
            needsReview: false,
            reviewReason: nil
        )
    }

    private static func makeDecision(
        policy: Policy,
        candidates: [RevisionCandidate],
        selected: RevisionCandidate,
        scores: [String: CandidateScores],
        winningCriteria: [Criterion],
        rule: Rule,
        needsReview: Bool,
        reviewReason: String?
    ) -> Decision {
        Decision(
            policyVersion: policy.version,
            candidateRevisionIDs: candidates.map(\.id),
            selectedRevisionID: selected.id,
            chosenOrigin: selected.origin,
            scores: scores,
            thresholds: policy.thresholds,
            ocrWinningCriteria: winningCriteria,
            decidingRule: rule,
            needsReview: needsReview,
            reviewReason: reviewReason,
            selectedConfidence: scores[selected.id]?.composite ?? 0
        )
    }

    private static func winningCriteria(
        embedded: CandidateScores,
        ocr: CandidateScores,
        thresholds: Thresholds
    ) -> [Criterion] {
        var criteria: [Criterion] = []
        let delta = thresholds.minimumComparativeDelta
        if ocr.coverage > embedded.coverage + delta { criteria.append(.coverage) }
        if ocr.usableText > embedded.usableText + delta { criteria.append(.usableText) }
        if ocr.confidence >= thresholds.lowConfidenceThreshold { criteria.append(.confidence) }
        if ocr.scriptConsistency > embedded.scriptConsistency + delta {
            criteria.append(.scriptConsistency)
        }
        if ocr.duplication + delta < embedded.duplication { criteria.append(.duplication) }
        if ocr.lowConfidenceBoxFraction <= thresholds.maximumLowConfidenceBoxFraction {
            criteria.append(.lowConfidenceBoxes)
        }
        return criteria
    }

    private static func score(
        _ candidate: RevisionCandidate,
        thresholds: Thresholds
    ) -> CandidateScores {
        let usableCount = usableCharacterCount(candidate.text)
        let coverage = min(1, Double(usableCount) / Double(max(1, thresholds.pageAreaProxyCharacters)))
        let usableText = min(1, Double(usableCount) / Double(max(1, thresholds.minimumUsableTextLength)))
        let confidence = candidate.confidence.map(clamp) ?? (candidate.origin == .ocr ? 0 : 1)
        let scriptConsistency = scriptConsistency(candidate.text)
        let duplication = duplicationRatio(candidate.text)
        let lowConfidenceBoxes = lowConfidenceBoxFraction(
            candidate.boundingBoxesJSON,
            fallbackConfidence: confidence,
            threshold: thresholds.lowConfidenceThreshold
        )
        let composite = clamp(
            coverage * 0.10
                + usableText * 0.20
                + confidence * 0.25
                + scriptConsistency * 0.20
                + (1 - duplication) * 0.15
                + (1 - lowConfidenceBoxes) * 0.10
        )
        return CandidateScores(
            coverage: coverage,
            usableText: usableText,
            confidence: confidence,
            scriptConsistency: scriptConsistency,
            duplication: duplication,
            lowConfidenceBoxFraction: lowConfidenceBoxes,
            composite: composite
        )
    }

    private static func isPoor(
        _ candidate: RevisionCandidate,
        scores: CandidateScores,
        thresholds: Thresholds
    ) -> Bool {
        if usableCharacterCount(candidate.text) < thresholds.minimumUsableTextLength { return true }
        if scores.scriptConsistency < thresholds.minimumScriptConsistency { return true }
        if scores.duplication > thresholds.maximumDuplicationRatio { return true }
        if candidate.origin == .ocr, scores.confidence < thresholds.lowConfidenceThreshold { return true }
        if candidate.origin == .ocr,
           scores.lowConfidenceBoxFraction > thresholds.maximumLowConfidenceBoxFraction { return true }
        return false
    }

    private static func usableCharacterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    private static func scriptConsistency(_ text: String) -> Double {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return 0 }
        let acceptedPunctuation = CharacterSet(charactersIn: ".,;:!?\"'()-/\\[]{}\u{00A7}$")
        let accepted = scalars.filter {
            CharacterSet.alphanumerics.contains($0) || acceptedPunctuation.contains($0)
        }.count
        return Double(accepted) / Double(scalars.count)
    }

    private static func duplicationRatio(_ text: String) -> Double {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return 1 }
        return Double(tokens.count - Set(tokens).count) / Double(tokens.count)
    }

    private static func lowConfidenceBoxFraction(
        _ json: String?,
        fallbackConfidence: Double,
        threshold: Double
    ) -> Double {
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let boxes = object as? [[String: Any]],
              !boxes.isEmpty else {
            return fallbackConfidence < threshold ? 1 : 0
        }
        let confidences = boxes.compactMap { box -> Double? in
            if let value = box["confidence"] as? Double { return value }
            if let number = box["confidence"] as? NSNumber { return number.doubleValue }
            return nil
        }
        guard !confidences.isEmpty else { return fallbackConfidence < threshold ? 1 : 0 }
        return Double(confidences.filter { $0 < threshold }.count) / Double(confidences.count)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
