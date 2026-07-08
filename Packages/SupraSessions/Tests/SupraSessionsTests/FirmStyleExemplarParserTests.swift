import Foundation
import SupraCore
import SupraDocuments
import SupraDraftingCore
@testable import SupraSessions
import SupraStore
import XCTest

/// M3-T1/T2 — exemplar parse: upload → STRICT-JSON structured extraction → candidate
/// FirmStyleProfile, with the §5.4 guardrails (identity never captured; exemplar text never
/// stored or forwarded into drafting prompts; malformed replies get exactly one repair, then a
/// graceful manual-entry fallback; image-only letterheads surface an advisory, never bytes).
///
/// RED-first: undefined `FirmStyleExemplarParser` / `ExemplarKind` (compile), then wrong
/// mappings. Tests drive the internal text entry point (extraction itself is covered by
/// SupraDocuments' own suite); the runtime is a canned `StubRuntimeClient`.
final class FirmStyleExemplarParserTests: XCTestCase {

    /// Call-counting prompt recorder for scripted multi-turn stubs (repair-path tests).
    private final class PromptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        func record(_ prompt: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            _prompts.append(prompt)
            return _prompts.count - 1
        }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
    }

    private func parser(replies: [String], box: PromptBox = PromptBox()) -> FirmStyleExemplarParser {
        let runtime = StubRuntimeClient(outcome: { request in
            let call = box.record(request.prompt)
            let reply = call < replies.count ? replies[call] : ""
            return .events([
                .event(request, 0, .token, token: reply),
                .event(request, 1, .generationCompleted)
            ])
        })
        return FirmStyleExemplarParser(runtimeClient: runtime, modelID: ModelID())
    }

    // T-PARSE-01 — letterhead exemplar maps into the candidate; untouched fields stay nil.
    func testLetterheadExemplarMapsToCandidate() async {
        let sut = parser(replies: [#"{"tagline":"Counselors at Law","reLabel":"Re:","ccPrefix":"copy to: "}"#])
        let outcome = await sut.parse(kind: .letterhead, text: "PEARSON SPECTER LITT\nCounselors at Law\nRe: matters", needsOCR: false)
        XCTAssertEqual(outcome.candidate.letterheadTagline, "Counselors at Law")
        XCTAssertEqual(outcome.candidate.letterheadRELabel, "Re:")
        XCTAssertEqual(outcome.candidate.letterheadCCPrefix, "copy to: ")
        XCTAssertNil(outcome.candidate.captionPartySeparator)            // off-kind fields untouched
        XCTAssertNil(outcome.candidate.signatureByPrefix)
    }

    // T-PARSE-02 — caption exemplar maps.
    func testCaptionExemplarMapsToCandidate() async {
        let sut = parser(replies: [#"{"partySeparator":"vs.","caseNumberLabel":"CASE NUMBER: "}"#])
        let outcome = await sut.parse(kind: .caption, text: "MCKERNON MOTORS vs. LIBERTY RAIL\nCASE NUMBER: 2026-CA-1", needsOCR: false)
        XCTAssertEqual(outcome.candidate.captionPartySeparator, "vs.")
        XCTAssertEqual(outcome.candidate.captionCaseNumberLabel, "CASE NUMBER: ")
        XCTAssertNil(outcome.candidate.letterheadTagline)
    }

    // T-PARSE-03 — signature exemplar maps.
    func testSignatureExemplarMapsToCandidate() async {
        let sut = parser(replies: [#"{"byPrefix":"BY: ","eSignatureMark":"s/ "}"#])
        let outcome = await sut.parse(kind: .signature, text: "BY: s/ Harvey Specter", needsOCR: false)
        XCTAssertEqual(outcome.candidate.signatureByPrefix, "BY: ")
        XCTAssertEqual(outcome.candidate.signatureESignatureMark, "s/ ")
        XCTAssertNil(outcome.candidate.certificateHeading)
    }

    // T-PARSE-04 — a malformed first reply triggers exactly ONE repair prompt, which succeeds.
    func testMalformedJSONTriggersSingleRepairThenSucceeds() async {
        let box = PromptBox()
        let sut = parser(replies: [
            "Sure! The tagline appears to be Counselors at Law.",          // no JSON object
            #"{"tagline":"Counselors at Law"}"#                             // repaired
        ], box: box)
        let outcome = await sut.parse(kind: .letterhead, text: "Counselors at Law", needsOCR: false)
        XCTAssertEqual(outcome.candidate.letterheadTagline, "Counselors at Law")
        XCTAssertEqual(box.prompts.count, 2, "exactly one repair round")
        XCTAssertTrue(box.prompts[1].contains("STRICT JSON"), "repair prompt restates the contract")
    }

    // T-PARSE-05 — still malformed after the one repair ⇒ empty candidate + fallback message.
    // The parser holds no store, so "no profile write" is structural; the empty candidate is
    // what the review UI shows as manual entry.
    func testUnparseableAfterRepairFallsBackToManualEntry() async {
        let box = PromptBox()
        let sut = parser(replies: ["not json at all", "STILL not json"], box: box)
        let outcome = await sut.parse(kind: .letterhead, text: "Counselors at Law", needsOCR: false)
        XCTAssertEqual(outcome.candidate, FirmStyleProfile(), "no field captured on failure")
        XCTAssertNotNil(outcome.message)
        XCTAssertEqual(box.prompts.count, 2, "one attempt + one repair, never more")
    }

    // T-PARSE-06 — identity content is never captured (invariant 4): a leaky model reply that
    // embeds a phone/bar number is truncated to the label; digits never reach the candidate.
    func testIdentityContentIsNeverCaptured() async throws {
        let sut = parser(replies: [#"{"phoneLabel":"Telephone: (305) 555-1212","barNumberLabel":"FBN 12345"}"#])
        let outcome = await sut.parse(
            kind: .signature,
            text: "Telephone: (305) 555-1212, John Q. Esq., FBN 12345",
            needsOCR: false)
        XCTAssertEqual(outcome.candidate.signaturePhoneLabel, "Telephone: ")   // label survives
        let encoded = String(decoding: try JSONEncoder().encode(outcome.candidate), as: UTF8.self)
        XCTAssertFalse(encoded.contains("555-1212"))
        XCTAssertFalse(encoded.contains("12345"))
        XCTAssertFalse(encoded.contains("John Q"))
    }

    // T-PARSE-11 (PR #50 review) — a signer NAME inside the extracted e-signature mark must be
    // rejected, not stored: "/s/ Jane Doe" carries no digits/@ so the generic label guard passes
    // it, but storing it would render the exemplar's name before the real signer on every future
    // signature (invariant 4). The mark gets a stricter guard; a clean sibling field survives.
    // RED: candidate.signatureESignatureMark == "/s/ Jane Doe" (name accepted).
    func testSignerNameInESignatureMarkIsRejected() async {
        let sut = parser(replies: [#"{"eSignatureMark":"/s/ Jane Doe","byPrefix":"BY: "}"#])
        let outcome = await sut.parse(kind: .signature, text: "BY: /s/ Jane Doe", needsOCR: false)
        XCTAssertNil(outcome.candidate.signatureESignatureMark)      // name-bearing mark rejected
        XCTAssertEqual(outcome.candidate.signatureByPrefix, "BY: ")  // clean sibling still captured
    }

    // T-PARSE-12 — real marks still pass the stricter mark guard exactly (trailing space kept).
    func testPlainMarksSurviveTheMarkGuard() async {
        let sut = parser(replies: [#"{"eSignatureMark":"s/ "}"#])
        let outcome = await sut.parse(kind: .signature, text: "s/ Harvey Specter", needsOCR: false)
        XCTAssertEqual(outcome.candidate.signatureESignatureMark, "s/ ")
    }

    // T-PARSE-07 — empty extraction ⇒ "No text was found" message, no model call at all.
    func testEmptyExtractionShowsNoTextMessageNoCall() async {
        let box = PromptBox()
        let sut = parser(replies: [#"{"tagline":"X"}"#], box: box)
        let outcome = await sut.parse(kind: .letterhead, text: "   \n  ", needsOCR: false)
        XCTAssertEqual(outcome.candidate, FirmStyleProfile())
        XCTAssertTrue(outcome.message?.contains("No text was found") == true)
        XCTAssertEqual(box.prompts.count, 0, "the model is never invoked on empty text")
    }

    // T-PARSE-08 — the exemplar's text never lands on the stored profile and never enters a
    // DRAFTING prompt (invariant: exemplar = parse source, not prompt context).
    @MainActor
    func testExemplarTextNeverEntersDraftingPrompt() async throws {
        let sentinel = "ZANZIBAR-UNIQUE-SENTINEL-PHRASE"
        let sut = parser(replies: [#"{"tagline":"Counselors at Law"}"#])
        let outcome = await sut.parse(kind: .letterhead, text: "Counselors at Law \(sentinel)", needsOCR: false)
        let encoded = String(decoding: try JSONEncoder().encode(outcome.candidate), as: UTF8.self)
        XCTAssertFalse(encoded.contains(sentinel), "no raw exemplar text on the candidate")

        // Persist the candidate the way the confirm step would, then draft a letter and spy
        // on the DRAFTING prompt: the sentinel must not appear.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExemplarStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SupraStore(url: dir.appendingPathComponent("test.sqlite"))
        try store.appSettings.setSetting(FirmStyleProfile.profileKey, value: outcome.candidate)

        var profile = AssistantProfile()
        profile.fullName = "Harvey Specter"; profile.organization = "Pearson Specter Litt"
        profile.barNumber = "100847"; profile.officeStreet = "200 West Forsyth Street"
        profile.officeCity = "Jacksonville"; profile.officeState = "Florida"; profile.officeZip = "32202"
        profile.officePhone = "(904) 555-0142"; profile.primaryEmail = "h@psl.example"
        try store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertFalse(request.prompt.contains(sentinel), "exemplar text leaked into a drafting prompt")
            return .events([
                .event(request, 0, .token, token: "Demand is made for $42,000."),
                .event(request, 1, .generationCompleted)
            ])
        })
        let storage = DocumentStorage(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ExemplarFiles-\(UUID().uuidString)"))
        let controller = MatterDraftingController(store: store, runtimeClient: runtime, storage: storage)
        let input = LetterDraftInput(
            recipientName: "Daniel Hardman, Esq.", recipientStreet: "1 Independent Drive",
            recipientCity: "Jacksonville", recipientState: "Florida", recipientZip: "32202",
            reSubject: "Unpaid invoice", claimSummary: "The invoice is unpaid.",
            demandAmount: "$42,000", responseDeadline: "July 15, 2026", tone: "firm")
        let result = await controller.draftLetterDemand(
            matterID: matter.id, input: input, modelID: ModelID(),
            route: ModelRouter().route(for: .drafting))
        if case let .failure(error) = result { XCTFail("draft failed: \(error)") }
    }

    // T-PARSE-10 — image-only/needsOCR letterhead: advisory surfaced, OCR text still mapped,
    // and the profile TYPE cannot carry image bytes (no Data-typed stored property).
    func testImageOnlyLetterheadSurfacesAdvisoryNoImageBytes() async {
        let sut = parser(replies: [#"{"tagline":"Attorneys at Law"}"#])
        let outcome = await sut.parse(kind: .letterhead, text: "Attorneys at Law", needsOCR: true)
        XCTAssertTrue(outcome.message?.contains("letterhead text but not a logo image") == true)
        XCTAssertEqual(outcome.candidate.letterheadTagline, "Attorneys at Law")
        let hasDataField = Mirror(reflecting: outcome.candidate).children
            .contains { $0.value is Data || $0.value is Data? }
        XCTAssertFalse(hasDataField, "FirmStyleProfile must never carry image bytes")
    }
}
