import Foundation
import SupraCore
@testable import SupraStore
import XCTest
final class AtomicSourcePublicationIntegrityTests: XCTestCase {
    func testTSTORE04AtomicPublisherRejectsNewLiveOutputForSoftDeletedMatter() throws {
        // T-STORE-04 expected RED: the atomic publisher checks the proposed
        // output but never requires its parent matter to remain live, so a write
        // after the delete cascade creates a new non-deleted output and version.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "Synthetic deleted publication matter 41",
            jurisdiction: "Nevada",
            partyPerspective: .defendant
        )
        try store.matters.softDeleteMatter(id: matter.id)
        XCTAssertNil(
            try store.matters.fetchMatter(id: matter.id),
            "the publication attempt must occur after the parent matter is soft-deleted"
        )

        let outputID = "t-store-04-deleted-matter-output-41"
        let sourceSetID = "t-store-04-deleted-matter-source-set-41"
        let newOutput = StructuredOutputRecord(
            id: outputID,
            matterID: matter.id,
            title: "Synthetic late publication 41",
            outputType: StructuredOutputType.documentQA.rawValue,
            status: StructuredOutputStatus.draft.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_790_004_041),
            updatedAt: Date(timeIntervalSince1970: 1_790_004_041)
        )
        let sourceSet = DocumentSourceSetRecord(
            id: sourceSetID,
            matterID: matter.id,
            status: DocumentSourceSetStatus.pending.rawValue,
            mode: DocumentSourceSetMode.guided.rawValue,
            scopeJSON: #"{"schema_version":41,"document_ids":[]}"#,
            retrievalQuery: "synthetic deleted matter publication 41",
            createdAt: Date(timeIntervalSince1970: 1_790_004_041)
        )

        XCTAssertThrowsError(
            try store.structuredOutputs.createVersionWithSourceSetAtomically(
                structuredOutputID: outputID,
                newOutput: newOutput,
                sourceSet: sourceSet,
                outputSources: [],
                contentMarkdown: "Synthetic publication that must not survive matter deletion.",
                verificationStatus: .legacyUnverified,
                verificationVersion: "",
                verificationResults: [],
                outputStatus: .draft
            ),
            "the atomic publication transaction must reject a soft-deleted parent matter"
        )
        XCTAssertFalse(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).contains { $0.id == outputID },
            "rejected publication must not create a new live structured output"
        )
        XCTAssertTrue(
            try store.structuredOutputs.fetchVersions(structuredOutputID: outputID).isEmpty,
            "rejected publication must not leave a version behind"
        )
        XCTAssertNil(
            try store.documentSources.fetchSourceSet(id: sourceSetID),
            "rejected publication must roll back its pending source set"
        )
    }

    func testTSTORE03AtomicPublisherRejectsCrossMatterDocumentLikeOrdinarySourceWrite() throws {
        // T-STORE-03 expected RED: the ordinary source path rejects this
        // cross-matter document, but the atomic publisher inserts it directly.
        let fixture = try makeFixture(caseName: "cross-matter")
        let invalid = DocumentOutputSourceRecord(
            id: "t-store-03-cross-matter-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.otherMatterDocument.id,
            chunkID: fixture.otherMatterChunk.id,
            revisionID: fixture.otherMatterRevision.id,
            citationLabel: "S97",
            locatorJSON: fixture.otherMatterLocatorJSON,
            excerpt: fixture.otherMatterExcerpt,
            rank: 17,
            warningsJSON: #"["synthetic_cross_matter_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_097)
        )

        try assertAtomicPublisherRejects(
            invalid,
            expectedOrdinaryError: .sourceMatterMismatch(fixture.otherMatterDocument.id),
            caseName: "cross-matter",
            fixture: fixture
        )
    }

    func testTSTORE03AtomicPublisherRejectsWrongRevisionLikeOrdinarySourceWrite() throws {
        // T-STORE-03 expected RED: the ordinary source path rejects a revision
        // owned by another document, while the atomic publisher bypasses that
        // revision/document integrity check.
        let fixture = try makeFixture(caseName: "wrong-revision")
        let invalid = DocumentOutputSourceRecord(
            id: "t-store-03-wrong-revision-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.primaryDocument.id,
            chunkID: fixture.primaryChunk.id,
            revisionID: fixture.siblingRevision.id,
            citationLabel: "S83",
            locatorJSON: fixture.primaryLocatorJSON,
            excerpt: fixture.primaryExcerpt,
            rank: 23,
            warningsJSON: #"["synthetic_revision_scope_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_083)
        )

        try assertAtomicPublisherRejects(
            invalid,
            expectedOrdinaryError: .revisionScopeMismatch(fixture.siblingRevision.id),
            caseName: "wrong-revision",
            fixture: fixture
        )
    }

    func testTSTORE03AtomicPublisherRejectsWrongChunkLikeOrdinarySourceWrite() throws {
        // T-STORE-03 expected RED: the ordinary source path rejects a chunk
        // owned by another document, while the atomic publisher bypasses that
        // chunk/document integrity check.
        let fixture = try makeFixture(caseName: "wrong-chunk")
        let invalid = DocumentOutputSourceRecord(
            id: "t-store-03-wrong-chunk-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.primaryDocument.id,
            chunkID: fixture.siblingChunk.id,
            revisionID: fixture.primaryRevision.id,
            citationLabel: "S71",
            locatorJSON: fixture.primaryLocatorJSON,
            excerpt: fixture.primaryExcerpt,
            rank: 29,
            warningsJSON: #"["synthetic_chunk_scope_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_071)
        )

        try assertAtomicPublisherRejects(
            invalid,
            expectedOrdinaryError: .chunkScopeMismatch(fixture.siblingChunk.id),
            caseName: "wrong-chunk",
            fixture: fixture
        )
    }

    func testTSTORE03ValidExactSourcePublishesAtomically() throws {
        // T-STORE-03 positive control: a future integrity validator must admit
        // an internally consistent document/chunk/revision/range/evidence graph.
        let fixture = try makeFixture(caseName: "valid-positive")
        let valid = primarySource(fixture, id: "t-store-03-valid-source", citationLabel: "S59")
        let expectedSupport = try supportedResult(for: valid)

        let version = try publishAtomically(
            source: valid,
            caseName: "valid-positive",
            fixture: fixture,
            verificationResults: [expectedSupport]
        )

        let persistedVersion = try XCTUnwrap(
            try fixture.store.structuredOutputs.fetchVersion(id: version.id)
        )
        XCTAssertEqual(
            persistedVersion.assuranceState,
            OutputAssuranceState.propositionSupported.rawValue
        )
        XCTAssertEqual(
            try JSONCoding.decode(
                [PropositionSupportResult].self,
                from: try XCTUnwrap(persistedVersion.verificationJSON)
            ),
            [expectedSupport]
        )
        let persistedSource = try XCTUnwrap(
            try fixture.store.documentSources.fetchSource(id: valid.id)
        )
        XCTAssertEqual(persistedSource.documentID, fixture.primaryDocument.id)
        XCTAssertEqual(persistedSource.chunkID, fixture.primaryChunk.id)
        XCTAssertEqual(persistedSource.revisionID, fixture.primaryRevision.id)
        XCTAssertEqual(persistedSource.locatorJSON, fixture.primaryLocatorJSON)
        XCTAssertEqual(persistedSource.excerpt, fixture.primaryExcerpt)
        XCTAssertEqual(persistedSource.structuredOutputVersionID, version.id)
    }

    func testTSTORE03RejectsSameDocumentRevisionThatDoesNotOwnCitedChunk() throws {
        // T-STORE-03 expected RED: both source write paths currently accept a
        // revision merely because it belongs to the document, even when the
        // cited immutable chunk belongs to another revision of that document.
        let fixture = try makeFixture(caseName: "same-document-wrong-revision")
        var invalid = primarySource(
            fixture,
            id: "t-store-03-same-document-wrong-revision-source",
            citationLabel: "S61"
        )
        invalid.revisionID = fixture.primaryAlternateRevision.id

        try assertAtomicPublisherRejects(
            invalid,
            expectedOrdinaryError: .revisionScopeMismatch(fixture.primaryAlternateRevision.id),
            caseName: "same-document-wrong-revision",
            fixture: fixture
        )
    }

    func testTSTORE03OrdinaryAndAtomicPathsRejectLocatorAndExcerptDrift() throws {
        // T-STORE-03 expected RED: neither path currently proves that the
        // retained source locator and excerpt equal the cited chunk's immutable
        // revision range, so provenance can be internally contradictory.
        let locatorFixture = try makeFixture(caseName: "locator-drift")
        var locatorDrift = primarySource(
            locatorFixture,
            id: "t-store-03-locator-drift-source",
            citationLabel: "S67"
        )
        locatorDrift.locatorJSON =
            #"{"source_kind":"text","part_index":7,"char_start":72,"char_end":173}"#
        try assertAtomicPublisherRejects(
            locatorDrift,
            expectedOrdinaryError: nil,
            caseName: "locator-drift",
            fixture: locatorFixture
        )

        let excerptFixture = try makeFixture(caseName: "excerpt-drift")
        var excerptDrift = primarySource(
            excerptFixture,
            id: "t-store-03-excerpt-drift-source",
            citationLabel: "S73"
        )
        excerptDrift.excerpt = "Synthetic mismatched retained excerpt 73."
        try assertAtomicPublisherRejects(
            excerptDrift,
            expectedOrdinaryError: nil,
            caseName: "excerpt-drift",
            fixture: excerptFixture
        )
    }

    func testTSTORE03AtomicPublisherRejectsVerificationEvidenceThatDoesNotMatchSourceRows() throws {
        // T-STORE-03 expected RED: atomic publication validates support-result
        // shape but not source id, citation label, locator, or retained excerpt
        // parity with the exact source rows written in the same transaction.
        for mutation in EvidenceMutation.allCases {
            let fixture = try makeFixture(caseName: "evidence-\(mutation.rawValue)")
            let source = primarySource(
                fixture,
                id: "t-store-03-evidence-\(mutation.rawValue)-source",
                citationLabel: "S79"
            )
            let invalidEvidence = try supportedResult(for: source, mutation: mutation)
            try assertAtomicPublisherRejects(
                source,
                expectedOrdinaryError: nil,
                caseName: "evidence-\(mutation.rawValue)",
                fixture: fixture,
                verificationResults: [invalidEvidence],
                validateOrdinarySourcePath: false
            )
        }
    }

    func testTSTORE03AtomicPublisherRejectsSoftDeletedSourceDocument() throws {
        // T-STORE-03 expected RED: the atomic publisher proves only that the
        // source document belongs to the matter. A document already in the
        // Recycle Bin still retains its chunks and revisions, so the publisher
        // currently grants proposition-supported assurance from a deleted source.
        let fixture = try makeFixture(caseName: "soft-deleted-source-document")
        try fixture.store.documentLibrary.softDeleteDocument(id: fixture.primaryDocument.id)
        XCTAssertEqual(
            try fixture.store.documentLibrary.fetchSoftDeletedDocuments(
                matterID: fixture.outputMatter.id
            ).map(\.id),
            [fixture.primaryDocument.id],
            "the source document must be deleted before the publication attempt"
        )
        let deletedSource = primarySource(
            fixture,
            id: "t-store-03-soft-deleted-source-document",
            citationLabel: "S89"
        )

        try assertAtomicPublisherRejects(
            deletedSource,
            expectedOrdinaryError: nil,
            caseName: "soft-deleted-source-document",
            fixture: fixture,
            validateOrdinarySourcePath: false
        )
    }

    func testTSTORE03AtomicPublisherRejectsWhollyUnboundSourceRow() throws {
        // T-STORE-03 expected RED: nullable historical source identities let a
        // new source row omit its document, chunk, and revision. The publisher
        // currently accepts the row's random id plus its self-supplied excerpt
        // as enough evidence for proposition-supported assurance.
        let fixture = try makeFixture(caseName: "wholly-unbound-source")
        let unboundSource = DocumentOutputSourceRecord(
            id: "t-store-03-wholly-unbound-source",
            sourceSetID: "replaced-by-test",
            documentID: nil,
            chunkID: nil,
            revisionID: nil,
            citationLabel: "S91",
            locatorJSON: #"{"source_kind":"text","part_index":97,"char_start":211,"char_end":307}"#,
            excerpt: "Synthetic unbound evidence value 91 must not earn assurance.",
            rank: 37,
            warningsJSON: #"["synthetic_unbound_source_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_091)
        )

        try assertAtomicPublisherRejects(
            unboundSource,
            expectedOrdinaryError: nil,
            caseName: "wholly-unbound-source",
            fixture: fixture,
            validateOrdinarySourcePath: false
        )
    }

    func testTSTORE03AtomicPublisherRejectsUnusedInvalidRowsInSupportedPacket() throws {
        // T-STORE-03 expected RED: evidence validation visits only the cited
        // row. A valid supported citation can therefore smuggle an unused,
        // provenance-free row into the same retained source packet.
        for invalidKind in ["wholly-unbound", "revisionless-chunk"] {
            let fixture = try makeFixture(caseName: "mixed-packet-\(invalidKind)")
            let validSource = primarySource(
                fixture,
                id: "t-store-03-mixed-packet-valid-\(invalidKind)",
                citationLabel: "S101"
            )
            let invalidSource: DocumentOutputSourceRecord
            if invalidKind == "revisionless-chunk" {
                var revisionlessChunk = fixture.siblingChunk
                revisionlessChunk.id = "t-store-03-mixed-packet-revisionless-chunk"
                revisionlessChunk.revisionID = nil
                try fixture.store.documentIndex.replaceChunks(
                    documentID: fixture.siblingDocument.id,
                    chunks: [revisionlessChunk]
                )
                invalidSource = DocumentOutputSourceRecord(
                    id: "t-store-03-mixed-packet-revisionless-source",
                    sourceSetID: "replaced-by-test",
                    documentID: fixture.siblingDocument.id,
                    chunkID: revisionlessChunk.id,
                    revisionID: nil,
                    citationLabel: "S103",
                    locatorJSON: #"{"source_kind":"text"}"#,
                    excerpt: fixture.siblingExcerpt,
                    rank: 47,
                    warningsJSON: #"["synthetic_unused_revisionless_probe"]"#,
                    createdAt: Date(timeIntervalSince1970: 1_790_003_103)
                )
            } else {
                invalidSource = DocumentOutputSourceRecord(
                    id: "t-store-03-mixed-packet-unbound-source",
                    sourceSetID: "replaced-by-test",
                    documentID: nil,
                    chunkID: nil,
                    revisionID: nil,
                    citationLabel: "S107",
                    locatorJSON: #"{"source_kind":"text","part_index":107,"char_start":211,"char_end":307}"#,
                    excerpt: "Synthetic unused unbound evidence value 107.",
                    rank: 53,
                    warningsJSON: #"["synthetic_unused_unbound_probe"]"#,
                    createdAt: Date(timeIntervalSince1970: 1_790_003_107)
                )
            }

            let publicationError = capturedError {
                _ = try publishAtomically(
                    sources: [validSource, invalidSource],
                    caseName: "mixed-packet-\(invalidKind)",
                    fixture: fixture,
                    verificationResults: [try supportedResult(for: validSource)]
                )
            }
            XCTAssertNotNil(
                publicationError,
                "every retained source row must carry immutable provenance even when unused by verifier evidence"
            )
            XCTAssertNil(
                try fixture.store.documentSources.fetchSource(id: validSource.id),
                "packet-wide rejection must roll back the otherwise-valid cited row"
            )
            XCTAssertNil(
                try fixture.store.documentSources.fetchSource(id: invalidSource.id),
                "packet-wide rejection must roll back the unused invalid row"
            )
            XCTAssertNil(
                try fixture.store.documentSources.fetchSourceSet(
                    id: "t-store-03-source-set-mixed-packet-\(invalidKind)"
                ),
                "packet-wide rejection must roll back the source set"
            )
        }
    }

    func testTSTORE03AtomicPublisherRejectsRevisionlessChunkForPropositionSupportedOutput() throws {
        // T-STORE-03 expected RED: a legacy-compatible chunk may retain a nil
        // revision id. The atomic publisher currently treats the mutable chunk
        // row itself as sufficient provenance and grants proposition-supported
        // assurance without any immutable revision binding.
        let fixture = try makeFixture(caseName: "revisionless-chunk")
        var revisionlessChunk = fixture.primaryChunk
        revisionlessChunk.id = "t-store-03-revisionless-chunk"
        revisionlessChunk.revisionID = nil
        try fixture.store.documentIndex.replaceChunks(
            documentID: fixture.primaryDocument.id,
            chunks: [revisionlessChunk]
        )
        XCTAssertNil(
            try XCTUnwrap(fixture.store.documentIndex.fetchChunk(id: revisionlessChunk.id)).revisionID,
            "the publication probe must cite a chunk with no immutable revision"
        )
        let revisionlessSource = DocumentOutputSourceRecord(
            id: "t-store-03-revisionless-source",
            sourceSetID: "replaced-by-test",
            documentID: fixture.primaryDocument.id,
            chunkID: revisionlessChunk.id,
            revisionID: nil,
            citationLabel: "S93",
            locatorJSON: #"{"source_kind":"text"}"#,
            excerpt: fixture.primaryExcerpt,
            rank: 41,
            warningsJSON: #"["synthetic_revisionless_chunk_probe"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_093)
        )

        try assertAtomicPublisherRejects(
            revisionlessSource,
            expectedOrdinaryError: nil,
            caseName: "revisionless-chunk",
            fixture: fixture,
            validateOrdinarySourcePath: false
        )
    }

    func testTSTORE03AtomicPublisherRejectsMalformedAndOutOfRangeRevisionOnlyLocator() throws {
        // T-STORE-03 expected RED: a revision-only source bypasses the chunk
        // locator validator. Missing or out-of-range endpoints currently fall
        // back to searching the entire revision, so a false locator can still
        // earn proposition-supported assurance from text found elsewhere.
        let invalidLocators = [
            (
                caseName: "revision-only-one-sided-range",
                locatorJSON: #"{"source_kind":"text","part_index":7,"char_start":71}"#
            ),
            (
                caseName: "revision-only-out-of-range",
                locatorJSON: #"{"source_kind":"text","part_index":7,"char_start":71,"char_end":997}"#
            ),
        ]

        for invalidLocator in invalidLocators {
            let fixture = try makeFixture(caseName: invalidLocator.caseName)
            let revisionOnlySource = DocumentOutputSourceRecord(
                id: "t-store-03-\(invalidLocator.caseName)-source",
                sourceSetID: "replaced-by-test",
                documentID: fixture.primaryDocument.id,
                chunkID: nil,
                revisionID: fixture.primaryRevision.id,
                citationLabel: "S95",
                locatorJSON: invalidLocator.locatorJSON,
                excerpt: fixture.primaryExcerpt,
                rank: 43,
                warningsJSON: #"["synthetic_revision_only_locator_probe"]"#,
                createdAt: Date(timeIntervalSince1970: 1_790_003_095)
            )

            try assertAtomicPublisherRejects(
                revisionOnlySource,
                expectedOrdinaryError: nil,
                caseName: invalidLocator.caseName,
                fixture: fixture,
                validateOrdinarySourcePath: false
            )
        }
    }

    private func assertAtomicPublisherRejects(
        _ invalidSource: DocumentOutputSourceRecord,
        expectedOrdinaryError: DocumentSourceRepositoryError?,
        caseName: String,
        fixture: PublicationFixture,
        verificationResults: [PropositionSupportResult]? = nil,
        validateOrdinarySourcePath: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if validateOrdinarySourcePath {
            let ordinarySet = try fixture.store.documentSources.createSourceSet(
                matterID: fixture.outputMatter.id,
                mode: .guided,
                scopeJSON: sourceScopeJSON(fixture),
                retrievalQuery: "ordinary source validator \(caseName) 97",
                retrievalDepth: "deep"
            )
            var ordinarySource = invalidSource
            ordinarySource.id = "ordinary-\(caseName)-source"
            ordinarySource.sourceSetID = ordinarySet.id
            let ordinaryError = capturedError {
                try fixture.store.documentSources.addOutputSource(ordinarySource)
            }
            XCTAssertNotNil(
                ordinaryError,
                "the ordinary source path must reject the same invalid provenance",
                file: file,
                line: line
            )
            if let expectedOrdinaryError {
                XCTAssertEqual(
                    ordinaryError as? DocumentSourceRepositoryError,
                    expectedOrdinaryError,
                    file: file,
                    line: line
                )
            }
            XCTAssertTrue(
                try fixture.store.documentSources.fetchSources(sourceSetID: ordinarySet.id).isEmpty,
                "the ordinary validator must remain the reference fail-closed behavior",
                file: file,
                line: line
            )
        }

        let atomicError = capturedError {
            _ = try publishAtomically(
                source: invalidSource,
                caseName: caseName,
                fixture: fixture,
                verificationResults: verificationResults ?? [try supportedResult(for: invalidSource)]
            )
        }
        XCTAssertNotNil(
            atomicError,
            "the atomic publication boundary must reject invalid provenance",
            file: file,
            line: line
        )
        let outputID = "t-store-03-output-\(caseName)"
        let sourceSetID = "t-store-03-source-set-\(caseName)"
        XCTAssertNil(
            try fixture.store.structuredOutputs.fetchOutputs(matterID: fixture.outputMatter.id)
                .first { $0.id == outputID },
            "invalid provenance must roll back the new output",
            file: file,
            line: line
        )
        XCTAssertTrue(
            try fixture.store.structuredOutputs.fetchVersions(structuredOutputID: outputID).isEmpty,
            "invalid provenance must not leave an assurance-bearing version",
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.documentSources.fetchSourceSet(id: sourceSetID),
            "invalid provenance must roll back the atomic source set",
            file: file,
            line: line
        )
        XCTAssertNil(
            try fixture.store.documentSources.fetchSource(id: invalidSource.id),
            "invalid provenance must roll back the atomic source row",
            file: file,
            line: line
        )
    }

    private func publishAtomically(
        source: DocumentOutputSourceRecord,
        caseName: String,
        fixture: PublicationFixture,
        verificationResults: [PropositionSupportResult]
    ) throws -> StructuredOutputVersionRecord {
        try publishAtomically(
            sources: [source],
            caseName: caseName,
            fixture: fixture,
            verificationResults: verificationResults
        )
    }

    private func publishAtomically(
        sources: [DocumentOutputSourceRecord],
        caseName: String,
        fixture: PublicationFixture,
        verificationResults: [PropositionSupportResult]
    ) throws -> StructuredOutputVersionRecord {
        let outputID = "t-store-03-output-\(caseName)"
        let sourceSetID = "t-store-03-source-set-\(caseName)"
        let sourceSet = DocumentSourceSetRecord(
            id: sourceSetID,
            matterID: fixture.outputMatter.id,
            status: DocumentSourceSetStatus.pending.rawValue,
            mode: DocumentSourceSetMode.guided.rawValue,
            scopeJSON: sourceScopeJSON(fixture),
            retrievalQuery: "atomic source validator \(caseName) 97",
            retrievalDepth: "deep",
            packingReportJSON: #"{"packed_source_count":1,"probe":97}"#,
            embeddingModelID: "synthetic/embed-97",
            embeddingModelRevision: "revision-atomic-7",
            chunkerVersion: 7,
            retrievalConfigJSON: #"{"rrf_k":83,"candidate_limit":97}"#,
            corpusSnapshotHash: String(repeating: "9", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_790_003_097)
        )
        let atomicSources = sources.map { source in
            var atomicSource = source
            atomicSource.sourceSetID = sourceSetID
            return atomicSource
        }
        let newOutput = StructuredOutputRecord(
            id: outputID,
            matterID: fixture.outputMatter.id,
            title: "Atomic source integrity \(caseName) 97",
            outputType: StructuredOutputType.documentQA.rawValue,
            status: StructuredOutputStatus.draft.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_790_003_097),
            updatedAt: Date(timeIntervalSince1970: 1_790_003_097)
        )
        return try fixture.store.structuredOutputs.createVersionWithSourceSetAtomically(
            structuredOutputID: outputID,
            newOutput: newOutput,
            sourceSet: sourceSet,
            outputSources: atomicSources,
            contentMarkdown:
                "Synthetic publication \(caseName) value 97 [\(atomicSources[0].citationLabel)].",
            verificationStatus: .allSupported,
            verificationVersion: "atomic-source-integrity/7",
            verificationResults: verificationResults,
            verificationDimensions: supportedDimensions(),
            outputStatus: .complete,
            promptBuilderVersion: "case-file-review-prompt/7",
            assuranceState: .propositionSupported
        )
    }

    private func capturedError(_ operation: () throws -> Void) -> Error? {
        do {
            try operation()
            return nil
        } catch {
            return error
        }
    }

    private func makeFixture(caseName: String) throws -> PublicationFixture {
        let store = try SupraStore.inMemory()
        let outputMatter = try store.matters.createMatter(
            name: "Synthetic output matter \(caseName)",
            jurisdiction: "Georgia",
            partyPerspective: .defendant
        )
        let otherMatter = try store.matters.createMatter(
            name: "Synthetic foreign matter \(caseName)",
            jurisdiction: "Oregon",
            partyPerspective: .plaintiff
        )
        let primary = try makeDocument(
            store: store,
            matterID: outputMatter.id,
            stem: "\(caseName)-primary",
            partIndex: 7,
            charStart: 71,
            charEnd: 173
        )
        let sibling = try makeDocument(
            store: store,
            matterID: outputMatter.id,
            stem: "\(caseName)-sibling",
            partIndex: 11,
            charStart: 83,
            charEnd: 197
        )
        let foreign = try makeDocument(
            store: store,
            matterID: otherMatter.id,
            stem: "\(caseName)-foreign",
            partIndex: 19,
            charStart: 137,
            charEnd: 311
        )
        return PublicationFixture(
            store: store,
            outputMatter: outputMatter,
            otherMatterDocument: foreign.document,
            otherMatterRevision: foreign.revision,
            otherMatterChunk: foreign.chunk,
            otherMatterLocatorJSON: foreign.locatorJSON,
            otherMatterExcerpt: foreign.excerpt,
            primaryDocument: primary.document,
            primaryRevision: primary.revision,
            primaryAlternateRevision: primary.alternateRevision,
            primaryChunk: primary.chunk,
            primaryLocatorJSON: primary.locatorJSON,
            primaryExcerpt: primary.excerpt,
            siblingDocument: sibling.document,
            siblingRevision: sibling.revision,
            siblingChunk: sibling.chunk,
            siblingLocatorJSON: sibling.locatorJSON,
            siblingExcerpt: sibling.excerpt
        )
    }

    private func makeDocument(
        store: SupraStore,
        matterID: String,
        stem: String,
        partIndex: Int,
        charStart: Int,
        charEnd: Int
    ) throws -> (
        document: MatterDocumentRecord,
        revision: DocumentPartRevisionRecord,
        alternateRevision: DocumentPartRevisionRecord,
        chunk: DocumentChunkRecord,
        locatorJSON: String,
        excerpt: String
    ) {
        let rangeLength = charEnd - charStart
        let marker = "Synthetic exact evidence \(stem) value \(partIndex). "
        XCTAssertLessThan(marker.count, rangeLength)
        let excerpt = marker + String(repeating: "e", count: rangeLength - marker.count)
        let text =
            String(repeating: "p", count: charStart)
            + excerpt
            + String(repeating: "s", count: 31)
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "blob-\(stem)",
                sha256: String(repeating: String((partIndex % 9) + 1), count: 64),
                byteSize: 8_191 + partIndex,
                originalExtension: "txt",
                managedRelativePath: "blobs/\(stem).txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Date(timeIntervalSince1970: 1_790_001_000 + Double(partIndex))
            )
        ).blob
        let document = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: "document-\(stem)",
                matterID: matterID,
                blobID: blob.id,
                displayName: "Synthetic-\(stem).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractedTextChecksum: "checksum-\(stem)-97",
                pagePartCount: partIndex + 1,
                importedAt: Date(timeIntervalSince1970: 1_790_001_000 + Double(partIndex))
            ))
        let revision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "revision-\(stem)",
                documentID: document.id,
                partIndex: partIndex,
                derivationKey: "derivation-\(stem)-7",
                origin: "parser",
                method: "synthetic_exact_text",
                text: text,
                charCount: text.count,
                toolchainVersion: "synthetic-parser/7",
                reason: "T-STORE-03 exact source scope probe",
                createdAt: Date(timeIntervalSince1970: 1_790_002_000 + Double(partIndex))
            ))
        let alternateRevision = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "revision-\(stem)-alternate",
                documentID: document.id,
                partIndex: partIndex,
                derivationKey: "derivation-\(stem)-alternate-11",
                origin: "parser",
                method: "synthetic_alternate_text",
                text: String(repeating: "z", count: text.count),
                charCount: text.count,
                toolchainVersion: "synthetic-parser/11",
                reason: "T-STORE-03 same-document wrong-revision probe",
                createdAt: Date(timeIntervalSince1970: 1_790_002_050 + Double(partIndex))
            )
        )
        let chunk = DocumentChunkRecord(
            id: "chunk-\(stem)",
            documentID: document.id,
            revisionID: revision.id,
            chunkerVersion: 7,
            chunkIndex: partIndex,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: charStart,
            charEnd: charEnd,
            normalizedText: excerpt,
            displayExcerpt: excerpt,
            tokenCount: 47 + partIndex,
            createdAt: Date(timeIntervalSince1970: 1_790_002_100 + Double(partIndex)),
            updatedAt: Date(timeIntervalSince1970: 1_790_002_100 + Double(partIndex))
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        let locatorJSON =
            "{\"source_kind\":\"text\",\"part_index\":\(partIndex),\"char_start\":\(charStart),\"char_end\":\(charEnd)}"
        return (document, revision, alternateRevision, chunk, locatorJSON, excerpt)
    }

    private func primarySource(
        _ fixture: PublicationFixture,
        id: String,
        citationLabel: String
    ) -> DocumentOutputSourceRecord {
        DocumentOutputSourceRecord(
            id: id,
            sourceSetID: "replaced-by-test",
            documentID: fixture.primaryDocument.id,
            chunkID: fixture.primaryChunk.id,
            revisionID: fixture.primaryRevision.id,
            citationLabel: citationLabel,
            locatorJSON: fixture.primaryLocatorJSON,
            excerpt: fixture.primaryExcerpt,
            rank: 31,
            warningsJSON: #"["synthetic_exact_provenance"]"#,
            createdAt: Date(timeIntervalSince1970: 1_790_003_197)
        )
    }

    private func sourceScopeJSON(_ fixture: PublicationFixture) -> String {
        "{\"document_ids\":[\"\(fixture.primaryDocument.id)\",\"\(fixture.siblingDocument.id)\"],\"schema_version\":7}"
    }

    private func supportedResult(
        for source: DocumentOutputSourceRecord,
        mutation: EvidenceMutation? = nil
    ) throws -> PropositionSupportResult {
        let evidenceSourceID = mutation == .sourceID ? "t-store-03-wrong-evidence-source" : source.id
        let evidenceLabel = mutation == .sourceLabel ? "S997" : source.citationLabel
        let evidenceLocator =
            mutation == .locator
            ? #"{"source_kind":"text","part_index":997,"char_start":0,"char_end":1}"#
            : source.locatorJSON
        let evidenceExcerpt =
            mutation == .retainedExcerpt
            ? "Synthetic mismatched verification excerpt 997."
            : source.excerpt
        return try PropositionSupportResult(
            propositionID: "atomic-proposition-\(source.citationLabel)",
            status: .supported,
            reasons: ["synthetic_atomic_source_probe"],
            evidence: [
                SupportEvidence(
                    sourceID: evidenceSourceID,
                    sourceLabel: evidenceLabel,
                    locator: evidenceLocator,
                    retainedExcerpt: evidenceExcerpt,
                    verifierName: "AtomicSourceIntegrityVerifier",
                    verifierVersion: "atomic-source-integrity/7"
                )
            ],
            timestamp: Date(timeIntervalSince1970: 1_790_003_097)
        )
    }

    private func supportedDimensions() -> VerificationDimensions {
        .complete(overrides: [
            .init(dimension: .propositionSupport, status: .satisfied),
            .init(dimension: .citationResolution, status: .satisfied),
            .init(dimension: .criticalValueFidelity, status: .satisfied),
            .init(dimension: .lowConfidenceHandling, status: .satisfied),
        ])
    }
}

private struct PublicationFixture {
    let store: SupraStore
    let outputMatter: MatterRecord
    let otherMatterDocument: MatterDocumentRecord
    let otherMatterRevision: DocumentPartRevisionRecord
    let otherMatterChunk: DocumentChunkRecord
    let otherMatterLocatorJSON: String
    let otherMatterExcerpt: String
    let primaryDocument: MatterDocumentRecord
    let primaryRevision: DocumentPartRevisionRecord
    let primaryAlternateRevision: DocumentPartRevisionRecord
    let primaryChunk: DocumentChunkRecord
    let primaryLocatorJSON: String
    let primaryExcerpt: String
    let siblingDocument: MatterDocumentRecord
    let siblingRevision: DocumentPartRevisionRecord
    let siblingChunk: DocumentChunkRecord
    let siblingLocatorJSON: String
    let siblingExcerpt: String
}

private enum EvidenceMutation: String, CaseIterable {
    case sourceID = "source-id"
    case sourceLabel = "source-label"
    case locator
    case retainedExcerpt = "retained-excerpt"
}
