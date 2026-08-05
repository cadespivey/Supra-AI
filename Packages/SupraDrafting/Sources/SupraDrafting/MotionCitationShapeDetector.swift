import Foundation

/// The single citation-shape contract shared by motion readiness and the final
/// deterministic verifier. Keep evidence allow-list decisions at each caller;
/// this type answers only whether arbitrary text contains a citation shape.
public enum MotionCitationShapeDetector {
    public static func containsCitationShape(in text: String) -> Bool {
        let patterns = [
            #"\b[A-Z][\w.'&-]+ v\.? [A-Z][\w.'&-]+"#,
            #"\b\d{1,4} [A-Z][\w.]*\.?( \d[a-z]{0,2})? \d{1,4}\b"#,
            #"§\s?\d"#,
            #"\bU\.?S\.?C\.?\b"#,
            #"\bC\.?F\.?R\.?\b"#,
            #"\bFla\.? Stat\.?\b"#,
            #"\bFla\.?\s+R\.?\s+Civ\.?\s+P\.?\s+\d+(?:\.\d+)?(?:\([a-z0-9]+\))*"#,
            #"\bFlorida\s+Rules?\s+of\s+Civil\s+Procedure\s+\d+(?:\.\d+)?(?:\([a-z0-9]+\))*"#,
            #"\b(statute|statutes|code|rule)\s*(section\s*)?\d"#,
        ]
        return patterns.contains {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
