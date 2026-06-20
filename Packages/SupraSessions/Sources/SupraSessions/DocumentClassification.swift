import Foundation

/// The approved document-classification taxonomy (1.3.2). Each case's raw value is
/// the exact tag string the model must emit; the assistant assigns one primary tag
/// (dominant function) plus zero or more secondary tags. Tags describe a document's
/// actual legal/business function — not its file format, name, or stray keywords.
public enum DocumentCategory: String, CaseIterable, Codable, Sendable {
    case pleadings
    case motionsAndBriefs = "motions_and_briefs"
    case courtOrdersAndOpinions = "court_orders_and_opinions"
    case courtFilingsProcedural = "court_filings_procedural"
    case docketAndCaseManagement = "docket_and_case_management"
    case discoveryRequests = "discovery_requests"
    case discoveryResponses = "discovery_responses"
    case documentProductionMaterials = "document_production_materials"
    case privilegeAndConfidentiality = "privilege_and_confidentiality"
    case depositionsAndTestimony = "depositions_and_testimony"
    case evidenceAndExhibits = "evidence_and_exhibits"
    case investigationAndFacts = "investigation_and_facts"
    case caseLaw = "case_law"
    case statutes
    case regulations
    case courtRules = "court_rules"
    case secondaryAuthority = "secondary_authority"
    case litigationStrategy = "litigation_strategy"
    case settlementAndResolution = "settlement_and_resolution"
    case contractsAndAgreements = "contracts_and_agreements"
    case corporateGovernance = "corporate_governance"
    case transactionsAndDeals = "transactions_and_deals"
    case financialRecords = "financial_records"
    case businessOperations = "business_operations"
    case employmentAndHR = "employment_and_hr"
    case regulatoryAndCompliance = "regulatory_and_compliance"
    case insuranceAndRisk = "insurance_and_risk"
    case realEstateAndProperty = "real_estate_and_property"
    case intellectualProperty = "intellectual_property"
    case correspondence
    case clientAndMatterAdmin = "client_and_matter_admin"
    case unknownOrMixed = "unknown_or_mixed"

    /// Human-readable label for the UI (the tag chips, filters).
    public var displayName: String {
        switch self {
        case .pleadings: "Pleadings"
        case .motionsAndBriefs: "Motions & Briefs"
        case .courtOrdersAndOpinions: "Court Orders & Opinions"
        case .courtFilingsProcedural: "Court Filings (Procedural)"
        case .docketAndCaseManagement: "Docket & Case Management"
        case .discoveryRequests: "Discovery Requests"
        case .discoveryResponses: "Discovery Responses"
        case .documentProductionMaterials: "Document Production Materials"
        case .privilegeAndConfidentiality: "Privilege & Confidentiality"
        case .depositionsAndTestimony: "Depositions & Testimony"
        case .evidenceAndExhibits: "Evidence & Exhibits"
        case .investigationAndFacts: "Investigation & Facts"
        case .caseLaw: "Case Law"
        case .statutes: "Statutes"
        case .regulations: "Regulations"
        case .courtRules: "Court Rules"
        case .secondaryAuthority: "Secondary Authority"
        case .litigationStrategy: "Litigation Strategy"
        case .settlementAndResolution: "Settlement & Resolution"
        case .contractsAndAgreements: "Contracts & Agreements"
        case .corporateGovernance: "Corporate Governance"
        case .transactionsAndDeals: "Transactions & Deals"
        case .financialRecords: "Financial Records"
        case .businessOperations: "Business Operations"
        case .employmentAndHR: "Employment & HR"
        case .regulatoryAndCompliance: "Regulatory & Compliance"
        case .insuranceAndRisk: "Insurance & Risk"
        case .realEstateAndProperty: "Real Estate & Property"
        case .intellectualProperty: "Intellectual Property"
        case .correspondence: "Correspondence"
        case .clientAndMatterAdmin: "Client & Matter Admin"
        case .unknownOrMixed: "Unknown / Mixed"
        }
    }

