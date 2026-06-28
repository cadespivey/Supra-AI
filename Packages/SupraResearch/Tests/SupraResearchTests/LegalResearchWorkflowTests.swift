import SupraResearch
import XCTest

final class LegalResearchWorkflowTests: XCTestCase {
    func testSourcePacketCapsAuthorityCountAndNotesOmissions() {
        let many = (1...20).map { i in
            LegalAuthority(id: "a\(i)", authorityType: .case, caseName: "Case \(i)", snippet: "snippet \(i)")
        }
        let packet = LegalResearchPromptBuilder.sourcePacket(many)
        let cap = LegalResearchPromptBuilder.maxPacketAuthorities
        XCTAssertTrue(packet.contains("[A\(cap)]"), "top-N authorities should be present")
        XCTAssertFalse(packet.contains("[A\(cap + 1)]"), "authorities beyond the cap must be dropped from the packet")
        XCTAssertTrue(packet.contains("\(many.count - cap) lower-ranked authorities were omitted"))
    }

    func testSourcePacketTruncatesOverlongAuthorityText() {
        let longText = String(repeating: "x", count: LegalResearchPromptBuilder.maxAuthorityTextChars + 500)
        let packet = LegalResearchPromptBuilder.sourcePacket([
            LegalAuthority(id: "a1", authorityType: .case, caseName: "Big", text: longText)
        ])
        XCTAssertTrue(packet.contains("[text truncated to fit the context window]"))
        XCTAssertLessThan(packet.count, longText.count, "an overlong authority must be trimmed to its budget")
    }

