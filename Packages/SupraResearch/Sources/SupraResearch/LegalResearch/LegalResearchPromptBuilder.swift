import Foundation

public enum LegalResearchPromptBuilder {
    /// Most authorities (highest-ranked first) to put in a source packet. Bounds the
    /// prompt so a large CourtListener result set can't overflow the context window
    /// and silently evict the binding authorities — or the "answer only from the
    /// packet" instructions — while the model still emits a confident answer.
    public static let maxPacketAuthorities = 12
    /// Per-authority text budget (characters). Caps any single long opinion so it
    /// can't crowd the other authorities out of the window.
    public static let maxAuthorityTextChars = 3000

    public static func buildAnswerPrompt(
        question: String,
        classification: LegalQueryClassification,
        rankedAuthorities: [RankedLegalAuthority]
    ) -> String {
        let packetCount = min(rankedAuthorities.count, maxPacketAuthorities)
        let labelRange = packetCount <= 1 ? "[A1]" : "[A1]–[A\(packetCount)]"
        return """
        USER QUESTION:
        \(question)

        QUERY CLASSIFICATION:
        - Jurisdiction: \(classification.jurisdiction ?? "Unspecified")
        - Court level: \(classification.courtLevel ?? "Unspecified")
        - Legal issue: \(classification.legalIssue)
        - Procedural posture: \(classification.proceduralPosture ?? "Unspecified")
        - Desired authority type: \(classification.desiredAuthorityType.rawValue)
        - Date sensitivity: \(classification.dateSensitivity ?? "Unspecified")
        - Court filters: \(classification.courtIDs.isEmpty ? "Unspecified" : classification.courtIDs.joined(separator: ", "))
        - Filed after: \(classification.dateFiledAfter ?? "Unspecified")
        - Filed before: \(classification.dateFiledBefore ?? "Unspecified")
        - Binding authority required: \(classification.bindingAuthorityRequired ? "yes" : "no")
        - Adverse authority requested: \(classification.adverseAuthorityRequested ? "yes" : "no")
        - Structured jurisdiction context:
        \(classification.jurisdictionContext ?? "No structured jurisdiction context supplied.")

        SOURCE PACKET:
        \(sourcePacket(rankedAuthorities.map(\.authority)))

        INSTRUCTIONS:
        Answer only from the SOURCE PACKET above.
        - End every sentence that states a legal proposition with the bracketed label of its supporting source, e.g. [A1]. Use only labels that appear in the packet (\(labelRange)); never invent a label.
        - If the packet does not support a proposition, write [NEEDS AUTHORITY] instead of citing it, and say what is missing.
        - Do not invent citations, quotes, dates, holdings, docket numbers, procedural posture, or subsequent history. Quote source text only when it appears verbatim in the packet.

        \(answerExemplar)
        """
    }

    /// A short worked example of the expected citation + hedging form. Quantized
    /// local models follow [A#] placement and uncertainty handling far more reliably
    /// from an example than from instructions alone.
    static let answerExemplar = """
    EXAMPLE OF THE EXPECTED FORM (illustrative only — do not reuse its facts or labels):
    The claim is governed by a two-year statute of limitations [A1]. That period runs from the date of injury rather than discovery, absent tolling [A2]. Because suit was filed more than two years after the injury and no tolling applies on these facts, the claim is time-barred [A1][A2]. Whether the continuing-violation doctrine could revive it is [NEEDS AUTHORITY] on this packet.
    """

    public static func buildCritiquePrompt(draft: String, authorities: [LegalAuthority]) -> String {
        """
        DRAFT TO CRITIQUE:
        \(draft)

        SOURCE PACKET:
        \(sourcePacket(authorities))

        Identify unsupported legal propositions, missing elements, adverse-authority risk, jurisdictional issues, citation defects, and overbroad conclusions. Do not rewrite the whole draft unless the user asks.
        """
    }

    public static func buildVerificationPrompt(draft: String, authorities: [LegalAuthority]) -> String {
        """
        DRAFT TO VERIFY:
        \(draft)

        SOURCE PACKET:
        \(sourcePacket(authorities))

        Return a structured report. Confirm that every citation appears in the source packet, every quote appears verbatim in the source text, and every conclusion stays within the authority cited.
        """
    }

    public static func sourcePacket(_ authorities: [LegalAuthority]) -> String {
        guard !authorities.isEmpty else {
            return "No CourtListener authorities were retrieved."
        }

        // Authorities arrive highest-ranked first; keep the top N so the binding
        // authorities stay in-window, and note any that were dropped.
        let included = Array(authorities.prefix(maxPacketAuthorities))
        var blocks = included.enumerated().map { index, authority in
            let label = "A\(index + 1)"
            let body = authority.text ?? authority.snippet ?? "No text returned."
            let trimmedBody = body.count > maxAuthorityTextChars
                ? String(body.prefix(maxAuthorityTextChars)) + "\n…[text truncated to fit the context window]"
                : body
            return """
            [\(label)] \(authority.caseName ?? "Untitled authority")
            - Authority ID: \(authority.id)
            - Citation: \(authority.citation ?? "No reporter citation supplied")
            - All citations: \(authority.citations.isEmpty ? "None supplied" : authority.citations.joined(separator: "; "))
            - Court: \(authority.court ?? "Unknown")
            - Jurisdiction: \(authority.jurisdiction ?? "Unknown")
            - Date filed: \(authority.dateFiled ?? "Unknown")
            - Precedential status: \(authority.precedentialStatus ?? "Unknown")
            - Docket number: \(authority.docketNumber ?? "Unknown")
            - CourtListener URL: \(authority.url ?? "Unavailable")
            - Snippet/Text:
            \(trimmedBody)
            """
        }

        let omitted = authorities.count - included.count
        if omitted > 0 {
            blocks.append("[Note] \(omitted) lower-ranked authorit\(omitted == 1 ? "y was" : "ies were") omitted to keep the highest-ranked sources within the context window.")
        }
        return blocks.joined(separator: "\n\n")
    }
}