    /// One-line description used to build the taxonomy section of the prompt.
    public var summary: String {
        switch self {
        case .pleadings: "Court-filed documents that define claims, defenses, parties, or requested relief (complaints, answers, counterclaims, petitions, notices of removal, amended pleadings)."
        case .motionsAndBriefs: "Advocacy documents requesting court action or opposing relief (motions to dismiss, summary-judgment briefs, oppositions, replies, memoranda of law)."
        case .courtOrdersAndOpinions: "Judicial rulings, procedural orders, and written decisions (orders, opinions, minute orders, scheduling orders, judgments, decrees, appellate opinions)."
        case .courtFilingsProcedural: "Filed litigation documents that are not pleadings, motions, merits briefing, or decisions (notices, certificates of service, cover sheets, disclosures, appearances, stipulations, proposed orders)."
        case .docketAndCaseManagement: "Materials tracking procedural posture, deadlines, hearings, and status (docket sheets, calendars, case-management plans, deadline charts, PACER/ECF summaries)."
        case .discoveryRequests: "Formal written requests seeking information, admissions, testimony, inspection, or documents (interrogatories, RFPs, RFAs, subpoenas, deposition/30(b)(6) notices)."
        case .discoveryResponses: "Formal answers, objections, or productions responding to discovery (interrogatory/RFP/RFA responses, objections, supplemental responses, verifications)."
        case .documentProductionMaterials: "Materials about collected, reviewed, produced, or withheld documents (production cover letters, Bates logs, review protocols, indexes, clawback notices, ESI reports)."
        case .privilegeAndConfidentiality: "Documents addressing privileged, protected, confidential, sealed, or sensitive information (privilege logs, clawback letters, protective orders, NDAs, redaction/sealing materials)."
        case .depositionsAndTestimony: "Transcribed, summarized, noticed, or prepared witness testimony (deposition/hearing/trial transcripts, errata sheets, witness outlines, deposition summaries, prep notes)."
        case .evidenceAndExhibits: "Materials used or likely to be used as factual proof (trial/deposition exhibits, demonstratives, exhibit lists, key documents, photographs, selected business records)."
        case .investigationAndFacts: "Fact-development materials not necessarily filed or produced (chronologies, witness-interview notes, factual memoranda, internal investigation reports, incident reports)."
        case .caseLaw: "Judicial decisions and case-law research (opinions, slip/unpublished opinions, Westlaw/Lexis exports, citator/KeyCite/Shepard's results, case summaries). Use when the document's function is to present, summarize, or analyze judicial authority."
        case .statutes: "Enacted statutory law and statutory research (code sections, annotated provisions, statutory excerpts, statute comparison/interpretation notes). Use when the function is to present or analyze statutes."
        case .regulations: "Administrative rules, agency regulations, and regulatory research (CFR/state admin-code provisions, proposed/final rules, agency guidance). Legal authority about rules — not business compliance records."
        case .courtRules: "Procedural, evidentiary, appellate, bankruptcy, local, or judge-specific rules governing proceedings (FRCP/FRE/FRAP, state rules, local rules, standing orders, ECF filing rules)."
        case .secondaryAuthority: "Non-binding legal commentary and practice guidance (treatises, practice guides, law-review articles, Restatement sections, encyclopedias, CLE materials, practice notes)."
        case .litigationStrategy: "Attorney work product on case theory, risk, tactics, valuation, or settlement posture (strategy memos, strengths/weaknesses, damages theories, trial themes)."
        case .settlementAndResolution: "Materials concerning settlement, mediation/arbitration resolution, or dispute closure (settlement agreements, term sheets, demand letters, offers of judgment, releases)."
        case .contractsAndAgreements: "Binding or proposed agreements governing relationships (commercial contracts, MSAs, SOWs, purchase/vendor/licensing agreements, leases, employment agreements, amendments)."
        case .corporateGovernance: "Entity governance, ownership, authority, and formal corporate records (bylaws, operating/shareholder agreements, board minutes, consents, resolutions, cap tables, formation docs)."
        case .transactionsAndDeals: "Business-transaction, financing, acquisition, or closing materials (LOIs, term sheets, diligence, merger/asset-purchase/financing agreements, closing checklists, disclosure schedules)."
        case .financialRecords: "Quantitative accounting, tax, payment, or financial-performance records (financial statements, ledgers, invoices, bank statements, tax returns, budgets, forecasts)."
        case .businessOperations: "Non-legal operational documents explaining how a business functions (policies, procedures, org charts, business plans, product/customer/vendor records, manuals, reports)."
        case .employmentAndHR: "Employment, personnel, compensation, and HR materials (offer letters, handbooks, disciplinary/termination records, comp plans, restrictive covenants, HR complaints, personnel files)."
        case .regulatoryAndCompliance: "Government/industry/licensing/audit/enforcement or internal-compliance obligations and records (regulatory filings, compliance policies, audit/inspection reports, consent orders, training records). Business compliance — not legal authority about rules."
        case .insuranceAndRisk: "Insurance coverage, claims, indemnity, and loss materials (policies, reservation-of-rights letters, claim notices, coverage opinions, indemnity demands, loss runs, claims files)."
        case .realEstateAndProperty: "Real property, leases, title, construction, land use, or zoning records (leases, deeds, title reports, easements, purchase-and-sale/construction agreements, surveys, zoning materials)."
        case .intellectualProperty: "IP ownership, protection, licensing, infringement, or registration (trademark/patent/copyright filings, license agreements, invention assignments, takedown/IP demand letters, clearance searches)."
        case .correspondence: "Communications between parties, counsel, clients, third parties, or internal personnel (emails, letters, texts, Slack/Teams exports, transmittals, meet-and-confer correspondence). If the message substantively serves another function, tag that function too."
        case .clientAndMatterAdmin: "Administrative materials about the representation itself (engagement letters, conflict checks, billing, budgets, staffing plans, matter-opening/intake forms, status reports)."
        case .unknownOrMixed: "Last resort: too little usable text, corrupted/blank scans, unlabeled attachments, or a miscellaneous compilation without a dominant purpose."
        }
    }

