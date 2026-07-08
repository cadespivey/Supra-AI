import Foundation

// Fla. R. Jud. Admin. 2.520(a) typography floor (SPEC §4.3). A firm's effective sheet is
// clamped before any render so a user-set FirmStyleProfile can never push font size or margins
// below the court minimum. Pure, total, and idempotent — clamping an already-conforming sheet
// returns it unchanged, and clamping twice equals clamping once.
//
// This is defense-in-depth: it *precedes* SupraExports' `StyleSheetCompiler.validateFloor`
// (which still throws on a below-floor sheet). Clamping first means a firm's own override is
// silently corrected up to the floor rather than failing the render (SPEC §4.3, open-question 3).

extension HouseStyleSheet {
    /// 12 pt = 24 half-points; 1 inch = 1440 twips.
    private static let minFontHalfPoints = 24
    private static let minMarginTwips = 1440

    /// Return a copy with `page.fontHalfPoints >= 24` and every `page.marginTwips` side `>= 1440`.
    public func clampedToFloor() -> HouseStyleSheet {
        var s = self
        s.page.fontHalfPoints = max(s.page.fontHalfPoints, Self.minFontHalfPoints)
        var m = s.page.marginTwips
        m.top = max(m.top, Self.minMarginTwips)
        m.leading = max(m.leading, Self.minMarginTwips)
        m.bottom = max(m.bottom, Self.minMarginTwips)
        m.trailing = max(m.trailing, Self.minMarginTwips)
        s.page.marginTwips = m
        return s
    }
}
