import Foundation
import SupraDocuments

/// Authors the synthetic Milestone 3 "Validation Matter" on disk (plan §15.2),
/// reused by the Diagnostics app-run validation. Born-digital PDF/DOCX/XLSX are
/// produced via the export builder; failure fixtures (.xls/.msg/corrupt) exercise
/// the import report's failure path. No real client data.
public enum Milestone3ValidationFixtures {
    /// Writes the fixture matter under a fresh temp directory and returns its root.
    @discardableResult
    public static func write(into base: URL) throws -> URL {
        let root = base.appendingPathComponent("Validation Matter", isDirectory: true)
        let fm = FileManager.default
        func mk(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }

        let pdfURL = try mk("Contracts/service-agreement.pdf")
        try DocumentExportBuilder.write(
            .init(title: "Service Agreement", contentMarkdown: "Indemnification survives termination. Executed March 3, 2024.", reviewWarning: "", sources: []),
            format: .pdf, to: pdfURL
        )
        try fm.copyItem(at: pdfURL, to: try mk("Duplicates/service-agreement-copy.pdf"))
        try DocumentExportBuilder.write(.init(title: "Termination Letter", contentMarkdown: "This Termination Letter is effective March 3, 2024.", reviewWarning: "", sources: []), format: .docx, to: try mk("Contracts/termination-letter.docx"))
        try DocumentExportBuilder.write(.init(title: "Notice Template", contentMarkdown: "Notice template body.", reviewWarning: "", sources: []), format: .docx, to: try mk("Contracts/notice-template.dotx"))
        try DocumentExportBuilder.write(.init(title: "Invoices", contentMarkdown: "x", reviewWarning: "", sources: [.init(label: "S1", documentName: "Acme Corp", locator: "Invoice", excerpt: "5000")]), format: .xlsx, to: try mk("Finance/invoice-summary.xlsx"))

        try "# Intake\n\nClient: Acme Corp. Wire transfer discussed.".write(to: try mk("Notes/intake-notes.md"), atomically: true, encoding: .utf8)
        try "The deposition referenced a wire transfer on March 5, 2024.".write(to: try mk("Notes/witness-notes.txt"), atomically: true, encoding: .utf8)
        try #"{\rtf1\ansi Retainer note.\par}"#.write(to: try mk("Notes/rich-text-note.rtf"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Archived</h1><p>Filed 2024-01-10.</p></body></html>".write(to: try mk("Web/archived-page.html"), atomically: true, encoding: .utf8)
        try "<doc author=\"Jane Roe\"><note>Metadata 2023</note></doc>".write(to: try mk("Web/metadata.xml"), atomically: true, encoding: .utf8)

        let attachment = Data("Attached termination notice dated March 3, 2024.".utf8).base64EncodedString()
        let eml = """
        From: counsel@example.com
        To: client@example.com
        Subject: Notice of Termination
        Date: Wed, 3 Apr 2024 10:00:00 +0000
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        Please see the attached notice. Indemnification applies.
        --B
        Content-Type: text/plain
        Content-Disposition: attachment; filename="attached-notice.txt"
        Content-Transfer-Encoding: base64

        \(attachment)
        --B--
        """
        try eml.write(to: try mk("Emails/notice-thread.eml"), atomically: true, encoding: .utf8)
        try Data("png-bytes".utf8).write(to: try mk("Images/scanned-notice.png"))
        try "binary-junk".write(to: try mk("Finance/legacy-ledger.xls"), atomically: true, encoding: .utf8)
        try "ole-junk".write(to: try mk("Emails/board-approval.msg"), atomically: true, encoding: .utf8)
        try "not a zip".write(to: try mk("Unsupported-Or-Bad/corrupt-file.docx"), atomically: true, encoding: .utf8)
        return root
    }
}
