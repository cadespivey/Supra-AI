import Foundation

/// A structural attribution violation in a grounded `AnswerDraft`. Every kind is decided by
/// EXACT rules (set membership, verbatim substring, a boolean flag) — no lexical
/// approximation, no token-overlap thresholds, no model judging a model.
public struct AttributionViolation: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A segment cites a SpanID that is not in the provided EvidenceSet.
        case citationNotInEvidence
        /// A quote references a SpanID that is not in the provided EvidenceSet.
        case quoteSpanNotInEvidence
        /// A quote is not a verbatim substring of its cited span's text.
        case quoteNotVerbatim
        /// A citation resolves to a low-confidence (e.g. OCR) span; support is unverifiable.
        case citedLowConfidence
        /// A segment carries prose but no citation and no quote — an uncited claim.
        case substantiveSegmentUncited
        /// The draft claims a refusal while also carrying non-blank answer segments —
        /// an internally inconsistent (mixed) result that must be reviewed, never
        /// fast-pathed as a clean refusal.
        case refusalCarriesAnswerContent
        /// The draft is neither a substantive answer nor a pure refusal (for
        /// example, completely empty or attribution attached to blank prose).
        case malformedOutcome
    }

    public let kind: Kind
    public let spanID: SpanID?
    public let detail: String

    public init(kind: Kind, spanID: SpanID?, detail: String) {
        self.kind = kind
        self.spanID = spanID
        self.detail = detail
    }
}

/// The outcome of validating a grounded answer's attributions.
public enum AttributionStatus: String, Sendable, Codable {
    /// A substantive answer whose every attribution is exactly valid.
    case validated
    /// A typed refusal — a clean, valid outcome that asserts nothing.
    case refused
    /// One or more attribution violations were found.
    case violations
}

/// The result of exact attribution validation.
public struct ValidationResult: Sendable, Codable, Equatable {
    public let status: AttributionStatus
    public let violations: [AttributionViolation]

    public init(status: AttributionStatus, violations: [AttributionViolation]) {
        self.status = status
        self.violations = violations
    }

    /// True for a validated answer or a clean refusal — nothing to review.
    public var isClean: Bool { violations.isEmpty }
}

/// Validates that a grounded `AnswerDraft`'s attributions hold **exactly** against the
/// EvidenceSet the model was given. This is the structural replacement for the lexical
/// `DocumentSupportVerifier` gate: fabrication of a citation is caught by set membership,
/// an altered quote by verbatim substring, and a refusal is a first-class clean outcome
/// rather than a sentence to be extracted as an (uncited) proposition.
///
/// It is deliberately pure and deterministic — identical inputs yield an identical result —
/// and it does not ask a model to judge another model's answer.
public enum AttributionValidator {
    public static func validate(draft: AnswerDraft, evidence: EvidenceSet) -> ValidationResult {
        // The refusal fast path exists ONLY for a validated pure refusal: a typed
        // refusal asserts nothing, so it can carry no attribution and is never a
        // proposition. A draft that claims a refusal while also carrying answer
        // content is mixed/malformed — it falls through to segment validation with an
        // explicit violation, so it always requires review (Phase 3C, finding #1).
        let outcome = AnswerOutcome(validating: draft)
        if case .refused = outcome {
            return ValidationResult(status: .refused, violations: [])
        }

        var violations: [AttributionViolation] = []

        if draft.refusal != nil {
            violations.append(AttributionViolation(
                kind: .refusalCarriesAnswerContent,
                spanID: nil,
                detail: "Draft claims a refusal but also carries answer segments; a refusal cannot contain material answer text or citations."
            ))
        } else if outcome == nil {
            violations.append(AttributionViolation(
                kind: .malformedOutcome,
                spanID: nil,
                detail: "Draft is neither a substantive answer nor a pure refusal."
            ))
        }

        for segment in draft.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Uncited claim: prose with no attribution at all. Structural — no lexical
            // "materiality" judgment; a grounded segment must carry a citation or a quote.
            if !text.isEmpty, segment.citations.isEmpty, segment.quotes.isEmpty {
                violations.append(AttributionViolation(
                    kind: .substantiveSegmentUncited,
                    spanID: nil,
                    detail: "Segment asserts a claim with no citation or quote."
                ))
            }

            for citation in segment.citations {
                guard let span = evidence.span(citation) else {
                    // Source content is data, never authorization: a cited id must be a
                    // real provided SpanID, even if some span's text literally contains it.
                    violations.append(AttributionViolation(
                        kind: .citationNotInEvidence,
                        spanID: citation,
                        detail: "Citation \(citation) is not a span in the provided evidence set."
                    ))
                    continue
                }
                if span.lowConfidence {
                    violations.append(AttributionViolation(
                        kind: .citedLowConfidence,
                        spanID: citation,
                        detail: "Citation \(citation) resolves to a low-confidence source; support is unverifiable."
                    ))
                }
            }

            for quote in segment.quotes {
                guard let span = evidence.span(quote.spanID) else {
                    violations.append(AttributionViolation(
                        kind: .quoteSpanNotInEvidence,
                        spanID: quote.spanID,
                        detail: "Quote references span \(quote.spanID), which is not in the provided evidence set."
                    ))
                    continue
                }
                // Exact, literal substring — the strongest guarantee. Whitespace-tolerant
                // matching, if ever needed for extraction quirks, is a documented later
                // relaxation, not a default that would let a paraphrase pass as a quote.
                let verbatim = quote.verbatim
                if verbatim.isEmpty || span.exactText.range(of: verbatim) == nil {
                    violations.append(AttributionViolation(
                        kind: .quoteNotVerbatim,
                        spanID: quote.spanID,
                        detail: "Quote is not a verbatim substring of span \(quote.spanID)."
                    ))
                }
            }
        }

        return ValidationResult(
            status: violations.isEmpty ? .validated : .violations,
            violations: violations
        )
    }
}
