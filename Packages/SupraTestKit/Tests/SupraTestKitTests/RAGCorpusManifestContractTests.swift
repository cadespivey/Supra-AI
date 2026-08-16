import CryptoKit
import Foundation
import XCTest
@testable import SupraTestKit

final class RAGCorpusManifestContractTests: XCTestCase {
    func testVersionedSyntheticManifestBindsEveryArtifactByExactDigest() throws {
        // T-RAG-CORPUS-01 expected RED: no typed, versioned RAG judgment
        // manifest exists, so its synthetic-data and digest contract cannot compile.
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.corpusID, "supra-rag-synthetic-legal")
        XCTAssertEqual(manifest.corpusVersion, "1.0.0")
        XCTAssertEqual(manifest.dataClassification, .syntheticFictionalNonprivileged)
        XCTAssertFalse(manifest.containsRealClientData)
        XCTAssertEqual(manifest.artifactRoot, "TestData/Synthetic Document Intelligence Benchmark")
        XCTAssertEqual(RAGCorpusValidator.validate(manifest), [])

        let artifactIDs = manifest.artifacts.map(\.artifactID)
        XCTAssertEqual(Set(artifactIDs).count, artifactIDs.count)
        for artifact in manifest.artifacts {
            XCTAssertFalse(artifact.path.hasPrefix("/"), artifact.artifactID)
            XCTAssertNil(
                artifact.path.split(separator: "/").first { $0 == ".." },
                artifact.artifactID
            )
            XCTAssertEqual(artifact.sha256.count, 64, artifact.artifactID)

            let artifactURL = repoRoot()
                .appendingPathComponent(manifest.artifactRoot, isDirectory: true)
                .appendingPathComponent(artifact.path)
            let data = try Data(contentsOf: artifactURL)
            XCTAssertEqual(Self.sha256(data), artifact.sha256, artifact.artifactID)
        }

