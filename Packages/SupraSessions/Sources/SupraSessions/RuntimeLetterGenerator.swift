import Foundation
import SupraCore
import SupraDrafting
import SupraDraftingCore
import SupraRuntimeClient
import SupraRuntimeInterface

/// A `LetterGenerator` backed by the on-device model runtime (the `letterDemand` kind).
///
/// It builds a tightly fact-scoped prompt from `PromptParts` — the caller's grounded
/// facts are the ONLY fact source — calls the drafting model, and parses the reply into
/// letter-body paragraphs. It never emits citations (a demand letter asserts no legal
/// authority), so the downstream verifier/pre-file gate see an empty `citesUsed`. The
/// firewall here is prompt-side (only grounded facts in) plus the attorney's review; the
/// pipeline still flags any cite that slips through.
struct RuntimeLetterGenerator: LetterGenerator {
    let runtimeClient: any RuntimeClientProtocol
    let modelID: ModelID
    let route: ModelRoute

    func generateLetter(_ parts: PromptParts) async throws -> GeneratedLetter {
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: Self.buildPrompt(parts),
            systemPrompt: route.systemPrompt,
            options: route.options
        )
        let raw = try await runtimeClient.collectGeneratedText(request)
        let answer = ReasoningContent.answer(from: raw)
        return GeneratedLetter(
            paragraphs: Self.parseParagraphs(answer),
            assertedFacts: [],
            citesUsed: []
        )
    }

    /// Assembles the generation prompt. The facts block is fenced as the only permitted
    /// source; the model is told to write the body only (the letterhead/date/recipient/
    /// salutation/closing/signature are added deterministically by the assembler).
    static func buildPrompt(_ parts: PromptParts) -> String {
        var lines: [String] = [parts.taskInstruction, ""]
        lines.append("Use ONLY these facts. Do not introduce any other facts, names, dates, amounts, or legal citations:")
        if parts.facts.isEmpty {
            lines.append("- (none provided)")
        } else {
            for fact in parts.facts {
                lines.append("- \(fact.label): \(fact.text)")
            }
        }
        if let voice = parts.voice {
            lines.append("")
            lines.append("Tone/register: \(voice.profile.registerNotes). Match the register only — never copy wording from examples.")
        }
        lines.append("")
        lines.append("Write only the BODY of the letter as plain paragraphs separated by blank lines.")
        lines.append("Do NOT include the letterhead, date, recipient address, \"Re:\" line, salutation, closing, or signature — those are added automatically.")
        lines.append("Do NOT cite cases or statutes. If a needed fact is missing, write [fact?] rather than inventing it.")
        return lines.joined(separator: "\n")
    }

    /// Splits the model's reply into paragraphs: blank lines are paragraph breaks, and
    /// wrapped lines within a paragraph are rejoined. Leading list markers are left intact.
    static func parseParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs.filter { !$0.isEmpty }
    }
}
