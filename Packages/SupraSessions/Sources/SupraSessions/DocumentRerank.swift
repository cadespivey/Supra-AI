import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface

/// Shared LLM rerank stage for deep-tier document retrieval (spec §3.1): scores a
/// wide candidate pool by how directly each passage helps answer the question and
/// returns the packed top selection. Extracted from `DocumentQAController` so the
/// matter-chat grounded deep pass reuses the SAME machinery (prompt shape, label
/// parsing, ordering, fallbacks) instead of duplicating it.
///
/// Best-effort by design: a model failure, or a reply with too few valid labels,
/// degrades to retrieval order — the rerank can improve a deep answer but never
/// block one.
enum DocumentRerank {
    /// Wide candidate pool for the deep tier — 40 keeps the rerank prompt inside
    /// small local-model contexts.
    static let candidatePoolSize = 40

    /// Per-candidate snippet length shown to the reranker. Longer than the 220-char
    /// display excerpt so the reranker scores on the same content the answer is
    /// grounded in (the chunk + folded neighbors), not just the leading sentence.
    static let snippetChars = 600

    /// The reranker's system prompt. Keep this string verbatim: tests distinguish
    /// rerank requests from answer requests by it, and it is the stable signature
    /// of this machinery across its call sites (Q&A regenerate, chat deep pass).
    static let rerankSystemPrompt = "You are a retrieval reranker. Output only the source labels."

    /// One rerank candidate: its retrieval label ("S1"…) and the packed text the
    /// answer would be grounded in.
    struct Candidate: Sendable {
        var label: String
        var text: String
    }

    /// The rerank prompt: the question plus a labelled listing of candidate
    /// snippets, asking for the `limit` most relevant labels only.
    static func prompt(question: String, candidates: [Candidate], limit: Int) -> String {
        let listing = candidates
            .map { "[\($0.label)] \(DocumentChunker.excerpt($0.text, limit: snippetChars))" }
            .joined(separator: "\n")
        return """
        Rank the passages by how directly they help answer the QUESTION.

        QUESTION: \(question)

        PASSAGES:
        \(listing)

        Return ONLY the labels of the \(limit) most relevant passages, most relevant first, comma-separated (e.g. S3, S1, S7). No other text.
        """
    }

    /// Runs the rerank generation and returns the packed label order: the model's
    /// preferred labels first (in its order, ignoring unknown/duplicate labels),
    /// backfilled in retrieval order, capped at `limit`. A model failure yields the
    /// retrieval-order prefix.
    static func packedOrder(
        question: String,
        candidates: [Candidate],
        limit: Int,
        runtimeClient: any RuntimeClientProtocol,
        modelID: ModelID
    ) async -> [String] {
        let retrievalLabels = candidates.map(\.label)
        var options = GenerationPreset.extractive.defaultOptions
        options.maxOutputTokens = 256
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: prompt(question: question, candidates: candidates, limit: limit),
            systemPrompt: rerankSystemPrompt,
            options: options
        )
        guard let raw = try? await runtimeClient.collectGeneratedText(request) else {
            return Array(retrievalLabels.prefix(limit))
        }
        return rerankOrder(
            retrievalLabels: retrievalLabels,
            preferred: parsePacketLabels(ReasoningContent.answer(from: raw)),
            limit: limit
        )
    }

    /// Final source order: the model's preferred labels first (in its order, ignoring
    /// unknown/duplicate labels), then any remaining candidates in retrieval order,
    /// capped at `limit`.
    static func rerankOrder(retrievalLabels: [String], preferred: [String], limit: Int) -> [String] {
        let valid = Set(retrievalLabels)
        var picked: [String] = []
        var seen = Set<String>()
        for label in preferred where valid.contains(label) && !seen.contains(label) {
            picked.append(label); seen.insert(label)
            if picked.count >= limit { break }
        }
        for label in retrievalLabels where picked.count < limit && !seen.contains(label) {
            picked.append(label); seen.insert(label)
        }
        return picked
    }

    /// Extracts S-style source labels (e.g. "S3") from a reranker's free-text reply.
    /// Anchored so a digit-bearing word echoed from the question/excerpts (e.g.
    /// "Windows10", "class3") doesn't yield a stray label that could promote a wrong
    /// passage.
    static func parsePacketLabels(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])[Ss]\\d+(?![0-9])") else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: ns).compactMap {
            Range($0.range, in: text).map { String(text[$0]).uppercased() }
        }
    }
}
