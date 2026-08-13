import Foundation

/// The Store-owned allowlist for durable Case File Review snapshot artifacts.
///
/// The raw value is the exact token persisted in `document_exports`. The file
/// extension is kept separate so callers cannot accidentally publish the
/// broader Structured Output `csv` or `xlsx` format tokens for Review-owned
/// artifacts.
public enum CaseFileReviewSnapshotExportFormat: String, Codable, CaseIterable, Sendable {
    case csv = "review_csv"
    case xlsx = "review_xlsx"

    public var persistedToken: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .xlsx: "xlsx"
        }
    }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .xlsx: "XLSX"
        }
    }
}
