import Foundation

public enum RAGCorpusDataClassification: String, Codable, Sendable {
    case syntheticFictionalNonprivileged = "synthetic_fictional_nonprivileged"
}

public enum RAGCorpusSize: String, Codable, Hashable, Sendable {
    case small
    case medium
    case large
}

public enum RAGCorpusQueryType: String, Codable, Hashable, Sendable {
    case factLookup = "fact_lookup"
    case tableLookup = "table_lookup"
    case versionResolution = "version_resolution"
    case contradiction
    case noAnswer = "no_answer"
}

public enum RAGCorpusHumanReviewStatus: String, Codable, Sendable {
    case pendingOwnerReview = "pending_owner_review"
    case approved
}

public struct RAGBenchmarkCorpusManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var corpusID: String
    public var corpusVersion: String
    public var dataClassification: RAGCorpusDataClassification
    public var containsRealClientData: Bool
    public var artifactRoot: String
    public var requiredSlices: [String]
    public var artifacts: [RAGBenchmarkArtifact]
    public var queries: [RAGBenchmarkQuery]
}

public struct RAGBenchmarkArtifact: Codable, Equatable, Sendable {
    public var artifactID: String
    public var path: String
    public var sha256: String
    public var documentType: String
    public var duplicateOfArtifactID: String?
}

public struct RAGCorpusHumanReview: Codable, Equatable, Sendable {
    public var status: RAGCorpusHumanReviewStatus
    public var reviewerRole: String
    public var reviewBasis: String
    public var reviewedBy: String?
    public var reviewedAt: String?
}

public struct RAGBenchmarkJudgment: Codable, Equatable, Sendable {
    public var evidenceID: String
    public var artifactID: String
    public var locator: String
    public var grade: Int
}

public struct RAGBenchmarkClaimExpectation: Codable, Equatable, Sendable {
    public var claimID: String
    public var expectedEvidenceIDs: [String]
}

public struct RAGBenchmarkQuery: Codable, Equatable, Sendable {
    public var queryID: String
    public var prompt: String
    public var expectedAnswer: String?
    public var queryType: RAGCorpusQueryType
    public var corpusSize: RAGCorpusSize
    public var slices: [String]
    public var scopeArtifactIDs: [String]
    public var expectedNoResult: Bool
    public var humanReview: RAGCorpusHumanReview
    public var judgments: [RAGBenchmarkJudgment]
    public var claims: [RAGBenchmarkClaimExpectation]
}

public enum RAGCorpusValidationIssue: Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case realClientDataDeclared
    case invalidArtifactRoot
    case duplicateArtifactID(String)
    case invalidArtifactPath(String)
    case invalidArtifactDigest(String)
    case duplicateArtifactTargetMissing(String)
    case duplicateArtifactDigestMismatch(String)
    case duplicateRequiredSlice(String)
    case unrepresentedRequiredSlice(String)
    case duplicateQueryID(String)
    case missingHumanReviewMetadata(String)
    case approvedReviewMissingIdentity(String)
    case undeclaredQuerySlice(queryID: String, slice: String)
    case unknownScopeArtifact(queryID: String, artifactID: String)
    case duplicateScopeArtifact(queryID: String, artifactID: String)
    case duplicateEvidenceID(queryID: String, evidenceID: String)
    case invalidJudgmentGrade(queryID: String, evidenceID: String)
    case unknownJudgmentArtifact(queryID: String, artifactID: String)
    case judgmentOutsideScope(queryID: String, artifactID: String)
    case missingJudgmentLocator(queryID: String, evidenceID: String)
    case duplicateClaimID(queryID: String, claimID: String)
    case claimHasNoEvidence(queryID: String, claimID: String)
    case claimReferencesUnknownEvidence(queryID: String, claimID: String, evidenceID: String)
    case noAnswerQueryHasJudgments(String)
    case noAnswerQueryHasClaims(String)
    case noAnswerQueryHasExpectedAnswer(String)
    case noAnswerQueryHasWrongType(String)
    case answerableQueryHasNoJudgments(String)
    case answerableQueryHasNoClaims(String)
    case answerableQueryMissingExpectedAnswer(String)
    case answerableQueryHasNoAnswerType(String)
}