        var invalid = manifest
        invalid.artifacts[0].path = "/Users/example/real-client/intake.pdf"
        XCTAssertTrue(
            RAGCorpusValidator.validate(invalid).contains(
                .invalidArtifactPath(invalid.artifacts[0].artifactID)
            )
        )
    }

    func testManifestCoversTheExactRequiredSlicesQueryTypesAndCorpusSizes() throws {
        // T-RAG-CORPUS-01 expected RED: the existing fixture manifest has no
        // graded retrieval slices or small/medium/large evaluation scopes.
        let manifest = try loadManifest()
        let requiredSlices = Set([
            "ocr",
            "table",
            "document_type",
            "revision",
            "supersession",
            "contrary_evidence",
            "duplicate",
            "no_answer",
            "corpus_small",
            "corpus_medium",
            "corpus_large",
        ])
        let observedSlices = Set(manifest.queries.flatMap(\.slices))

        XCTAssertEqual(Set(manifest.requiredSlices), requiredSlices)
        XCTAssertTrue(requiredSlices.isSubset(of: observedSlices))
        XCTAssertEqual(
            Set(manifest.queries.map(\.queryType)),
            Set<RAGCorpusQueryType>([.factLookup, .tableLookup, .versionResolution, .contradiction, .noAnswer])
        )
        XCTAssertEqual(
            Set(manifest.queries.map(\.corpusSize)),
            Set<RAGCorpusSize>([.small, .medium, .large])
        )
        XCTAssertTrue(
            Set(manifest.artifacts.map(\.documentType))
                .isSuperset(of: ["docx", "eml", "scanned_pdf", "xlsx"])
        )
    }

    func testEveryAnswerableQueryHasReviewedMetadataGradesAndExactCitationEdges() throws {
        // T-RAG-CORPUS-01 expected RED: no corpus type encodes per-query
        // human-review state, graded evidence, or exact claim/evidence edges.
        let manifest = try loadManifest()
        let artifactIDs = Set(manifest.artifacts.map(\.artifactID))
        let answerableQueries = manifest.queries.filter { !$0.expectedNoResult }

        XCTAssertEqual(answerableQueries.count, 4)
        for query in answerableQueries {
            XCTAssertEqual(query.humanReview.status, .pendingOwnerReview, query.queryID)
            XCTAssertEqual(query.humanReview.reviewerRole, "repository_owner_attorney", query.queryID)
            XCTAssertFalse(query.humanReview.reviewBasis.isEmpty, query.queryID)
            XCTAssertNil(query.humanReview.reviewedBy, query.queryID)
            XCTAssertNil(query.humanReview.reviewedAt, query.queryID)
            XCTAssertNotNil(query.expectedAnswer, query.queryID)
            XCTAssertFalse(query.judgments.isEmpty, query.queryID)
            XCTAssertFalse(query.claims.isEmpty, query.queryID)
            XCTAssertTrue(query.judgments.contains { $0.grade == 3 }, query.queryID)

            let evidenceIDs = query.judgments.map(\.evidenceID)
            XCTAssertEqual(Set(evidenceIDs).count, evidenceIDs.count, query.queryID)
            XCTAssertTrue(query.judgments.allSatisfy { (1...3).contains($0.grade) }, query.queryID)
            XCTAssertTrue(query.judgments.allSatisfy { artifactIDs.contains($0.artifactID) }, query.queryID)

            let positiveEvidenceIDs = Set(query.judgments.map(\.evidenceID))
            for claim in query.claims {
                XCTAssertFalse(claim.expectedEvidenceIDs.isEmpty, "\(query.queryID)/\(claim.claimID)")
                XCTAssertTrue(
                    Set(claim.expectedEvidenceIDs).isSubset(of: positiveEvidenceIDs),
                    "\(query.queryID)/\(claim.claimID)"
                )
            }
        }
    }

    func testNoAnswerGoldenIsExplicitAndAccidentalEmptyRowsFailClosed() throws {
        // T-RAG-CORPUS-01 expected RED: no manifest validator distinguishes an
        // intentional no-answer golden from an accidentally empty answerable row.
        let manifest = try loadManifest()
        let noAnswer = try XCTUnwrap(manifest.queries.first { $0.expectedNoResult })

        XCTAssertEqual(noAnswer.queryID, "rag-no-answer-settlement-release")
        XCTAssertEqual(noAnswer.queryType, .noAnswer)
        XCTAssertNil(noAnswer.expectedAnswer)
        XCTAssertTrue(noAnswer.judgments.isEmpty)
        XCTAssertTrue(noAnswer.claims.isEmpty)

        var invalidNoAnswer = manifest
        let noAnswerIndex = try XCTUnwrap(
            invalidNoAnswer.queries.firstIndex { $0.queryID == noAnswer.queryID }
        )
        let positiveJudgment = try XCTUnwrap(
            manifest.queries.first { !$0.expectedNoResult }?.judgments.first
        )
        invalidNoAnswer.queries[noAnswerIndex].judgments = [positiveJudgment]
        XCTAssertTrue(
            RAGCorpusValidator.validate(invalidNoAnswer).contains(
                .noAnswerQueryHasJudgments(noAnswer.queryID)
            )
        )

        var invalidAnswerable = manifest
        let answerableIndex = try XCTUnwrap(
            invalidAnswerable.queries.firstIndex { !$0.expectedNoResult }
        )
        let answerableID = invalidAnswerable.queries[answerableIndex].queryID
        invalidAnswerable.queries[answerableIndex].judgments = []
        XCTAssertTrue(
            RAGCorpusValidator.validate(invalidAnswerable).contains(
                .answerableQueryHasNoJudgments(answerableID)
            )
        )
    }

    private func loadManifest() throws -> RAGBenchmarkCorpusManifest {
        let url = repoRoot().appendingPathComponent("TestData/Benchmarks/rag-corpus-v1.json")
        return try JSONDecoder().decode(
            RAGBenchmarkCorpusManifest.self,
            from: Data(contentsOf: url)
        )
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
