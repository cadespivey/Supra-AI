import Foundation

/// The narrow jurisdiction and citation contract for the first supported motion
/// vertical. Florida Rule of Civil Procedure 1.140 applies here only when the
/// explicit filing court is a Florida state trial court; broad matter metadata,
/// federal courts, and appellate courts never substitute for that filing court.
public enum FloridaMotionToDismissContract {
    public static let filingCourtRequirement =
        "The filing court must be a Florida state circuit or county court for this Rule 1.140 motion workflow."

    public static func isSupportedFilingCourt(_ explicitCourt: String) -> Bool {
        let court = normalizedWhitespace(explicitCourt).lowercased()
        guard !court.isEmpty,
              court.range(of: #"\bflorida\b"#, options: .regularExpression) != nil,
              court.range(of: #"\b(?:circuit|county)\s+court\b"#, options: .regularExpression) != nil else {
            return false
        }

        let excludedCourtShapes = [
            #"\bunited\s+states\b"#,
            #"\bfederal\b"#,
            #"\bdistrict\s+court\b"#,
            #"\bcourt\s+of\s+appeals?\b"#,
            #"\bdistrict\s+court\s+of\s+appeal\b"#,
            #"\bsupreme\s+court\b"#,
            #"\bappellate\b"#,
        ]
        return !excludedCourtShapes.contains {
            court.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Accepts one complete citation composed of an optional case caption, one
    /// supported state reporter, an optional state-reporter pinpoint, and an
    /// anchored Florida Supreme Court or District Court of Appeal parenthetical.
    /// The caption grammar cannot consume another comma-delimited reporter, so a
    /// mixed federal + Florida string fails rather than borrowing its final
    /// Florida parenthetical.
    public static func isSupportedAuthorityCitation(_ citation: String) -> Bool {
        let value = normalizedWhitespace(citation)
        guard !value.isEmpty else { return false }

        let optionalCaseCaption = #"(?:(?:(?!,\s*\d).)+,\s*)?"#
        let southernReporter = #"\d{1,4}\s+So\.\s+(?:(?:2d|3d)\s+)?\d{1,6}"#
        let southernPinpoint = #"(?:,\s+\d{1,6}(?:[-–—]\d{1,6})?)?"#
        let weeklyReporter = #"\d{1,3}\s+Fla\.\s+L\.\s+Weekly\s+(?:D|S)?\d{1,6}"#
        let weeklyPinpoint = #"(?:,\s+(?:D|S)?\d{1,6}(?:[-–—](?:D|S)?\d{1,6})?)?"#
        let stateParenthetical =
            #"\s+\(\s*Fla\.(?:\s+(?:1st|2d|3d|4th|5th|6th)\s+DCA)?\s+\d{4}\s*\)"#
        let supportedCitation =
            "^\(optionalCaseCaption)(?:\(southernReporter)\(southernPinpoint)|"
            + "\(weeklyReporter)\(weeklyPinpoint))\(stateParenthetical)$"

        return value.range(
            of: supportedCitation,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
