import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class ExhaustiveListTaskTests: XCTestCase {
    private static let modelArtifact = FrozenModelArtifactProbe(
        repository: "synthetic/exhaustive-runtime",
        revision: "0123456789abcdef0123456789abcdef01234567",
        contentBindingAlgorithm: "supra-release-model-sha256-v1",
        contentBindingSchemaVersion: 1,
        artifactFingerprintSHA256: String(repeating: "7", count: 64)
    )
    private static let modelLineageJSON = #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/exhaustive-runtime","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#

    func testTEVID01ExactQuotesWithAbsentAndCorrectModelOffsetsAreLocatedByHost() async throws {
        // T-EVID-01 expected RED: the mapper ignores emitted quote/span fields and
        // persists the model's whole-revision locator/excerpt instead of validating
        // the frozen text and deriving exact Character ranges on the host. Model
        // offsets are optional: an exact unique quote works without them, while
        // a supplied slice-relative span must agree with the host-derived absolute range.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exact quote evidence")
        let characterBudget = 241
        let prefix = "PREFIX-219-NONDEFAULT 👩🏽‍⚖️ | "
        let absentOffsetQuote = "Payment was due on October 17, 2031 in the amount of $731.42."
        let explicitSpanQuote = "Notice was delivered at 9:41 p.m. 🇺🇳."
        let suffix = " | SUFFIX-887-NONDEFAULT"
        let absentExpectedStart = prefix.count
        let absentExpectedEnd = absentExpectedStart + absentOffsetQuote.count
        let explicitExpectedStart = characterBudget * 3 + 37
        let bridge = String(
            repeating: "B",
            count: explicitExpectedStart - absentExpectedEnd
        )
        let sourceText = prefix + absentOffsetQuote + bridge + explicitSpanQuote + suffix
        XCTAssertNotEqual(sourceText.count, sourceText.utf8.count)
        XCTAssertNotEqual(sourceText.count, sourceText.utf16.count)
        let explicitExpectedEnd = explicitExpectedStart + explicitSpanQuote.count
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "exact-quote-schedule.txt",
            partTexts: [sourceText]
        )
        let inputProbe = ListPartitionProbe()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "exact-quote-host-derived-locator-run",
                matterID: matter.id,
                title: "Exact quoted payment",
                query: "Extract both exact quoted sentences.",
                characterBudget: characterBudget,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            await inputProbe.record(input)
            let source = try XCTUnwrap(input.partition.sources.first)
            var items: [SyntheticQuotedItem] = []
            if source.text.contains(absentOffsetQuote) {
                items.append(SyntheticQuotedItem(
                    itemKey: "exact-payment-sentence-219",
                    value: absentOffsetQuote,
                    evidence: [.init(quote: absentOffsetQuote)]
                ))
            }
            if source.text.contains(explicitSpanQuote) {
                let relativeRange = try XCTUnwrap(
                    Self.characterRange(of: explicitSpanQuote, in: source.text)
                )
                items.append(SyntheticQuotedItem(
                    itemKey: "exact-notice-sentence-443",
                    value: explicitSpanQuote,
                    evidence: [.init(
                        quote: explicitSpanQuote,
                        charStart: relativeRange.lowerBound,
                        charEnd: relativeRange.upperBound
                    )]
                ))
            }
            return try Self.quotedResponse(input, items: items)
        }

        let mapperInputs = await inputProbe.inputs
        let explicitSource = try XCTUnwrap(mapperInputs.flatMap(\.partition.sources).first {
            $0.text.contains(explicitSpanQuote)
        })
        let absentSource = try XCTUnwrap(mapperInputs.flatMap(\.partition.sources).first {
            $0.text.contains(absentOffsetQuote)
        })
        XCTAssertFalse(absentSource.text.contains(explicitSpanQuote))
        XCTAssertFalse(explicitSource.text.contains(absentOffsetQuote))
        let explicitSliceLocator = try JSONDecoder().decode(
            DocumentSourceLocator.self,
            from: Data(explicitSource.locatorJSON.utf8)
        )
        let explicitSliceStart = try XCTUnwrap(explicitSliceLocator.charStart)
        let suppliedRelativeRange = try XCTUnwrap(
            Self.characterRange(of: explicitSpanQuote, in: explicitSource.text)
        )
        XCTAssertGreaterThan(explicitSliceStart, 0)
        XCTAssertNotEqual(suppliedRelativeRange.lowerBound, explicitExpectedStart)
        XCTAssertEqual(
            explicitSliceStart + suppliedRelativeRange.lowerBound,
            explicitExpectedStart
        )
        XCTAssertEqual(
            explicitSliceStart + suppliedRelativeRange.upperBound,
            explicitExpectedEnd
        )

        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        let outputSources = try store.documentSources.fetchSources(
            structuredOutputVersionID: result.version.id
        )
        XCTAssertEqual(outputSources.count, 2)
        XCTAssertEqual(Set(outputSources.compactMap(\.revisionID)), Set(fixture.revisionIDs))
        let expectedRanges = [
            absentOffsetQuote: absentExpectedStart..<absentExpectedEnd,
            explicitSpanQuote: explicitExpectedStart..<explicitExpectedEnd,
        ]
        for source in outputSources {
            let expectedRange = try XCTUnwrap(expectedRanges[source.excerpt])
            let locator = try JSONDecoder().decode(
                DocumentSourceLocator.self,
                from: Data(source.locatorJSON.utf8)
            )
            XCTAssertEqual(locator.charStart, expectedRange.lowerBound)
            XCTAssertNotEqual(locator.charStart, 0, "the old whole-revision locator start must be absent")
            XCTAssertEqual(locator.charEnd, expectedRange.upperBound)
            XCTAssertNotEqual(locator.charEnd, sourceText.count, "the old whole-revision locator end must be absent")
            XCTAssertEqual(
                Self.substring(sourceText, from: expectedRange.lowerBound, to: expectedRange.upperBound),
                source.excerpt
            )
        }

        let verificationJSON = try XCTUnwrap(result.version.verificationJSON)
        let support = try DateCoding.decoder.decode(
            [PropositionSupportResult].self,
            from: Data(verificationJSON.utf8)
        )
        XCTAssertEqual(support.count, 2)
        XCTAssertTrue(support.allSatisfy { $0.status == .supported })
        XCTAssertEqual(Set(support.flatMap(\.evidence).map(\.retainedExcerpt)), Set(expectedRanges.keys))
    }

    func testTEVID02FabricatedValueWithStructurallyValidRevisionEvidenceIsRejected() async throws {
        // T-EVID-02 expected RED: exhaustive-list support treats any structurally
        // valid primary evidence reference as supported without checking whether
        // the frozen source text supports the emitted value.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic fabricated-value rejection")
        let supportedValue = "$731.42"
        let fabricatedValue = "$9,913.77"
        let sourcePrefix = "NONDEFAULT-SCHEDULE-417 states the exact payment amount is "
        let sourceText = sourcePrefix + supportedValue + "."
        let supportedStart = sourcePrefix.count
        let supportedEnd = supportedStart + supportedValue.count
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "payment-schedule.txt",
            partTexts: [sourceText]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "fabricated-value-host-validation-run",
                matterID: matter.id,
                title: "Validated payment schedule",
                query: "Extract the exact scheduled payment amount.",
                characterBudget: 1_811,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            try Self.quotedResponse(
                input,
                itemKey: "scheduled-payment-417",
                value: fabricatedValue,
                quote: supportedValue,
                charStart: supportedStart,
                charEnd: supportedEnd
            )
        }

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.values, [fabricatedValue], "the rejected model value remains visible for review")
        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertNotEqual(result.version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        let verificationJSON = try XCTUnwrap(result.version.verificationJSON)
        let supportResults = try DateCoding.decoder.decode(
            [PropositionSupportResult].self,
            from: Data(verificationJSON.utf8)
        )
        let support = try XCTUnwrap(supportResults.first)
        XCTAssertEqual(support.status, .unsupported)
        XCTAssertFalse(support.evidence.isEmpty)
        XCTAssertEqual(support.evidence.first?.sourceID, fixture.revisionIDs.first)
        let retainedExcerpt = try XCTUnwrap(support.evidence.first?.retainedExcerpt)
        XCTAssertTrue(retainedExcerpt.contains(supportedValue))
        XCTAssertFalse(retainedExcerpt.contains(fabricatedValue))
        XCTAssertEqual(
            result.version.verificationDimensions.result(for: .propositionSupport).status,
            .failed
        )
        XCTAssertEqual(
            result.version.verificationDimensions.result(for: .criticalValueFidelity).status,
            .failed
        )
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
    }

    func testTEVID03MismatchedAmbiguousAndOutOfRangeEvidenceFailsClosed() async throws {
        // T-EVID-01 expected RED: evidence decoding ignores quote/span fields,
        // so conflicting offsets, an absent quote, an ambiguous repeated quote,
        // and an out-of-range slice span all pass structural revision checks.
        let attacks = [
            ExactEvidenceAttack(
                id: "wrong-offsets-173",
                sourceText: "PREFIX-173-NONDEFAULT | UNIQUE-QUOTE-173-NONDEFAULT",
                value: "UNIQUE-QUOTE-173-NONDEFAULT",
                evidence: .init(
                    quote: "UNIQUE-QUOTE-173-NONDEFAULT",
                    charStart: 0,
                    charEnd: 1
                )
            ),
            ExactEvidenceAttack(
                id: "mismatched-quote-311",
                sourceText: "MISMATCH-SOURCE-311-NONDEFAULT",
                value: "MISMATCH-SOURCE-311-NONDEFAULT",
                evidence: .init(quote: "ABSENT-QUOTE-311-NONDEFAULT")
            ),
            ExactEvidenceAttack(
                id: "ambiguous-quote-577",
                sourceText: "REPEATED-QUOTE-577-NONDEFAULT | REPEATED-QUOTE-577-NONDEFAULT",
                value: "REPEATED-QUOTE-577-NONDEFAULT",
                evidence: .init(quote: "REPEATED-QUOTE-577-NONDEFAULT")
            ),
            ExactEvidenceAttack(
                id: "out-of-range-span-839",
                sourceText: "OUT-OF-RANGE-SPAN-839-NONDEFAULT",
                value: "OUT-OF-RANGE-SPAN-839-NONDEFAULT",
                evidence: .init(quote: nil, charStart: 71, charEnd: 79)
            ),
        ]

        for attack in attacks {
            let store = try makeStore()
            let matter = try store.matters.createMatter(name: "Synthetic rejected evidence \(attack.id)")
            _ = try insertDocument(
                store: store,
                matterID: matter.id,
                name: "\(attack.id).txt",
                partTexts: [attack.sourceText]
            )
            let result = try await ExhaustiveListTask(store: store).run(
                request: ExhaustiveListRequest(
                    runKey: "\(attack.id)-run",
                    matterID: matter.id,
                    title: "Rejected exact evidence \(attack.id)",
                    query: "Extract only values supported by unambiguous exact evidence.",
                    characterBudget: 2_117,
                    modelLineageJSON: Self.modelLineageJSON
                )
            ) { input in
                try Self.quotedResponse(
                    input,
                    items: [SyntheticQuotedItem(
                        itemKey: attack.id,
                        value: attack.value,
                        evidence: [attack.evidence]
                    )]
                )
            }

            XCTAssertEqual(result.coverage.partitionCount, 1, attack.id)
            XCTAssertEqual(result.coverage.failedPartitionCount, 1, attack.id)
            XCTAssertEqual(result.coverage.succeededPartitionCount, 0, attack.id)
            XCTAssertTrue(result.items.isEmpty, attack.id)
            XCTAssertEqual(
                result.version.verificationStatus,
                OutputVerificationStatus.needsReview.rawValue,
                attack.id
            )
            XCTAssertNotEqual(
                result.version.verificationStatus,
                OutputVerificationStatus.allSupported.rawValue,
                attack.id
            )
            let output = try XCTUnwrap(
                store.structuredOutputs.fetchOutputs(matterID: matter.id).first,
                attack.id
            )
            XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue, attack.id)
            let partition = try XCTUnwrap(result.partitions.first, attack.id)
            XCTAssertFalse(partition.errorSummary?.isEmpty ?? true, attack.id)
        }
    }

    func testTEVID04PrimaryAndContraryEvidenceMustComeFromThePresentedSlice() async throws {
        // T-EVID-01 expected RED: revision-level validation may resolve a valid
        // quote anywhere in the frozen revision, even when that span was not in
        // the mapper's exact slice. The same boundary must cover contrary_evidence.
        let headQuote = "HEAD-SHOWN-QUOTE-137-NONDEFAULT"
        let tailQuote = "TAIL-UNSHOWN-QUOTE-941-NONDEFAULT"
        let revisionText = headQuote
            + String(repeating: "X", count: 3_119)
            + "👩🏽‍⚖️|e\u{301}|"
            + String(repeating: "Y", count: 3_127)
            + tailQuote
        for path in [UnshownEvidencePath.primary, .contrary] {
            let store = try makeStore()
            let matter = try store.matters.createMatter(
                name: "Synthetic unshown \(path.rawValue) rejection"
            )
            _ = try insertDocument(
                store: store,
                matterID: matter.id,
                name: "unshown-tail-\(path.rawValue)-evidence.txt",
                partTexts: [revisionText]
            )
            let inputProbe = ListPartitionProbe()

            let result = try await ExhaustiveListTask(store: store).run(
                request: ExhaustiveListRequest(
                    runKey: "unshown-\(path.rawValue)-evidence-run",
                    matterID: matter.id,
                    title: "Presented-slice \(path.rawValue) evidence boundary",
                    query: "Extract only values whose exact evidence was shown in this partition.",
                    characterBudget: 521,
                    modelLineageJSON: Self.modelLineageJSON
                )
            ) { input in
                await inputProbe.record(input)
                let presentedText = input.partition.sources.map(\.text).joined()
                guard presentedText.contains(headQuote) else {
                    return try Self.quotedResponse(input, items: [])
                }
                let item: SyntheticQuotedItem = switch path {
                case .primary:
                    SyntheticQuotedItem(
                        itemKey: "unshown-primary-941",
                        value: tailQuote,
                        evidence: [.init(quote: tailQuote)]
                    )
                case .contrary:
                    SyntheticQuotedItem(
                        itemKey: "unshown-contrary-941",
                        value: headQuote,
                        evidence: [.init(quote: headQuote)],
                        contraryEvidence: [.init(quote: tailQuote)]
                    )
                }
                return try Self.quotedResponse(input, items: [item])
            }

            let recordedInputs = await inputProbe.inputs
            let attackedInputs = recordedInputs.filter {
                $0.partition.sources.contains { $0.text.contains(headQuote) }
            }
            XCTAssertEqual(attackedInputs.count, 1, path.rawValue)
            let attackedText = try XCTUnwrap(
                attackedInputs.first,
                path.rawValue
            ).partition.sources.map(\.text).joined()
            XCTAssertFalse(
                attackedText.contains(tailQuote),
                "\(path.rawValue): the cited revision span must not have been shown to this mapper"
            )
            XCTAssertEqual(result.coverage.failedPartitionCount, 1, path.rawValue)
            XCTAssertTrue(result.items.isEmpty, path.rawValue)
            XCTAssertEqual(
                result.version.verificationStatus,
                OutputVerificationStatus.needsReview.rawValue,
                path.rawValue
            )
            let persistedSources = try store.documentSources.fetchSources(
                structuredOutputVersionID: result.version.id
            )
            XCTAssertFalse(
                persistedSources.contains { $0.excerpt.contains(tailQuote) },
                path.rawValue
            )
        }
    }

    func testTCORP04WholeMatterMembershipAndEligibilityDriftUsesFrozenLineageAndMarksStale() async throws {
        // T-CORP-04 expected RED: staleness compares revision IDs only for frozen
        // eligible members; an added whole-matter source and eligibility change are
        // missed, while output lineage is rebuilt from the mutated live scope.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic frozen scope drift")
        let original = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "frozen-scope-original.txt",
            partTexts: ["FROZEN-SCOPE-VALUE-613-NONDEFAULT"]
        )
        let mutation = ListScopeDriftProbe()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "whole-matter-membership-drift-run",
                matterID: matter.id,
                title: "Frozen-scope lineage review",
                query: "Extract the frozen-scope value.",
                scope: .wholeMatter,
                characterBudget: 1_919,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            if await mutation.claimMutation() {
                let added = try insertListFixtureDocument(
                    store: store,
                    matterID: matter.id,
                    name: "added-after-freeze.txt",
                    partTexts: ["ADDED-IN-SCOPE-VALUE-827-NONDEFAULT"]
                )
                await mutation.recordAddedDocumentID(added.documentID)
                try store.documentLibrary.updateStatus(
                    documentID: original.documentID,
                    status: .needsReview
                )
            }
            return try Self.quotedResponse(
                input,
                itemKey: "frozen-scope-value-613",
                value: "FROZEN-SCOPE-VALUE-613-NONDEFAULT",
                quote: "FROZEN-SCOPE-VALUE-613-NONDEFAULT",
                charStart: nil,
                charEnd: nil
            )
        }

        let capturedAddedDocumentID = await mutation.addedDocumentID
        let addedDocumentID = try XCTUnwrap(capturedAddedDocumentID)
        let snapshot = try JSONDecoder().decode(
            CorpusAnalysisSnapshot.self,
            from: Data(result.run.corpusSnapshotJSON.utf8)
        )
        XCTAssertEqual(snapshot.members.compactMap(\.documentID), [original.documentID])
        XCTAssertFalse(snapshot.members.compactMap(\.documentID).contains(addedDocumentID))
        XCTAssertEqual(snapshot.members.first?.disposition, .eligible)
        let partitionKeyByID = Dictionary(
            uniqueKeysWithValues: result.partitions.map { ($0.id, $0.partitionKey) }
        )
        let frozenSlices = try store.corpusAnalysis.fetchSlices(
            matterID: matter.id,
            runID: result.run.id
        ).map {
            FrozenSliceLineageProbe(
                partitionKey: try XCTUnwrap(partitionKeyByID[$0.partitionID]),
                ordinal: $0.ordinal,
                memberKey: $0.memberKey,
                documentID: $0.documentID,
                partIndex: $0.partIndex,
                revisionID: $0.revisionID,
                charStart: $0.charStart,
                charEnd: $0.charEnd,
                revisionCharCount: $0.revisionCharCount,
                textSHA256: $0.textSHA256,
                locator: try JSONDecoder().decode(
                    DocumentSourceLocator.self,
                    from: Data($0.locatorJSON.utf8)
                )
            )
        }
        let frozenLineageHash = try Self.frozenCorpusLineageHash(
            snapshot: snapshot,
            slices: frozenSlices
        )

        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.stale.rawValue)
        let reasonsJSON = try XCTUnwrap(result.run.assuranceReasonsJSON)
        let reasons = try JSONDecoder().decode([String].self, from: Data(reasonsJSON.utf8))
        XCTAssertTrue(reasons.contains { $0.contains(original.documentID) }, "eligibility drift must name the frozen member")
        XCTAssertTrue(reasons.contains { $0.contains(addedDocumentID) }, "membership drift must name the added in-scope member")

        let sourceSet = try XCTUnwrap(store.documentSources.fetchSourceSet(
            structuredOutputVersionID: result.version.id
        ))
        let persistedLineageHash = try XCTUnwrap(sourceSet.corpusSnapshotHash)
        XCTAssertEqual(persistedLineageHash, frozenLineageHash)
        var revisionChangedSnapshot = snapshot
        let changedRevisionID = "revision-id-drift-997-nondefault"
        revisionChangedSnapshot.members[0].revisionIDs = [changedRevisionID]
        let revisionChangedSlices = frozenSlices.map { slice in
            var changed = slice
            changed.revisionID = changedRevisionID
            return changed
        }
        XCTAssertNotEqual(
            try Self.frozenCorpusLineageHash(
                snapshot: revisionChangedSnapshot,
                slices: revisionChangedSlices
            ),
            frozenLineageHash,
            "revision identity must remain content-significant even when every range and text hash is unchanged"
        )
        var ordinalChangedSlices = frozenSlices
        ordinalChangedSlices[0].ordinal += 17
        XCTAssertNotEqual(
            try Self.frozenCorpusLineageHash(
                snapshot: snapshot,
                slices: ordinalChangedSlices
            ),
            frozenLineageHash,
            "slice presentation order must be content-significant"
        )
        var partitionChangedSlices = frozenSlices
        partitionChangedSlices[0].partitionKey += "|regrouped-991-nondefault"
        XCTAssertNotEqual(
            try Self.frozenCorpusLineageHash(
                snapshot: snapshot,
                slices: partitionChangedSlices
            ),
            frozenLineageHash,
            "partition grouping must be content-significant"
        )
        var locatorChangedSlices = frozenSlices
        locatorChangedSlices[0].locator.pageLabel = "page-label-drift-983-nondefault"
        XCTAssertNotEqual(
            try Self.frozenCorpusLineageHash(
                snapshot: snapshot,
                slices: locatorChangedSlices
            ),
            frozenLineageHash,
            "citation locator metadata must be content-significant"
        )

        let outputSources = try store.documentSources.fetchSources(
            structuredOutputVersionID: result.version.id
        )
        XCTAssertEqual(Set(outputSources.compactMap(\.documentID)), [original.documentID])
        XCTAssertFalse(outputSources.compactMap(\.documentID).contains(addedDocumentID))
        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: original.documentID)?.status,
            MatterDocumentStatus.needsReview.rawValue
        )
    }

    func testTCORP05ChangedSemanticRequestCannotReuseRunKeyOrAttachedOutput() async throws {
        // T-CORP-05 expected RED: run-key collision checks omit the exhaustive-list
        // query/task request digest and the run record has no v2 request identity.
        // An exact retry must remain idempotent, while a query-only mutation fails
        // before returning or replacing the first attached output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic request digest collision")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "request-digest-source.txt",
            partTexts: ["REQUEST-DIGEST-VALUE-541-NONDEFAULT"]
        )
        let runKey = "semantic-request-digest-run-key"
        let title = "Stable presentation title"
        let firstQuery = "Extract the request-digest value 541."
        let changedQuery = "Extract a materially different termination-date field 977."
        let firstRequest = ExhaustiveListRequest(
            runKey: runKey,
            matterID: matter.id,
            title: title,
            query: firstQuery,
            characterBudget: 1_577,
            maximumRetryCount: 3,
            modelLineageJSON: Self.modelLineageJSON
        )
        let first = try await ExhaustiveListTask(store: store).run(
            request: firstRequest
        ) { input in
            try Self.quotedResponse(
                input,
                itemKey: "request-digest-value-541",
                value: "REQUEST-DIGEST-VALUE-541-NONDEFAULT",
                quote: "REQUEST-DIGEST-VALUE-541-NONDEFAULT",
                charStart: nil,
                charEnd: nil
            )
        }
        let beforeRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: first.run.id))
        let frozenSnapshot = try JSONDecoder().decode(
            CorpusAnalysisSnapshot.self,
            from: Data(beforeRun.corpusSnapshotJSON.utf8)
        )
        let partitionKeyByID = Dictionary(
            uniqueKeysWithValues: first.partitions.map { ($0.id, $0.partitionKey) }
        )
        let frozenSlices = try store.corpusAnalysis.fetchSlices(
            matterID: matter.id,
            runID: first.run.id
        ).map {
            FrozenSliceLineageProbe(
                partitionKey: try XCTUnwrap(partitionKeyByID[$0.partitionID]),
                ordinal: $0.ordinal,
                memberKey: $0.memberKey,
                documentID: $0.documentID,
                partIndex: $0.partIndex,
                revisionID: $0.revisionID,
                charStart: $0.charStart,
                charEnd: $0.charEnd,
                revisionCharCount: $0.revisionCharCount,
                textSHA256: $0.textSHA256,
                locator: try JSONDecoder().decode(
                    DocumentSourceLocator.self,
                    from: Data($0.locatorJSON.utf8)
                )
            )
        }
        let expectedRequestDigest = try Self.exhaustiveRequestDigest(
            matterID: matter.id,
            query: firstQuery,
            scope: firstRequest.scope,
            snapshot: frozenSnapshot,
            slices: frozenSlices,
            characterBudget: firstRequest.characterBudget,
            maximumRetryCount: firstRequest.maximumRetryCount,
            modelArtifact: Self.modelArtifact
        )
        XCTAssertEqual(beforeRun.requestSchemaVersion, 2)
        XCTAssertEqual(beforeRun.requestDigest, expectedRequestDigest)
        XCTAssertEqual(expectedRequestDigest.count, 64)
        XCTAssertEqual(expectedRequestDigest, expectedRequestDigest.lowercased())

        let exactRetryProbe = ListGeneratorProbe()
        let exactRetry = try await ExhaustiveListTask(store: store).run(
            request: firstRequest
        ) { input in
            await exactRetryProbe.recordCall()
            return try Self.response(input, items: [
                .init(
                    itemKey: "foreign-idempotency-value-883",
                    value: "FOREIGN-IDEMPOTENCY-VALUE-883-MUST-NOT-PERSIST",
                    evidence: [.primary]
                ),
            ])
        }
        let exactRetryCallCount = await exactRetryProbe.callCount
        XCTAssertEqual(exactRetryCallCount, 0)
        XCTAssertEqual(exactRetry.run.id, first.run.id)
        XCTAssertEqual(exactRetry.version.id, first.version.id)
        XCTAssertEqual(exactRetry.outputID, first.outputID)
        XCTAssertFalse(
            exactRetry.items.flatMap(\.values).contains("FOREIGN-IDEMPOTENCY-VALUE-883-MUST-NOT-PERSIST")
        )

        let changedGeneratorProbe = ListGeneratorProbe()
        var secondResult: ExhaustiveListResult?
        var collisionError: CorpusAnalysisEngineError?
        var unexpectedErrorDescription: String?

        do {
            secondResult = try await ExhaustiveListTask(store: store).run(
                request: ExhaustiveListRequest(
                    runKey: runKey,
                    matterID: matter.id,
                    title: title,
                    query: changedQuery,
                    characterBudget: 1_577,
                    maximumRetryCount: 3,
                    modelLineageJSON: Self.modelLineageJSON
                )
            ) { input in
                await changedGeneratorProbe.recordCall()
                return try Self.response(input, items: [
                    .init(
                        itemKey: "changed-termination-date-977",
                        value: "CHANGED-TERMINATION-DATE-977-NONDEFAULT",
                        evidence: [.primary]
                    ),
                ])
            }
        } catch let error as CorpusAnalysisEngineError {
            collisionError = error
        } catch {
            unexpectedErrorDescription = error.localizedDescription
        }

        XCTAssertNil(secondResult, "a changed request must not reuse the first attached output")
        XCTAssertEqual(collisionError, .runKeyCollision(runKey))
        XCTAssertNil(unexpectedErrorDescription)
        let changedGeneratorCallCount = await changedGeneratorProbe.callCount
        XCTAssertEqual(changedGeneratorCallCount, 0, "collision must fail before generation")
        let afterRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: first.run.id))
        XCTAssertEqual(afterRun.structuredOutputVersionID, first.version.id)
        XCTAssertEqual(afterRun.corpusSnapshotJSON, beforeRun.corpusSnapshotJSON)
        XCTAssertEqual(afterRun.reconciliationJSON, beforeRun.reconciliationJSON)
        XCTAssertEqual(afterRun.requestSchemaVersion, 2)
        XCTAssertEqual(afterRun.requestDigest, expectedRequestDigest)
        XCTAssertNotEqual(
            try Self.exhaustiveRequestDigest(
                matterID: matter.id,
                query: changedQuery,
                scope: firstRequest.scope,
                snapshot: frozenSnapshot,
                slices: frozenSlices,
                characterBudget: firstRequest.characterBudget,
                maximumRetryCount: firstRequest.maximumRetryCount,
                modelArtifact: Self.modelArtifact
            ),
            expectedRequestDigest,
            "the query-only mutation must change the independently computed request identity"
        )
        var otherArtifact = Self.modelArtifact
        otherArtifact.artifactFingerprintSHA256 = String(repeating: "8", count: 64)
        XCTAssertNotEqual(
            try Self.exhaustiveRequestDigest(
                matterID: matter.id,
                query: firstQuery,
                scope: firstRequest.scope,
                snapshot: frozenSnapshot,
                slices: frozenSlices,
                characterBudget: firstRequest.characterBudget,
                maximumRetryCount: firstRequest.maximumRetryCount,
                modelArtifact: otherArtifact
            ),
            expectedRequestDigest,
            "repository and revision alone must not collapse distinct model artifacts"
        )
        let outputs = try store.structuredOutputs.fetchOutputs(matterID: matter.id)
        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: first.outputID)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(versions.map(\.id), [first.version.id])
        let outputSources = try store.documentSources.fetchSources(structuredOutputVersionID: first.version.id)
        XCTAssertEqual(outputSources.compactMap(\.revisionID), fixture.revisionIDs)
        let generationID = try XCTUnwrap(first.version.generationSessionID)
        let generation = try XCTUnwrap(store.generation.fetchGenerationSession(generationID: generationID))
        XCTAssertTrue(generation.prompt.contains(firstQuery))
        XCTAssertFalse(generation.prompt.contains(changedQuery))
    }

    func testTCORP05NormalizedQueryIsTheOnlyQueryExecutedAndPersisted() async throws {
        // T-CORP-05 expected RED: request_digest collapses query whitespace but
        // the generator and generation audit receive the raw query, so a
        // whitespace-only payload mutation preserves identity while changing
        // the executed prompt bytes.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic normalized query execution")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "normalized-query-source.txt",
            partTexts: ["NORMALIZED-QUERY-SOURCE-1993-NONDEFAULT"]
        )
        let rawQuery = "Extract   every\n\t  normalized-query   value 1993."
        let normalizedQuery = "Extract every normalized-query value 1993."
        let probe = ListPartitionProbe()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "normalized-query-run-1993",
                matterID: matter.id,
                title: "Normalized query review",
                query: rawQuery,
                characterBudget: 1_993,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            await probe.record(input)
            return try Self.response(input, items: [])
        }

        let inputs = await probe.inputs
        XCTAssertFalse(inputs.isEmpty)
        XCTAssertTrue(inputs.allSatisfy { $0.prompt.contains(normalizedQuery) })
        XCTAssertTrue(inputs.allSatisfy { !$0.prompt.contains(rawQuery) })
        let generationID = try XCTUnwrap(result.version.generationSessionID)
        let generation = try XCTUnwrap(
            store.generation.fetchGenerationSession(generationID: generationID)
        )
        XCTAssertTrue(generation.prompt.contains(normalizedQuery))
        XCTAssertFalse(generation.prompt.contains(rawQuery))
    }

    func testTENG09ListReconcilesDuplicatesConflictsContraryEvidenceAndNamedOmissions() async throws {
        // T-ENG-09 expected RED: exhaustive-list schema, reconciliation, metrics, and atomic output linkage are missing.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exhaustive list")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "invoice-ledger.txt",
            partTexts: ["MAP-A", "MAP-A-DUPLICATE", "MAP-B-ONE", "MAP-B-CONFLICT-X"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-quality-run",
                matterID: matter.id,
                title: "Every invoice reference",
                query: "Extract every invoice reference.",
                characterBudget: 16,
                evaluationExpectedItemKeys: ["invoice-a", "invoice-b", "invoice-c"],
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            switch source.text {
            case "MAP-A":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-a", value: "$100", evidence: [.primary]),
                ])
            case "MAP-A-DUPLICATE":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-a", value: "$100", evidence: [.primary]),
                ])
            case "MAP-B-ONE":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-b", value: "$200", evidence: [.primary]),
                ])
            default:
                return try Self.response(input, items: [
                    .init(
                        itemKey: "invoice-b",
                        value: "$250",
                        evidence: [.primary],
                        contraryEvidence: [.primary]
                    ),
                    .init(itemKey: "invoice-x", value: "$999", evidence: [.primary]),
                ])
            }
        }

        XCTAssertEqual(Set(result.items.map(\.itemKey)), ["invoice-a", "invoice-b", "invoice-x"])
        let invoiceB = try XCTUnwrap(result.items.first { $0.itemKey == "invoice-b" })
        XCTAssertEqual(Set(invoiceB.values), ["$200", "$250"])
        XCTAssertEqual(invoiceB.contraryEvidence.count, 1)
        XCTAssertEqual(result.omissions.map(\.itemKey), ["invoice-c"])
        XCTAssertEqual(result.metrics.recall, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.metrics.precision, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.metrics.duplicateCount, 1)
        XCTAssertEqual(result.metrics.conflictCount, 1)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)

        let persistedRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: result.run.id))
        XCTAssertEqual(persistedRun.structuredOutputVersionID, result.version.id)
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.id, result.outputID)
        XCTAssertEqual(output.outputType, StructuredOutputType.documentExhaustiveList.rawValue)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertEqual(output.activeVersionID, result.version.id)
        let sourceSet = try XCTUnwrap(store.documentSources.fetchSourceSet(
            structuredOutputVersionID: result.version.id
        ))
        XCTAssertEqual(sourceSet.status, DocumentSourceSetStatus.attached.rawValue)
        XCTAssertNotNil(sourceSet.embeddingModelID, "T-LIN-01: engine source sets stamp embedding lineage")
        XCTAssertNotNil(sourceSet.embeddingModelRevision)
        XCTAssertNotNil(sourceSet.chunkerVersion)
        XCTAssertNotNil(sourceSet.retrievalConfigJSON)
        XCTAssertNotNil(sourceSet.corpusSnapshotHash)
        XCTAssertNotNil(sourceSet.packingReportJSON)
        let outputSources = try store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(Set(outputSources.compactMap(\.revisionID)), Set(fixture.revisionIDs))
        XCTAssertTrue(result.version.contentMarkdown.contains("invoice-c"))
        XCTAssertTrue(try XCTUnwrap(persistedRun.reconciliationJSON).contains("invoice-c"))
        let generationID = try XCTUnwrap(result.version.generationSessionID, "T-LIN-03: engine versions carry generation lineage")
        let generation = try XCTUnwrap(store.generation.fetchGenerationSession(generationID: generationID))
        XCTAssertEqual(generation.modelRepository, "synthetic/exhaustive-runtime")
        XCTAssertEqual(generation.modelRevision, Self.modelArtifact.revision)
        XCTAssertEqual(generation.promptBuilderVersion, "exhaustive-list-v1")
        XCTAssertEqual(result.version.promptBuilderVersion, "exhaustive-list-v1")
        XCTAssertEqual(result.version.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertTrue(generation.prompt.contains("Extract every invoice reference."))
        XCTAssertTrue(generation.optionsJSON.contains("character_budget"))
    }

    func testTENG10FailedPartitionPersistsIncompleteOutputWithNamedDocumentAndReason() async throws {
        // T-ENG-10 expected RED: failed partitions cannot yet produce an attached, explicitly incomplete list output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic incomplete list")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "partial-invoices.txt",
            partTexts: ["MAP-GOOD", "MAP-FAIL"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-incomplete-run",
                matterID: matter.id,
                title: "Incomplete invoice list",
                query: "Extract every invoice.",
                characterBudget: 8,
                evaluationExpectedItemKeys: ["invoice-good", "invoice-missing"],
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            if input.partition.sources.first?.text == "MAP-FAIL" {
                throw CorpusAnalysisMapFailure.permanent("synthetic forced map failure")
            }
            return try Self.response(input, items: [
                .init(itemKey: "invoice-good", value: "$100", evidence: [.primary]),
            ])
        }

        XCTAssertEqual(result.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertEqual(result.coverage.failedPartitionCount, 1)
        XCTAssertEqual(result.coverage.pendingPartitionCount, 0)
        XCTAssertEqual(result.omissions.map(\.itemKey), ["invoice-missing"])
        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertTrue(result.version.contentMarkdown.contains("Assurance: corpus_incomplete"))
        XCTAssertFalse(result.version.contentMarkdown.contains("Assurance: corpus_complete"))
        XCTAssertTrue(result.version.contentMarkdown.contains("partial-invoices.txt"))
        XCTAssertTrue(result.version.contentMarkdown.contains("synthetic forced map failure"))
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertEqual(
            try store.corpusAnalysis.fetchRun(matterID: matter.id, id: result.run.id)?.structuredOutputVersionID,
            result.version.id
        )
    }

    func testTENG11SchemaInvalidMapFailsPartitionAndPersistsOnlyResponseDigest() async throws {
        // T-ENG-11 expected RED: the typed engine mapper cannot receive or fail closed on malformed raw model output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic malformed list")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "malformed-list.txt",
            partTexts: ["MAP-MALFORMED"]
        )
        let malformed = #"{"schema_version":1,"items":[{"item_key":7,"value":"bad"}]}"#
        let expectedDigest = SHA256.hash(data: Data(malformed.utf8)).map { String(format: "%02x", $0) }.joined()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-schema-run",
                matterID: matter.id,
                title: "Malformed list",
                query: "Extract every reference.",
                characterBudget: 13,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { _ in malformed }

        let partition = try XCTUnwrap(result.partitions.first)
        XCTAssertEqual(partition.disposition, CorpusAnalysisPartitionDisposition.failed.rawValue)
        XCTAssertEqual(partition.dispositionReason, "schema_invalid")
        XCTAssertTrue(try XCTUnwrap(partition.errorSummary).contains(expectedDigest))
        XCTAssertTrue(partition.attemptHistoryJSON.contains(expectedDigest))
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.version.contentMarkdown.contains(malformed))
        XCTAssertFalse(try XCTUnwrap(result.run.reconciliationJSON).contains(malformed))
        XCTAssertTrue(result.version.contentMarkdown.contains(expectedDigest))
    }

    func testTENG12NegativeConclusionIsBlockedUnlessCoverageIsCompleteAndNoPositiveExists() async throws {
        // T-ENG-12 expected RED: no negative-conclusion gate maps inadequate coverage to negative_blocked.
        let incompleteStore = try makeStore()
        let incompleteMatter = try incompleteStore.matters.createMatter(name: "Synthetic blocked negative")
        _ = try insertDocument(
            store: incompleteStore,
            matterID: incompleteMatter.id,
            name: "blocked-negative.txt",
            partTexts: ["MAP-FAIL"]
        )
        let incomplete = try await ExhaustiveListTask(store: incompleteStore).run(
            request: ExhaustiveListRequest(
                runKey: "negative-blocked-run",
                matterID: incompleteMatter.id,
                title: "Blocked negative",
                query: "Find any termination reference.",
                characterBudget: 8,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { _ in throw CorpusAnalysisMapFailure.permanent("synthetic negative probe failure") }
        let blocked = CorpusNegativeGate.evaluate(
            run: incomplete.run,
            coverage: incomplete.coverage,
            positiveFindingCount: incomplete.items.count
        )
        XCTAssertFalse(blocked.allowed)
        XCTAssertEqual(blocked.assuranceState, .negativeBlocked)
        XCTAssertTrue(blocked.reasons.contains { $0.contains("failed") || $0.contains("incomplete") })

        let completeStore = try makeStore()
        let completeMatter = try completeStore.matters.createMatter(name: "Synthetic allowed negative")
        _ = try insertDocument(
            store: completeStore,
            matterID: completeMatter.id,
            name: "allowed-negative.txt",
            partTexts: ["MAP-NONE"]
        )
        let complete = try await ExhaustiveListTask(store: completeStore).run(
            request: ExhaustiveListRequest(
                runKey: "negative-allowed-run",
                matterID: completeMatter.id,
                title: "Allowed negative",
                query: "Find any termination reference.",
                characterBudget: 8,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in try Self.response(input, items: []) }
        let allowed = CorpusNegativeGate.evaluate(
            run: complete.run,
            coverage: complete.coverage,
            positiveFindingCount: complete.items.count
        )
        XCTAssertTrue(allowed.allowed)
        XCTAssertEqual(allowed.assuranceState, .corpusComplete)
        XCTAssertTrue(allowed.reasons.isEmpty)
    }

    func testTDIM04ContraryEvidenceAcrossPartitionsFailsNamedDimensionWithBothPositionsRetained() async throws {
        // T-DIM-04 expected RED: exhaustive output dimensions do not consume
        // the engine's cross-partition contrary-evidence references.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic contrary sweep")
        let supporting = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "supporting-agreement.txt",
            partTexts: ["PRIMARY-POSITION-NONDEFAULT"]
        )
        let contrary = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "contrary-amendment.txt",
            partTexts: ["CONTRARY-POSITION-NONDEFAULT"]
        )
        let supportingRevisionID = try XCTUnwrap(supporting.revisionIDs.first)

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "contrary-dimension-run",
                matterID: matter.id,
                title: "Renewal positions",
                query: "Extract every renewal position and sweep for contrary evidence.",
                characterBudget: 28,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            if source.revisionID == supportingRevisionID {
                return try Self.response(input, items: [
                    .init(itemKey: "renewal", value: "Agreement renews", evidence: [.primary]),
                ])
            }
            return try Self.response(input, items: [
                .init(
                    itemKey: "renewal",
                    value: "Agreement renews",
                    evidence: [],
                    contraryEvidence: [.primary]
                ),
            ])
        }

        let dimension = result.version.verificationDimensions.result(for: .contraryEvidence)
        XCTAssertEqual(dimension.status, .failed)
        XCTAssertTrue(dimension.reason?.contains("contrary-amendment.txt") == true)
        XCTAssertEqual(Set(dimension.evidence.map(\.sourceID)), Set(contrary.revisionIDs))
        XCTAssertTrue(dimension.evidence.allSatisfy { !$0.locator.isEmpty && !$0.excerpt.isEmpty })
        XCTAssertEqual(
            result.version.verificationDimensions.result(for: .propositionSupport).status,
            .satisfied,
            "contrary review must remain independent from proposition support"
        )
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        let renewal = try XCTUnwrap(result.items.first { $0.itemKey == "renewal" })
        XCTAssertEqual(Set(renewal.evidence.map(\.revisionID)), Set(supporting.revisionIDs))
        XCTAssertEqual(Set(renewal.contraryEvidence.map(\.revisionID)), Set(contrary.revisionIDs))
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: result.version.id)
        XCTAssertEqual(
            Set(sources.compactMap(\.revisionID)),
            Set(supporting.revisionIDs + contrary.revisionIDs),
            "both the supporting and contrary positions must remain attached"
        )
    }

    func testTDIM05FailedPartitionFailsListAndCorpusDimensionsWithoutErasingSupport() async throws {
        // T-DIM-05 expected RED: the coverage ledger affects aggregate assurance
        // but is not bound into independently persisted dimensions.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic dimension completeness")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "successful-ledger.txt",
            partTexts: ["MAP-SUCCESS-NONDEFAULT"]
        )
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "failed-ledger.txt",
            partTexts: ["MAP-FAILURE-NONDEFAULT"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "dimension-incomplete-run",
                matterID: matter.id,
                title: "Incomplete payment list",
                query: "Extract every payment.",
                characterBudget: 22,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            if input.partition.sources.first?.text == "MAP-FAILURE-NONDEFAULT" {
                throw CorpusAnalysisMapFailure.permanent("NONDEFAULT DIMENSION PARTITION FAILURE")
            }
            return try Self.response(input, items: [
                .init(itemKey: "payment-one", value: "$731", evidence: [.primary]),
            ])
        }

        let dimensions = result.version.verificationDimensions
        XCTAssertEqual(dimensions.result(for: .listCompleteness).status, .failed)
        XCTAssertTrue(dimensions.result(for: .listCompleteness).reason?.contains("failed-ledger.txt") == true)
        XCTAssertEqual(dimensions.result(for: .corpusCoverage).status, .failed)
        XCTAssertTrue(dimensions.result(for: .corpusCoverage).reason?.contains("NONDEFAULT DIMENSION PARTITION FAILURE") == true)
        XCTAssertEqual(dimensions.result(for: .propositionSupport).status, .satisfied)
        XCTAssertEqual(result.version.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
    }

    func testTDIM06RankedRetrievalCannotAuthorizeOrPersistCleanNegativeConclusion() {
        // T-DIM-06 expected RED: the negative gate has no method contract and
        // therefore cannot reject a top-k absence probe before persistence.
        let decision = CorpusNegativeGate.evaluate(
            method: CorpusNegativeMethod.rankedRetrieval,
            proposedConclusion: "NO TERMINATION CLAUSE EXISTS — NONDEFAULT",
            positiveFindingCount: 0
        )

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.assuranceState, .negativeBlocked)
        XCTAssertNil(decision.permittedConclusion)
        XCTAssertEqual(decision.verificationDimensions.result(for: .negativeValidity).status, .failed)
        XCTAssertTrue(decision.verificationDimensions.result(for: .negativeValidity).reason?.contains(
            "adequate exhaustive method was not run"
        ) == true)
    }

    func testTDIM07LowConfidenceMemberBlocksNegativeDespiteCompleteTerminalPartitions() {
        // T-DIM-07 expected RED: a complete partition ledger does not inspect
        // review-required/low-confidence snapshot members for negative validity.
        let run = CorpusAnalysisRunRecord(
            runKey: "low-confidence-negative-run",
            matterID: "synthetic-negative-matter",
            taskKind: CorpusAnalysisTaskKind.negativeCheck.rawValue,
            scopeJSON: #"{"schema_version":1}"#,
            corpusSnapshotJSON: #"{"schema_version":1,"members":[]}"#,
            partitionStrategy: "part_range:characters=173",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.persisted.rawValue,
            assuranceState: OutputAssuranceState.corpusComplete.rawValue
        )
        let snapshot = CorpusAnalysisSnapshot(members: [
            .init(
                memberKey: "document:low-ocr",
                documentID: "low-ocr-document",
                displayName: "Low OCR Exhibit",
                revisionIDs: ["low-ocr-revision"],
                indexState: DocumentIndexStatus.textIndexed.rawValue,
                disposition: .excluded,
                reason: "low_ocr_confidence:page=3:confidence=0.31"
            ),
        ])
        let decision = CorpusNegativeGate.evaluate(
            method: CorpusNegativeMethod.exhaustiveCorpus,
            proposedConclusion: "NO RESPONSIVE PAYMENT EXISTS — NONDEFAULT",
            run: run,
            coverage: Self.completeCoverage,
            snapshot: snapshot,
            positiveFindingCount: 0
        )

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.assuranceState, .negativeBlocked)
        XCTAssertNil(decision.permittedConclusion)
        XCTAssertEqual(decision.verificationDimensions.result(for: .negativeValidity).status, .failed)
        XCTAssertEqual(decision.verificationDimensions.result(for: .lowConfidenceHandling).status, .failed)
        let reason = decision.verificationDimensions.result(for: .negativeValidity).reason ?? ""
        XCTAssertTrue(reason.contains("Low OCR Exhibit"))
        XCTAssertTrue(reason.contains("page=3"))
        XCTAssertTrue(reason.contains("confidence=0.31"))
    }

    private static var completeCoverage: CorpusAnalysisCoverage {
        CorpusAnalysisCoverage(
            snapshotMemberCount: 1,
            eligibleMemberCount: 1,
            excludedMemberCount: 0,
            excludedMembersDisclosed: true,
            partitionCount: 1,
            pendingPartitionCount: 0,
            succeededPartitionCount: 1,
            failedPartitionCount: 0,
            cancelledPartitionCount: 0,
            excludedPartitionCount: 0,
            terminalPartitionCount: 1,
            balanceErrorCount: 0
        )
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExhaustiveListTask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        partTexts: [String]
    ) throws -> ListFixtureDocument {
        try insertListFixtureDocument(
            store: store,
            matterID: matterID,
            name: name,
            partTexts: partTexts
        )
    }

    private static func frozenCorpusLineageHash(
        snapshot: CorpusAnalysisSnapshot,
        slices: [FrozenSliceLineageProbe]
    ) throws -> String {
        let canonicalSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: snapshot.schemaVersion,
            members: snapshot.members.sorted { $0.memberKey < $1.memberKey }
        )
        let envelope = FrozenCorpusLineageEnvelope(
            snapshot: canonicalSnapshot,
            slices: slices.sorted(by: FrozenSliceLineageProbe.lessThan)
        )
        return sha256(try canonicalData(envelope))
    }

    private static func exhaustiveRequestDigest(
        matterID: String,
        query: String,
        scope: CorpusAnalysisScope,
        snapshot: CorpusAnalysisSnapshot,
        slices: [FrozenSliceLineageProbe],
        characterBudget: Int,
        maximumRetryCount: Int,
        modelArtifact: FrozenModelArtifactProbe
    ) throws -> String {
        let canonicalSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: snapshot.schemaVersion,
            members: snapshot.members.sorted { $0.memberKey < $1.memberKey }
        )
        let envelope = FrozenExhaustiveRequestEnvelope(
            matterID: matterID,
            normalizedQuery: query.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            scope: FrozenScopeProbe(
                schemaVersion: scope.schemaVersion,
                mode: scope.documentIDs == nil ? "whole_matter" : "selected_documents",
                documentIDs: scope.documentIDs?.sorted()
            ),
            snapshot: canonicalSnapshot,
            slices: slices.sorted(by: FrozenSliceLineageProbe.lessThan),
            characterBudget: characterBudget,
            maximumRetryCount: maximumRetryCount,
            modelArtifact: modelArtifact
        )
        return sha256(try canonicalData(envelope))
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func substring(_ value: String, from start: Int, to end: Int) -> String {
        let lower = value.index(value.startIndex, offsetBy: start)
        let upper = value.index(value.startIndex, offsetBy: end)
        return String(value[lower..<upper])
    }

    private static func characterRange(of quote: String, in value: String) -> Range<Int>? {
        guard let range = value.range(of: quote) else { return nil }
        let lower = value.distance(from: value.startIndex, to: range.lowerBound)
        let upper = value.distance(from: value.startIndex, to: range.upperBound)
        return lower..<upper
    }

    private static func response(
        _ input: ExhaustiveListGenerationInput,
        items: [SyntheticListItem]
    ) throws -> String {
        let source = try XCTUnwrap(input.partition.sources.first)
        let evidence = CorpusAnalysisEvidenceReference(
            documentID: source.documentID,
            revisionID: source.revisionID,
            locatorJSON: source.locatorJSON
        )
        let payload = SyntheticListResponse(items: items.map { item in
            SyntheticListMapItem(
                itemKey: item.itemKey,
                value: item.value,
                evidence: item.evidence.map { _ in evidence },
                contraryEvidence: item.contraryEvidence.map { _ in evidence }
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func quotedResponse(
        _ input: ExhaustiveListGenerationInput,
        itemKey: String,
        value: String,
        quote: String?,
        charStart: Int?,
        charEnd: Int?
    ) throws -> String {
        try quotedResponse(
            input,
            items: [SyntheticQuotedItem(
                itemKey: itemKey,
                value: value,
                evidence: [.init(
                    quote: quote,
                    charStart: charStart,
                    charEnd: charEnd
                )]
            )]
        )
    }

    private static func quotedResponse(
        _ input: ExhaustiveListGenerationInput,
        items: [SyntheticQuotedItem]
    ) throws -> String {
        let source = try XCTUnwrap(input.partition.sources.first)
        let reference: (SyntheticQuotedEvidenceSpec) -> SyntheticQuotedEvidenceReference = { spec in
            SyntheticQuotedEvidenceReference(
                documentID: source.documentID,
                revisionID: source.revisionID,
                locatorJSON: source.locatorJSON,
                quote: spec.quote,
                charStart: spec.charStart,
                charEnd: spec.charEnd
            )
        }
        let payload = SyntheticQuotedListResponse(items: items.map { item in
            SyntheticQuotedListMapItem(
                itemKey: item.itemKey,
                value: item.value,
                evidence: item.evidence.map(reference),
                contraryEvidence: item.contraryEvidence.map(reference)
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

private func insertListFixtureDocument(
    store: SupraStore,
    matterID: String,
    name: String,
    partTexts: [String]
) throws -> ListFixtureDocument {
    let key = "\(name.replacingOccurrences(of: ".", with: "-"))-\(UUID().uuidString)"
    let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
        sha256: "list-\(key)",
        byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
        originalExtension: "txt",
        managedRelativePath: "blobs/\(key).txt"
    )).blob
    let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
        matterID: matterID,
        blobID: blob.id,
        displayName: name,
        status: MatterDocumentStatus.ready.rawValue,
        extractionStatus: DocumentExtractionStatus.extracted.rawValue,
        indexStatus: DocumentIndexStatus.textIndexed.rawValue
    ))
    let parts = partTexts.enumerated().map { index, text in
        DocumentPagePartRecord(
            id: "\(key)-part-\(index)",
            documentID: document.id,
            partIndex: index,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
    }
    let revisions = partTexts.enumerated().map { index, text in
        DocumentPartRevisionRecord(
            id: "\(key)-revision-\(index)",
            documentID: document.id,
            partIndex: index,
            derivationKey: "fixture-\(index)",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
    }
    let selections = revisions.map { revision in
        DocumentPartSelectionRecord(
            id: "\(key)-selection-\(revision.partIndex)",
            documentID: document.id,
            partIndex: revision.partIndex,
            selectedRevisionID: revision.id,
            selectionKey: "fixture-\(revision.partIndex)",
            selectedBy: "test",
            decisionJSON: #"{"rule":"fixture"}"#
        )
    }
    _ = try store.documentRevisions.replacePartsAndPersistLineage(
        documentID: document.id,
        parts: parts,
        revisions: revisions,
        selections: selections
    )
    return ListFixtureDocument(documentID: document.id, revisionIDs: revisions.map(\.id))
}

private actor ListScopeDriftProbe {
    private var mutationClaimed = false
    private(set) var addedDocumentID: String?

    func claimMutation() -> Bool {
        if mutationClaimed { return false }
        mutationClaimed = true
        return true
    }

    func recordAddedDocumentID(_ documentID: String) {
        addedDocumentID = documentID
    }
}

private actor ListGeneratorProbe {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

private actor ListPartitionProbe {
    private(set) var inputs: [ExhaustiveListGenerationInput] = []

    func record(_ input: ExhaustiveListGenerationInput) {
        inputs.append(input)
    }
}

private struct ListFixtureDocument {
    var documentID: String
    var revisionIDs: [String]
}

private enum SyntheticEvidenceToken {
    case primary
}

private struct SyntheticListItem {
    var itemKey: String
    var value: String
    var evidence: [SyntheticEvidenceToken]
    var contraryEvidence: [SyntheticEvidenceToken] = []
}

private struct SyntheticListResponse: Encodable {
    var schemaVersion = 1
    var items: [SyntheticListMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct SyntheticListMapItem: Encodable {
    var itemKey: String
    var value: String
    var evidence: [CorpusAnalysisEvidenceReference]
    var contraryEvidence: [CorpusAnalysisEvidenceReference]

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}

private struct SyntheticQuotedListResponse: Encodable {
    var schemaVersion = 1
    var items: [SyntheticQuotedListMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct SyntheticQuotedListMapItem: Encodable {
    var itemKey: String
    var value: String
    var evidence: [SyntheticQuotedEvidenceReference]
    var contraryEvidence: [SyntheticQuotedEvidenceReference] = []

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}

private struct SyntheticQuotedEvidenceReference: Encodable {
    var documentID: String
    var revisionID: String
    var locatorJSON: String
    var quote: String?
    var charStart: Int?
    var charEnd: Int?

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case revisionID = "revision_id"
        case locatorJSON = "locator_json"
        case quote
        case charStart = "char_start"
        case charEnd = "char_end"
    }
}

private struct SyntheticQuotedEvidenceSpec: Sendable {
    var quote: String?
    var charStart: Int? = nil
    var charEnd: Int? = nil
}

private struct SyntheticQuotedItem: Sendable {
    var itemKey: String
    var value: String
    var evidence: [SyntheticQuotedEvidenceSpec]
    var contraryEvidence: [SyntheticQuotedEvidenceSpec] = []
}

private struct ExactEvidenceAttack: Sendable {
    var id: String
    var sourceText: String
    var value: String
    var evidence: SyntheticQuotedEvidenceSpec
}

private enum UnshownEvidencePath: String, Sendable {
    case primary
    case contrary
}

private struct FrozenModelArtifactProbe: Codable, Sendable {
    var repository: String
    var revision: String
    var contentBindingAlgorithm: String
    var contentBindingSchemaVersion: Int
    var artifactFingerprintSHA256: String

    private enum CodingKeys: String, CodingKey {
        case repository = "model_repository"
        case revision = "model_revision"
        case contentBindingAlgorithm = "content_binding_algorithm"
        case contentBindingSchemaVersion = "content_binding_schema_version"
        case artifactFingerprintSHA256 = "artifact_fingerprint_sha256"
    }
}

private struct FrozenScopeProbe: Codable, Sendable {
    var schemaVersion: Int
    var mode: String
    var documentIDs: [String]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case mode
        case documentIDs = "document_ids"
    }
}

private struct FrozenSliceLineageProbe: Codable, Sendable {
    var partitionKey: String
    var ordinal: Int
    var memberKey: String
    var documentID: String
    var partIndex: Int
    var revisionID: String
    var charStart: Int
    var charEnd: Int
    var revisionCharCount: Int
    var textSHA256: String
    var locator: DocumentSourceLocator

    static func lessThan(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.partitionKey != rhs.partitionKey { return lhs.partitionKey < rhs.partitionKey }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        if lhs.memberKey != rhs.memberKey { return lhs.memberKey < rhs.memberKey }
        if lhs.documentID != rhs.documentID { return lhs.documentID < rhs.documentID }
        if lhs.partIndex != rhs.partIndex { return lhs.partIndex < rhs.partIndex }
        if lhs.revisionID != rhs.revisionID { return lhs.revisionID < rhs.revisionID }
        if lhs.charStart != rhs.charStart { return lhs.charStart < rhs.charStart }
        if lhs.charEnd != rhs.charEnd { return lhs.charEnd < rhs.charEnd }
        return lhs.textSHA256 < rhs.textSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case partitionKey = "partition_key"
        case ordinal
        case memberKey = "member_key"
        case documentID = "document_id"
        case partIndex = "part_index"
        case revisionID = "revision_id"
        case charStart = "char_start"
        case charEnd = "char_end"
        case revisionCharCount = "revision_char_count"
        case textSHA256 = "text_sha256"
        case locator
    }
}

private struct FrozenCorpusLineageEnvelope: Codable, Sendable {
    var schemaVersion = 2
    var snapshot: CorpusAnalysisSnapshot
    var slices: [FrozenSliceLineageProbe]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshot
        case slices
    }
}

private struct FrozenExhaustiveRequestEnvelope: Codable, Sendable {
    var schemaVersion = 2
    var taskKind = CorpusAnalysisTaskKind.exhaustiveList.rawValue
    var taskSchemaVersion = ExhaustiveListTask.schemaVersion
    var promptBuilderVersion = ExhaustiveListTask.promptBuilderVersion
    var matterID: String
    var normalizedQuery: String
    var scope: FrozenScopeProbe
    var snapshot: CorpusAnalysisSnapshot
    var slices: [FrozenSliceLineageProbe]
    var characterBudget: Int
    var maximumRetryCount: Int
    var modelArtifact: FrozenModelArtifactProbe

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskKind = "task_kind"
        case taskSchemaVersion = "task_schema_version"
        case promptBuilderVersion = "prompt_builder_version"
        case matterID = "matter_id"
        case normalizedQuery = "normalized_query"
        case scope
        case snapshot
        case slices
        case characterBudget = "character_budget"
        case maximumRetryCount = "maximum_retry_count"
        case modelArtifact = "model_artifact"
    }
}
