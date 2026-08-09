import Foundation
import XCTest

/// T-RP-UI-07...09 exercise the native Review workbench against a hermetic,
/// synthetic Review Project. The dedicated launch flag is intentionally separate
/// from base `-uiTestMode` so unrelated hosted tests keep their smallest fixture.
@MainActor
final class CaseFileReviewHostedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTRPUI07ReviewProjectRendersFourColumnMatrixAndTwoExactRows() throws {
        // T-RP-UI-07 expected RED: `-uiTestReviewProject` is not handled, so the
        // hermetic matter has no Review Project and `review.matrix` never appears.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(
            matrix.waitForExistence(timeout: 20),
            "The dedicated Review fixture must render the native four-column matrix"
        )

        for header in ["Finding", "Generated value", "Sources", "Review"] {
            XCTAssertEqual(
                renderedElements(label: header, in: matrix).count,
                1,
                "The hosted matrix must render one exact \(header) column header"
            )
        }

        let findingRows = elements(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        XCTAssertEqual(findingRows.count, 2, "The synthetic Review Project must render two rows")

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists, "The non-default alpha finding is missing")
        XCTAssertTrue(betaFinding.exists, "The non-default beta finding is missing")

        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        XCTAssertNotEqual(alphaCellID, betaCellID, "Each Review row needs a stable, distinct cell identity")

        XCTAssertEqual(
            renderedElements(label: Fixture.alphaGeneratedValue, in: matrix).count,
            1,
            "The alpha row must render its exact persisted generated value"
        )
        XCTAssertEqual(
            renderedElements(label: Fixture.betaGeneratedValue, in: matrix).count,
            1,
            "The beta row must render its exact persisted generated value"
        )
        let alphaSources = app.buttons["review.sources.\(alphaCellID)"]
        let betaSources = app.buttons["review.sources.\(betaCellID)"]
        XCTAssertTrue(alphaSources.exists)
        XCTAssertTrue(betaSources.exists)
        XCTAssertTrue(app.buttons["review.markReviewed.\(alphaCellID)"].exists)
        XCTAssertTrue(app.buttons["review.markReviewed.\(betaCellID)"].exists)

        XCTAssertFalse(
            alphaSources.label.contains(Fixture.defaultSourceCountCanary),
            "The exact alpha Sources control must not render the zero-source default"
        )
        XCTAssertFalse(
            betaSources.label.contains(Fixture.defaultSourceCountCanary),
            "The exact beta Sources control must not render the zero-source default"
        )
    }

    func testTRPUI08BetaSourcesOpensDistinctSupportingAndContraryEvidence() throws {
        // T-RP-UI-08 expected RED: without the dedicated Review Project seed,
        // there is no beta Sources control and no inspector/evidence to inspect.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(betaFinding.exists, "The beta row did not appear")
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let sources = app.buttons["review.sources.\(betaCellID)"]
        XCTAssertTrue(sources.exists, "The beta Sources control is missing")
        XCTAssertEqual(
            sources.label,
            Fixture.betaSourceSummary,
            "The beta source count must distinguish supporting from contrary proof"
        )
        sources.click()

        let inspector = app.scrollViews["review.sourcesInspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "The beta Sources inspector did not open")
        XCTAssertGreaterThan(
            inspector.frame.midX,
            app.windows.firstMatch.frame.midX,
            "Sources must open as a trailing inspector"
        )

        for heading in ["Supporting evidence", "Contrary evidence"] {
            XCTAssertEqual(
                renderedElements(label: heading, in: inspector).count,
                1,
                "The inspector must render one exact \(heading) section"
            )
        }
        let expectedEvidence = [
            (Fixture.betaSupportingLabel, Fixture.betaSupportingExcerpt),
            (Fixture.betaContraryLabel, Fixture.betaContraryExcerpt),
        ]
        XCTAssertEqual(
            elements(in: inspector, identifierPrefix: Fixture.evidenceIdentifierPrefix).count,
            2,
            "The beta inspector must contain exactly its supporting and contrary proof cards"
        )
        for (label, excerpt) in expectedEvidence {
            XCTAssertEqual(
                evidenceElements(
                    citationLabel: label,
                    excerpt: excerpt,
                    in: inspector
                ).count,
                1,
                "The inspector is missing exact frozen evidence card \(label)"
            )
        }

        XCTAssertEqual(
            evidenceElements(
                citationLabel: Fixture.alphaCitationLabel,
                in: inspector
            ).count,
            0,
            "Opening beta Sources must not leak evidence from the alpha row"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.emptySupportingCanary, in: inspector).firstMatch.exists,
            "The supporting section must not silently render its empty-state default"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.emptyContraryCanary, in: inspector).firstMatch.exists,
            "The contrary section must not silently render its empty-state default"
        )
    }

    func testTRPUI09MarkReviewedAttestsOnlyTheBetaRow() throws {
        // T-RP-UI-09 expected RED: without the dedicated Review Project seed,
        // neither row-level Mark Reviewed control exists to drive the attestation.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists, "The alpha row did not appear")
        XCTAssertTrue(betaFinding.exists, "The beta row did not appear")
        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )

        let alphaMark = app.buttons["review.markReviewed.\(alphaCellID)"]
        let betaMark = app.buttons["review.markReviewed.\(betaCellID)"]
        let alphaReviewed = app.descendants(matching: .any)["review.reviewed.\(alphaCellID)"]
        let betaReviewed = app.descendants(matching: .any)["review.reviewed.\(betaCellID)"]
        XCTAssertTrue(alphaMark.exists, "Alpha must begin in the needs-review state")
        XCTAssertTrue(betaMark.exists, "Beta must begin in the needs-review state")
        XCTAssertFalse(alphaReviewed.exists, "Alpha must not begin with a reviewed attestation")
        XCTAssertFalse(betaReviewed.exists, "Beta must not begin with a reviewed attestation")

        betaMark.click()

        XCTAssertTrue(
            betaReviewed.waitForExistence(timeout: 10),
            "Mark Reviewed must replace beta's action with a reviewed attestation"
        )
        XCTAssertEqual(
            renderedElements(label: "Reviewed", in: matrix).count,
            1,
            "The beta attestation must visibly read Reviewed"
        )
        XCTAssertTrue(alphaMark.exists, "Reviewing beta must leave alpha actionable")
        XCTAssertFalse(alphaReviewed.exists, "Reviewing beta must not attest alpha")
        XCTAssertTrue(betaMark.waitForNonExistence(timeout: 5))
        XCTAssertEqual(
            elements(in: app, identifierPrefix: "review.reviewed.").count,
            1,
            "Exactly one row may become reviewed"
        )
        XCTAssertEqual(
            elements(in: app, identifierPrefix: "review.markReviewed.").count,
            1,
            "Exactly one other row must remain pending"
        )
        XCTAssertEqual(renderedElements(label: Fixture.alphaGeneratedValue, in: matrix).count, 1)
        XCTAssertEqual(renderedElements(label: Fixture.betaGeneratedValue, in: matrix).count, 1)
    }

    func testTRPUI10RowBoundValueEditorCancelsThenEditsOnlyBetaAndClearsReview() throws {
        // T-RP-UI-10 expected RED: generated values are inert matrix-wide Text,
        // so no row-bound value control or popover can cancel/save an attorney
        // override and return only the changed row to needs-review.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists, "The alpha row did not appear")
        XCTAssertTrue(betaFinding.exists, "The beta row did not appear")
        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )

        let alphaValue = app.buttons["review.value.\(alphaCellID)"]
        let betaValue = app.buttons["review.value.\(betaCellID)"]
        XCTAssertTrue(alphaValue.exists, "The alpha value needs its exact row-bound edit control")
        XCTAssertTrue(betaValue.exists, "The beta value needs its exact row-bound edit control")
        XCTAssertEqual(alphaValue.label, Fixture.alphaGeneratedValue)
        XCTAssertEqual(betaValue.label, Fixture.betaGeneratedValue)
        XCTAssertEqual(alphaValue.value as? String, "Generated")
        XCTAssertEqual(betaValue.value as? String, "Generated")
        XCTAssertFalse(
            alphaValue.label.contains(Fixture.betaGeneratedValue),
            "The alpha value control must not bind beta's generated value"
        )
        XCTAssertFalse(
            betaValue.label.contains(Fixture.alphaGeneratedValue),
            "The beta value control must not bind alpha's generated value"
        )

        let betaMark = app.buttons["review.markReviewed.\(betaCellID)"]
        let betaReviewed = app.descendants(matching: .any)["review.reviewed.\(betaCellID)"]
        betaMark.click()
        XCTAssertTrue(
            betaReviewed.waitForExistence(timeout: 10),
            "Beta must be reviewed before testing that an effective-value change clears it"
        )

        betaValue.click()
        let editor = app.descendants(matching: .any)["review.valueEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The beta value popover did not open")
        let generatedBaseline = editor.descendants(matching: .any)[
            "review.valueEditor.generatedValue"
        ]
        XCTAssertTrue(generatedBaseline.exists, "The editor must retain the frozen generated baseline")
        XCTAssertEqual(accessibleText(of: generatedBaseline), Fixture.betaGeneratedValue)
        let field = editor.descendants(matching: .any)["review.valueEditor.field"]
        let cancel = app.buttons["review.valueEditor.cancel"]
        let save = app.buttons["review.valueEditor.save"]
        XCTAssertTrue(field.exists, "The reviewed-value field is missing")
        XCTAssertTrue(cancel.exists, "The editor needs an explicit Cancel action")
        XCTAssertTrue(save.exists, "The editor needs an explicit Save changes action")
        replaceText(in: field, with: Fixture.cancelledBetaEdit)
        cancel.click()

        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Cancel must dismiss the editor")
        XCTAssertEqual(betaValue.label, Fixture.betaGeneratedValue)
        XCTAssertEqual(betaValue.value as? String, "Generated")
        XCTAssertTrue(betaReviewed.exists, "Cancelling must not clear the prior beta attestation")
        XCTAssertFalse(
            app.descendants(matching: .any)["review.edited.\(betaCellID)"].exists,
            "Cancel must not leave an Edited marker"
        )

        betaValue.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The beta editor did not reopen")
        let reopenedField = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertTrue(reopenedField.exists)
        replaceText(in: reopenedField, with: Fixture.editedBetaValue)
        let reopenedSave = app.buttons["review.valueEditor.save"]
        XCTAssertTrue(reopenedSave.isEnabled, "A non-default reviewed value must enable Save changes")
        reopenedSave.click()

        let editedBetaValue = valueButton(
            in: app,
            cellID: betaCellID,
            displayedValue: Fixture.editedBetaValue
        )
        XCTAssertTrue(
            editedBetaValue.waitForExistence(timeout: 10),
            "Saving must replace beta's displayed effective value"
        )
        XCTAssertEqual(editedBetaValue.value as? String, "Edited")
        XCTAssertFalse(
            editedBetaValue.label.contains(Fixture.betaGeneratedValue),
            "Beta's exact value control must not keep displaying the generated default after Save"
        )
        let betaEdited = app.descendants(matching: .any)["review.edited.\(betaCellID)"]
        XCTAssertTrue(betaEdited.waitForExistence(timeout: 5), "Beta needs a visible Edited marker")
        XCTAssertEqual(accessibleText(of: betaEdited), "Edited")
        XCTAssertFalse(
            app.descendants(matching: .any)["review.edited.\(alphaCellID)"].exists,
            "Editing beta must not mark alpha as edited"
        )
        XCTAssertEqual(alphaValue.label, Fixture.alphaGeneratedValue)
        XCTAssertEqual(alphaValue.value as? String, "Generated")
        XCTAssertFalse(
            alphaValue.label.contains(Fixture.editedBetaValue),
            "The beta override must stay absent from alpha's exact value control"
        )
        XCTAssertTrue(
            betaReviewed.waitForNonExistence(timeout: 5),
            "Changing beta's effective value must clear its prior Reviewed attestation"
        )
        XCTAssertTrue(
            app.buttons["review.markReviewed.\(betaCellID)"].waitForExistence(timeout: 5),
            "After an effective edit, beta must return to the actionable needs-review state"
        )
    }

    func testTRPUI11EditedSourcesStayBoundToGeneratedProofAndUseGeneratedRestoresBeta() throws {
        // T-RP-UI-11 expected RED: there is no attorney-edited state, no warning
        // that frozen Sources prove the generated result rather than the override,
        // and no reversible Use generated value action scoped to beta.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")
        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists)
        XCTAssertTrue(betaFinding.exists)
        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let alphaValue = app.buttons["review.value.\(alphaCellID)"]
        let betaValue = app.buttons["review.value.\(betaCellID)"]
        XCTAssertTrue(alphaValue.exists)
        XCTAssertTrue(betaValue.exists)

        betaValue.click()
        let editor = app.descendants(matching: .any)["review.valueEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The beta value editor did not open")
        let generatedBaseline = editor.descendants(matching: .any)[
            "review.valueEditor.generatedValue"
        ]
        XCTAssertTrue(generatedBaseline.exists)
        XCTAssertEqual(accessibleText(of: generatedBaseline), Fixture.betaGeneratedValue)
        let field = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertTrue(field.exists)
        replaceText(in: field, with: Fixture.editedBetaValue)
        app.buttons["review.valueEditor.save"].click()
        let editedBetaValue = valueButton(
            in: app,
            cellID: betaCellID,
            displayedValue: Fixture.editedBetaValue
        )
        XCTAssertTrue(editedBetaValue.waitForExistence(timeout: 10))

        let inspector = app.scrollViews["review.sourcesInspector"]
        if !inspector.exists {
            app.buttons["review.sources.\(betaCellID)"].click()
        }
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "Beta Sources did not open")
        let editedNotice = inspector.descendants(matching: .any)["review.sourcesEditedNotice"]
        XCTAssertTrue(
            editedNotice.waitForExistence(timeout: 5),
            "Edited beta needs a visible generated-proof warning"
        )
        XCTAssertEqual(accessibleText(of: editedNotice), Fixture.editedSourcesWarning)
        let inspectorBaseline = inspector.descendants(matching: .any)[
            "review.sourcesGeneratedValue.\(betaCellID)"
        ]
        XCTAssertTrue(inspectorBaseline.exists, "Sources must name beta's original generated result")
        XCTAssertEqual(accessibleText(of: inspectorBaseline), Fixture.betaGeneratedValue)
        XCTAssertEqual(
            inspector.descendants(matching: .button).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                    Fixture.evidenceIdentifierPrefix,
                    Fixture.editedBetaValue
                )
            ).count,
            0,
            "Beta's attorney override must not be presented as a frozen evidence-card excerpt"
        )
        XCTAssertEqual(
            evidenceElements(
                citationLabel: Fixture.betaSupportingLabel,
                excerpt: Fixture.betaSupportingExcerpt,
                in: inspector
            ).count,
            1,
            "The frozen supporting proof must remain the original beta evidence"
        )
        XCTAssertEqual(
            evidenceElements(
                citationLabel: Fixture.betaContraryLabel,
                excerpt: Fixture.betaContraryExcerpt,
                in: inspector
            ).count,
            1,
            "The frozen contrary proof must remain the original beta evidence"
        )

        app.buttons["Close Sources"].click()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "Sources did not close")

        let alphaMark = app.buttons["review.markReviewed.\(alphaCellID)"]
        let alphaReviewed = app.descendants(matching: .any)["review.reviewed.\(alphaCellID)"]
        let betaMark = app.buttons["review.markReviewed.\(betaCellID)"]
        let betaReviewed = app.descendants(matching: .any)["review.reviewed.\(betaCellID)"]
        XCTAssertTrue(alphaMark.exists, "Alpha must still need review before beta is attested")
        XCTAssertFalse(alphaReviewed.exists, "Attesting beta must not pre-attest alpha")
        XCTAssertTrue(betaMark.exists, "Edited beta must be independently reviewable")
        betaMark.click()
        XCTAssertTrue(
            betaReviewed.waitForExistence(timeout: 10),
            "Beta must be Reviewed before testing the Use generated value reset"
        )

        editedBetaValue.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The edited beta editor did not reopen")
        let useGenerated = app.buttons["review.valueEditor.useGenerated"]
        XCTAssertTrue(
            useGenerated.waitForExistence(timeout: 5),
            "An edited row needs a reversible Use generated value action"
        )
        useGenerated.click()

        let restoredBetaValue = valueButton(
            in: app,
            cellID: betaCellID,
            displayedValue: Fixture.betaGeneratedValue
        )
        XCTAssertTrue(
            restoredBetaValue.waitForExistence(timeout: 10),
            "Use generated value must restore beta's original display"
        )
        XCTAssertEqual(restoredBetaValue.value as? String, "Generated")
        XCTAssertFalse(
            restoredBetaValue.label.contains(Fixture.editedBetaValue),
            "The restored beta value must not retain the attorney override"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["review.edited.\(betaCellID)"].waitForNonExistence(timeout: 5),
            "Restoring beta must remove its Edited marker"
        )
        XCTAssertTrue(
            betaReviewed.waitForNonExistence(timeout: 5),
            "Use generated value must clear beta's prior Reviewed attestation"
        )
        XCTAssertTrue(
            betaMark.waitForExistence(timeout: 5),
            "Restoring beta must return only beta to the actionable needs-review state"
        )
        XCTAssertEqual(alphaValue.label, Fixture.alphaGeneratedValue)
        XCTAssertEqual(alphaValue.value as? String, "Generated")
        XCTAssertTrue(alphaMark.exists, "Restoring beta must leave alpha's review state untouched")
        XCTAssertFalse(alphaReviewed.exists, "Restoring beta must not mark alpha Reviewed")
        XCTAssertFalse(
            alphaValue.label.contains(Fixture.editedBetaValue),
            "Restoring beta must leave alpha's exact value control untouched"
        )
    }

    func testTRPUI14ProgressAndAttentionFiltersReconcileHiddenSourcesAndExplicitEmptyState() throws {
        // T-RP-UI-14 expected RED: the Review workbench has no full-project
        // progress summary or accessible All / Needs review / Edited / Evidence
        // attention filter controls. Filtering also cannot close Sources when its
        // selected row becomes hidden or distinguish a filtered-empty result from
        // a genuinely empty persisted Review Project.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let controlStrip = app.descendants(matching: .any)["review.controlStrip"]
        let progress = app.descendants(matching: .any)["review.progress"]
        let filters = app.descendants(matching: .any)["review.filters"]
        let filterMenu = app.descendants(matching: .any)["review.filter.menu"]
        XCTAssertTrue(
            controlStrip.waitForExistence(timeout: 10),
            "Review needs one compact progress-and-filter control strip"
        )
        XCTAssertTrue(progress.exists, "The full-project progress summary is missing")
        XCTAssertTrue(filters.exists, "The accessible filter group is missing")
        XCTAssertTrue(
            filterMenu.exists
                || app.descendants(matching: .any)["review.filter.all"].exists,
            "Review must render either its wide inline filters or compact filter menu"
        )
        XCTAssertTrue(
            waitForAccessibleText(
                "0 of 2 findings reviewed",
                in: progress,
                timeout: 5
            ),
            "Initial progress must use the full two-row project, not a filtered subset"
        )
        XCTAssertTrue(
            waitForActiveReviewFilter(
                identifier: "review.filter.all",
                label: "All",
                app: app,
                timeout: 5
            ),
            "The initial filter must visibly and accessibly be All"
        )

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists, "The alpha filter canary row is missing")
        XCTAssertTrue(betaFinding.exists, "The beta filter canary row is missing")
        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )

        app.buttons["review.sources.\(alphaCellID)"].click()
        let inspector = app.scrollViews["review.sourcesInspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "Alpha Sources did not open")

        selectReviewFilter(
            identifier: "review.filter.evidenceAttention",
            label: "Evidence attention",
            app: app
        )

        XCTAssertTrue(
            alphaFinding.waitForNonExistence(timeout: 5),
            "Evidence attention must hide alpha's supporting-only row"
        )
        XCTAssertTrue(betaFinding.exists, "Beta's contrary evidence must keep it visible")
        XCTAssertEqual(
            elements(in: matrix, identifierPrefix: Fixture.findingIdentifierPrefix).count,
            1,
            "Evidence attention must render exactly the non-default beta canary"
        )
        XCTAssertTrue(
            inspector.waitForNonExistence(timeout: 5),
            "Filtering out the selected alpha row must close its Sources inspector"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.alphaGeneratedValue, in: matrix).firstMatch.exists,
            "A hidden row's generated value must not remain in the filtered matrix"
        )
        XCTAssertTrue(
            waitForActiveReviewFilter(
                identifier: "review.filter.evidenceAttention",
                label: "Evidence attention",
                app: app,
                timeout: 5
            ),
            "The filter menu must expose its non-default active value"
        )

        selectReviewFilter(identifier: "review.filter.all", label: "All", app: app)
        XCTAssertTrue(alphaFinding.waitForExistence(timeout: 5))
        XCTAssertTrue(betaFinding.exists)

        let betaMark = app.buttons["review.markReviewed.\(betaCellID)"]
        let betaReviewed = app.descendants(matching: .any)["review.reviewed.\(betaCellID)"]
        XCTAssertTrue(betaMark.exists, "Beta must begin actionable")
        betaMark.click()
        XCTAssertTrue(betaReviewed.waitForExistence(timeout: 10), "Beta did not become Reviewed")
        XCTAssertTrue(
            waitForAccessibleText(
                "1 of 2 findings reviewed",
                in: progress,
                timeout: 10
            ),
            "Progress must advance after beta is reviewed"
        )

        selectReviewFilter(
            identifier: "review.filter.needsReview",
            label: "Needs review",
            app: app
        )
        XCTAssertTrue(alphaFinding.exists, "Needs review must retain pending alpha")
        XCTAssertTrue(
            betaFinding.waitForNonExistence(timeout: 5),
            "Needs review must exclude the reviewed beta absence canary"
        )
        XCTAssertEqual(
            elements(in: matrix, identifierPrefix: Fixture.findingIdentifierPrefix).count,
            1
        )
        XCTAssertTrue(
            waitForAccessibleText(
                "1 of 2 findings reviewed",
                in: progress,
                timeout: 5
            ),
            "Filtering to one row must not shrink the full-project progress denominator"
        )

        selectReviewFilter(identifier: "review.filter.all", label: "All", app: app)
        let alphaValue = app.buttons["review.value.\(alphaCellID)"]
        XCTAssertTrue(alphaValue.exists, "All must restore alpha's exact value control")
        alphaValue.click()
        let editor = app.descendants(matching: .any)["review.valueEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Alpha's value editor did not open")
        let field = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertTrue(field.exists)
        replaceText(in: field, with: Fixture.editedAlphaValue)
        app.buttons["review.valueEditor.save"].click()

        let editedAlphaValue = valueButton(
            in: app,
            cellID: alphaCellID,
            displayedValue: Fixture.editedAlphaValue
        )
        XCTAssertTrue(
            editedAlphaValue.waitForExistence(timeout: 10),
            "The non-default alpha override did not persist to its exact row"
        )
        XCTAssertFalse(
            editedAlphaValue.label.contains(Fixture.alphaGeneratedValue),
            "Edited alpha must not keep rendering its generated default"
        )
        let alphaMark = app.buttons["review.markReviewed.\(alphaCellID)"]
        let alphaReviewed = app.descendants(matching: .any)["review.reviewed.\(alphaCellID)"]
        XCTAssertTrue(alphaMark.exists, "Editing alpha must leave it ready for fresh review")
        alphaMark.click()
        XCTAssertTrue(alphaReviewed.waitForExistence(timeout: 10), "Alpha did not become Reviewed")
        XCTAssertTrue(
            waitForAccessibleText(
                "2 of 2 findings reviewed",
                in: progress,
                timeout: 10
            ),
            "Progress must report the completed full project"
        )

        selectReviewFilter(identifier: "review.filter.edited", label: "Edited", app: app)
        XCTAssertTrue(alphaFinding.exists, "Edited must retain attorney-edited alpha")
        XCTAssertTrue(
            betaFinding.waitForNonExistence(timeout: 5),
            "Edited must exclude beta's generated-value absence canary"
        )
        XCTAssertTrue(editedAlphaValue.exists)
        XCTAssertTrue(
            waitForAccessibleText(
                "2 of 2 findings reviewed",
                in: progress,
                timeout: 5
            ),
            "Edited filtering must not change completed-project progress"
        )

        selectReviewFilter(
            identifier: "review.filter.evidenceAttention",
            label: "Evidence attention",
            app: app
        )
        XCTAssertTrue(betaFinding.exists, "Contrary beta must remain evidence attention")
        XCTAssertTrue(
            alphaFinding.waitForNonExistence(timeout: 5),
            "Edited-but-supported alpha must not satisfy Evidence attention"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.editedAlphaValue, in: matrix).firstMatch.exists,
            "The hidden edited alpha value must not leak through the evidence predicate"
        )

        selectReviewFilter(
            identifier: "review.filter.needsReview",
            label: "Needs review",
            app: app
        )
        let filteredEmpty = app.descendants(matching: .any)["review.filteredEmpty"]
        let showAll = app.buttons["review.filter.showAll"]
        XCTAssertTrue(
            filteredEmpty.waitForExistence(timeout: 5),
            "A zero-match filter needs an explicit filtered-empty state"
        )
        XCTAssertTrue(showAll.exists, "Filtered-empty state needs one accessible Show All escape")
        XCTAssertTrue(
            showAll.isHittable,
            "Filtered-empty Show All must remain visibly usable"
        )
        XCTAssertEqual(showAll.label, "Show all findings")
        XCTAssertEqual(
            elements(in: matrix, identifierPrefix: Fixture.findingIdentifierPrefix).count,
            0,
            "Both reviewed rows must be absent from Needs review"
        )
        XCTAssertTrue(
            waitForAccessibleText(
                "2 of 2 findings reviewed",
                in: progress,
                timeout: 5
            ),
            "Filtered-empty is not an empty project and must retain full progress"
        )

        showAll.click()
        XCTAssertTrue(
            waitForActiveReviewFilter(
                identifier: "review.filter.all",
                label: "All",
                app: app,
                timeout: 10
            ),
            "Show All must visibly reset the active filter"
        )
        let restoredAlphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let restoredBetaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(
            restoredAlphaFinding.waitForExistence(timeout: 10),
            "Show All must restore alpha"
        )
        XCTAssertTrue(restoredBetaFinding.exists, "Show All must restore beta")
        XCTAssertEqual(
            elements(in: matrix, identifierPrefix: Fixture.findingIdentifierPrefix).count,
            2
        )
        let restoredEditedAlphaValue = valueButton(
            in: app,
            cellID: alphaCellID,
            displayedValue: Fixture.editedAlphaValue
        )
        XCTAssertTrue(
            restoredEditedAlphaValue.exists,
            "Filtering must not discard alpha's persisted edit"
        )
    }

    func testTRPUI15DirtyDraftCancelKeepsProjectAndDiscardSwitchesWithoutCrossProjectLeak() throws {
        // T-RP-UI-15 expected RED: `-uiTestReviewProjectSwitching` is unhandled,
        // so no second synthetic Review Project or project Picker exists. The
        // current direct Picker binding also has no dirty-draft Cancel / Discard
        // boundary and clears the editor as soon as selectedProjectID changes.
        let app = launchReviewProject(
            additionalArguments: ["-uiTestReviewProjectSwitching"]
        )
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let projectPicker = app.descendants(matching: .any)["review.projectPicker"]
        XCTAssertTrue(
            projectPicker.waitForExistence(timeout: 10),
            "The two-project fixture needs one accessible Review Project Picker"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 5),
            "The newer fixed Project A must be selected deterministically"
        )

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists)
        XCTAssertTrue(betaFinding.exists)
        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaValue = app.buttons["review.value.\(betaCellID)"]
        XCTAssertTrue(betaValue.exists)
        XCTAssertEqual(betaValue.label, Fixture.betaGeneratedValue)
        betaValue.click()

        let editor = app.descendants(matching: .any)["review.valueEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Project A's beta editor did not open")
        let field = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertTrue(field.exists)
        clearText(in: field)
        XCTAssertEqual(
            field.value as? String,
            "",
            "Deleting Project A's value must produce one exact empty dirty draft"
        )
        XCTAssertFalse(
            app.buttons["review.valueEditor.save"].isEnabled,
            "An empty draft must remain unsaveable even though navigation treats it as dirty"
        )

        selectReviewProject(Fixture.projectBTitle, app: app)
        let cancelSwitch = app.buttons["review.projectSwitch.cancel"]
        let discardSwitch = app.buttons["review.projectSwitch.discard"]
        XCTAssertTrue(
            cancelSwitch.waitForExistence(timeout: 5),
            "A dirty Project A draft must offer Cancel before selecting B"
        )
        XCTAssertTrue(discardSwitch.exists, "A dirty Project A draft must offer explicit Discard")
        cancelSwitch.click()

        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 5),
            "Cancel must keep Project A selected"
        )
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Cancel must retain the value editor")
        let retainedField = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertEqual(
            retainedField.value as? String,
            "",
            "Keep editing must retain Project A's exact empty unsaved draft"
        )
        XCTAssertFalse(app.buttons["review.valueEditor.save"].isEnabled)
        XCTAssertTrue(alphaFinding.exists)
        XCTAssertTrue(betaFinding.exists)
        XCTAssertFalse(
            element(
                in: matrix,
                identifierPrefix: Fixture.findingIdentifierPrefix,
                value: Fixture.projectBFinding
            ).exists,
            "Cancelling the switch must not render Project B's canary row"
        )
        XCTAssertTrue(
            valueButton(
                in: app,
                cellID: betaCellID,
                displayedValue: Fixture.betaGeneratedValue
            ).exists,
            "An unsaved draft must not replace Project A's persisted beta value"
        )

        selectReviewProject(Fixture.projectBTitle, app: app)
        XCTAssertTrue(discardSwitch.waitForExistence(timeout: 5))
        discardSwitch.click()

        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Discard must close Project A's editor")
        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectBTitle, in: projectPicker, timeout: 10),
            "Discard must complete the pending switch to Project B"
        )
        let projectBFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.projectBFinding
        )
        XCTAssertTrue(projectBFinding.waitForExistence(timeout: 10), "Project B's row did not appear")
        let projectBCellID = try cellID(
            of: projectBFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        XCTAssertEqual(
            elements(in: matrix, identifierPrefix: Fixture.findingIdentifierPrefix).count,
            1,
            "The minimum Project B fixture must expose exactly its own one row"
        )
        XCTAssertTrue(alphaFinding.waitForNonExistence(timeout: 5))
        XCTAssertTrue(betaFinding.waitForNonExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["review.row.\(alphaCellID)"].exists,
            "Project A alpha identity must not cross into B"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["review.row.\(betaCellID)"].exists,
            "Project A beta identity must not cross into B"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.alphaGeneratedValue, in: matrix).firstMatch.exists,
            "Project A alpha value must be absent from B's exact matrix"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.betaGeneratedValue, in: matrix).firstMatch.exists,
            "Project A beta value must be absent from B's exact matrix"
        )
        let projectBValue = valueButton(
            in: app,
            cellID: projectBCellID,
            displayedValue: Fixture.projectBGeneratedValue
        )
        XCTAssertTrue(projectBValue.exists, "Project B's exact generated value is missing")
        XCTAssertEqual(projectBValue.value as? String, "Generated")
        projectBValue.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Project B's editor did not open")
        let projectBField = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertEqual(
            projectBField.value as? String,
            Fixture.projectBGeneratedValue,
            "Project B's editor must begin from B's generated value, not A's draft"
        )
        XCTAssertNotEqual(
            projectBField.value as? String,
            "",
            "Project A's discarded empty draft must not cross into Project B"
        )
        app.buttons["review.valueEditor.cancel"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))

        selectReviewProject(Fixture.projectATitle, app: app)
        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 10),
            "A clean Project B must switch back to A without a discard prompt"
        )
        XCTAssertFalse(cancelSwitch.exists)
        XCTAssertFalse(discardSwitch.exists)
        XCTAssertTrue(alphaFinding.waitForExistence(timeout: 10))
        XCTAssertTrue(betaFinding.exists)
        XCTAssertTrue(projectBFinding.waitForNonExistence(timeout: 5))
        XCTAssertFalse(
            renderedElements(label: Fixture.projectBGeneratedValue, in: matrix).firstMatch.exists,
            "Project B's value must not cross back into Project A"
        )

        let restoredBetaValue = valueButton(
            in: app,
            cellID: betaCellID,
            displayedValue: Fixture.betaGeneratedValue
        )
        XCTAssertTrue(restoredBetaValue.exists)
        XCTAssertEqual(restoredBetaValue.value as? String, "Generated")
        XCTAssertFalse(app.descendants(matching: .any)["review.edited.\(betaCellID)"].exists)
        restoredBetaValue.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let reopenedAField = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertEqual(
            reopenedAField.value as? String,
            Fixture.betaGeneratedValue,
            "Returning to A must rebuild the editor from its persisted generated value"
        )
        XCTAssertNotEqual(
            reopenedAField.value as? String,
            "",
            "Project A's discarded empty draft must not survive project navigation"
        )
    }

    func testTRPUI16FailedProjectSwitchRetainsExactDraftForResume() throws {
        // T-RP-UI-16 expected RED: the dedicated failure flag is unhandled and
        // `discardAndPerformPendingNavigation` clears the editor before project
        // selection can report success. A failed switch therefore cannot leave
        // Project A's exact dirty draft available through Unsaved edit / Resume.
        let app = launchReviewProject(additionalArguments: [
            "-uiTestReviewProjectSwitching",
            "-uiTestReviewNavigationFailure",
        ])
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")
        let projectPicker = app.descendants(matching: .any)["review.projectPicker"]
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 5),
            "Project A must be selected before the failure canary is exercised"
        )

        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(betaFinding.exists)
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaValue = valueButton(
            in: app,
            cellID: betaCellID,
            displayedValue: Fixture.betaGeneratedValue
        )
        XCTAssertTrue(betaValue.exists)
        betaValue.click()

        let editor = app.descendants(matching: .any)["review.valueEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let field = editor.descendants(matching: .any)["review.valueEditor.field"]
        replaceText(in: field, with: Fixture.failedProjectSwitchDraft)
        XCTAssertEqual(field.value as? String, Fixture.failedProjectSwitchDraft)

        selectReviewProject(Fixture.projectBTitle, app: app)
        let discard = app.buttons["review.projectSwitch.discard"]
        XCTAssertTrue(
            discard.waitForExistence(timeout: 5),
            "The exact dirty draft must require confirmation before the failing switch"
        )
        discard.click()

        XCTAssertTrue(
            app.staticTexts[Fixture.corruptProjectMessage].waitForExistence(timeout: 10),
            "The failed project selection must remain visibly explained"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 5),
            "A failed switch must leave Project A selected"
        )
        XCTAssertTrue(betaFinding.exists, "Project A's beta row must remain rendered")
        XCTAssertTrue(
            valueButton(
                in: app,
                cellID: betaCellID,
                displayedValue: Fixture.betaGeneratedValue
            ).exists,
            "The unsaved canary must not replace Project A's persisted generated value"
        )
        XCTAssertFalse(
            element(
                in: matrix,
                identifierPrefix: Fixture.findingIdentifierPrefix,
                value: Fixture.projectBFinding
            ).exists,
            "The failed destination's row must not cross into Project A"
        )

        let unsavedEdit = app.descendants(matching: .any)["review.unsavedEdit"]
        let resume = app.buttons["review.unsavedEdit.resume"]
        XCTAssertTrue(
            unsavedEdit.waitForExistence(timeout: 5),
            "Failed navigation must retain an explicit recoverable dirty-draft state"
        )
        XCTAssertTrue(resume.isHittable, "The retained draft must be resumable")
        resume.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Resume must reopen the exact editor")
        let resumedField = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertEqual(
            resumedField.value as? String,
            Fixture.failedProjectSwitchDraft,
            "Failed navigation must preserve the exact non-default draft byte-for-byte"
        )
        XCTAssertNotEqual(resumedField.value as? String, Fixture.betaGeneratedValue)
        XCTAssertTrue(app.buttons["review.valueEditor.save"].isEnabled)
    }

    func testTRPUI17FailedOpenReviewRetainsExactDraftForResume() throws {
        // T-RP-UI-17 expected RED: Open Review lacks a stable accessibility seam
        // and shares the same premature clear path as Picker navigation. The
        // dedicated failure fixture is also missing, so a valid B would destroy
        // A's dirty draft rather than retain it after a failed attempt.
        let app = launchReviewProject(additionalArguments: [
            "-uiTestReviewProjectSwitching",
            "-uiTestReviewNavigationFailure",
        ])
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")
        let projectPicker = app.descendants(matching: .any)["review.projectPicker"]
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 5))

        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(betaFinding.exists)
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaValue = valueButton(
            in: app,
            cellID: betaCellID,
            displayedValue: Fixture.betaGeneratedValue
        )
        XCTAssertTrue(betaValue.exists)
        betaValue.click()
        let editor = app.descendants(matching: .any)["review.valueEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let field = editor.descendants(matching: .any)["review.valueEditor.field"]
        replaceText(in: field, with: Fixture.failedOpenReviewDraft)
        XCTAssertEqual(field.value as? String, Fixture.failedOpenReviewDraft)

        openReviewOutput(Fixture.projectBTitle, app: app)
        let discard = app.buttons["review.projectSwitch.discard"]
        XCTAssertTrue(
            discard.waitForExistence(timeout: 5),
            "Dirty Open Review navigation must use the shared discard boundary"
        )
        discard.click()

        let failureAlert = app.sheets.firstMatch
        XCTAssertTrue(
            failureAlert.waitForExistence(timeout: 10),
            "A failed Open Review action needs its explicit failure sheet"
        )
        XCTAssertTrue(
            failureAlert.staticTexts["Review action failed"].exists,
            "A failed Open Review action needs its explicit failure alert"
        )
        XCTAssertTrue(
            failureAlert.staticTexts[Fixture.corruptProjectMessage].exists,
            "The failure alert must report the real corrupt-project boundary"
        )
        failureAlert.buttons["OK"].click()

        XCTAssertTrue(
            waitForAccessibleText(Fixture.projectATitle, in: projectPicker, timeout: 5),
            "Failed Open Review must retain Project A"
        )
        XCTAssertTrue(betaFinding.exists)
        XCTAssertFalse(
            element(
                in: matrix,
                identifierPrefix: Fixture.findingIdentifierPrefix,
                value: Fixture.projectBFinding
            ).exists,
            "The failed Open Review destination must remain absent"
        )
        XCTAssertTrue(
            valueButton(
                in: app,
                cellID: betaCellID,
                displayedValue: Fixture.betaGeneratedValue
            ).exists,
            "The failed action must not persist the unsaved draft"
        )

        let resume = app.buttons["review.unsavedEdit.resume"]
        XCTAssertTrue(
            resume.waitForExistence(timeout: 5),
            "The failed Open Review draft must remain available for Resume"
        )
        resume.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let resumedField = editor.descendants(matching: .any)["review.valueEditor.field"]
        XCTAssertEqual(resumedField.value as? String, Fixture.failedOpenReviewDraft)
        XCTAssertNotEqual(resumedField.value as? String, Fixture.betaGeneratedValue)
        XCTAssertTrue(app.buttons["review.valueEditor.save"].isEnabled)
    }

    func testTRPUI18MinimumWidthSourcesKeepsProgressAndCompactFilterUsable() throws {
        // T-RP-UI-18 expected RED: Sources has no stable whole-panel geometry
        // seam and overlays the entire workbench while the strip reserves raw
        // `sourcesWidth`. At the supported minimum, progress/filter controls can
        // therefore be covered or clipped even while AX descendants stay mounted.
        let app = launchReviewProject(additionalArguments: [
            "-uiTestWindowWidth", "880",
        ])
        let window = app.windows.firstMatch
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")
        XCTAssertLessThan(
            window.frame.width,
            1_000,
            "The hosted gate must exercise a supported narrow window, not the 1,100-point default"
        )
        XCTAssertGreaterThanOrEqual(window.frame.width, 879)

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists)
        XCTAssertTrue(betaFinding.exists)
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        app.buttons["review.sources.\(betaCellID)"].click()

        let inspector = app.scrollViews["review.sourcesInspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "Beta Sources did not open")
        XCTAssertGreaterThan(
            inspector.frame.width,
            600,
            "The wide-Sources canary must exercise the panel's effective maximum at minimum width"
        )
        let sourcesPanel = app.descendants(matching: .any)["review.sourcesPanel"]
        XCTAssertTrue(
            sourcesPanel.waitForExistence(timeout: 5),
            "The whole Sources panel needs a stable geometry surface"
        )

        let progress = app.descendants(matching: .any)["review.progress"]
        let filterMenu = app.descendants(matching: .any)["review.filter.menu"]
        XCTAssertTrue(progress.exists, "Review progress must remain mounted above Sources")
        XCTAssertTrue(
            waitForAccessibleText("0 of 2 findings reviewed", in: progress, timeout: 5),
            "Sources must not change or hide the full-project progress denominator"
        )
        XCTAssertTrue(
            window.frame.contains(progress.frame) && !progress.frame.isEmpty,
            "Progress must remain visibly inside the minimum-width window"
        )
        XCTAssertFalse(
            progress.frame.intersects(sourcesPanel.frame),
            "Sources must overlay only Matrix results, not the progress strip"
        )
        XCTAssertTrue(
            filterMenu.waitForExistence(timeout: 5),
            "Sources-open compact layout needs one visible filter menu"
        )
        XCTAssertTrue(
            window.frame.contains(filterMenu.frame) && filterMenu.isHittable,
            "The compact filter must remain inside the minimum-width window and pointer reachable"
        )
        XCTAssertFalse(
            filterMenu.frame.intersects(sourcesPanel.frame),
            "Sources must not cover the compact filter"
        )

        selectReviewFilter(
            identifier: "review.filter.evidenceAttention",
            label: "Evidence attention",
            app: app
        )
        XCTAssertTrue(betaFinding.exists, "Beta's contrary evidence must remain visible")
        XCTAssertTrue(alphaFinding.waitForNonExistence(timeout: 5))
        XCTAssertTrue(inspector.exists, "Filtering to selected beta must keep its Sources open")
        XCTAssertTrue(
            waitForAccessibleText("0 of 2 findings reviewed", in: progress, timeout: 5),
            "Filtering under Sources must retain the full project denominator"
        )
    }

    func testTRPCREATEUI01NewReviewSetupUsesExactSelectedScopeAndDurableSubmission() throws {
        // T-RP-CREATE-UI-01 expected RED: `-uiTestReviewCreation` is unhandled,
        // so Review has no New Review action, exact scope preview, managed-model
        // readiness, fixed-column disclosure, or durable queued handoff.
        // Hardening RED: the current pre-Start picker says `Verified`, even though
        // fresh content verification begins only after Start Review is chosen.
        // Native-AX RED: the visible `Name` caption is not programmatically
        // associated with its field, so VoiceOver receives the placeholder example
        // as the field label instead of keeping label and placeholder distinct.
        let app = launchReviewCreation(scenario: "setup")
        let newReview = app.buttons["review.newReview"]
        XCTAssertTrue(
            newReview.waitForExistence(timeout: 10),
            "Review needs one stable New Review action"
        )
        newReview.click()

        let setup = app.descendants(matching: .any)["review.creation.sheet"]
        XCTAssertTrue(
            setup.waitForExistence(timeout: 10),
            "New Review must open its native setup sheet"
        )
        let name = setup.descendants(matching: .any)["review.creation.name"]
        let instruction = setup.descendants(matching: .any)["review.creation.instruction"]
        let allScope = setup.descendants(matching: .any)["review.creation.scope.all"]
        let selectedScope = setup.descendants(matching: .any)["review.creation.scope.selected"]
        let model = setup.descendants(matching: .any)["review.creation.model"]
        let denominator = setup.descendants(matching: .any)["review.creation.scopeSummary"]
        let columnPreview = setup.descendants(matching: .any)["review.creation.columnPreview"]
        let disclosure = setup.descendants(matching: .any)["review.creation.disclosure"]
        let start = app.buttons["review.creation.start"]

        for control in [name, instruction, allScope, selectedScope, model, denominator, columnPreview, disclosure] {
            XCTAssertTrue(control.exists, "New Review is missing required setup control \(control.identifier)")
        }
        XCTAssertTrue(start.exists, "New Review needs one explicit Start Review action")
        XCTAssertFalse(start.isEnabled, "Blank name and instruction must keep Start Review disabled")
        XCTAssertEqual(
            name.label,
            "Name",
            "The Review Project name field must expose its visible purpose to native accessibility"
        )
        XCTAssertEqual(
            name.placeholderValue,
            Fixture.creationNamePlaceholder,
            "The example project name must remain a placeholder rather than becoming the field label"
        )
        XCTAssertNotEqual(
            name.label,
            Fixture.creationNamePlaceholder,
            "Native accessibility must not conflate the Name label with its example value"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationWholeScopeSummary, in: denominator, timeout: 5),
            "Whole-matter scope must expose the exact eligible and excluded denominator"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationModelName, in: model, timeout: 5),
            "Setup must name the exact app-managed local-model candidate"
        )
        XCTAssertEqual(
            model.label,
            Fixture.creationModelPickerLabel,
            "The pre-Start picker must describe management, not claim fresh verification"
        )
        XCTAssertFalse(
            accessibleText(of: model).contains("Verified"),
            "Fresh model verification belongs to the Start action, not the picker receipt"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationDisclosure, in: disclosure, timeout: 5),
            "Setup must disclose its frozen local execution boundary"
        )
        let fixedColumns = ["Finding", "Generated value", "Sources", "Review"]
        for column in fixedColumns {
            XCTAssertEqual(
                renderedElements(label: column, in: columnPreview).count,
                1,
                "The setup preview must expose one exact fixed \(column) column"
            )
        }
        // Visual-polish RED: the priority-only preview collapses Finding to 20 points,
        // leaving the fixed Matrix promise mounted in AX but visibly illegible.
        let columnFrames = fixedColumns.map {
            renderedElements(label: $0, in: columnPreview).firstMatch.frame
        }
        let minimumLegibleWidths: [CGFloat] = [30, 70, 38, 32]
        for (column, frame) in zip(fixedColumns, columnFrames) {
            XCTAssertGreaterThan(
                frame.width,
                minimumLegibleWidths[fixedColumns.firstIndex(of: column)!],
                "The fixed \(column) column must remain visibly legible, not only mounted in accessibility"
            )
            XCTAssertGreaterThanOrEqual(
                frame.minX,
                columnPreview.frame.minX - 1,
                "The fixed \(column) column must remain inside the preview's leading edge"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                columnPreview.frame.maxX + 1,
                "The fixed \(column) column must remain inside the preview's trailing edge"
            )
        }
        for (left, right) in zip(columnFrames, columnFrames.dropFirst()) {
            XCTAssertLessThanOrEqual(
                left.maxX,
                right.minX + 1,
                "The fixed Review columns must retain their left-to-right visual order without overlap"
            )
        }

        let excludedRows = [
            "review.creation.excluded.reviewRequired": Fixture.creationReviewRequiredExclusion,
            "review.creation.excluded.extractionFailed": Fixture.creationExtractionFailureExclusion,
            "review.creation.excluded.importUnfinished": Fixture.creationImportUnfinishedExclusion,
        ]
        for (identifier, expected) in excludedRows {
            let row = setup.descendants(matching: .any)[identifier]
            XCTAssertTrue(row.exists, "Exact scope preview is missing excluded source \(expected)")
            XCTAssertTrue(
                waitForAccessibleText(expected, in: row, timeout: 5),
                "Excluded sources must retain their literal planner reason"
            )
        }

        selectedScope.click()
        let selectedSummary = setup.descendants(matching: .any)["review.creation.selectedSummary"]
        XCTAssertTrue(
            selectedSummary.waitForExistence(timeout: 5),
            "Selected documents needs an exact selected-source summary"
        )
        XCTAssertTrue(
            waitForAccessibleText("0 eligible selected", in: selectedSummary, timeout: 5),
            "Explicit scope must fail closed before a source is selected"
        )
        XCTAssertFalse(start.isEnabled, "Zero eligible selected sources must keep Start Review disabled")

        let amendment = setup.descendants(matching: .any)[Fixture.creationSelectedDocumentIdentifier]
        XCTAssertTrue(amendment.exists, "The non-default eligible source is missing")
        amendment.click()
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationSelectedScopeSummary, in: selectedSummary, timeout: 5),
            "Selected scope must retain the exact non-default source and count"
        )
        XCTAssertFalse(
            accessibleText(of: selectedSummary).contains(Fixture.creationDefaultOnlyDocument),
            "The selected-scope summary must not leak the unselected whole-matter canary"
        )

        replaceText(in: name, with: Fixture.creationTitle)
        replaceText(in: instruction, with: Fixture.creationInstruction)
        XCTAssertTrue(
            start.isEnabled,
            "A non-default name, instruction, exact eligible source, and managed model must enable Start Review"
        )
        start.click()

        XCTAssertTrue(
            setup.waitForNonExistence(timeout: 10),
            "Setup may close only after its durable submission succeeds"
        )
        let status = app.descendants(matching: .any)["review.creation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "The durable queued run status is missing")
        XCTAssertTrue(
            waitForAccessibleText("Queued", in: status, timeout: 5),
            "The setup fixture must remain deterministically queued after submission"
        )
        let runTitle = app.descendants(matching: .any)["review.creation.runTitle"]
        let runInstruction = app.descendants(matching: .any)["review.creation.runInstruction"]
        XCTAssertTrue(waitForAccessibleText(Fixture.creationTitle, in: runTitle, timeout: 5))
        XCTAssertTrue(waitForAccessibleText(Fixture.creationInstruction, in: runInstruction, timeout: 5))
        XCTAssertFalse(
            accessibleText(of: runTitle).contains(Fixture.creationDefaultTitleCanary),
            "The durable run-title element must not fall back to the default title canary"
        )
    }

    func testTRPCREATEUI02PausedRunSurvivesRelaunchThenResumesAndCancels() throws {
        // T-RP-CREATE-UI-02 expected RED: Review has no durable corpus-job status
        // surface or dedicated persistent hosted fixture. A paused exact run
        // therefore cannot survive a process boundary or route Resume/Cancel.
        // Copy hardening RED: progress appends `complete` to a terminal-partition
        // count that may include failed or cancelled work, overstating success.
        let storageRoot = appSandboxWritableReviewCreationRoot()
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
            try? FileManager.default.removeItem(at: storageRoot)
        }
        configureReviewCreation(
            app,
            scenario: "paused",
            persistentRoot: storageRoot
        )
        launchConfiguredReviewCreation(app)

        let status = app.descendants(matching: .any)["review.creation.status"]
        let progress = app.descendants(matching: .any)["review.creation.progress"]
        let resume = app.buttons["review.creation.resume"]
        let pause = app.buttons["review.creation.pause"]
        let cancel = app.buttons["review.creation.cancel"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "Paused Review status did not appear")
        XCTAssertTrue(waitForAccessibleText("Paused", in: status, timeout: 5))
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationPausedProgress, in: progress, timeout: 5),
            "Progress must use terminal partitions against the frozen denominator"
        )
        XCTAssertFalse(
            accessibleText(of: progress).contains("documents"),
            "Corpus partition progress must not be relabeled as document progress"
        )
        XCTAssertFalse(
            accessibleText(of: progress).contains("complete"),
            "Terminal partition progress needs a neutral state word that remains true for failure and cancellation"
        )
        XCTAssertTrue(resume.exists, "Paused work needs Resume")
        XCTAssertTrue(cancel.exists, "Paused work needs Cancel")
        XCTAssertFalse(pause.exists, "Paused work must not advertise a second Pause")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        launchConfiguredReviewCreation(app)

        XCTAssertTrue(status.waitForExistence(timeout: 20), "Relaunched Review status did not appear")
        XCTAssertTrue(
            waitForAccessibleText("Paused", in: status, timeout: 5),
            "Paused state must reconstruct from the same file-backed Store"
        )
        XCTAssertTrue(waitForAccessibleText(Fixture.creationPausedProgress, in: progress, timeout: 5))
        XCTAssertTrue(resume.exists, "Relaunched paused work must remain resumable")
        XCTAssertTrue(cancel.exists, "Relaunched paused work must remain cancellable")

        resume.click()
        XCTAssertTrue(
            waitForAccessibleText("Reviewing", in: status, timeout: 10),
            "Resume must route the exact persisted Review job back to active work"
        )
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Active work needs Pause")
        XCTAssertTrue(cancel.exists, "Active work needs Cancel")
        XCTAssertTrue(resume.waitForNonExistence(timeout: 5), "Active work must not retain Resume")

        cancel.click()
        XCTAssertTrue(
            waitForAccessibleText("Cancelled", in: status, timeout: 10),
            "Cancel must terminalize the exact active Review job"
        )
        XCTAssertTrue(pause.waitForNonExistence(timeout: 5))
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(resume.waitForNonExistence(timeout: 5))
    }

    func testTRPCREATEUI04SelectedScopeRejectsEveryExcludedSource() throws {
        // T-RP-CREATE-UI-04 expected RED: excluded source rows currently retain
        // document-bound Button actions in Selected documents, so review-required
        // and extraction-failed rows advertise themselves as selectable.
        // Native-AX hardening RED: All-mode receipt rows still surface as disabled
        // buttons, while selected eligible rows expose no Selected/Not selected
        // accessibility value when their checkbox state changes.
        let app = launchReviewCreation(scenario: "setup")
        let newReview = app.buttons["review.newReview"]
        XCTAssertTrue(newReview.waitForExistence(timeout: 10))
        newReview.click()

        let setup = app.descendants(matching: .any)["review.creation.sheet"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let selectedScope = setup.descendants(matching: .any)["review.creation.scope.selected"]
        XCTAssertTrue(selectedScope.exists)
        let allModeEligible = setup.descendants(matching: .any)[
            Fixture.creationDefaultDocumentIdentifier
        ]
        XCTAssertTrue(allModeEligible.exists, "All ready documents is missing its eligible receipt row")
        XCTAssertNotEqual(
            allModeEligible.elementType,
            .button,
            "All-mode eligible sources are receipt rows, not selectable controls"
        )
        selectedScope.click()

        let selectedSummary = setup.descendants(matching: .any)["review.creation.selectedSummary"]
        XCTAssertTrue(selectedSummary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForAccessibleText("0 eligible selected", in: selectedSummary, timeout: 5),
            "Selected scope must begin with an empty, fail-closed receipt"
        )

        let excludedRows = [
            ("review.creation.excluded.reviewRequired", Fixture.creationReviewRequiredDocument),
            ("review.creation.excluded.extractionFailed", Fixture.creationExtractionFailureDocument),
            ("review.creation.excluded.importUnfinished", Fixture.creationImportUnfinishedDocument),
        ]
        for (identifier, excludedName) in excludedRows {
            let row = setup.descendants(matching: .any)[identifier]
            XCTAssertTrue(row.exists, "Selected scope is missing excluded source \(excludedName)")
            XCTAssertFalse(
                row.isEnabled,
                "Excluded source \(excludedName) must not advertise a selectable control"
            )
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(
                waitForAccessibleText("0 eligible selected", in: selectedSummary, timeout: 2),
                "Pointer input on excluded source \(excludedName) must leave the receipt empty"
            )
            XCTAssertFalse(
                accessibleText(of: selectedSummary).contains(excludedName),
                "Excluded source \(excludedName) must never enter the selected-source receipt"
            )
        }

        let amendment = setup.descendants(matching: .any)[Fixture.creationSelectedDocumentIdentifier]
        XCTAssertTrue(amendment.exists)
        XCTAssertTrue(amendment.isEnabled, "An eligible source must remain selectable")
        XCTAssertEqual(
            amendment.value as? String,
            "Not selected",
            "An unselected eligible source must expose its state to native accessibility"
        )
        amendment.click()
        XCTAssertEqual(
            amendment.value as? String,
            "Selected",
            "Toggling an eligible source must expose its new selected state"
        )
        XCTAssertNotEqual(
            amendment.value as? String,
            "Not selected",
            "The selected source must not retain the default accessibility value"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationSelectedScopeSummary, in: selectedSummary, timeout: 5)
        )
        for (_, excludedName) in excludedRows {
            XCTAssertFalse(
                accessibleText(of: selectedSummary).contains(excludedName),
                "Selecting an eligible source must not leak excluded source \(excludedName) into the receipt"
            )
        }
    }

    func testTRPCREATEUI05ClosingDuringModelVerificationCancelsWithoutCreatingAJob() throws {
        // T-RP-CREATE-UI-05 expected RED: the slow-verification DEBUG scenario is
        // not implemented, setup does not expose a stable dismiss control, and its
        // unowned Task can finish after dismissal and persist a Review run/job.
        let storageRoot = appSandboxWritableReviewCreationRoot()
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
            try? FileManager.default.removeItem(at: storageRoot)
        }
        configureReviewCreation(
            app,
            scenario: "slowVerification",
            persistentRoot: storageRoot
        )
        launchConfiguredReviewCreation(app)

        let newReview = app.buttons["review.newReview"]
        XCTAssertTrue(newReview.waitForExistence(timeout: 10))
        newReview.click()
        let setup = app.descendants(matching: .any)["review.creation.sheet"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))

        let name = setup.descendants(matching: .any)["review.creation.name"]
        let instruction = setup.descendants(matching: .any)["review.creation.instruction"]
        replaceText(in: name, with: Fixture.creationCancellationTitle)
        replaceText(in: instruction, with: Fixture.creationInstruction)
        let start = app.buttons["review.creation.start"]
        XCTAssertTrue(start.isEnabled)
        start.click()
        XCTAssertTrue(
            waitForAccessibleText("Verifying model…", in: start, timeout: 3),
            "The slow fixture must hold setup in its cancellable verification phase"
        )

        let dismiss = app.buttons["review.creation.dismiss"]
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 2),
            "Setup needs one stable Cancel control while verification is active"
        )
        XCTAssertEqual(dismiss.label, "Cancel")
        XCTAssertTrue(dismiss.isEnabled, "Verification must remain explicitly cancellable")
        dismiss.click()
        XCTAssertTrue(
            setup.waitForNonExistence(timeout: 5),
            "Cancel must close setup without waiting for model verification"
        )

        let status = app.descendants(matching: .any)["review.creation.status"]
        XCTAssertFalse(
            status.waitForExistence(timeout: 5),
            "A cancelled verification must not later surface a persisted Review status"
        )
        XCTAssertEqual(
            elements(in: app, identifierPrefix: "review.creation.run").count,
            0,
            "A cancelled verification must leave zero projected creation runs"
        )
        XCTAssertTrue(
            app.buttons["review.newReview"].isEnabled,
            "Zero queued jobs must leave New Review available"
        )

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        launchConfiguredReviewCreation(app)
        XCTAssertFalse(
            app.descendants(matching: .any)["review.creation.status"].waitForExistence(timeout: 3),
            "The same throwaway Store must reconstruct zero jobs after cancelled verification"
        )
        XCTAssertEqual(
            elements(in: app, identifierPrefix: "review.creation.run").count,
            0,
            "Cancelled verification must leave no durable run across relaunch"
        )
        XCTAssertTrue(app.buttons["review.newReview"].isEnabled)
    }

    func testTRPCREATEUI06ScopeDriftRefreshesReceiptAndRequiresSecondStart() throws {
        // T-RP-CREATE-UI-06 expected RED: the scope-drift DEBUG scenario is not
        // implemented and Start submits a freshly planned whole-matter scope
        // immediately, so setup cannot stop on a changed receipt for reconfirmation.
        let app = launchReviewCreation(scenario: "scopeDrift")
        let newReview = app.buttons["review.newReview"]
        XCTAssertTrue(newReview.waitForExistence(timeout: 10))
        newReview.click()

        let setup = app.descendants(matching: .any)["review.creation.sheet"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let summary = setup.descendants(matching: .any)["review.creation.scopeSummary"]
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationWholeScopeSummary, in: summary, timeout: 5),
            "The first receipt must freeze the original two-source eligible scope"
        )
        let name = setup.descendants(matching: .any)["review.creation.name"]
        let instruction = setup.descendants(matching: .any)["review.creation.instruction"]
        replaceText(in: name, with: Fixture.creationScopeDriftTitle)
        replaceText(in: instruction, with: Fixture.creationInstruction)

        let start = app.buttons["review.creation.start"]
        XCTAssertTrue(start.isEnabled)
        start.click()

        XCTAssertTrue(
            setup.waitForExistence(timeout: 5),
            "A changed source set must keep setup open instead of silently queueing it"
        )
        let scopeChanged = setup.descendants(matching: .any)["review.creation.scopeChanged"]
        XCTAssertTrue(
            scopeChanged.waitForExistence(timeout: 5),
            "Changed scope needs one stable reconfirmation notice"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationScopeChangedNotice, in: scopeChanged, timeout: 5),
            "The notice must explain that the refreshed receipt needs a second Start"
        )
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationRefreshedScopeSummary, in: summary, timeout: 5),
            "The receipt must refresh to the exact new eligible and excluded denominator"
        )
        let lateSource = setup.descendants(matching: .any)[Fixture.creationLateDocumentIdentifier]
        XCTAssertTrue(lateSource.exists, "The refreshed receipt must name the newly ready source")
        XCTAssertTrue(
            waitForAccessibleText(Fixture.creationLateDocumentLabel, in: lateSource, timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["review.creation.status"].waitForExistence(timeout: 2),
            "Receipt drift must persist zero Review jobs before explicit reconfirmation"
        )
        XCTAssertTrue(start.isEnabled, "The refreshed receipt must offer an explicit second Start")
        XCTAssertTrue(waitForAccessibleText("Start Review", in: start, timeout: 2))

        start.click()
        XCTAssertTrue(
            setup.waitForNonExistence(timeout: 10),
            "Only the second Start may accept the refreshed receipt and close setup"
        )
        let status = app.descendants(matching: .any)["review.creation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForAccessibleText("Queued", in: status, timeout: 5))
    }

    private func launchReviewProject(
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestReviewProject",
            "-uiTestSelectFirstMatter",
            "-uiTestInitialMatterTab", "Review",
        ]
        app.launchArguments += additionalArguments
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Main window did not appear")
        XCTAssertTrue(
            app.staticTexts["McKernon Motors v. Liberty Rail"].waitForExistence(timeout: 20),
            "The synthetic matter did not open"
        )
        return app
    }

    private func launchReviewCreation(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        configureReviewCreation(app, scenario: scenario)
        launchConfiguredReviewCreation(app)
        return app
    }

    private func configureReviewCreation(
        _ app: XCUIApplication,
        scenario: String,
        persistentRoot: URL? = nil
    ) {
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestReviewCreation",
            "-uiTestReviewCreationScenario", scenario,
            "-uiTestSelectFirstMatter",
            "-uiTestInitialMatterTab", "Review",
        ]
        if let persistentRoot {
            app.launchEnvironment["SUPRA_UI_TEST_REVIEW_CREATION_ROOT"] = persistentRoot.path
        }
    }

    private func launchConfiguredReviewCreation(_ app: XCUIApplication) {
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Main window did not appear")
        XCTAssertTrue(
            app.staticTexts["McKernon Motors v. Liberty Rail"].waitForExistence(timeout: 20),
            "The synthetic matter did not open"
        )
    }

    /// The app validates this root against its own sandbox temporary directory
    /// before granting the one Review fixture cross-process Store persistence.
    private func appSandboxWritableReviewCreationRoot() -> URL {
        let runnerHome = FileManager.default.homeDirectoryForCurrentUser.path
        let containerMarker = "/Library/Containers/"
        let hostHome = runnerHome.range(of: containerMarker).map {
            String(runnerHome[..<$0.lowerBound])
        } ?? runnerHome
        return URL(fileURLWithPath: hostHome, isDirectory: true)
            .appendingPathComponent("Library/Containers/ai.supra.SupraAI/Data/tmp", isDirectory: true)
            .appendingPathComponent("ReviewCreationUITest-\(UUID().uuidString)", isDirectory: true)
    }

    private func selectReviewFilter(
        identifier: String,
        label: String,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let inlineOption = app.descendants(matching: .any)[identifier]
        if inlineOption.exists {
            inlineOption.click()
        } else {
            let menu = app.descendants(matching: .any)["review.filter.menu"]
            XCTAssertTrue(
                menu.waitForExistence(timeout: 5),
                "Neither wide nor compact Review filter controls are available",
                file: file,
                line: line
            )
            menu.click()
            let compactOption = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(
                compactOption.waitForExistence(timeout: 5),
                "Review filter option \(label) is unavailable",
                file: file,
                line: line
            )
            compactOption.click()
        }
        XCTAssertTrue(
            waitForActiveReviewFilter(
                identifier: identifier,
                label: label,
                app: app,
                timeout: 5
            ),
            "Review filters did not expose \(label) as active",
            file: file,
            line: line
        )
    }

    private func selectReviewProject(
        _ title: String,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = app.descendants(matching: .any)["review.projectPicker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "Review Project Picker is unavailable",
            file: file,
            line: line
        )
        picker.click()
        let option = app.menuItems[title]
        XCTAssertTrue(
            option.waitForExistence(timeout: 5),
            "Review Project option \(title) is unavailable",
            file: file,
            line: line
        )
        option.click()
    }

    private func openReviewOutput(
        _ title: String,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let control = app.descendants(matching: .any)["review.openReview"]
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "Open Review is unavailable",
            file: file,
            line: line
        )
        control.click()
        let option = app.menuItems[title]
        XCTAssertTrue(
            option.waitForExistence(timeout: 5),
            "Open Review output \(title) is unavailable",
            file: file,
            line: line
        )
        option.click()
    }

    private func elements(
        in scope: XCUIElement,
        identifierPrefix: String
    ) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        )
    }

    private func element(
        in scope: XCUIElement,
        identifierPrefix: String,
        value: String
    ) -> XCUIElement {
        scope.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                identifierPrefix,
                value
            )
        ).firstMatch
    }

    private func renderedElements(label: String, in scope: XCUIElement) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR value == %@ OR title == %@",
                label,
                label,
                label
            )
        )
    }

    private func valueButton(
        in app: XCUIApplication,
        cellID: String,
        displayedValue: String
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "review.value.\(cellID)",
                displayedValue
            )
        ).firstMatch
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func clearText(in field: XCUIElement) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
    }

    private func accessibleText(of element: XCUIElement) -> String {
        if !element.label.isEmpty {
            return element.label
        }
        return element.value as? String ?? ""
    }

    private func waitForAccessibleText(
        _ expected: String,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(
            format: "label == %@ OR value == %@ OR title == %@",
            expected,
            expected,
            expected
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForActiveReviewFilter(
        identifier: String,
        label: String,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let menu = app.descendants(matching: .any)["review.filter.menu"]
        if menu.exists {
            return waitForAccessibleText(label, in: menu, timeout: timeout)
        }
        let inlineOption = app.descendants(matching: .any)[identifier]
        let predicate = NSPredicate(
            format: "isSelected == true OR value == %@ OR value == 'Selected'",
            label
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: inlineOption
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func evidenceElements(
        citationLabel: String,
        excerpt: String? = nil,
        in scope: XCUIElement
    ) -> XCUIElementQuery {
        let base = scope.descendants(matching: .button).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                Fixture.evidenceIdentifierPrefix,
                "\(citationLabel),"
            )
        )
        guard let excerpt else { return base }
        return base.matching(NSPredicate(format: "label CONTAINS %@", excerpt))
    }

    private func cellID(
        of element: XCUIElement,
        identifierPrefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        XCTAssertTrue(
            element.identifier.hasPrefix(identifierPrefix),
            "Review row is missing the stable accessibility prefix",
            file: file,
            line: line
        )
        let suffix = String(element.identifier.dropFirst(identifierPrefix.count))
        XCTAssertFalse(
            suffix.isEmpty,
            "Review row accessibility identity must not use the empty/default suffix",
            file: file,
            line: line
        )
        return try XCTUnwrap(
            suffix.isEmpty ? nil : suffix,
            "Review row accessibility identity is missing",
            file: file,
            line: line
        )
    }

    private enum Fixture {
        static let findingIdentifierPrefix = "review.row."
        static let evidenceIdentifierPrefix = "review.evidence."

        static let alphaFinding = "synthetic payment deadline"
        static let alphaGeneratedValue = "March 18, 2031"
        static let editedAlphaValue = "March 21, 2031 after verified delivery"
        static let alphaCitationLabel = "E1"

        static let betaFinding = "synthetic renewal notice period"
        static let betaGeneratedValue = "120 calendar days"
        static let editedBetaValue = "105 calendar days after written notice"
        static let cancelledBetaEdit = "111 days must remain a cancelled draft"
        static let betaSourceSummary = "1 supporting · 1 contrary"
        static let betaSupportingLabel = "E2"
        static let betaContraryLabel = "E3"
        static let betaSupportingExcerpt =
            "The fictional Atlas Supply Agreement requires renewal notice at least 120 calendar days before expiration."
        static let betaContraryExcerpt =
            "A fictional amendment states that either party may give renewal notice 90 calendar days before expiration."
        static let editedSourcesWarning =
            "Sources are frozen from the generated result. They do not validate the attorney-edited value."

        static let projectATitle = "Atlas Supply Agreement review"
        static let projectBTitle = "Atlas Amendment review"
        static let projectBFinding = "synthetic amended renewal notice period"
        static let projectBGeneratedValue = "90 calendar days"
        static let failedProjectSwitchDraft = "73 days — failed project switch draft"
        static let failedOpenReviewDraft = "81 days — failed open draft"
        static let corruptProjectMessage = "The persisted Review Project graph is incomplete."

        static let creationTitle = "Atlas Amendment deadline review"
        static let creationInstruction =
            "Extract the amended renewal notice deadline and identify conflicting notice language."
        static let creationDefaultTitleCanary = "New Review"
        static let creationDefaultOnlyDocument = "Atlas Ready Agreement.txt"
        static let creationSelectedDocumentIdentifier =
            "review.creation.document.ui-review-create-amendment-document"
        static let creationDefaultDocumentIdentifier =
            "review.creation.document.ui-review-create-default-document"
        static let creationLateDocumentIdentifier =
            "review.creation.document.ui-review-create-late-document"
        static let creationWholeScopeSummary = "2 eligible · 3 excluded"
        static let creationRefreshedScopeSummary = "3 eligible · 3 excluded"
        static let creationSelectedScopeSummary = "1 eligible · Atlas Amendment.txt"
        static let creationModelPickerLabel = "Managed local model"
        static let creationModelName = "Synthetic Review Model · Managed"
        static let creationDisclosure =
            "Exact frozen corpus · Local model · runs in background"
        static let creationReviewRequiredDocument = "Beacon Review Draft.txt"
        static let creationExtractionFailureDocument = "Atlas Extraction Failure.txt"
        static let creationImportUnfinishedDocument = "Atlas Import Pending.txt"
        static let creationReviewRequiredExclusion =
            "Beacon Review Draft.txt — Review required"
        static let creationExtractionFailureExclusion =
            "Atlas Extraction Failure.txt — Extraction failed"
        static let creationImportUnfinishedExclusion =
            "Atlas Import Pending.txt — Import unfinished"
        static let creationCancellationTitle = "Cancelled Atlas verification"
        static let creationScopeDriftTitle = "Atlas refreshed-scope review"
        static let creationScopeChangedNotice =
            "Source scope changed. Review the updated receipt, then start again."
        static let creationLateDocumentLabel = "Atlas Late Addendum.txt — Ready"
        static let creationNamePlaceholder = "Lease renewal review"
        static let creationPausedProgress = "1 of 3 partitions resolved"

        static let defaultSourceCountCanary = "0 supporting"
        static let emptySupportingCanary =
            "No supporting evidence is recorded for this finding."
        static let emptyContraryCanary =
            "No contrary evidence is recorded for this finding."
    }
}

/// Source/composition gates for the first visible Case File Review slice.
/// The hosted gates above drive the native surface; these source checks retain
/// the approved composition contract without replacing interaction coverage.
final class CaseFileReviewCompositionUITests: XCTestCase {
    func testTRPUI01MatterWorkspaceComposesReviewTabAndScopedController() throws {
        // T-RP-UI-01 expected RED: MatterWorkspaceView has no Review tab or
        // CaseFileReviewView destination, and MattersController does not yet vend a
        // matter-scoped CaseFileReviewController.
        let workspace = try appSource(
            relativePath: "SupraAI/Matters/MatterWorkspaceView.swift"
        )
        let mattersController = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/MattersController.swift"
        )

        XCTAssertEqual(
            try matchCount(#"\bcase\s+review\s*=\s*"Review""#, in: workspace),
            1,
            "the existing matter tab set must gain one literal Review tab"
        )
        XCTAssertTrue(
            workspace.contains("CaseFileReviewView("),
            "the Review tab must render the dedicated native review surface"
        )
        XCTAssertTrue(
            workspace.contains("controller.caseFileReviewController"),
            "the workspace must use the selected matter's scoped review controller"
        )
        XCTAssertTrue(
            mattersController.contains(
                "@Published public private(set) var caseFileReviewController: CaseFileReviewController?"
            ),
            "MattersController must publish the scoped review controller"
        )
        XCTAssertTrue(
            mattersController.contains("caseFileReviewController = nil"),
            "clearing the selected matter must clear the review controller"
        )
        XCTAssertTrue(
            mattersController.contains("CaseFileReviewController("),
            "selecting a matter must compose a CaseFileReviewController"
        )
    }

    func testTRPUI02ReviewMatrixHasExactlyFourLiteralColumns() throws {
        // T-RP-UI-02 expected RED: CaseFileReviewView.swift does not exist, so no
        // native Table exposes the approved Finding / Generated value / Sources /
        // Review matrix.
        let review = try caseFileReviewSource()
        let expectedColumns = ["Finding", "Generated value", "Sources", "Review"]

        XCTAssertGreaterThanOrEqual(
            try matchCount(#"\bTable\s*\("#, in: review),
            1,
            "the matrix must use SwiftUI Table for the first native implementation"
        )
        for column in expectedColumns {
            XCTAssertEqual(
                try matchCount(
                    "TableColumn\\s*\\(\\s*\"\(NSRegularExpression.escapedPattern(for: column))\"",
                    in: review
                ),
                1,
                "the matrix must contain one literal \(column) column"
            )
        }
        XCTAssertEqual(
            try matchCount(#"\bTableColumn\s*\("#, in: review),
            expectedColumns.count,
            "the smallest matrix slice must not add, hide, or synthesize extra columns"
        )
        XCTAssertTrue(
            review.contains(#".accessibilityIdentifier("review.matrix")"#),
            "the matrix must expose its stable native accessibility surface"
        )
    }

    func testTRPUI03SourcesInspectorSeparatesEvidenceAndPinsAccessibilityContract() throws {
        // T-RP-UI-03 expected RED: there is no trailing Sources inspector, no
        // Supporting/Contrary evidence separation, and none of the review-specific
        // accessibility identifiers exist.
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains("SlideOverPanel("),
            "Sources must reuse Supra's trailing native inspector chrome"
        )
        XCTAssertTrue(
            review.contains("DocumentPreviewView("),
            "an inspectable source must continue into Supra's revision-aware document preview"
        )
        XCTAssertTrue(
            review.contains("Supporting evidence"),
            "supporting evidence must be named rather than folded into one source count"
        )
        XCTAssertTrue(
            review.contains("Contrary evidence"),
            "contrary evidence must remain visibly distinct from supporting evidence"
        )

        let exactIdentifiers = ["review.sourcesInspector"]
        for identifier in exactIdentifiers {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(identifier)\")"),
                "missing exact accessibility identifier \(identifier)"
            )
        }

        let dynamicIdentifierPrefixes = [
            "review.row.",
            "review.sources.",
            "review.markReviewed.",
            "review.reviewed.",
            "review.evidence.",
        ]
        for prefix in dynamicIdentifierPrefixes {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(prefix)\\("),
                "missing dynamic accessibility identifier prefix \(prefix)"
            )
        }
    }

    func testTRPUI04EvidenceRailUsesApprovedTokens() throws {
        // T-RP-UI-04 expected RED: the selected-row-to-Sources evidence rail and
        // its approved light/dark gold tokens do not exist.
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains("A77920"),
            "the light evidence-rail token must retain the approved mock-up value"
        )
        XCTAssertTrue(
            review.contains("D2AC5C"),
            "the dark evidence-rail token must retain the approved mock-up value"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "evidenceRailColor", in: review),
            3,
            "the semantic rail color must be declared and used by both matrix selection and inspector"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "evidenceRailWidth", in: review),
            3,
            "the semantic rail width must be declared and used by both sides of the evidence connection"
        )
    }

    func testTRPUI05StaleProjectStateRemainsPersistentlyVisible() throws {
        // T-RP-UI-05 expected RED: deletion can mark a durable Review Project
        // stale, but the first view draft only reveals unavailable state after
        // opening an individual source. The matrix itself must keep a literal,
        // accessible project-level notice visible.
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains(#"project.status == "stale""#),
            "the view must derive its notice from the persisted project state"
        )
        XCTAssertTrue(
            review.contains("Review source changed"),
            "stale state needs concise, literal user-facing copy"
        )
        XCTAssertTrue(
            review.contains("Frozen findings and excerpts remain available"),
            "the notice must distinguish retained review work from unavailable live proof"
        )
        XCTAssertTrue(
            review.contains(#".accessibilityIdentifier("review.staleNotice")"#),
            "the persistent stale notice needs a stable native accessibility surface"
        )
    }

    func testTRPUI06ReviewAttestationCopyAndActorRemainTruthful() throws {
        // T-RP-UI-06 expected RED: Mark Reviewed is available before Sources are
        // opened, but its hint currently claims the sources were reviewed and the
        // action writes the literal actor "user".
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains("Record that this finding was reviewed"),
            "the first attestation must describe only the finding-level action it records"
        )
        XCTAssertFalse(
            review.contains("finding and its sources were reviewed"),
            "the UI must not claim source review without requiring a Sources inspection"
        )
        XCTAssertFalse(
            review.contains(#"reviewedBy: "user""#),
            "review identity must come from the local profile rather than a literal placeholder"
        )
    }

    func testTRPUI12ValueEditorPinsPopoverProvenanceCopyAndPolishedActivityLabels() throws {
        // T-RP-UI-12 expected RED: CaseFileReviewView has no row-bound value
        // popover, edit-state/provenance accessibility contract, or explicit
        // Activity Log labels for the new audited edit and restore transitions.
        // Audit-amendment expected RED: current copy mentions Save only and omits
        // the immediate Use generated value reset that also clears Reviewed state.
        let review = try caseFileReviewSource()
        let workspace = try appSource(
            relativePath: "SupraAI/Matters/MatterWorkspaceView.swift"
        )

        let exactIdentifiers = [
            "review.valueEditor",
            "review.valueEditor.field",
            "review.valueEditor.generatedValue",
            "review.valueEditor.save",
            "review.valueEditor.cancel",
            "review.valueEditor.useGenerated",
            "review.sourcesEditedNotice",
        ]
        for identifier in exactIdentifiers {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(identifier)\")"),
                "missing exact Review value accessibility identifier \(identifier)"
            )
        }

        let dynamicIdentifierPrefixes = [
            "review.value.",
            "review.edited.",
            "review.sourcesGeneratedValue.",
        ]
        for prefix in dynamicIdentifierPrefixes {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(prefix)\\("),
                "missing row-bound Review value accessibility prefix \(prefix)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            try matchCount(#"\.popover\s*\("#, in: review),
            1,
            "the compact Review value editor must be presented as a row-anchored popover"
        )
        XCTAssertTrue(
            review.contains("Generated result"),
            "the popover must label the immutable generated baseline"
        )
        XCTAssertTrue(
            review.contains("Reviewed value"),
            "the popover must label the attorney-controlled effective value"
        )
        XCTAssertTrue(
            review.contains("Sources remain attached to the generated result."),
            "the editor must not imply frozen proof validates the override"
        )
        XCTAssertTrue(
            review.contains(
                "Changing this value—including Use generated value—clears any prior Reviewed mark."
            ),
            "the editor must disclose the review-attestation reset before Save or Use generated value"
        )
        XCTAssertTrue(
            review.contains(
                "Sources are frozen from the generated result. They do not validate the attorney-edited value."
            ),
            "edited Sources need the approved provenance warning"
        )
        XCTAssertTrue(
            review.contains("controller.editValue("),
            "Save changes must call the matter-scoped Review controller"
        )
        XCTAssertTrue(
            review.contains("controller.useGeneratedValue("),
            "Use generated value must call the reversible controller transition"
        )

        let activityLabels = [
            (
                eventType: "case_file_review_cell_value_edited",
                label: "Review Value Edited"
            ),
            (
                eventType: "case_file_review_cell_value_restored",
                label: "Generated Review Value Restored"
            ),
        ]
        for item in activityLabels {
            XCTAssertTrue(
                workspace.contains("case \"\(item.eventType)\": \"\(item.label)\""),
                "Activity Log needs the concise label \(item.label)"
            )
        }
    }

    func testTRPUI13WorkflowControlsPinAccessibleFiltersProgressAndGuardedNavigation() throws {
        // T-RP-UI-13 expected RED: the Review surface has no progress/filter
        // control strip, filtered-empty escape, or stable project-switch actions.
        // Its Picker still calls selectProject directly, and Open Review uses a
        // separate unguarded path, so one shared dirty-draft navigation boundary
        // does not exist.
        let review = try caseFileReviewSource()

        let exactIdentifiers = [
            "review.controlStrip",
            "review.progress",
            "review.filters",
            "review.filter.menu",
            "review.filter.all",
            "review.filter.needsReview",
            "review.filter.edited",
            "review.filter.evidenceAttention",
            "review.filteredEmpty",
            "review.filter.showAll",
            "review.projectPicker",
            "review.projectSwitch.cancel",
            "review.projectSwitch.discard",
        ]
        for identifier in exactIdentifiers {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(identifier)\")"),
                "missing exact Review workflow accessibility identifier \(identifier)"
            )
        }

        for label in ["All", "Needs review", "Edited", "Evidence attention"] {
            XCTAssertTrue(
                review.contains("\"\(label)\""),
                "the compact Review filter must expose the literal option \(label)"
            )
        }
        XCTAssertTrue(
            review.contains("findings reviewed"),
            "progress accessibility must literally describe N of M findings reviewed"
        )
        XCTAssertTrue(
            review.contains("Show all findings"),
            "filtered-empty state needs one literal recovery action"
        )
        XCTAssertGreaterThanOrEqual(
            try matchCount(
                #"ViewThatFits\s*\(\s*in:\s*\.horizontal\s*\)"#,
                in: review
            ),
            1,
            "wide inline filters and the compact menu must share one horizontal ViewThatFits"
        )
        XCTAssertTrue(
            review.contains("Discard value changes?"),
            "dirty Review navigation needs literal confirmation copy"
        )
        XCTAssertTrue(
            review.contains("Keep editing"),
            "the confirmation must name its draft-preserving action"
        )
        XCTAssertTrue(
            review.contains("Discard and switch"),
            "the confirmation must name its destructive navigation action"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "valueEditorIsDirty", in: review),
            2,
            "navigation dirtiness must be distinct and used, including empty drafts"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "valueEditorCanSave", in: review),
            2,
            "Save enablement must remain a separate non-empty-draft predicate"
        )

        XCTAssertFalse(
            review.contains("set: { controller.selectProject($0) }"),
            "the Project Picker must not bypass dirty-draft navigation handling"
        )
        XCTAssertGreaterThanOrEqual(
            try matchCount(
                #"set:\s*\{[^}]{0,240}requestNavigation\s*\("#,
                in: review
            ),
            1,
            "the Project Picker setter must request guarded navigation"
        )
        XCTAssertGreaterThanOrEqual(
            try matchCount(
                #"private\s+func\s+open[^\{]{0,160}\{[\s\S]{0,400}requestNavigation\s*\("#,
                in: review
            ),
            1,
            "Open Review must enter the same guarded navigation path as the Picker"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "requestNavigation(", in: review),
            3,
            "Review needs two callers plus one shared requestNavigation implementation"
        )
    }

    func testTRPCREATEUI03ProductionCompositionUsesAtomicPinnedQueueAndExactHandoff() throws {
        // T-RP-CREATE-UI-03 expected RED: production has no separate Review
        // creation controller, ModelLibrary cannot derive a managed content pin,
        // corpus preparation and queue insertion are not atomic, and the native
        // workbench has no exact ready-run handoff.
        let review = try reviewAppSources()
        let workspace = try appSource(
            relativePath: "SupraAI/Matters/MatterWorkspaceView.swift"
        )
        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        let matters = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/MattersController.swift"
        )
        let modelLibrary = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/ModelLibrary.swift"
        )
        let queue = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/DocumentProcessingQueue.swift"
        )
        let preparer = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/CorpusAnalysisQueuePreparer.swift"
        )
        let corpusRepository = try packageSource(
            relativePath: "Packages/SupraStore/Sources/SupraStore/Repositories/CorpusAnalysisRepository.swift"
        )

        XCTAssertTrue(
            matters.contains(
                "@Published public private(set) var caseFileReviewCreationController: CaseFileReviewCreationController?"
            ),
            "MattersController must publish creation separately from the durable workbench controller"
        )
        XCTAssertTrue(
            matters.contains("caseFileReviewCreationController = nil"),
            "clearing a matter must clear its scoped creation controller"
        )
        XCTAssertTrue(
            matters.contains("CaseFileReviewCreationController("),
            "selecting a matter must compose one separate creation controller"
        )
        XCTAssertTrue(
            workspace.contains("controller.caseFileReviewCreationController"),
            "the Review destination must receive the selected matter's creation controller"
        )
        XCTAssertTrue(
            review.contains("@ObservedObject var creationController: CaseFileReviewCreationController"),
            "the native workbench must observe creation without merging controller authorities"
        )

        let creation = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/CaseFileReviewCreationController.swift"
        )
        XCTAssertTrue(
            creation.contains("submitCorpusAnalysis"),
            "the creation controller must use its explicit generic submission boundary"
        )
        XCTAssertTrue(
            creation.contains("CorpusAnalysisPinnedModel"),
            "the creation boundary must require an exact pinned model, not a routed role default"
        )
        XCTAssertTrue(
            [environment, preparer, queue].joined(separator: "\n")
                .contains("CorpusAnalysisQueuePreparer("),
            "production composition must build the existing exact v2 preparer"
        )
        XCTAssertTrue(
            environment.contains("submitCorpusAnalysis:"),
            "AppEnvironment must inject the production submission path explicitly"
        )
        XCTAssertTrue(
            [environment, queue].joined(separator: "\n").contains("enqueueCorpusAnalysis("),
            "production submission must enter the existing corpus queue as its sole executor"
        )

        XCTAssertTrue(
            modelLibrary.contains("public func makeCorpusAnalysisPinnedModel("),
            "ModelLibrary must expose one public managed-model pin projection"
        )
        XCTAssertTrue(
            modelLibrary.contains("modelID: ModelID"),
            "managed pinning must resolve one explicit registered model identity"
        )
        XCTAssertTrue(
            environment.contains("makeCorpusAnalysisPinnedModel(modelID:"),
            "production composition must call the verified managed-model pin provider"
        )

        XCTAssertTrue(
            corpusRepository.contains("submitPreparedCorpusAnalysis("),
            "Store must own the atomic prepared-run and corpus-job submission"
        )
        XCTAssertTrue(
            queue.contains("store.corpusAnalysis.submitPreparedCorpusAnalysis("),
            "the queue's corpus entry point must use the Store-owned atomic submission"
        )
        XCTAssertGreaterThanOrEqual(
            try matchCount(
                #"submitPreparedCorpusAnalysis\s*\([^\)]*run:\s*[^,]+,[^\)]*partitions:\s*[^,]+,[^\)]*slices:\s*[^,]+,[^\)]*job:"#,
                in: corpusRepository
            ),
            1,
            "the atomic Store boundary must commit run, partitions, slices, and queue job together"
        )

        XCTAssertTrue(
            review.contains(
                "case openCreatedReview(CaseFileReviewCreationController.Run)"
            ),
            "a completed created run must enter the existing dirty-navigation boundary"
        )
        XCTAssertTrue(
            review.contains("requestNavigation(.openCreatedReview("),
            "the creation status action must request guarded workbench navigation"
        )
        XCTAssertGreaterThanOrEqual(
            try matchCount(
                #"private\s+func\s+openCreatedReview[^\{]*\{[\s\S]{0,500}controller\.openReview\s*\([\s\S]{0,240}sourceRunID:\s*[^,]+,[\s\S]{0,160}title:"#,
                in: review
            ),
            1,
            "ready handoff must carry the exact persisted run identity and title into the workbench"
        )

        let exactIdentifiers = [
            "review.newReview",
            "review.creation.sheet",
            "review.creation.name",
            "review.creation.instruction",
            "review.creation.scope.all",
            "review.creation.scope.selected",
            "review.creation.scopeSummary",
            "review.creation.selectedSummary",
            "review.creation.model",
            "review.creation.columnPreview",
            "review.creation.disclosure",
            "review.creation.start",
            "review.creation.dismiss",
            "review.creation.scopeChanged",
            "review.creation.status",
            "review.creation.progress",
            "review.creation.pause",
            "review.creation.resume",
            "review.creation.cancel",
            "review.creation.openResults",
        ]
        for identifier in exactIdentifiers {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(identifier)\")"),
                "missing exact Review creation accessibility identifier \(identifier)"
            )
        }
        XCTAssertTrue(
            review.contains(#".accessibilityIdentifier("review.creation.document.\("#),
            "eligible source choices need stable document-bound identities"
        )
        XCTAssertTrue(
            review.contains("run.statusLabel"),
            "the native surface must render the controller-owned durable status label"
        )
        XCTAssertTrue(
            environment.contains("-uiTestReviewCreation")
                && environment.contains("SUPRA_UI_TEST_REVIEW_CREATION_ROOT"),
            "the single hosted creation fixture must be explicitly gated and use its throwaway root"
        )
        XCTAssertTrue(
            environment.contains(#""slowVerification""#)
                && environment.contains(#""scopeDrift""#),
            "the hosted fixture must deterministically exercise cancellable verification and receipt drift"
        )
    }

    private func caseFileReviewSource() throws -> String {
        try appSource(relativePath: "SupraAI/Review/CaseFileReviewView.swift")
    }

    private func reviewAppSources() throws -> String {
        let reviewDirectory = appRootURL
            .appendingPathComponent("SupraAI/Review", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: reviewDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(sourceURLs.isEmpty, "the native Review source directory is empty")
        return try sourceURLs.map { try source(at: $0) }.joined(separator: "\n")
    }

    private func appSource(relativePath: String) throws -> String {
        try source(at: appRootURL.appendingPathComponent(relativePath))
    }

    private func packageSource(relativePath: String) throws -> String {
        try source(at: repositoryRootURL.appendingPathComponent(relativePath))
    }

    private func source(at url: URL) throws -> String {
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: url.path),
            "required source file is missing: \(url.path)"
        )
        return try XCTUnwrap(
            String(data: data, encoding: .utf8),
            "required source file is not UTF-8: \(url.path)"
        )
    }

    private var appRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryRootURL: URL {
        appRootURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func matchCount(_ pattern: String, in source: String) throws -> Int {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
    }

    private func occurrenceCount(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