    /// Lookup by the exact tag string the model emits (tolerant of whitespace/case).
    public static func from(rawTag: String) -> DocumentCategory? {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue == trimmed }
    }
}

/// The structured classification a document receives — the model's JSON output,
/// validated against the taxonomy. Suitable as RAG/filtering metadata; it only
/// *suggests* and flags likelihoods, never making legal conclusions.
public struct DocumentClassification: Codable, Sendable, Equatable {
    public var primaryTag: String
    public var secondaryTags: [String]
    public var confidence: Double
    public var reasoningSummary: String
    public var documentFunction: String
    public var isPrivilegedLikely: Bool
    public var isConfidentialLikely: Bool
    public var isCourtFiledLikely: Bool
    public var isDiscoveryMaterialLikely: Bool
    public var detectedDocumentDate: String?
    public var detectedPartiesOrEntities: [String]
    public var detectedJurisdiction: String?
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case primaryTag = "primary_tag"
        case secondaryTags = "secondary_tags"
        case confidence
        case reasoningSummary = "reasoning_summary"
        case documentFunction = "document_function"
        case isPrivilegedLikely = "is_privileged_likely"
        case isConfidentialLikely = "is_confidential_likely"
        case isCourtFiledLikely = "is_court_filed_likely"
        case isDiscoveryMaterialLikely = "is_discovery_material_likely"
        case detectedDocumentDate = "detected_document_date"
        case detectedPartiesOrEntities = "detected_parties_or_entities"
        case detectedJurisdiction = "detected_jurisdiction"
        case warnings
    }

    public init(
        primaryTag: String,
        secondaryTags: [String] = [],
        confidence: Double = 0,
        reasoningSummary: String = "",
        documentFunction: String = "",
        isPrivilegedLikely: Bool = false,
        isConfidentialLikely: Bool = false,
        isCourtFiledLikely: Bool = false,
        isDiscoveryMaterialLikely: Bool = false,
        detectedDocumentDate: String? = nil,
        detectedPartiesOrEntities: [String] = [],
        detectedJurisdiction: String? = nil,
        warnings: [String] = []
    ) {
        self.primaryTag = primaryTag
        self.secondaryTags = secondaryTags
        self.confidence = confidence
        self.reasoningSummary = reasoningSummary
        self.documentFunction = documentFunction
        self.isPrivilegedLikely = isPrivilegedLikely
        self.isConfidentialLikely = isConfidentialLikely
        self.isCourtFiledLikely = isCourtFiledLikely
        self.isDiscoveryMaterialLikely = isDiscoveryMaterialLikely
        self.detectedDocumentDate = detectedDocumentDate
        self.detectedPartiesOrEntities = detectedPartiesOrEntities
        self.detectedJurisdiction = detectedJurisdiction
        self.warnings = warnings
    }

    // Tolerant decoding — the model may omit fields; default them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryTag = (try? c.decode(String.self, forKey: .primaryTag)) ?? DocumentCategory.unknownOrMixed.rawValue
        secondaryTags = (try? c.decode([String].self, forKey: .secondaryTags)) ?? []
        confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0
        reasoningSummary = (try? c.decode(String.self, forKey: .reasoningSummary)) ?? ""
        documentFunction = (try? c.decode(String.self, forKey: .documentFunction)) ?? ""
        isPrivilegedLikely = (try? c.decode(Bool.self, forKey: .isPrivilegedLikely)) ?? false
        isConfidentialLikely = (try? c.decode(Bool.self, forKey: .isConfidentialLikely)) ?? false
        isCourtFiledLikely = (try? c.decode(Bool.self, forKey: .isCourtFiledLikely)) ?? false
        isDiscoveryMaterialLikely = (try? c.decode(Bool.self, forKey: .isDiscoveryMaterialLikely)) ?? false
        detectedDocumentDate = try? c.decodeIfPresent(String.self, forKey: .detectedDocumentDate)
        detectedPartiesOrEntities = (try? c.decode([String].self, forKey: .detectedPartiesOrEntities)) ?? []
        detectedJurisdiction = try? c.decodeIfPresent(String.self, forKey: .detectedJurisdiction)
        warnings = (try? c.decode([String].self, forKey: .warnings)) ?? []
    }

    /// The validated primary category (falls back to unknown/mixed).
    public var primaryCategory: DocumentCategory {
        DocumentCategory.from(rawTag: primaryTag) ?? .unknownOrMixed
    }

    /// Valid secondary categories, de-duplicated and excluding the primary.
    public var secondaryCategories: [DocumentCategory] {
        var seen: Set<DocumentCategory> = [primaryCategory]
        var result: [DocumentCategory] = []
        for tag in secondaryTags {
            guard let category = DocumentCategory.from(rawTag: tag), !seen.contains(category) else { continue }
            seen.insert(category)
            result.append(category)
        }
        return result
    }

    /// Coerces a raw model result into a valid classification: a known primary
    /// tag, de-duplicated known secondary tags, clamped confidence, and a warning
    /// when confidence is low (per the spec's < 0.50 rule).
    public func normalized() -> DocumentClassification {
        var result = self
        result.primaryTag = primaryCategory.rawValue
        result.secondaryTags = secondaryCategories.map(\.rawValue)
        result.confidence = min(max(confidence, 0), 1)
        // The spec requires at least one warning whenever confidence < 0.50. Add
        // ours unless the model already flagged the uncertainty itself.
        if result.confidence < 0.5 && !result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("confidence") }) {
            result.warnings.insert("Low-confidence classification; review the suggested category.", at: 0)
        }
        return result
    }
}

