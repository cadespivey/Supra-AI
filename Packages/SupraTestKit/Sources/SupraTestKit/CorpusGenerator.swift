import Foundation

/// Materializes a `MatterSpec` into a real folder tree of documents in their
/// declared formats. Used by the `SeedCorpus` CLI (to write the committed corpus)
/// and by the validation tests (to build a corpus in a temp dir).
public struct CorpusGenerator {
    public init() {}

    /// Writes all of a matter's documents + attorney notes under `matterDir`.
    public func write(matter: MatterSpec, to matterDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: matterDir, withIntermediateDirectories: true)

        for document in matter.documents {
            let folderURL = matterDir.appendingPathComponent(document.folder, isDirectory: true)
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL.appendingPathComponent(document.filename)
            if let duplicateOf = document.duplicateOf {
                let sourceURL = matterDir.appendingPathComponent(duplicateOf)
                try fm.copyItem(at: sourceURL, to: fileURL)
                continue
            }
            let body = document.bodyText ?? document.purpose ?? document.filename
            let features = Set(document.benchmarkFeatures ?? [])
            switch document.format {
            case .pdf:
                try CorpusRenderers.writeBornDigitalPDF(text: body, to: fileURL)
            case .scanned_pdf:
                try CorpusRenderers.writeScannedPDF(text: body, to: fileURL)
            case .mixed_pdf:
                try CorpusRenderers.writeMixedPDF(text: body, to: fileURL)
            case .locked_pdf:
                try CorpusRenderers.writeLockedPDF(text: body, to: fileURL)
            case .image_png:
                if features.contains(.lowConfidenceOCR) {
                    try CorpusRenderers.writeLowConfidenceImagePNG(text: body, to: fileURL)
                } else {
                    try CorpusRenderers.writeImagePNG(text: body, to: fileURL)
                }
            case .docx:
                try CorpusRenderers.writeDOCX(text: body, features: features, to: fileURL)
            case .xlsx:
                try CorpusRenderers.writeXLSX(sheets: document.spreadsheet ?? [], features: features, to: fileURL)
            case .eml:
                try CorpusRenderers.writeEML(document.email ?? fallbackEmail(document), to: fileURL)
            case .msg:
                try CorpusRenderers.writeMSG(document.email ?? fallbackEmail(document), to: fileURL)
            }
        }

        // Attorney notes (Markdown).
        let notesDir = matterDir.appendingPathComponent("Notes", isDirectory: true)
        try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try matter.attorneyNotesMarkdown.data(using: .utf8)?
            .write(to: notesDir.appendingPathComponent("attorney-notes.md"))

        // The answer key travels with the corpus for reference / automated checks.
        let answerKeyData = try JSONEncoder.pretty.encode(matter.answerKey)
        try answerKeyData.write(to: matterDir.appendingPathComponent("_answer-key.json"))

        if matter.benchmarkProfile != nil {
            let marker = """
            SYNTHETIC-DATA-ONLY

            Every person, organization, matter, identifier, and event in this
            benchmark is SYNTHETIC, FICTIONAL, AND NONPRIVILEGED. It is intended
            only for deterministic document-ingestion testing.
            """
            try Data(marker.utf8).write(to: matterDir.appendingPathComponent("SYNTHETIC-DATA-ONLY.txt"))
        }
    }

    /// Copies external source documents (real case law / procedural PDFs/DOCs)
    /// into a destination folder under the matter.
    public func copyExternal(_ sources: [URL], into matterDir: URL, folder: String) throws {
        let fm = FileManager.default
        let dest = matterDir.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for source in sources where fm.fileExists(atPath: source.path) {
            let target = dest.appendingPathComponent(source.lastPathComponent)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }
    }

    private func fallbackEmail(_ document: DocumentSpec) -> EmailSpec {
        EmailSpec(from: "sender@example.com", to: "recipient@example.com", subject: document.filename,
                  date: "Mon, 1 Jan 2024 09:00:00 -0500", body: document.bodyText ?? "(no body)",
                  attachmentFilename: nil, attachmentBody: nil)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
