import Foundation
import SupraCore
import SupraDocuments
import SupraDraftingCore
import SupraRuntimeClient
import SupraRuntimeInterface

/// Which structural element an uploaded exemplar demonstrates (SPEC §5).
public enum ExemplarKind: String, Sendable, Equatable {
    case letterhead
    case caption
    case signature
}

/// The result of parsing an exemplar: a sparse candidate profile for the review pane, plus an
/// optional advisory/failure message. The parser NEVER writes the profile (it has no store) —
/// the user's confirm step persists the reviewed candidate via `FirmStyleProfileController`.
public struct ExemplarParseOutcome: Sendable, Equatable {
    public var candidate: FirmStyleProfile
    public var message: String?

    public init(candidate: FirmStyleProfile, message: String? = nil) {
        self.candidate = candidate
        self.message = message
    }
}

/// LLM-assisted STRUCTURED extraction of style labels from an uploaded exemplar document
/// ("just my letterhead / caption / signature block") — SPEC §5.2/§5.4.
///
/// The exemplar is a PARSE SOURCE, not prompt context: its text is sent to the model once,
/// mapped field-by-field into a candidate `FirmStyleProfile`, and discarded. Nothing from the
/// exemplar is stored verbatim, and nothing enters any drafting prompt. Guardrails are
/// deterministic, not just prompt-side: every captured value passes `sanitizedLabel`, which
/// truncates at the first digit/@ so phone numbers, bar numbers, and e-mail addresses can never
/// reach the candidate even if the model leaks them (invariant 4: identity is slot-only).
public struct FirmStyleExemplarParser: Sendable {
    private let runtimeClient: any RuntimeClientProtocol
    private let modelID: ModelID
    private let extraction: ExtractionService

    public init(
        runtimeClient: any RuntimeClientProtocol,
        modelID: ModelID,
        extraction: ExtractionService = ExtractionService()
    ) {
        self.runtimeClient = runtimeClient
        self.modelID = modelID
        self.extraction = extraction
    }

    // MARK: - Per-kind extraction DTOs (M3-T1; all fields optional — the model omits unknowns)

    struct LetterheadExtraction: Codable {
        var tagline: String?
        var phoneLabel: String?
        var faxLabel: String?
        var reLabel: String?
        var enclosurePrefix: String?
        var ccPrefix: String?
    }

    struct CaptionExtraction: Codable {
        var partySeparator: String?
        var caseNumberLabel: String?
        var divisionLabel: String?
        var judgeLabel: String?
    }

    struct SignatureExtraction: Codable {
        var byPrefix: String?
        var eSignatureMark: String?
        var representationPrefix: String?
        var barNumberLabel: String?
        var phoneLabel: String?
        var faxLabel: String?
    }

    // MARK: - Entry points

    /// Upload path: extract text from the document (reusing the writing-sample extraction
    /// service), then parse. The extracted text is used for this one call and discarded.
    public func parse(kind: ExemplarKind, fileURL: URL) async -> ExemplarParseOutcome {
        let result: ExtractionResult
        do {
            result = try await extraction.extract(fileURL: fileURL)
        } catch {
            return ExemplarParseOutcome(
                candidate: FirmStyleProfile(),
                message: (error as? ExtractionError)?.errorDescription ?? error.localizedDescription
            )
        }
        return await parse(kind: kind, text: result.combinedText, needsOCR: result.needsOCR)
    }

    /// Core path (internal for tests): exemplar text → one structured-extraction call →
    /// (at most one repair) → sanitized candidate mapping.
    func parse(kind: ExemplarKind, text: String, needsOCR: Bool) async -> ExemplarParseOutcome {
        let exemplar = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exemplar.isEmpty else {
            return ExemplarParseOutcome(
                candidate: FirmStyleProfile(),
                message: "No text was found in the exemplar. Enter your style choices manually below."
            )
        }

        // First attempt, then exactly ONE repair restating the contract (SPEC §5.2).
        var reply = await generate(prompt: Self.userPrompt(kind: kind, exemplar: exemplar), kind: kind)
        var json = reply.flatMap { DocumentClassificationService.extractJSONObject(from: $0) }
        if json == nil {
            let repair = Self.repairPrompt(kind: kind, previousReply: reply ?? "")
            reply = await generate(prompt: repair, kind: kind)
            json = reply.flatMap { DocumentClassificationService.extractJSONObject(from: $0) }
        }
        guard let json, let candidate = Self.decodeCandidate(kind: kind, json: json) else {
            return ExemplarParseOutcome(
                candidate: FirmStyleProfile(),
                message: "The exemplar couldn't be read into style fields. Enter your style choices manually below."
            )
        }

        var message: String?
        if needsOCR, kind == .letterhead {
            message = "This looks like a scanned or image-based document — we can capture your letterhead text but not a logo image yet. Review the fields below."
        } else if needsOCR {
            message = "This looks like a scanned or image-based document; the fields below were read from its recognized text. Review them carefully."
        }
        return ExemplarParseOutcome(candidate: candidate, message: message)
    }

    // MARK: - Generation

