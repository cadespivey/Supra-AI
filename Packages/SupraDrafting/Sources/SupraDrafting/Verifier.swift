import Foundation
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
        case let .letter(letter, _):
            return await verifyLetter(letter)
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

    private func verifyLetter(_ letter: GeneratedLetter) async -> VerificationResult {
        var failures: [GateFailure] = []
        var followUps: [FollowUp] = []
        // Authority discipline only if the letter cited law.
        let verifiedRaws: Set<String> = []
        for cite in letter.citesUsed where !cite.isPlaceholder && !verifiedRaws.contains(cite.raw) {
            failures.append(GateFailure(gate: .authorityValidity, detail: "Unverified cite \(cite.raw) in letter.", repair: .stripToPlaceholderAndFlag))
            followUps.append(FollowUp(severity: .advisory, kind: .verify, message: "Cite \(cite.raw) replaced with [cite]."))
        }
        return VerificationResult(failures: failures, followUps: followUps)
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
