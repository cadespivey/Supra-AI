import Foundation
import SupraDraftingCore
import XCTest

/// FOUNDATION — Codable round-trip, resolver identity/overlay, floor clamp, default parity.
/// RED-first: every method below fails to COMPILE until FirmStyleProfile / NumberFormat /
/// resolved(over:) / clampedToFloor() exist (SPEC §4.1, §4.3, §10; PLAN M1-T1..T4).
///
/// Gates PLAN tasks: M1-T1 (T-CODEC-*), M1-T4 (T-DEFAULT-01), M1-T2 (T-RESOLVE-*),
/// M1-T3 (T-FLOOR-*). See Docs/Drafting-Impl-FirmStyleProfile-TESTPLAN.md.
final class FirmStyleProfileTests: XCTestCase {

    // T-CODEC-01 — empty profile round-trips. RED: undefined symbol `FirmStyleProfile`.
    func testEmptyProfileCodableRoundTrips() throws {
        let p = FirmStyleProfile()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(FirmStyleProfile.self, from: data)
        XCTAssertEqual(p, back)
    }

    // T-CODEC-02 — fully-populated profile round-trips.
    func testPopulatedProfileCodableRoundTrips() throws {
        var p = FirmStyleProfile()
        p.captionPartySeparator = "vs."
        p.letterheadTagline = "Counselors at Law"
        p.signatureRepresentationPrefix = "Counsel for "
        p.bodyNumberFormat = .numberParen
        p.pageFontHalfPoints = 26
        p.pageMarginTwips = EdgeInsets(top: 1500, leading: 1500, bottom: 1500, trailing: 1500)
        p.certificateClauseText = [.flEPortal: "CUSTOM CLAUSE"]
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(FirmStyleProfile.self, from: data)
        XCTAssertEqual(p, back)
    }

    // T-CODEC-03 — lower schemaVersion + missing keys decode to nil/defaults, do NOT throw.
    // RED: decode throws (no resilient init(from:)) OR undefined symbol.
    func testLowerSchemaVersionMissingKeysDecodeToDefaults() throws {
        let json = Data(#"{"schemaVersion":0}"#.utf8)
        let p = try JSONDecoder().decode(FirmStyleProfile.self, from: json)
        XCTAssertNil(p.captionPartySeparator)
        XCTAssertNil(p.letterheadTagline)
        XCTAssertEqual(p.schemaVersion, FirmStyleProfile.currentSchemaVersion) // stamped to 1
    }

    // T-CODEC-04 — [ServiceMethodClause:String] map round-trips on enum rawValue keys.
    func testClauseTextMapRoundTrips() throws {
        var p = FirmStyleProfile()
        p.certificateClauseText = [.flEPortal: "X"]
        let back = try JSONDecoder().decode(
            FirmStyleProfile.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.certificateClauseText?[.flEPortal], "X")
    }

    // T-RESOLVE-01 — empty profile resolves to .defaultFL EXACTLY (invariant 5, SPEC §4.1).
    // RED: undefined method `resolved(over:)`.
    func testEmptyProfileResolvesToDefaultFL() {
        XCTAssertEqual(FirmStyleProfile().resolved(over: .defaultFL), HouseStyleSheet.defaultFL)
    }

    // T-RESOLVE-02 — single overlay lands; off-target field untouched. WIRE-PROOF at merge layer.
    func testSingleOverlayLandsAndLeavesOthers() {
        var p = FirmStyleProfile()
        p.captionPartySeparator = "vs."
        let s = p.resolved(over: .defaultFL)
        XCTAssertEqual(s.caption.partySeparator, "vs.")                 // custom present
        XCTAssertNotEqual(s.caption.partySeparator, "v.")               // default absent
        XCTAssertEqual(s.caption.caseNumberLabel, "CASE NO.: ")         // off-target untouched
    }

    // T-DEFAULT-01 — new field defaults equal today's literals (§4.2). Supporting, NOT a wiring proof.
    func testNewFieldDefaultsEqualTodaysLiterals() {
        let d = HouseStyleSheet.defaultFL
        XCTAssertEqual(d.caption.partySeparator, "v.")
        XCTAssertEqual(d.signature.eSignature.mark, "/s/ ")
        XCTAssertEqual(d.certificate.heading, "CERTIFICATE OF SERVICE")
        XCTAssertEqual(d.letterhead?.headerBlock.tagline, "Attorneys at Law")
        XCTAssertEqual(d.body.numberFormat, .numberDot)
    }

    // T-FLOOR-01 — clamp raises 20→24 half-pt and 1080→1440 twips per side (SPEC §4.3). WIRE-PROOF.
    // RED: undefined method `clampedToFloor()`.
    func testClampRaisesFontAndMargins() {
        var s = HouseStyleSheet.defaultFL
        s.page.fontHalfPoints = 20
        s.page.marginTwips = EdgeInsets(top: 1080, leading: 1080, bottom: 1080, trailing: 1080)
        let c = s.clampedToFloor()
        XCTAssertEqual(c.page.fontHalfPoints, 24)
        XCTAssertNotEqual(c.page.fontHalfPoints, 20)
        XCTAssertEqual(c.page.marginTwips.top, 1440)
        XCTAssertEqual(c.page.marginTwips.leading, 1440)
        XCTAssertEqual(c.page.marginTwips.bottom, 1440)
        XCTAssertEqual(c.page.marginTwips.trailing, 1440)
    }

    // T-FLOOR-02 — idempotent when seeded ABOVE the floor, so idempotence is meaningful
    // independent of the raise tests (a no-op impl also passes this — see RED-FIRST note; the
    // clamp's DO-something proof lives in T-FLOOR-01/03/04). RED: undefined method.
    func testClampIsIdempotentSlightlyAboveFloor() {
        var s = HouseStyleSheet.defaultFL
        s.page.fontHalfPoints = 26                                            // 13 pt, above floor
        s.page.marginTwips = EdgeInsets(top: 1500, leading: 1500, bottom: 1500, trailing: 1500)
        XCTAssertEqual(s.clampedToFloor(), s)                                 // unchanged
        XCTAssertEqual(s.clampedToFloor().clampedToFloor(), s.clampedToFloor())
    }

    // T-FLOOR-03 — per-side clamp. WIRE-PROOF (leading below floor).
    func testClampIsPerSide() {
        var s = HouseStyleSheet.defaultFL
        s.page.marginTwips = EdgeInsets(top: 1440, leading: 720, bottom: 1440, trailing: 1440)
        let c = s.clampedToFloor()
        XCTAssertEqual(c.page.marginTwips.leading, 1440)  // raised
        XCTAssertNotEqual(c.page.marginTwips.leading, 720)
        XCTAssertEqual(c.page.marginTwips.top, 1440)      // untouched
    }

    // T-FLOOR-04 — a below-floor PROFILE cannot override the floor (invariant 1). WIRE-PROOF.
    func testBelowFloorProfileCannotOverrideFloor() {
        var p = FirmStyleProfile()
        p.pageFontHalfPoints = 20                                            // 10 pt
        p.pageMarginTwips = EdgeInsets(top: 720, leading: 720, bottom: 720, trailing: 720) // 0.5"
        let s = p.resolved(over: .defaultFL).clampedToFloor()
        XCTAssertEqual(s.page.fontHalfPoints, 24)   // custom-below-floor was clamped up
        XCTAssertNotEqual(s.page.fontHalfPoints, 20)
        XCTAssertEqual(s.page.marginTwips.leading, 1440)
    }
}