    private func generate(prompt: String, kind: ExemplarKind) async -> String? {
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: prompt,
            systemPrompt: Self.systemContract(kind: kind),
            options: GenerationOptions(
                preset: .extractive,
                temperature: 0.0,
                topP: 1.0,
                maxOutputTokens: 400,
                thinkingBudget: .off
            )
        )
        guard let raw = try? await runtimeClient.collectGeneratedText(request) else { return nil }
        return ReasoningContent.answer(from: raw)
    }

    // MARK: - Prompts (STRICT JSON contract; labels only — never identity)

    private static func fieldList(kind: ExemplarKind) -> String {
        switch kind {
        case .letterhead:
            return #""tagline", "phoneLabel", "faxLabel", "reLabel", "enclosurePrefix", "ccPrefix""#
        case .caption:
            return #""partySeparator", "caseNumberLabel", "divisionLabel", "judgeLabel""#
        case .signature:
            return #""byPrefix", "eSignatureMark", "representationPrefix", "barNumberLabel", "phoneLabel", "faxLabel""#
        }
    }

    private static func systemContract(kind: ExemplarKind) -> String {
        """
        You extract STRUCTURAL STYLE LABELS from a law-firm document exemplar. Reply with STRICT \
        JSON only — one object, no prose, no markdown. Allowed keys: \(fieldList(kind: kind)). \
        Omit any key you cannot see in the exemplar. Values are the exact label/prefix text \
        INCLUDING trailing spaces or punctuation. NEVER include names, street addresses, phone \
        numbers, e-mail addresses, bar numbers, case numbers, or any other identity or matter \
        content — labels and separators only.
        """
    }

    private static func userPrompt(kind: ExemplarKind, exemplar: String) -> String {
        """
        Exemplar (\(kind.rawValue)):
        ---
        \(String(exemplar.prefix(4000)))
        ---
        Return the JSON object now.
        """
    }

    private static func repairPrompt(kind: ExemplarKind, previousReply: String) -> String {
        """
        Your previous reply was not valid JSON. Reply again with STRICT JSON only — a single \
        object with keys from: \(fieldList(kind: kind)). No prose, no markdown, no explanation.
        Previous reply:
        ---
        \(String(previousReply.prefix(1000)))
        ---
        """
    }

    // MARK: - Mapping + identity guardrail

    private static func decodeCandidate(kind: ExemplarKind, json: String) -> FirmStyleProfile? {
        let data = Data(json.utf8)
        var candidate = FirmStyleProfile()
        switch kind {
        case .letterhead:
            guard let d = try? JSONDecoder().decode(LetterheadExtraction.self, from: data) else { return nil }
            candidate.letterheadTagline = sanitizedLabel(d.tagline)
            candidate.letterheadPhoneLabel = sanitizedLabel(d.phoneLabel)
            candidate.letterheadFaxLabel = sanitizedLabel(d.faxLabel)
            candidate.letterheadRELabel = sanitizedLabel(d.reLabel)
            candidate.letterheadEnclosurePrefix = sanitizedLabel(d.enclosurePrefix)
            candidate.letterheadCCPrefix = sanitizedLabel(d.ccPrefix)
        case .caption:
            guard let d = try? JSONDecoder().decode(CaptionExtraction.self, from: data) else { return nil }
            candidate.captionPartySeparator = sanitizedLabel(d.partySeparator)
            candidate.captionCaseNumberLabel = sanitizedLabel(d.caseNumberLabel)
            candidate.captionDivisionLabel = sanitizedLabel(d.divisionLabel)
            candidate.captionJudgeLabel = sanitizedLabel(d.judgeLabel)
        case .signature:
            guard let d = try? JSONDecoder().decode(SignatureExtraction.self, from: data) else { return nil }
            candidate.signatureByPrefix = sanitizedLabel(d.byPrefix)
            candidate.signatureESignatureMark = sanitizedMark(d.eSignatureMark)
            candidate.signatureRepresentationPrefix = sanitizedLabel(d.representationPrefix)
            candidate.signatureBarNumberLabel = sanitizedLabel(d.barNumberLabel)
            candidate.signaturePhoneLabel = sanitizedLabel(d.phoneLabel)
            candidate.signatureFaxLabel = sanitizedLabel(d.faxLabel)
        }
        return candidate
    }

    /// Deterministic identity guardrail (invariant 4): a style LABEL never contains digits or an
    /// e-mail. Truncate at the first digit/@ (dropping a dangling opening bracket/dash), so a
    /// leaky "Telephone: (305) 555-1212" becomes exactly "Telephone: " and "FBN 12345" keeps
    /// only its label. Values with no identity content pass through EXACTLY (trailing spaces —
    /// e.g. "cc:  " — are significant). Overlong or emptied values are rejected.
    static func sanitizedLabel(_ raw: String?) -> String? {
        guard var value = raw else { return nil }
        if let cut = value.firstIndex(where: { $0.isNumber || $0 == "@" }) {
            value = String(value[..<cut])
            while let last = value.last, last == "(" || last == "[" || last == "-" || last == "–" {
                value.removeLast()
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.count <= 60 else { return nil }
        return value
    }

    /// Stricter guard for the e-signature mark (PR #50 review). Marks are tiny tokens —
    /// "/s/ ", "s/ ", "-s- " — but names carry no digits/@, so `sanitizedLabel` alone would let a
    /// leaky "/s/ Jane Doe" become the firm-wide mark and print the exemplar signer's name
    /// before the REAL signer on every future signature. Accept at most one letter cluster of
    /// ≤ 2 letters within ≤ 8 characters; anything wordier is rejected outright (never truncated
    /// to a guess — the user can type an unusual mark manually in Settings).
    static func sanitizedMark(_ raw: String?) -> String? {
        guard let value = sanitizedLabel(raw), value.count <= 8 else { return nil }
        let clusters = value.split(whereSeparator: { !$0.isLetter })
        guard clusters.count <= 1, clusters.allSatisfy({ $0.count <= 2 }) else { return nil }
        return value
    }
}
