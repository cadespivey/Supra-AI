import Foundation

/// One formula-injection policy for every CSV, spreadsheet, and tabular copy
/// surface. The policy is deliberately strict: negative numeric-looking text is
/// neutralized along with all other `-` prefixes so a future type inference
/// change cannot turn an attacker-controlled cell into a formula.
public enum CSVCellSanitizer {
    /// Prefixes a dangerous cell with an apostrophe while preserving the
    /// original bytes after that prefix. Leading BOM, whitespace, and control or
    /// Unicode format scalars do not hide a formula marker. Tab and carriage
    /// return are themselves dangerous markers.
    public static func neutralize(_ value: String) -> String {
        guard isDangerous(value) else { return value }
        return "'" + value
    }

    /// Neutralizes first, then applies RFC 4180 delimiter/quote escaping.
    public static func encode(_ value: String) -> String {
        let safe = neutralize(value)
        guard safe.contains(",") || safe.contains("\"")
                || safe.contains("\n") || safe.contains("\r") else {
            return safe
        }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func isDangerous(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            if scalar.value == 0x09 || scalar.value == 0x0D { return true }
            if scalar.value == 0xFEFF
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format {
                continue
            }
            return scalar.value == 0x3D // =
                || scalar.value == 0x2B // +
                || scalar.value == 0x2D // -
                || scalar.value == 0x40 // @
        }
        return false
    }
}