/// Builds the deterministic system prompt for the classifier from the taxonomy +
/// the approved rules (1.3.2 spec). The user's practice is primarily commercial
/// litigation; all documents are legal or business related.
public enum DocumentClassificationPrompt {
    public static func system() -> String {
        let taxonomy = DocumentCategory.allCases
            .map { "- \($0.rawValue): \($0.summary)" }
            .joined(separator: "\n")

        return """
        You are a document classifier for a commercial-litigation practice. Every document is legal or business related and may include corporate-law materials, legal research, discovery materials, correspondence, business financial documents, contracts, transaction documents, employment records, compliance materials, and administrative matter records.

        Classify the document using one or more tags from the approved taxonomy. Assign exactly one primary_tag (the document's dominant function) and zero or more secondary_tags for other materially applicable categories. This is a cursory suggestion that places the document in a broad category. Support multi-label tagging — many legal/business documents serve more than one function.

        Classify by the document's actual function, legal/business purpose, and content — NOT by file format, filename, superficial keywords, or the mere presence of legal citations.

        Approved taxonomy (use these exact tag strings; do not invent tags):
        \(taxonomy)

        Key rules:
        - Always return exactly one primary_tag; return zero or more secondary_tags; use only approved tags; secondary_tags must not repeat primary_tag.
        - Prefer the most specific applicable tag; avoid broad defaults when a narrower tag fits. Use "unknown_or_mixed" only as a last resort.
        - A court-filed brief citing cases is "motions_and_briefs", not "case_law". A downloaded opinion, statute, regulation, rule, or treatise is the applicable research/authority tag. A Federal Rule of Civil Procedure excerpt is "court_rules", not "statutes". A scheduling order is "court_orders_and_opinions" or "docket_and_case_management", not "court_rules".
        - A final agreement governing an ongoing relationship is "contracts_and_agreements"; deal/diligence/closing/financing materials are "transactions_and_deals". "regulations" is legal authority about rules; "regulatory_and_compliance" is business compliance records. "financial_records" is quantitative accounting/tax/payment data; "business_operations" is general operating material.
        - Do not treat every email as merely "correspondence" — if the email substantively serves another function, tag that too. Distinguish discovery_requests from discovery_responses, and document_production_materials from the documents actually produced.
        - Do NOT infer privilege merely because lawyers are involved, confidentiality merely because a document is business-related, or litigation_strategy merely because a matter is in litigation. Flag is_privileged_likely / is_confidential_likely only from the document's own content and context — never decide whether privilege actually applies.

        Return ONLY valid JSON (no markdown, no text outside the JSON) in exactly this shape:
        {
          "primary_tag": "string (one approved tag)",
          "secondary_tags": ["string (approved tags, excluding primary)"],
          "confidence": 0.0,
          "reasoning_summary": "Brief explanation of why the tags fit.",
          "document_function": "Brief neutral description of what the document does.",
          "is_privileged_likely": false,
          "is_confidential_likely": false,
          "is_court_filed_likely": false,
          "is_discovery_material_likely": false,
          "detected_document_date": "YYYY-MM-DD or null",
          "detected_parties_or_entities": ["string"],
          "detected_jurisdiction": "string or null",
          "warnings": ["Any uncertainty, OCR problems, mixed-document issues, or caveats."]
        }

        Output requirements: confidence is a number from 0 to 1; use null for unknown scalars and [] for unknown lists. Confidence guidance — 0.90-1.00 clearly fits; 0.75-0.89 likely fits with some ambiguity/overlap; 0.50-0.74 may fit but ambiguous/limited text; below 0.50 use caution and prefer "unknown_or_mixed" if no reliable classification is possible. If confidence is below 0.50, include at least one warning explaining the uncertainty.
        """
    }

    /// Wraps the document's extracted text (with filename context) as the user turn.
    /// Long text is truncated to keep the prompt within the model's context window.
    public static func userContent(fileName: String, text: String, maxCharacters: Int = 12_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.count > maxCharacters
            ? String(trimmed.prefix(maxCharacters)) + "\n\n[Document truncated for classification.]"
            : trimmed
        return """
        Classify the following document. Filename: \(fileName)

        --- DOCUMENT TEXT ---
        \(body)
        --- END DOCUMENT TEXT ---

        Return only the JSON object.
        """
    }
}
