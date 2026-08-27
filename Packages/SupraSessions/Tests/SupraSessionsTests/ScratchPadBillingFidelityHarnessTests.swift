import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

private func blockCurrentThreadForTimeoutRegression() {
    Thread.sleep(forTimeInterval: 0.25)
}

final class ScratchPadBillingFidelityHarnessTests: XCTestCase {
    @MainActor
    func testRunRetainsGatewayRawTextWhileScoringProductionAnswer() async {
        let raw = "private reasoning\n</think>\n{\"lineItems\":[]}"
        let runtime = StubRuntimeClient { request in
            .events([
                .event(request, 0, .token, token: raw),
                .event(request, 1, .generationCompleted),
            ])
        }

        let revision = String(repeating: "b", count: 40)
        let manifestSHA256 = String(repeating: "c", count: 64)
        let artifactFingerprintSHA256 = String(repeating: "d", count: 64)
        let record = await ScratchPadBillingFidelityHarness.run(
            modelID: ModelID(),
            modelName: "Synthetic raw-output model",
            modelRepositoryID: "synthetic/raw-output-model",
            modelRevision: revision,
            modelManifestSHA256: manifestSHA256,
            modelContentBindingAlgorithm: "supra-release-model-sha256-v1",
            modelContentBindingSchemaVersion: 1,
            modelArtifactFingerprintSHA256: artifactFingerprintSHA256,
            sourceCommitSHA: String(repeating: "a", count: 40),
            modelExecutionGateway: runtime
        )

        XCTAssertEqual(record.modelRepositoryID, "synthetic/raw-output-model")
        XCTAssertEqual(record.modelRevision, revision)
        XCTAssertEqual(record.modelManifestSHA256, manifestSHA256)
        XCTAssertEqual(record.modelContentBindingAlgorithm, "supra-release-model-sha256-v1")
        XCTAssertEqual(record.modelContentBindingSchemaVersion, 1)
        XCTAssertEqual(record.modelArtifactFingerprintSHA256, artifactFingerprintSHA256)
        XCTAssertEqual(record.outcomes.count, 20)
        XCTAssertTrue(record.outcomes.allSatisfy { $0.rawModelText == raw })
        XCTAssertTrue(record.outcomes.allSatisfy(\.firstPassJSONValid))
        XCTAssertTrue(record.outcomes.allSatisfy { !$0.strictJSONObjectOnly })
    }

