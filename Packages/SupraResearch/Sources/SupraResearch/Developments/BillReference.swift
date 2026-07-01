import Foundation

/// Detects a specific bill referenced in free text ("HB 123", "S.B. 456", "H.R. 40"),
/// so legislative sources can target that bill instead of keyword-searching. Returns a
/// normalized form ("HB 123") or nil when no bill is named.
public enum BillReference {
    public static func billNumber(in text: String) -> String? {
        let pattern = #"(?i)\b(H\.?\s?R\.?|S\.?\s?B\.?|H\.?\s?B\.?|A\.?\s?B\.?|S\.?\s?J\.?\s?R\.?|H\.?\s?J\.?\s?R\.?|L\.?\s?B\.?|H\.?\s?F\.?|S\.?\s?F\.?)\s?-?\s?(\d{1,5})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let prefixRange = Range(match.range(at: 1), in: text),
              let numberRange = Range(match.range(at: 2), in: text) else { return nil }
        let prefix = text[prefixRange]
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        return "\(prefix) \(text[numberRange])"
    }
}
