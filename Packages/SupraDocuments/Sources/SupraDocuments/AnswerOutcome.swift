import Foundation

/// The typed, internally consistent outcome of a grounded generation: either the model
/// answered, or it refused. Nothing else is representable — a draft that is BOTH
/// (a refusal carrying answer segments) or NEITHER (no refusal, no non-blank segment)
/// fails validation and the caller must route it to review.
///
/// This is the Phase 3C replacement for boolean refusal signals on the typed path:
/// consumers that need the refusal fast path must obtain it by validating the draft
/// here (or via `AttributionValidator`, which enforces the same invariant), so an
/// answered result can never enter the refusal fast path and a refusal can never carry
/// material answer text or citations.
public enum AnswerOutcome: Sendable, Equatable {
    case answered(AnswerDraft)
    case refused(Refusal)

    /// Fail-closed validation of a tolerantly decoded draft.
    ///
    /// - A draft with a refusal and NO non-blank segment is `.refused` (blank segments
    ///   carry no answer content).
    /// - A draft with non-blank segments and no refusal is `.answered`.
    /// - A draft with both — the model refused AND asserted — is malformed: `nil`.
    /// - A draft with neither is malformed: `nil`.
    public init?(validating draft: AnswerDraft) {
        let hasAnswerContent = draft.segments.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch (draft.refusal, hasAnswerContent) {
        case (let refusal?, false):
            self = .refused(refusal)
        case (nil, true):
            self = .answered(draft)
        case (_?, true), (nil, false):
            return nil
        }
    }
}
