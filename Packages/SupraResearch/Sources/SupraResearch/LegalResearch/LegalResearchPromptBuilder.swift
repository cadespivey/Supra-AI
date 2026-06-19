import Foundation

public enum LegalResearchPromptBuilder {
    public static func buildAnswerPrompt(
        question: String,
        classification: LegalQueryClassification,
        rankedAuthorities: [RankedLegalAuthority]
    ) -> String {
        """
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
        Answer only from the source packet. Cite every legal proposition to a source-packet citation or CourtListener URL. If the packet does not answer the question, say what is missing. Do not invent citations, quotes, dates, holdings, docket numbers, procedural posture, or subsequent history.
        """
    }

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

        return authorities.enumerated().map { index, authority in
            let label = "A\(index + 1)"
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
            \(authority.text ?? authority.snippet ?? "No text returned.")
            """
        }
        .joined(separator: "\n\n")
    }
}
