import Foundation
import SupraCore
import SupraStore

/// The aggregate result of replaying real matter-chat user questions through the Phase 2
/// coverage-vs-keyword routing shadow: counts per comparison plus derived rates. Metadata only —
/// it holds no question or source text. This is the evidence a go/no-go for flipping corpus
/// coverage to the primary router consumes.
public struct CoverageRoutingReport: Sendable, Equatable {
    /// Matters that contributed at least one replayable user question.
    public let matterCount: Int
    /// Total user questions compared (after de-duplication).
    public let questionsScanned: Int
    public let agreeGround: Int
    public let agreeSkip: Int
    public let coverageWouldGround: Int
    public let coverageWouldSkip: Int
    public let marginal: Int
    /// Whether a real embedder backed the coverage probe. When false the coverage retrieval was
    /// FTS-only (no semantic bucket), so the divergence figures are a conservative lower bound.
    public let usedSemantic: Bool
    /// Store reads that failed during the scan (matters/folders/chats/messages). Non-zero means the
    /// tally is under-counted — some matters or questions were silently dropped — so the report is
    /// NOT trustworthy go/no-go evidence. A read failure is otherwise indistinguishable from an
    /// empty result, so this is the only signal that the run was incomplete.
    public let readErrors: Int

    public init(
        matterCount: Int,
        questionsScanned: Int,
        agreeGround: Int,
        agreeSkip: Int,
        coverageWouldGround: Int,
        coverageWouldSkip: Int,
        marginal: Int,
        usedSemantic: Bool,
        readErrors: Int
    ) {
        self.matterCount = matterCount
        self.questionsScanned = questionsScanned
        self.agreeGround = agreeGround
        self.agreeSkip = agreeSkip
        self.coverageWouldGround = coverageWouldGround
        self.coverageWouldSkip = coverageWouldSkip
        self.marginal = marginal
        self.usedSemantic = usedSemantic
        self.readErrors = readErrors
    }

    /// The scan completed with no store read failures — the tally covers every live matter and
    /// question. When false, treat the figures as a floor, not evidence.
    public var completedCleanly: Bool { readErrors == 0 }

    private func rate(_ count: Int) -> Double {
        questionsScanned == 0 ? 0 : Double(count) / Double(questionsScanned)
    }

    /// Share of questions where coverage and the keyword router agree (both ground or both skip).
    public var agreementRate: Double { rate(agreeGround + agreeSkip) }
    /// Share where they disagree in a confident direction (would-ground or would-skip).
    public var divergenceRate: Double { rate(coverageWouldGround + coverageWouldSkip) }
    /// The R2 improvement rate: keyword-miss questions the corpus strongly covers — the ones
    /// coverage-first routing would newly ground.
    public var wouldGroundRate: Double { rate(coverageWouldGround) }
    /// Keyword over-grounding: questions coverage-first routing would send to the legal route.
    public var wouldSkipRate: Double { rate(coverageWouldSkip) }
}

/// Phase 2 (retrieve-before-route) evidence probe. Replays every live matter's historical user
/// questions through the keyword router (`MatterChatDocumentIntent`) and the corpus-coverage
/// signal (`MatterCorpusCoverage`), grading each with `CoverageRoutingShadow.compare` and folding
/// the results into a `CoverageRoutingReport`. Read-only — it never mutates the store. Lives in
/// SupraSessions because the keyword classifier is internal to this module; the app calls the
/// public entrypoint.
public enum CoverageRoutingProbe {
    /// Pure aggregation: fold a flat list of per-question comparisons into a report. `readErrors`
    /// carries the count of store reads that failed during the scan (0 on a clean run).
    public static func report(
        comparisons: [CoverageRoutingComparison],
        matterCount: Int,
        usedSemantic: Bool,
        readErrors: Int = 0
    ) -> CoverageRoutingReport {
        var agreeGround = 0, agreeSkip = 0, wouldGround = 0, wouldSkip = 0, marginal = 0
        for comparison in comparisons {
            switch comparison {
            case .agreeGround: agreeGround += 1
            case .agreeSkip: agreeSkip += 1
            case .coverageWouldGround: wouldGround += 1
            case .coverageWouldSkip: wouldSkip += 1
            case .marginal: marginal += 1
            }
        }
        return CoverageRoutingReport(
            matterCount: matterCount,
            questionsScanned: comparisons.count,
            agreeGround: agreeGround,
            agreeSkip: agreeSkip,
            coverageWouldGround: wouldGround,
            coverageWouldSkip: wouldSkip,
            marginal: marginal,
            usedSemantic: usedSemantic,
            readErrors: readErrors
        )
    }

