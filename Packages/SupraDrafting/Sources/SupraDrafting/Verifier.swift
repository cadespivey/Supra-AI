import Foundation
import SupraCore
import SupraDraftingCore

// Deterministic verification gates (NoticeAppearance §6 / MotionToDismiss §1.3).
// Pure, synchronous-where-possible checks; authority validation is async (CitatorClient).

public struct DraftVerifier: Verifier, Sendable {
    public let citator: CitatorClient?

    public init(citator: CitatorClient? = nil) {
        self.citator = citator
    }

    public func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        switch unit {
        case let .wholeDocument(model):
            return verifyWholeDocument(model, kind: kind)
        case let .section(section, requirement, facts, authorities):
            return await verifySection(section, requirement: requirement, facts: facts, authorities: authorities)
        case let .letter(letter, _, facts):
            return verifyLetter(letter, facts: facts)
        }
    }

    // MARK: - Whole-document (slot-fill kinds, e.g. noticeAppearance)

    private func verifyWholeDocument(_ model: DocumentModel, kind: DraftKindID) -> VerificationResult {
        var failures: [GateFailure] = []
        var followUps: [FollowUp] = []

        if model.caption.parties.isEmpty || model.caption.caseNumber.isEmpty {
            failures.append(GateFailure(gate: .contract, detail: "Caption is incomplete (parties / case number).", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Caption must include parties and a case number."))
        }
        if model.signature == nil {
            failures.append(GateFailure(gate: .contract, detail: "Signature block missing.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "A signature block is required."))
        }
        // Court filings asserting service require a certificate.
        if model.certificate == nil {
            failures.append(GateFailure(gate: .contract, detail: "Certificate of service missing.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "A certificate of service is required for a filed document."))
        }
        return VerificationResult(failures: failures, followUps: followUps)
    }

    // MARK: - Per-Auth-section (motion)

    private func verifySection(_ section: GeneratedSection, requirement: SectionRequirement,
                               facts: [GroundedFact], authorities: [VerifiedAuthority]) async -> VerificationResult {
        var failures: [GateFailure] = []
        var followUps: [FollowUp] = []

        // factProvenance — every asserted fact traces to a [S#] in `facts`.
        let factLabels = Set(facts.map(\.label))
        for ref in section.assertedFacts where !factLabels.contains(ref.label) {
            failures.append(GateFailure(gate: .factProvenance, detail: "Untraced fact \(ref.label).", repair: .stripToPlaceholderAndFlag))
            followUps.append(FollowUp(severity: .advisory, kind: .verify, message: "Fact \(ref.label) has no matter provenance; replaced with \(factPlaceholder)."))
        }

        // authority — every cite is a VerifiedAuthority or the [cite] placeholder; never model-originated.
        let verifiedRaws = Set(authorities.map(\.cite.raw))
        for cite in section.citesUsed where !cite.isPlaceholder {
            if !verifiedRaws.contains(cite.raw) {
                failures.append(GateFailure(gate: .authorityValidity, detail: "Unverified cite \(cite.raw).", repair: .stripToPlaceholderAndFlag))
                followUps.append(FollowUp(severity: .advisory, kind: .verify, message: "Cite \(cite.raw) was not retrieved from an authority source; replaced with [cite]."))
            } else if let citator {
                let validity = await citator.validate(cite)
                if validity != .confirmed {
                    followUps.append(FollowUp(severity: .advisory, kind: .verify, message: "Cite \(cite.raw) could not be confirmed as good law; attorney review required."))
                }
            }
        }

        // contract — required content present.
        for needle in requirement.mustContain {
            let present = section.blocks.contains { block in
                if case let .paragraph(text) = block { return text.contains(needle) }
                if case let .pointHeading(_, _, text) = block { return text.contains(needle) }
                return false
            }
            if !present {
                failures.append(GateFailure(gate: .contract, detail: "Section missing required content: \(needle).", repair: .regenerate(maxPasses: 2)))
            }
        }

        return VerificationResult(failures: failures, followUps: followUps)
    }

    // MARK: - Letter (whole-letter provenance surface)

    private func verifyLetter(_ letter: GeneratedLetter, facts: [GroundedFact]) -> VerificationResult {
        var failures: [GateFailure] = []
        var followUps: [FollowUp] = []
        var supportResults: [PropositionSupportResult] = []
        let factsByLabel = Dictionary(grouping: facts, by: \.label)
        var outputOffset = 0

        if letter.paragraphProvenance.isEmpty {
            let proposition = CitedProposition(
                id: "letter-paragraph-1",
                text: "",
                citationLabels: [],
                outputRange: 0..<0
            )
            appendBlocked(
                proposition: proposition,
                status: .unverifiable,
                reason: "letter contains no generated paragraphs",
                gate: .elementCompleteness,
                evidence: [],
                failures: &failures,
                followUps: &followUps,
                supportResults: &supportResults
            )
        }

        for (index, paragraph) in letter.paragraphProvenance.enumerated() {
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let proposition = CitedProposition(
                id: "letter-paragraph-\(index + 1)",
                text: text,
                citationLabels: paragraph.factLabels + paragraph.citationLabels,
                outputRange: outputOffset..<(outputOffset + text.utf16.count)
            )
            outputOffset += text.utf16.count + 2

            if text.isEmpty {
                appendBlocked(
                    proposition: proposition,
                    status: .unverifiable,
                    reason: "empty generated paragraph",
                    gate: .elementCompleteness,
                    evidence: [],
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            let citationShaped = Self.containsCitationShape(text)
            let placeholder = text.localizedCaseInsensitiveContains("[cite]")
                || text.localizedCaseInsensitiveContains("[fact?]")
            if citationShaped || placeholder || !paragraph.citationLabels.isEmpty {
                appendBlocked(
                    proposition: proposition,
                    status: .unsupported,
                    reason: "unverified citation or placeholder",
                    gate: citationShaped || !paragraph.citationLabels.isEmpty ? .authorityValidity : .factProvenance,
                    evidence: [],
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            // A small, exact set of non-factual sign-off prose is permitted without a source.
            if paragraph.factLabels.isEmpty, Self.isNonMaterialBoilerplate(text) {
                continue
            }

            let uniqueLabels = Array(Set(paragraph.factLabels)).sorted()
            let unknownLabels = uniqueLabels.filter { factsByLabel[$0]?.count != 1 }
            if uniqueLabels.isEmpty || !unknownLabels.isEmpty {
                appendBlocked(
                    proposition: proposition,
                    status: .unsupported,
                    reason: uniqueLabels.isEmpty ? "material proposition has no fact labels" : "unknown or ambiguous fact label",
                    gate: .factProvenance,
                    evidence: [],
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            let referencedFacts = uniqueLabels.compactMap { factsByLabel[$0]?.first }
            let evidence = referencedFacts.map {
                SupportEvidence(
                    sourceID: $0.docId,
                    sourceLabel: $0.label,
                    locator: $0.locator,
                    retainedExcerpt: $0.text,
                    verifierName: "SupraDrafting.DraftVerifier",
                    verifierVersion: "acr-draft-v1"
                )
            }
            let combinedSource = referencedFacts.map(\.text).joined(separator: "\n")
            if !Self.sourceIsUsable(combinedSource) || referencedFacts.contains(where: { Self.containsPromptInjection($0.text) }) {
                appendBlocked(
                    proposition: proposition,
                    status: .unverifiable,
                    reason: "referenced source is missing, too short, or instruction-shaped",
                    gate: .factProvenance,
                    evidence: evidence,
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            if Self.containsNegation(text) != Self.containsNegation(combinedSource) {
                appendBlocked(
                    proposition: proposition,
                    status: .unsupported,
                    reason: "generated proposition conflicts with negative or contradictory source text",
                    gate: .factProvenance,
                    evidence: evidence,
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            if !Self.isOrderedSubsequence(
                Self.orderedCriticalValues(in: text),
                of: Self.orderedCriticalValues(in: combinedSource)
            ) {
                appendBlocked(
                    proposition: proposition,
                    status: .unsupported,
                    reason: "generated proposition reassigns or omits a source-critical value",
                    gate: .factProvenance,
                    evidence: evidence,
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            let unsupportedTokens = Self.materialTokens(in: text)
                .subtracting(Self.tokens(in: combinedSource))
            if !unsupportedTokens.isEmpty {
                appendBlocked(
                    proposition: proposition,
                    status: .unsupported,
                    reason: "generated proposition exceeds referenced source text",
                    gate: .factProvenance,
                    evidence: evidence,
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
                continue
            }

            if let result = try? PropositionSupportResult(
                propositionID: proposition.id,
                status: .supported,
                reasons: ["all material tokens appear in the referenced source text"],
                evidence: evidence,
                timestamp: Date()
            ) {
                supportResults.append(result)
            } else {
                appendBlocked(
                    proposition: proposition,
                    status: .unverifiable,
                    reason: "support evidence was incomplete",
                    gate: .factProvenance,
                    evidence: evidence,
                    failures: &failures,
                    followUps: &followUps,
                    supportResults: &supportResults
                )
            }
        }

        return VerificationResult(
            failures: failures,
            followUps: followUps,
            propositionSupport: supportResults
        )
    }

    private func appendBlocked(
        proposition: CitedProposition,
        status: PropositionSupportStatus,
        reason: String,
        gate: Gate,
        evidence: [SupportEvidence],
        failures: inout [GateFailure],
        followUps: inout [FollowUp],
        supportResults: inout [PropositionSupportResult]
    ) {
        failures.append(GateFailure(
            gate: gate,
            detail: "Paragraph \(proposition.id.replacingOccurrences(of: "letter-paragraph-", with: "")) failed deterministic support verification: \(reason).",
            repair: .stripToPlaceholderAndFlag
        ))
        followUps.append(FollowUp(
            severity: .blocking,
            kind: .verify,
            message: "Generation blocked because a paragraph was not fully supported by the supplied facts."
        ))
        if let result = try? PropositionSupportResult(
            propositionID: proposition.id,
            status: status,
            reasons: [reason],
            evidence: evidence,
            timestamp: Date()
        ) {
            supportResults.append(result)
        }
    }

    private static func tokens(in text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Words that add demand-letter grammar/voice but do not strengthen the factual content.
    private static let draftingVocabulary: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "before", "by", "for", "from",
        "has", "have", "in", "is", "it", "of", "on", "or", "our", "that", "the", "their",
        "this", "to", "was", "we", "will", "with", "you", "your",
        "accordingly", "balance", "claim", "client", "demand", "demanded", "firm", "letter", "made",
        "matter", "outstanding", "payment", "please", "regarding", "remains", "respond", "response"
    ]

    private static func materialTokens(in text: String) -> Set<String> {
        tokens(in: text).subtracting(draftingVocabulary)
    }

    private static func sourceIsUsable(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 12 && tokens(in: trimmed).count >= 3
    }

    private static func containsPromptInjection(_ source: String) -> Bool {
        let lower = source.lowercased()
        return [
            "ignore previous", "ignore all previous", "system prompt", "assistant:",
            "developer message", "tool call", "change your role", "output format"
        ].contains { lower.contains($0) }
    }

    private static func containsNegation(_ text: String) -> Bool {
        text.range(
            of: #"(?i)\bnot\b|\bnever\b|\bwithout\b|\bnone\b|\bno\s+(?!later\b)"#,
            options: .regularExpression
        ) != nil
    }

    private static func orderedCriticalValues(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(?:[$€£]\s*\d[\d,.]*|\b\d[\d,.]*(?:%|percent)?\b|\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b)"#
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map {
                text[$0].lowercased().replacingOccurrences(of: " ", with: "")
            }
        }
    }

    private static func isOrderedSubsequence(_ required: [String], of available: [String]) -> Bool {
        guard !required.isEmpty else { return true }
        var nextIndex = 0
        for value in required {
            guard nextIndex < available.count,
                  let match = available[nextIndex...].firstIndex(of: value)
            else { return false }
            nextIndex = match + 1
        }
        return true
    }

    private static func containsCitationShape(_ text: String) -> Bool {
        let patterns = [
            #"\b[A-Z][\w.'&-]+ v\.? [A-Z][\w.'&-]+"#,
            #"\b\d{1,4} [A-Z][\w.]*\.?( \d[a-z]{0,2})? \d{1,4}\b"#,
            #"§\s?\d"#,
            #"\bU\.?S\.?C\.?\b"#,
            #"\bC\.?F\.?R\.?\b"#,
            #"\bFla\.? Stat\.?\b"#,
            #"\b(statute|statutes|code|rule)\s*(section\s*)?\d"#
        ]
        return patterns.contains {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func isNonMaterialBoilerplate(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [
            "govern yourself accordingly",
            "we look forward to your prompt response",
            "please respond promptly"
        ].contains(normalized)
    }
}

// MARK: - Firewall repair (applied deterministically to a generated section before render)

public enum Firewall {
    /// Strips untraced facts → `[fact?]` and model-originated cites → `[cite]`. Never re-rolls.
    /// Returns the repaired section and the follow-ups raised (LetterDemand §1.3 / Motion §1.3).
    public static func sanitize(_ section: GeneratedSection,
                                facts: [GroundedFact],
                                authorities: [VerifiedAuthority]) -> (GeneratedSection, [FollowUp]) {
        var followUps: [FollowUp] = []
        let factLabels = Set(facts.map(\.label))
        let verifiedRaws = Set(authorities.map(\.cite.raw))

        var sanitizedCites: [CitationRef] = []
        for cite in section.citesUsed {
            if cite.isPlaceholder || verifiedRaws.contains(cite.raw) {
                sanitizedCites.append(cite)
            } else {
                sanitizedCites.append(citePlaceholder)
                followUps.append(FollowUp(severity: .advisory, kind: .verify, message: "Replaced unverified cite \(cite.raw) with [cite]."))
            }
        }

        var sanitizedFacts: [FactRef] = []
        for ref in section.assertedFacts {
            if factLabels.contains(ref.label) {
                sanitizedFacts.append(ref)
            } else {
                followUps.append(FollowUp(severity: .advisory, kind: .verify, message: "Stripped untraced fact \(ref.label) → \(factPlaceholder)."))
            }
        }

        let repaired = GeneratedSection(blocks: section.blocks, citesUsed: sanitizedCites, assertedFacts: sanitizedFacts)
        return (repaired, followUps)
    }
}