public enum RAGCorpusValidator {
    public static func validate(_ manifest: RAGBenchmarkCorpusManifest) -> [RAGCorpusValidationIssue] {
        var issues: [RAGCorpusValidationIssue] = []

        if manifest.schemaVersion != 1 {
            issues.append(.unsupportedSchemaVersion(manifest.schemaVersion))
        }
        if manifest.containsRealClientData {
            issues.append(.realClientDataDeclared)
        }
        if !isSafeRelativePath(manifest.artifactRoot) {
            issues.append(.invalidArtifactRoot)
        }

        var artifactsByID: [String: RAGBenchmarkArtifact] = [:]
        for artifact in manifest.artifacts {
            if artifactsByID.updateValue(artifact, forKey: artifact.artifactID) != nil {
                issues.append(.duplicateArtifactID(artifact.artifactID))
            }
            if !isSafeRelativePath(artifact.path) {
                issues.append(.invalidArtifactPath(artifact.artifactID))
            }
            if !isSHA256(artifact.sha256) {
                issues.append(.invalidArtifactDigest(artifact.artifactID))
            }
        }

        for artifact in manifest.artifacts {
            guard let duplicateOfArtifactID = artifact.duplicateOfArtifactID else { continue }
            guard let canonical = artifactsByID[duplicateOfArtifactID] else {
                issues.append(.duplicateArtifactTargetMissing(artifact.artifactID))
                continue
            }
            if canonical.sha256 != artifact.sha256 {
                issues.append(.duplicateArtifactDigestMismatch(artifact.artifactID))
            }
        }

        let requiredSlices = Set(manifest.requiredSlices)
        for slice in duplicateValues(in: manifest.requiredSlices) {
            issues.append(.duplicateRequiredSlice(slice))
        }
        let representedSlices = Set(manifest.queries.flatMap(\.slices))
        for slice in requiredSlices.subtracting(representedSlices).sorted() {
            issues.append(.unrepresentedRequiredSlice(slice))
        }

        var queryIDs = Set<String>()
        for query in manifest.queries {
            if !queryIDs.insert(query.queryID).inserted {
                issues.append(.duplicateQueryID(query.queryID))
            }
            if query.humanReview.reviewerRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || query.humanReview.reviewBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                issues.append(.missingHumanReviewMetadata(query.queryID))
            }
            if query.humanReview.status == .approved,
               isBlank(query.humanReview.reviewedBy) || isBlank(query.humanReview.reviewedAt)
            {
                issues.append(.approvedReviewMissingIdentity(query.queryID))
            }

            for slice in query.slices where !requiredSlices.contains(slice) {
                issues.append(.undeclaredQuerySlice(queryID: query.queryID, slice: slice))
            }

            var scopeArtifactIDs = Set<String>()
            for artifactID in query.scopeArtifactIDs {
                if !scopeArtifactIDs.insert(artifactID).inserted {
                    issues.append(.duplicateScopeArtifact(queryID: query.queryID, artifactID: artifactID))
                }
                if artifactsByID[artifactID] == nil {
                    issues.append(.unknownScopeArtifact(queryID: query.queryID, artifactID: artifactID))
                }
            }

            var evidenceIDs = Set<String>()
            for judgment in query.judgments {
                if !evidenceIDs.insert(judgment.evidenceID).inserted {
                    issues.append(
                        .duplicateEvidenceID(queryID: query.queryID, evidenceID: judgment.evidenceID)
                    )
                }
                if !(1...3).contains(judgment.grade) {
                    issues.append(
                        .invalidJudgmentGrade(queryID: query.queryID, evidenceID: judgment.evidenceID)
                    )
                }
                if artifactsByID[judgment.artifactID] == nil {
                    issues.append(
                        .unknownJudgmentArtifact(queryID: query.queryID, artifactID: judgment.artifactID)
                    )
                } else if !scopeArtifactIDs.contains(judgment.artifactID) {
                    issues.append(
                        .judgmentOutsideScope(queryID: query.queryID, artifactID: judgment.artifactID)
                    )
                }
                if judgment.locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(
                        .missingJudgmentLocator(queryID: query.queryID, evidenceID: judgment.evidenceID)
                    )
                }
            }

            var claimIDs = Set<String>()
            for claim in query.claims {
                if !claimIDs.insert(claim.claimID).inserted {
                    issues.append(.duplicateClaimID(queryID: query.queryID, claimID: claim.claimID))
                }
                if claim.expectedEvidenceIDs.isEmpty {
                    issues.append(.claimHasNoEvidence(queryID: query.queryID, claimID: claim.claimID))
                }
                for evidenceID in claim.expectedEvidenceIDs where !evidenceIDs.contains(evidenceID) {
                    issues.append(
                        .claimReferencesUnknownEvidence(
                            queryID: query.queryID,
                            claimID: claim.claimID,
                            evidenceID: evidenceID
                        )
                    )
                }
            }

            if query.expectedNoResult {
                if !query.judgments.isEmpty {
                    issues.append(.noAnswerQueryHasJudgments(query.queryID))
                }
                if !query.claims.isEmpty {
                    issues.append(.noAnswerQueryHasClaims(query.queryID))
                }
                if !isBlank(query.expectedAnswer) {
                    issues.append(.noAnswerQueryHasExpectedAnswer(query.queryID))
                }
                if query.queryType != .noAnswer {
                    issues.append(.noAnswerQueryHasWrongType(query.queryID))
                }
            } else {
                if query.judgments.isEmpty {
                    issues.append(.answerableQueryHasNoJudgments(query.queryID))
                }
                if query.claims.isEmpty {
                    issues.append(.answerableQueryHasNoClaims(query.queryID))
                }
                if isBlank(query.expectedAnswer) {
                    issues.append(.answerableQueryMissingExpectedAnswer(query.queryID))
                }
                if query.queryType == .noAnswer {
                    issues.append(.answerableQueryHasNoAnswerType(query.queryID))
                }
            }
        }

        return issues
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func duplicateValues(in values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates.sorted()
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