    /// Replays the de-duplicated user questions across all live matters. For each question it runs
    /// the exact routing inputs the live grounding path uses (folder names + party anchors →
    /// `classify`) and the coverage assessment, then compares them. `maxQuestionsPerMatter` caps a
    /// single matter's contribution (nil = no cap). Not actor-bound — the store reads and the
    /// coverage assessment run off the caller's actor.
    public static func run(
        store: SupraStore,
        embedder: (any TextEmbedder)?,
        maxQuestionsPerMatter: Int? = nil
    ) async -> CoverageRoutingReport {
        var readErrors = 0
        let matters: [MatterRecord]
        do {
            matters = try store.matters.fetchMatters()
        } catch {
            // A top-level failure means nothing could be scanned; flag it so an all-zero report is
            // not mistaken for an empty store.
            return report(comparisons: [], matterCount: 0, usedSemantic: embedder != nil, readErrors: 1)
        }
        var comparisons: [CoverageRoutingComparison] = []
        var mattersWithQuestions = 0
        for matter in matters {
            let questions = userQuestions(
                store: store, matterID: matter.id, cap: maxQuestionsPerMatter, readErrors: &readErrors
            )
            guard !questions.isEmpty else { continue }
            mattersWithQuestions += 1
            let folderNames: [String]
            do {
                folderNames = try store.documentLibrary.fetchFolders(matterID: matter.id).map(\.name)
            } catch {
                folderNames = []
                readErrors += 1
            }
            let partyAnchors = MatterChatDocumentIntent.partyAnchors(
                matterName: matter.name, clientNames: matter.clientNames
            )
            for question in questions {
                let intent = MatterChatDocumentIntent.classify(
                    question, folderNames: folderNames, partyAnchors: partyAnchors
                )
                let coverage = await MatterCorpusCoverage.assess(
                    matterID: matter.id, question: question, store: store, embedder: embedder
                )
                comparisons.append(
                    CoverageRoutingShadow.compare(keywordGrounds: intent != .none, coverage: coverage)
                )
            }
        }
        return report(
            comparisons: comparisons,
            matterCount: mattersWithQuestions,
            usedSemantic: embedder != nil,
            readErrors: readErrors
        )
    }

    /// The distinct, non-empty user questions for a matter (soft-deleted rows already excluded by
    /// the repository), newest chats first, optionally capped. De-duplicated case-insensitively so
    /// a repeated ask does not skew the tally. A failed chat/message read increments `readErrors`
    /// rather than being silently swallowed, so an incomplete scan is visible in the report.
    static func userQuestions(
        store: SupraStore, matterID: String, cap: Int?, readErrors: inout Int
    ) -> [String] {
        let chats: [ChatRecord]
        do {
            chats = try store.chats.fetchMatterChats(matterID: matterID)
        } catch {
            readErrors += 1
            return []
        }
        var seen = Set<String>()
        var questions: [String] = []
        for chat in chats {
            let messages: [MessageRecord]
            do {
                messages = try store.chats.fetchMessages(chatID: chat.id)
            } catch {
                readErrors += 1
                continue
            }
            for message in messages where message.role == MessageRole.user.rawValue {
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
                questions.append(trimmed)
                if let cap, questions.count >= cap { return questions }
            }
        }
        return questions
    }
}