    func testStandardCorpusHasRequiredCoverage() {
        let fixtures = ScratchPadBillingFidelityHarness.standardFixtures()
        let expectations = fixtures.flatMap(\.expectations)

        XCTAssertEqual(fixtures.count, 20)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count)
        XCTAssertGreaterThanOrEqual(expectations.filter { $0.matterBasis == .untaggedInference }.count, 5)
        XCTAssertGreaterThanOrEqual(expectations.filter { $0.timeBasis == .inferredTimestampGap }.count, 5)
        XCTAssertTrue(expectations.contains { $0.expectedTaskCode == nil })
        XCTAssertTrue(fixtures.contains { !$0.attachments.isEmpty })
        XCTAssertTrue(fixtures.contains { $0.entries.contains(where: \.isNonBillable) })
        XCTAssertTrue(fixtures.contains { !$0.autoTimestamp })
        XCTAssertTrue(fixtures.allSatisfy { !$0.entries.isEmpty && !$0.matters.isEmpty })
    }

    func testAdjudicatedUTBMSFixtureLabelsAndAcceptableSets() throws {
        let fixtures = Dictionary(uniqueKeysWithValues: ScratchPadBillingFidelityHarness.standardFixtures().map { ($0.id, $0) })
        func expectation(_ fixtureID: String) throws -> ScratchPadBillingFidelityExpectation {
            try XCTUnwrap(fixtures[fixtureID]?.expectations.first)
        }

        XCTAssertEqual(try expectation("f4").expectedTaskCode, "L120")
        XCTAssertEqual(try expectation("f6").acceptableTaskCodes, Set(["L500", "L510"]))
        XCTAssertEqual(try expectation("f9").expectedActivityCode, "A107")
        XCTAssertEqual(try expectation("f10").expectedTaskCode, "L250")
        XCTAssertEqual(try expectation("f11").acceptableTaskCodes, Set(["L120", "L210"]))
        XCTAssertEqual(try expectation("f13").acceptableTaskCodes, Set(["L210", "L250"]))
        XCTAssertEqual(try expectation("f14").expectedActivityCode, "A101")
    }

    @MainActor
    func testPromptContextExcludesNoteCanaryAndItsAttachmentButKeepsBillableDocumentEvidence() {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures().first { !$0.attachments.isEmpty }!
        let context = ScratchPadBillingFidelityScorer.context(for: fixture)
        let prompt = BillingDraftPrompt.user(context)

        XCTAssertFalse(context.entries.contains(where: \.isNonBillable))
        XCTAssertFalse(prompt.contains("BILLING_CANARY_DO_NOT_USE"))
        XCTAssertFalse(prompt.contains("excluded-canary.txt"))
        XCTAssertTrue(prompt.contains("licensing-risk-review.txt"))
        XCTAssertTrue(prompt.contains("indemnity and limitation-of-liability provisions"))
    }

    @MainActor
    func testCanonicalOutputsClearEveryHardGate() throws {
        let outcomes = ScratchPadBillingFidelityHarness.standardFixtures().map { fixture in
            ScratchPadBillingFidelityScorer.score(
                fixture: fixture,
                rawModelText: ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
            )
        }
        let summary = ScratchPadBillingFidelitySummary(outcomes: outcomes)

        XCTAssertEqual(summary.firstPassJSONValidityRate, 1)
        XCTAssertEqual(summary.parserAcceptanceRate, 1)
        XCTAssertEqual(summary.matterAccuracyRate, 1)
        XCTAssertEqual(summary.untaggedMatterAccuracyRate, 1)
        XCTAssertEqual(summary.narrativeSubjectRate, 1)
        XCTAssertEqual(summary.explicitTimeAccuracyRate, 1)
        XCTAssertEqual(summary.inferredTimeToleranceRate, 1)
        XCTAssertEqual(summary.canonicalTaskCodeRate, 1)
        XCTAssertEqual(summary.canonicalActivityCodeRate, 1)
        XCTAssertEqual(summary.reasonableTaskCodeRate, 1)
        XCTAssertEqual(summary.reasonableActivityCodeRate, 1)
        XCTAssertTrue(summary.passesHardGates)
    }

    @MainActor
    func testSemanticScoringAllowsDefensibleAlternativeButRejectsUnrelatedCanonicalCode() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        XCTAssertTrue(fixture.expectations[0].acceptableTaskCodes.contains("L310"))
        XCTAssertTrue(fixture.expectations[0].acceptableTaskCodes.contains("L350"))

        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        let defensibleAlternative = canonical.replacingOccurrences(of: "L310", with: "L350")
        let alternativeScore = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: defensibleAlternative
        ).lineScores[0]
        XCTAssertTrue(alternativeScore.taskCodeCanonical)
        XCTAssertTrue(alternativeScore.taskCodeReasonable)

        let unrelatedCanonical = canonical.replacingOccurrences(of: "L310", with: "L500")
        let unrelatedScore = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: unrelatedCanonical
        ).lineScores[0]
        XCTAssertTrue(unrelatedScore.taskCodeCanonical, "L500 is a real litigation code")
        XCTAssertFalse(unrelatedScore.taskCodeReasonable, "an appeal code is not reasonable for written discovery")
    }

    @MainActor
    func testSystemPromptRequiresOneLineForTimestampBoundaryPair() {
        let prompt = BillingDraftPrompt.system()

        XCTAssertTrue(prompt.contains("produce exactly one line citing both boundary note ids"))
        XCTAssertTrue(prompt.contains("count the elapsed interval once"))
        XCTAssertTrue(prompt.contains("Whenever taskCode or activityCode is null"))
    }

    @MainActor
    func testCanonicalUniqueClientInferencePassesProductionPath() async throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[15]
        let outcome = await ScratchPadBillingFidelityHarness.runFixture(
            fixture,
            timekeeper: BillingTimekeeper(
                id: "synthetic-tk",
                name: "Synthetic Timekeeper",
                classification: "PARTNER",
                defaultRate: 500,
                lawFirmID: "synthetic-firm"
            )
        ) { _, _ in
            ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        }

        XCTAssertNil(outcome.generationError)
        XCTAssertFalse(outcome.authorizationRejected)
        XCTAssertEqual(outcome.outputLineCount, 3)
        XCTAssertTrue(outcome.lineScores.allSatisfy(\.matterCorrect))
    }

    @MainActor
    func testProductionPathPersistsNormalizedCodesAndFiltersExcludedEvidence() async throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let invalidCodes = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
            .replacingOccurrences(of: "L310", with: "L999")
            .replacingOccurrences(of: "A103", with: "A120")
        let outcome = await ScratchPadBillingFidelityHarness.runFixture(
            fixture,
            timekeeper: BillingTimekeeper(
                id: "synthetic-tk",
                name: "Synthetic Timekeeper",
                classification: "PARTNER",
                defaultRate: 500,
                lawFirmID: "synthetic-firm"
            )
        ) { _, _ in invalidCodes }

        XCTAssertTrue(outcome.firstPassJSONValid)
        XCTAssertEqual(outcome.outputLineCount, 1)
        XCTAssertNil(outcome.lineScores[0].actualTaskCode, "production validation drops an invalid task code")
        XCTAssertNil(outcome.lineScores[0].actualActivityCode, "production validation drops an invalid activity code")
        XCTAssertFalse(outcome.lineScores[0].taskCodeCanonical)
        XCTAssertFalse(outcome.lineScores[0].activityCodeCanonical)
        XCTAssertFalse(outcome.lineScores[0].taskCodeReasonable)
        XCTAssertFalse(outcome.lineScores[0].activityCodeReasonable)
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])
        XCTAssertEqual(summary.canonicalTaskCodeRate, 0)
        XCTAssertEqual(summary.canonicalActivityCodeRate, 0)
    }

    @MainActor
    func testInvalidRawCodeDroppedToAllowedBlankStillFailsCanonicalGate() async throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[6]
        let invalidTaskCode = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
            .replacingOccurrences(of: "\"taskCode\":null", with: "\"taskCode\":\"L999\"")
        let outcome = await ScratchPadBillingFidelityHarness.runFixture(
            fixture,
            timekeeper: BillingTimekeeper(
                id: "synthetic-tk",
                name: "Synthetic Timekeeper",
                classification: "PARTNER",
                defaultRate: 500,
                lawFirmID: "synthetic-firm"
            )
        ) { _, _ in invalidTaskCode }

        XCTAssertNil(outcome.lineScores[0].actualTaskCode)
        XCTAssertTrue(outcome.lineScores[0].allowsBlankTaskCode)
        XCTAssertFalse(outcome.lineScores[0].taskCodeCanonical)
        XCTAssertFalse(outcome.lineScores[0].taskCodeReasonable)
        XCTAssertFalse(ScratchPadBillingFidelitySummary(outcomes: [outcome]).passesHardGates)
    }

    @MainActor
    func testProductionPathPromptExcludesNoteCanaryAndItsAttachment() async throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures().first { !$0.attachments.isEmpty }!
        var capturedPrompt = ""
        _ = await ScratchPadBillingFidelityHarness.runFixture(
            fixture,
            timekeeper: BillingTimekeeper(
                id: "synthetic-tk",
                name: "Synthetic Timekeeper",
                classification: "PARTNER",
                defaultRate: 500,
                lawFirmID: "synthetic-firm"
            )
        ) { _, userPrompt in
            capturedPrompt = userPrompt
            return ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        }

        XCTAssertFalse(capturedPrompt.contains("BILLING_CANARY_DO_NOT_USE"))
        XCTAssertFalse(capturedPrompt.contains("excluded-canary.txt"))
        XCTAssertTrue(capturedPrompt.contains("licensing-risk-review.txt"))
    }

    @MainActor
    func testUnexpectedDuplicateOutputIsReportedAndFailsTheGate() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
        var lines = try XCTUnwrap(object["lineItems"] as? [[String: Any]])
        lines.append(try XCTUnwrap(lines.first))
        object["lineItems"] = lines
        let duplicated = String(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!

        let outcome = ScratchPadBillingFidelityScorer.score(fixture: fixture, rawModelText: duplicated)
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])

        XCTAssertEqual(outcome.outputLineCount, 2)
        XCTAssertEqual(outcome.normalizedOutputLines.count, 2)
        XCTAssertEqual(outcome.unexpectedOutputLineCount, 1)
        XCTAssertEqual(summary.unexpectedOutputLineCount, 1)
        XCTAssertFalse(summary.passesHardGates)
    }

    @MainActor
    func testRawExtraRejectedDuringPersistenceDoesNotContaminatePersistedUnexpectedLineGate() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
        var lines = try XCTUnwrap(object["lineItems"] as? [[String: Any]])
        lines.append(try XCTUnwrap(lines.first))
        object["lineItems"] = lines
        let duplicatedRaw = String(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!

        let outcome = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: duplicatedRaw,
            normalizedModelText: canonical
        )
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])

        XCTAssertEqual(outcome.rawOutputLineCount, 2)
        XCTAssertEqual(outcome.outputLineCount, 1)
        XCTAssertEqual(outcome.rawUnexpectedOutputLineCount, 1)
        XCTAssertEqual(outcome.unexpectedOutputLineCount, 0)
        XCTAssertEqual(summary.rawUnexpectedOutputLineCount, 1)
        XCTAssertEqual(summary.unexpectedOutputLineCount, 0)
        XCTAssertTrue(summary.passesHardGates)
    }

    @MainActor
    func testAuthorizationRejectionPreservesSeparateRawModelScoresInReport() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        let outcome = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: canonical,
            normalizedModelText: #"{"lineItems":[]}"#,
            generationError: "localized authorization failure",
            authorizationRejected: true
        )
        let encoded = try JSONEncoder().encode(outcome)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rawScores = try XCTUnwrap(report["rawModelLineScores"] as? [[String: Any]])

        XCTAssertEqual(rawScores.first?["matterCorrect"] as? Bool, true)
        XCTAssertEqual(outcome.lineScores.first?.matterCorrect, false)
        XCTAssertEqual(report["authorizationRejected"] as? Bool, true)
    }

    @MainActor
    func testLegacyV2OutcomeAndSummaryDecodeWithRawMetricDefaults() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let outcome = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        )
        var outcomeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome)) as? [String: Any]
        )
        outcomeObject.removeValue(forKey: "rawModelLineScores")
        outcomeObject.removeValue(forKey: "authorizationRejected")
        outcomeObject.removeValue(forKey: "rawUnexpectedOutputLineCount")
        let legacyOutcome = try JSONDecoder().decode(
            ScratchPadBillingFidelityOutcome.self,
            from: JSONSerialization.data(withJSONObject: outcomeObject, options: [.sortedKeys])
        )

        XCTAssertEqual(legacyOutcome.rawModelLineScores.count, legacyOutcome.lineScores.count)
        XCTAssertFalse(legacyOutcome.authorizationRejected)
        XCTAssertEqual(legacyOutcome.rawUnexpectedOutputLineCount, legacyOutcome.unexpectedOutputLineCount)

        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])
        var summaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        )
        for key in [
            "rawModelMatterAccuracyRate",
            "rawModelSourceAttributionRate",
            "rawModelReasonableTaskCodeRate",
            "rawModelReasonableActivityCodeRate",
            "authorizationRejectedFixtureCount",
            "rawUnexpectedOutputLineCount",
        ] {
            summaryObject.removeValue(forKey: key)
        }
        let legacySummary = try JSONDecoder().decode(
            ScratchPadBillingFidelitySummary.self,
            from: JSONSerialization.data(withJSONObject: summaryObject, options: [.sortedKeys])
        )

        XCTAssertEqual(legacySummary.rawModelMatterAccuracyRate, legacySummary.matterAccuracyRate)
        XCTAssertEqual(legacySummary.rawModelSourceAttributionRate, legacySummary.sourceAttributionRate)
        XCTAssertEqual(legacySummary.rawModelReasonableTaskCodeRate, legacySummary.reasonableTaskCodeRate)
        XCTAssertEqual(legacySummary.rawModelReasonableActivityCodeRate, legacySummary.reasonableActivityCodeRate)
        XCTAssertEqual(legacySummary.authorizationRejectedFixtureCount, 0)
        XCTAssertEqual(legacySummary.rawUnexpectedOutputLineCount, legacySummary.unexpectedOutputLineCount)
    }

    @MainActor
    func testDroppedCodesGainReviewNoteButStillFailCanonicalGate() async throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
        var lines = try XCTUnwrap(object["lineItems"] as? [[String: Any]])
        lines[0]["taskCode"] = "L999"
        lines[0]["activityCode"] = "A120"
        lines[0].removeValue(forKey: "codeNote")
        object["lineItems"] = lines
        let invalid = String(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!
        let outcome = await ScratchPadBillingFidelityHarness.runFixture(
            fixture,
            timekeeper: BillingTimekeeper(
                id: "synthetic-tk",
                name: "Synthetic Timekeeper",
                classification: "PARTNER",
                defaultRate: 500,
                lawFirmID: "synthetic-firm"
            )
        ) { _, _ in invalid }
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])

        XCTAssertNil(outcome.lineScores[0].actualTaskCode)
        XCTAssertNil(outcome.lineScores[0].actualActivityCode)
        let codeNote = try XCTUnwrap(outcome.lineScores[0].actualCodeNote)
        XCTAssertTrue(codeNote.contains("Rejected unsupported task code L999."))
        XCTAssertTrue(codeNote.contains("Rejected unsupported activity code A120."))
        XCTAssertTrue(outcome.lineScores[0].abstentionJustified)
        XCTAssertEqual(summary.justifiedAbstentionRate, 1)
        XCTAssertFalse(outcome.lineScores[0].taskCodeCanonical)
        XCTAssertFalse(outcome.lineScores[0].activityCodeCanonical)
        XCTAssertFalse(summary.passesHardGates)
    }

    @MainActor
    func testBlankCodesWithPlaceholderCodeNoteFailReviewabilityGate() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
        var lines = try XCTUnwrap(object["lineItems"] as? [[String: Any]])
        lines[0]["taskCode"] = NSNull()
        lines[0]["activityCode"] = NSNull()
        lines[0]["codeNote"] = "x"
        object["lineItems"] = lines
        let placeholder = String(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!

        let outcome = ScratchPadBillingFidelityScorer.score(fixture: fixture, rawModelText: placeholder)
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])

        XCTAssertFalse(outcome.lineScores[0].abstentionJustified)
        XCTAssertEqual(summary.justifiedAbstentionRate, 0)
        XCTAssertFalse(summary.passesHardGates)
    }

    @MainActor
    func testInferredDurationWithoutEvidenceFailsHardGate() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[10]
        let canonical = ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
        var lines = try XCTUnwrap(object["lineItems"] as? [[String: Any]])
        lines[0]["evidence"] = ""
        object["lineItems"] = lines
        let missingEvidence = String(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!

        let outcome = ScratchPadBillingFidelityScorer.score(fixture: fixture, rawModelText: missingEvidence)
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])

        XCTAssertEqual(summary.inferredTimeEvidenceRate, 0)
        XCTAssertFalse(summary.passesHardGates)
    }

    func testProbeTimeoutClockResolvesWhileMainActorOperationIsBlocked() async {
        let clock = ContinuousClock()
        let started = clock.now

        let result = await Task.detached {
            do {
                let _: String = try await ScratchPadBillingFidelityTimeout.value(
                    after: .milliseconds(20)
                ) {
                    blockCurrentThreadForTimeoutRegression()
                    return "late"
                }
                return false
            } catch {
                return error as? ScratchPadBillingFidelityTimeoutError == .timedOut
            }
        }.value

        XCTAssertTrue(result)
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(150))
    }

    @MainActor
    func testProbeTimeoutReturnsBeforeSuspendedOperationCompletesAndCancelsIt() async {
        let clock = ContinuousClock()
        let started = clock.now
        var operationWasCancelled = false

        do {
            let _: String = try await ScratchPadBillingFidelityTimeout.value(
                after: .milliseconds(20)
            ) {
                do {
                    try await Task.sleep(for: .seconds(10))
                    return "late"
                } catch {
                    operationWasCancelled = Task.isCancelled
                    throw error
                }
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ScratchPadBillingFidelityTimeoutError, .timedOut)
        }

        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(500))
        await Task.yield()
        XCTAssertTrue(operationWasCancelled)
    }

    @MainActor
    func testMalformedOutputFailsWithoutInventingScores() {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let outcome = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: "not json"
        )
        let summary = ScratchPadBillingFidelitySummary(outcomes: [outcome])

        XCTAssertFalse(outcome.firstPassJSONValid)
        XCTAssertTrue(outcome.lineScores.allSatisfy { $0.matchedOutputIndex == nil })
        XCTAssertEqual(summary.firstPassJSONValidityRate, 0)
        XCTAssertEqual(summary.matterAccuracyRate, 0)
        XCTAssertEqual(summary.narrativeSubjectRate, 0)
        XCTAssertFalse(summary.passesHardGates)
    }

    @MainActor
    func testReportCarriesEveryNarrativeAndCodeSetScoringInput() throws {
        let fixture = ScratchPadBillingFidelityHarness.standardFixtures()[0]
        let outcome = ScratchPadBillingFidelityScorer.score(
            fixture: fixture,
            rawModelText: ScratchPadBillingFidelityHarness.canonicalJSON(for: fixture)
        )
        let line = try XCTUnwrap(outcome.lineScores.first)

        XCTAssertEqual(line.narrativeTermGroups, fixture.expectations[0].narrativeTermGroups)
        XCTAssertEqual(line.billingCodeSet, BillingCodeSet.litigation.rawValue)
        let encoded = try JSONEncoder().encode(outcome)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let lineScores = try XCTUnwrap(decoded["lineScores"] as? [[String: Any]])
        XCTAssertNotNil(lineScores.first?["narrativeTermGroups"])
        XCTAssertEqual(lineScores.first?["billingCodeSet"] as? String, "litigation")
    }
}