    func testInRangePacketLabelCountsAsACitation() {
        let authorities = [LegalAuthority(id: "a1", authorityType: .case, caseName: "Foo v. Bar", citation: "1 U.S. 1")]
        let answer = "The statute of limitations requires filing the claim within two years [A1]."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: authorities)
        XCTAssertFalse(
            report.issues.contains { $0.kind == .missingCitation },
            "a proposition ending in an in-range [A#] label should be treated as cited"
        )
    }

    func testLabelBeyondPacketCapIsFlaggedEvenWhenMoreAuthoritiesRetrieved() {
        // The model only sees the first maxPacketAuthorities of the packet, so a label
        // past that bound is fabricated even though more authorities were retrieved.
        let authorities = (1...18).map {
            LegalAuthority(id: "a\($0)", authorityType: .case, caseName: "Case \($0)", citation: "\($0) U.S. \($0)")
        }
        let report = LegalCitationVerifier.verify(answer: "The rule applies here [A15].", authorities: authorities)
        XCTAssertTrue(
            report.issues.contains { $0.kind == .unsupportedCitation && ($0.excerpt ?? "").contains("[A15]") },
            "[A15] is beyond the 12-source packet the model actually saw"
        )
        XCTAssertFalse(report.passed)
    }

    func testIntegerOverflowLabelIsFlaggedNotDropped() {
        let authorities = [LegalAuthority(id: "a1", authorityType: .case, caseName: "Foo v. Bar", citation: "1 U.S. 1")]
        let report = LegalCitationVerifier.verify(answer: "Liability attaches [A99999999999999999999].", authorities: authorities)
        XCTAssertTrue(
            report.issues.contains { $0.kind == .unsupportedCitation },
            "an integer-overflow label must still be flagged as out-of-range, not silently dropped"
        )
    }

    func testFabricatedHoldingUnderValidLabelIsFlaggedWhenAuthorityTextSubstantial() {
        // Substantial (hydrated) opinion text about leases; the cited proposition is an
        // unrelated fabricated holding under a valid label.
        let leaseOpinion = String(repeating: "The parties executed a commercial lease for warehouse space and disputed the renewal option. ", count: 30)
        let authorities = [LegalAuthority(id: "a1", authorityType: .case, caseName: "Lease Co. v. Tenant", text: leaseOpinion)]
        let answer = "The court squarely held that punitive damages are categorically barred in all securities fraud actions [A1]."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: authorities)
        XCTAssertTrue(
            report.issues.contains { $0.kind == .unsupportedCitation },
            "a fabricated holding sharing almost no terms with the cited opinion must be flagged"
        )
    }

    func testGenuineParaphraseUnderValidLabelPassesAgainstSubstantialText() {
        let limitationsOpinion = String(repeating: "The statute of limitations for a securities fraud claim is two years from discovery of the violation. ", count: 20)
        let authorities = [LegalAuthority(id: "a1", authorityType: .case, caseName: "Sec. v. Fraud", text: limitationsOpinion)]
        let answer = "The limitations period for a securities fraud claim runs two years from discovery [A1]."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: authorities)
        XCTAssertFalse(
            report.issues.contains { $0.kind == .unsupportedCitation },
            "a genuine paraphrase that overlaps the cited opinion must not be over-flagged"
        )
    }

    func testOutOfRangePacketLabelIsFlaggedUnsupported() {
        let authorities = [LegalAuthority(id: "a1", authorityType: .case, caseName: "Foo v. Bar", citation: "1 U.S. 1")]
        let answer = "The court held that liability attaches under the rule [A5]."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: authorities)
        XCTAssertTrue(
            report.issues.contains { $0.kind == .unsupportedCitation && ($0.excerpt ?? "").contains("[A5]") },
            "a label past the packet size is a fabricated reference"
        )
    }

    func testNormalizesAndRanksCourtListenerAuthority() {
        let dto = CourtListenerSearchResultDTO(
            absoluteURL: "/opinion/1/foo-v-bar/",
            caseName: "Foo v. Bar",
            citation: ["123 Cal. App. 5th 456"],
            clusterID: 1,
            court: "California Court of Appeal",
            courtID: "calctapp",
            dateFiled: "2024-02-03",
            opinions: [CourtListenerOpinionDTO(id: 99, snippet: "A non-compete clause was void under California law.")],
            status: "Published"
        )

        let authority = LegalAuthorityNormalizer.normalize(dto)
        XCTAssertEqual(authority.id, "courtlistener:opinion:99")
        XCTAssertEqual(authority.source, .courtlistener)
        XCTAssertEqual(authority.caseName, "Foo v. Bar")
        XCTAssertEqual(authority.citation, "123 Cal. App. 5th 456")
        XCTAssertEqual(authority.url, "https://www.courtlistener.com/opinion/1/foo-v-bar/")

        let classification = LegalQueryClassification(
            jurisdiction: "California",
            legalIssue: "California non-compete clause",
            bindingAuthorityRequired: true
        )
        let ranked = LegalAuthorityRanker.rank([authority], for: classification)
        XCTAssertEqual(ranked.first?.authority.id, authority.id)
        XCTAssertTrue(ranked.first?.reasons.contains("term_relevance") ?? false)
    }

    func testVerifierRejectsInventedCitation() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1",
            authorityType: .case,
            caseName: "Real v. Case",
            citation: "123 Cal. App. 5th 456",
            citations: ["123 Cal. App. 5th 456"],
            court: "California Court of Appeal",
            jurisdiction: "California",
            text: "The court held that the contract term was unenforceable."
        )
        let answer = "California law requires this result. Fake v. Madeup, 999 F.3d 1234."

        let report = LegalCitationVerifier.verify(
            answer: answer,
            authorities: [authority],
            expectedJurisdiction: "California"
        )

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation })
        XCTAssertTrue(report.issues.contains { $0.excerpt?.contains("999 F.3d 1234") ?? false })
    }

    func testVerifierRejectsWrongReporterAttachedToKnownCaseName() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1",
            authorityType: .case,
            caseName: "Real v. Case",
            citation: "123 Cal. App. 5th 456",
            citations: ["123 Cal. App. 5th 456"],
            court: "California Court of Appeal",
            jurisdiction: "California",
            text: "The court held that the contract term was unenforceable."
        )
        let answer = "Real v. Case, 999 F.3d 1234 held that the contract term was unenforceable."

        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation })
        XCTAssertTrue(report.issues.contains { $0.excerpt?.contains("999 F.3d 1234") ?? false })
    }

    func testVerifierRejectsUnsupportedQuote() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1",
            authorityType: .case,
            caseName: "Real v. Case",
            citation: "123 Cal. App. 5th 456",
            citations: ["123 Cal. App. 5th 456"],
            court: "California Court of Appeal",
            jurisdiction: "California",
            text: "The court held that the contract term was unenforceable."
        )
        let answer = #"Real v. Case says "this exact invented quote never happened." 123 Cal. App. 5th 456."#

        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedQuote })
    }

    func testClassifierFindsJurisdictionAdverseRequestAndCitation() {
        let classification = LegalQueryClassifier.classify(
            "Find adverse California authority discussing 410 U.S. 113 after summary judgment."
        )
        XCTAssertEqual(classification.jurisdiction, "California")
        XCTAssertTrue(classification.adverseAuthorityRequested)
        XCTAssertEqual(classification.citationLookup, "410 U.S. 113")
        XCTAssertEqual(classification.proceduralPosture, "summary judgment")
    }

    func testClassifierFindsCourtIDsAndDateFilters() {
        let classification = LegalQueryClassifier.classify(
            "Find binding 9th Cir. and N.D. Cal. authority after 2020 on employee non-compete agreements."
        )

        XCTAssertEqual(classification.jurisdiction, "Ninth Circuit")
        XCTAssertTrue(classification.courtIDs.contains("ca9"))
        XCTAssertTrue(classification.courtIDs.contains("cand"))
        XCTAssertEqual(classification.dateFiledAfter, "2020-01-01")
        XCTAssertFalse(classification.legalIssue.localizedCaseInsensitiveContains("after 2020"))
    }

    func testClassifierFindsStateReporterStatuteAndCaseNameCitations() {
        XCTAssertEqual(
            LegalQueryClassifier.firstCitation(in: "Verify 123 Cal. App. 5th 456 for California contracts."),
            "123 Cal. App. 5th 456"
        )
        XCTAssertEqual(
            LegalQueryClassifier.firstCitation(in: "Research 33 U.S.C. § 913 for DBA claim filing."),
            "33 U.S.C. § 913"
        )
        XCTAssertEqual(
            LegalQueryClassifier.firstCitation(in: "What does 20 C.F.R. § 702.221 require?"),
            "20 C.F.R. § 702.221"
        )
        XCTAssertEqual(
            LegalQueryClassifier.firstCitation(in: "Research Cal. Civ. Code § 16600 and non-competes."),
            "Cal. Civ. Code § 16600"
        )
        XCTAssertEqual(
            LegalQueryClassifier.firstCitation(in: "Find Roe v. Wade for privacy analysis."),
            "Roe v. Wade"
        )
        XCTAssertEqual(
            LegalQueryClassifier.firstCitation(in: "Find Smith and Wesson v. Jones for product liability."),
            "Smith and Wesson v. Jones"
        )
    }

    func testVerifierChecksCurlyQuotesAndStatutoryCitations() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1",
            authorityType: .case,
            caseName: "Real v. Case",
            citation: "123 Cal. App. 5th 456",
            citations: ["123 Cal. App. 5th 456"],
            court: "California Court of Appeal",
            jurisdiction: "California",
            text: "The court held that the contract term was unenforceable."
        )
        let answer = "Real v. Case says “invented quoted text.” 123 Cal. App. 5th 456. Cal. Civ. Code § 16600 applies."

        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])

        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedQuote })
        XCTAssertTrue(report.citedStrings.contains { $0.contains("§ 16600") })
    }

    // MARK: - Strict case-name matching (audit [6])

    func testBareCaseNameCiteNotSupportedByUnrelatedAuthorityViaSubstring() {
        // Authority parties do not contain the cited parties — must be unsupported,
        // not "verified" through loose substring matching.
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1",
            authorityType: .case,
            caseName: "Smithfield Foods v. Jonestown Holdings",
            citations: [],
            court: "California Court of Appeal",
            jurisdiction: "California",
            text: "Some unrelated holding."
        )
        let answer = "The rule applies. See Acme v. Globex."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation && ($0.excerpt?.contains("Acme") ?? false) })
    }

    func testReverseContainmentNoLongerVerifiesFabricatedLongerName() {
        // Authority "Doe v. Roe"; the answer cites a fabricated, longer name whose
        // parties are a superset. Old bidirectional containment marked this
        // supported; it must now be flagged.
        let authority = LegalAuthority(
            id: "courtlistener:opinion:2",
            authorityType: .case,
            caseName: "Doe v. Roe",
            citations: [],
            court: "Ninth Circuit",
            jurisdiction: "ca9"
        )
        let answer = "As established in Doe Industries International v. Roe Holdings Worldwide."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation })
    }

    func testAbbreviatedCaseNameWithMatchingReporterIsStillSupported() {
        // A correct reporter plus an abbreviated (subset) case name should pass.
        let authority = LegalAuthority(
            id: "courtlistener:opinion:3",
            authorityType: .case,
            caseName: "Brown v. Board of Education of Topeka",
            citation: "347 U.S. 483",
            citations: ["347 U.S. 483"],
            court: "Supreme Court of the United States",
            jurisdiction: "scotus"
        )
        let answer = "Segregation is unconstitutional. Brown v. Board, 347 U.S. 483."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])
        XCTAssertFalse(report.issues.contains { $0.kind == .unsupportedCitation })
    }

    // MARK: - Federal statutory/regulatory citation recognition (Round 2 [1])

    func testExtractorRecognizesFederalStatuteAndRegulationCites() {
        let cites = LegalCitationVerifier.extractCitationLikeStrings(
            from: "Liability arises under 42 U.S.C. § 1983 and the procedure in 20 C.F.R. § 404.1520 applies."
        )
        XCTAssertTrue(cites.contains { $0.contains("§ 1983") }, "U.S.C. cite must be extracted")
        XCTAssertTrue(cites.contains { $0.contains("404.1520") }, "C.F.R. cite must be extracted")
    }

    func testExtractorRecognizesOtherHighTrafficAuthorityForms() {
        let text = "See Fed. R. Civ. P. 12(b)(6); Fed. R. Evid. 403; Pub. L. No. 117-99; 86 Fed. Reg. 12345; U.C.C. § 2-207; Restatement (Second) of Torts § 402A."
        let cites = LegalCitationVerifier.extractCitationLikeStrings(from: text)
        XCTAssertTrue(cites.contains { $0.contains("12(b)(6)") }, "federal civil rule")
        XCTAssertTrue(cites.contains { $0.contains("403") }, "federal evidence rule")
        XCTAssertTrue(cites.contains { $0.localizedCaseInsensitiveContains("Pub. L") }, "public law")
        XCTAssertTrue(cites.contains { $0.localizedCaseInsensitiveContains("Fed. Reg") }, "federal register")
        XCTAssertTrue(cites.contains { $0.contains("2-207") }, "U.C.C.")
        XCTAssertTrue(cites.contains { $0.contains("402A") }, "Restatement")
    }

    func testFabricatedFederalRuleIsFlaggedUnsupported() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1", authorityType: .case, caseName: "Real v. Case",
            citation: "123 Cal. App. 5th 456", citations: ["123 Cal. App. 5th 456"],
            court: "California Court of Appeal", jurisdiction: "California"
        )
        let answer = "Per Real v. Case, 123 Cal. App. 5th 456, dismissal is proper under Fed. R. Civ. P. 12(b)(6)."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation && ($0.excerpt?.localizedCaseInsensitiveContains("Fed. R") ?? false) })
    }

    func testFabricatedFederalStatuteIsFlaggedUnsupported() {
        let authority = LegalAuthority(
            id: "courtlistener:opinion:1",
            authorityType: .case,
            caseName: "Real v. Case",
            citation: "123 Cal. App. 5th 456",
            citations: ["123 Cal. App. 5th 456"],
            court: "California Court of Appeal",
            jurisdiction: "California"
        )
        // A real, supported case cite PLUS a fabricated federal statute — the
        // statute must not slip through as part of a verification-passed answer.
        let answer = "Per Real v. Case, 123 Cal. App. 5th 456, and 42 U.S.C. § 9999, the claim holds."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority])
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.issues.contains { $0.kind == .unsupportedCitation && ($0.excerpt?.contains("§ 9999") ?? false) })
    }

    func testFederalUSCCitationMatchesOpenLegalCodesTitleLabel() {
        let authority = LegalAuthority(
            id: "open-legal-codes:us-usc-title-33:chapter-18/section-913",
            source: .openlegalcodes,
            authorityType: .statute,
            caseName: "Filing of claims",
            citation: "United States Code, Title 33 § 913",
            citations: ["§ 913", "United States Code, Title 33 § 913"],
            jurisdiction: "Federal",
            snippet: "Time for filing claims under the Longshore and Harbor Workers' Compensation Act.",
            text: "Time for filing claims under the Longshore and Harbor Workers' Compensation Act."
        )
        let answer = "The claim-filing provision is codified at 33 U.S.C. § 913 [A1]."

        let report = LegalCitationVerifier.verify(answer: answer, authorities: [authority], expectedJurisdiction: "Federal")

        XCTAssertFalse(
            report.issues.contains { $0.kind == .unsupportedCitation && ($0.excerpt?.contains("33 U.S.C. § 913") ?? false) },
            "federal statutory citations should match equivalent provider labels"
        )
    }

    // MARK: - Per-citation jurisdiction (audit [17])

    func testJurisdictionMismatchFlaggedPerCitedAuthority() {
        // Two authorities retrieved: one in CA, one in NY. The answer cites the NY
        // case while CA was requested — the cited authority must be flagged, even
        // though *some* retrieved authority matches the jurisdiction.
        let ca = LegalAuthority(
            id: "courtlistener:opinion:ca",
            authorityType: .case,
            caseName: "Alpha v. Beta",
            citation: "1 Cal. 5th 1",
            citations: ["1 Cal. 5th 1"],
            court: "Supreme Court of California",
            jurisdiction: "California"
        )
        let ny = LegalAuthority(
            id: "courtlistener:opinion:ny",
            authorityType: .case,
            caseName: "Gamma v. Delta",
            citation: "2 N.Y.3d 2",
            citations: ["2 N.Y.3d 2"],
            court: "New York Court of Appeals",
            jurisdiction: "New York"
        )
        let answer = "Under the controlling rule, Gamma v. Delta, 2 N.Y.3d 2, governs."
        let report = LegalCitationVerifier.verify(answer: answer, authorities: [ca, ny], expectedJurisdiction: "California")
        XCTAssertTrue(report.issues.contains { $0.kind == .jurisdictionMismatch && ($0.excerpt?.contains("N.Y.3d") ?? false) })
    }

    // MARK: - Precedential ranking (audit [31])

    func testUnpublishedAuthorityRanksBelowPublished() {
        let published = LegalAuthority(
            id: "courtlistener:opinion:pub",
            authorityType: .case,
            caseName: "Pub v. Lished",
            citation: "10 Cal. 5th 10",
            citations: ["10 Cal. 5th 10"],
            court: "Supreme Court of California",
            jurisdiction: "California",
            dateFiled: "2021-01-01",
            precedentialStatus: "Published"
        )
        let unpublished = LegalAuthority(
            id: "courtlistener:opinion:unpub",
            authorityType: .case,
            caseName: "Un v. Published",
            citation: "11 Cal. 5th 11",
            citations: ["11 Cal. 5th 11"],
            court: "Supreme Court of California",
            jurisdiction: "California",
            dateFiled: "2021-01-01",
            precedentialStatus: "Unpublished"
        )
        let classification = LegalQueryClassification(jurisdiction: "California", legalIssue: "general")
        let ranked = LegalAuthorityRanker.rank([unpublished, published], for: classification)
        XCTAssertEqual(ranked.first?.authority.id, published.id)
        XCTAssertTrue(ranked.first?.reasons.contains("precedential") ?? false)
        XCTAssertTrue(ranked.last?.reasons.contains("non_precedential") ?? false)
    }

    // MARK: - Source planning

    func testDBALimitationsPlansFederalPrimaryLawWithoutUserJurisdiction() {
        let classification = LegalQueryClassifier.classify(
            "When does the statute of limitations run for claims made by claimants under the Defense Base Act?"
        )
        let target = LegalSourceTarget(kind: .global)
        let plan = LegalResearchSourcePlanner.plan(classification: classification, target: target)

        XCTAssertTrue(plan.requiresPrimaryLaw)
        XCTAssertTrue(plan.satisfiesJurisdictionRequirement, "inherently federal statutory schemes should not ask for a state/circuit first")
        XCTAssertEqual(plan.effectiveClassification.jurisdiction, "Federal")
        XCTAssertTrue(plan.primaryLawCitationQuery?.contains("42 U.S.C. § 1651") ?? false)
        XCTAssertTrue(plan.primaryLawCitationQuery?.contains("33 U.S.C. § 913") ?? false)
    }

    func testStateLimitationsQuestionRequiresPrimaryLaw() {
        let classification = LegalQueryClassifier.classify(
            "What is the statute of limitations for a written contract claim in Florida?"
        )
        let target = LegalSourceTarget(kind: .global, jurisdiction: "Florida")
        let plan = LegalResearchSourcePlanner.plan(classification: classification, target: target)

        XCTAssertTrue(plan.requiresPrimaryLaw)
        XCTAssertTrue(plan.shouldRetrievePrimaryLaw)
        XCTAssertEqual(plan.effectiveClassification.jurisdiction, "Florida")
    }

    func testGenericWhenDoesQuestionDoesNotRequirePrimaryLaw() {
        let classification = LegalQueryClassifier.classify(
            "When does res judicata bar relitigation under New York law?"
        )
        let plan = LegalResearchSourcePlanner.plan(
            classification: classification,
            target: LegalSourceTarget(kind: .global, jurisdiction: "New York")
        )

        XCTAssertFalse(plan.requiresPrimaryLaw)
        XCTAssertFalse(plan.shouldRetrievePrimaryLaw)
    }

    func testCommonLawElementsQuestionDoesNotRequireStatutoryGate() {
        let classification = LegalQueryClassifier.classify(
            "What are the elements of promissory estoppel?"
        )
        let plan = LegalResearchSourcePlanner.plan(
            classification: classification,
            target: LegalSourceTarget(kind: .global, jurisdiction: "Federal")
        )

        XCTAssertFalse(plan.requiresPrimaryLaw)
        XCTAssertFalse(plan.shouldRetrievePrimaryLaw)
        XCTAssertTrue(plan.shouldRetrieveCaseLaw)
    }

    func testDevelopmentsAreNotRetrievedForOrdinaryStatutoryQuestion() {
        let ordinary = LegalQueryClassifier.classify("What is the deadline to file a DBA claim?")
        XCTAssertFalse(LegalResearchSourcePlanner.plan(classification: ordinary, target: LegalSourceTarget(kind: .global)).shouldRetrieveDevelopments)

        let current = LegalQueryClassifier.classify("What are the latest proposed rules affecting DBA claims?")
        XCTAssertTrue(LegalResearchSourcePlanner.plan(classification: current, target: LegalSourceTarget(kind: .global)).shouldRetrieveDevelopments)
    }

    func testAuthorityPriorityUsesFederalHierarchyForFederalIssues() {
        let classification = LegalQueryClassifier.classify(
            "Find binding 9th Cir. authority on FLSA overtime exemptions."
        )
        let plan = LegalResearchSourcePlanner.plan(classification: classification, target: LegalSourceTarget(kind: .global))
        let labels = plan.authorityPriority.map(\.label)

        XCTAssertEqual(labels.first, "Governing federal text")
        XCTAssertTrue(labels.contains("U.S. Supreme Court"))
        XCTAssertTrue(labels.contains("Governing federal circuit"))
    }

    func testAuthorityPriorityTreatsEveryCatalogFederalCourtIDAsFederal() {
        let federalCourtIDs = Array(Set(
            JurisdictionCatalog.shared.options
                .filter { $0.system == .federal }
                .flatMap(\.courtListenerIDs)
        )).sorted()
        XCTAssertTrue(federalCourtIDs.contains("cacd"), "the catalog includes federal districts beyond the old allowlist")
        XCTAssertTrue(federalCourtIDs.contains("ded"), "D. Del. is a federal district court")

        for courtID in federalCourtIDs {
            let classification = LegalQueryClassification(
                legalIssue: "motion to dismiss standard",
                courtIDs: [courtID]
            )
            let plan = LegalResearchSourcePlanner.plan(
                classification: classification,
                target: LegalSourceTarget(kind: .global)
            )
            XCTAssertEqual(
                plan.authorityPriority.first?.label,
                "Governing federal text",
                "courtID \(courtID) should use the federal authority hierarchy"
            )
        }
    }

    func testAuthorityPriorityKeepsCaliforniaStateHierarchy() {
        let classification = LegalQueryClassifier.classify(
            "Find California authority on non-compete agreements."
        )
        let plan = LegalResearchSourcePlanner.plan(classification: classification, target: LegalSourceTarget(kind: .global))
        let labels = plan.authorityPriority.map(\.label)

        XCTAssertEqual(labels.first, "Governing state text")
        XCTAssertTrue(labels.contains("State court of last resort"))
        XCTAssertFalse(labels.contains("Governing federal circuit"))
    }

    func testAnswerExemplarDoesNotInjectSpecificLimitationsPeriod() {
        let prompt = LegalResearchPromptBuilder.buildAnswerPrompt(
            question: "When does a limitations period run?",
            classification: LegalQueryClassification(jurisdiction: "Federal", legalIssue: "limitations"),
            rankedAuthorities: []
        )
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("two-year statute of limitations"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("date of injury rather than discovery"))
    }
}
