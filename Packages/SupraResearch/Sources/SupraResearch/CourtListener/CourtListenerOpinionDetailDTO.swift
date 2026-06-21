import Foundation

/// A single opinion fetched from CourtListener's `/api/rest/v4/opinions/{id}/`
/// detail endpoint (the search endpoint only returns a short highlighted
/// snippet). Carries the full opinion text and HTML for building a longer
/// passage and an in-app HTML view / download — all on the allow-listed
/// `www.courtlistener.com` host.
public struct CourtListenerOpinionDetailDTO: Codable, Sendable, Equatable {
    public let id: Int?
    public let plainText: String?
    public let html: String?
    public let htmlWithCitations: String?
    public let htmlLawbox: String?
    public let htmlColumbia: String?
    public let downloadURL: String?
    public let absoluteURL: String?
    /// CourtListener's stored copy of the source file, relative to the storage
    /// CDN (e.g. `pdf/2009/04/.../file.pdf`). Empty for text-only opinions.
    public let localPath: String?

    public init(
        id: Int? = nil,
        plainText: String? = nil,
        html: String? = nil,
        htmlWithCitations: String? = nil,
        htmlLawbox: String? = nil,
        htmlColumbia: String? = nil,
        downloadURL: String? = nil,
        absoluteURL: String? = nil,
        localPath: String? = nil
    ) {
        self.id = id
        self.plainText = plainText
        self.html = html
        self.htmlWithCitations = htmlWithCitations
        self.htmlLawbox = htmlLawbox
        self.htmlColumbia = htmlColumbia
        self.downloadURL = downloadURL
        self.absoluteURL = absoluteURL
        self.localPath = localPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case plainText = "plain_text"
        case html
        case htmlWithCitations = "html_with_citations"
        case htmlLawbox = "html_lawbox"
        case htmlColumbia = "html_columbia"
        case downloadURL = "download_url"
        case absoluteURL = "absolute_url"
        case localPath = "local_path"
    }

    /// The CourtListener-hosted PDF URL on the storage CDN, when the stored file is
    /// a PDF. Nil for text-only opinions or non-PDF stored files. This is the only
    /// host the app downloads opinion PDFs from (no token sent).
    public var courtListenerPDFURL: URL? {
        guard let localPath else { return nil }
        let trimmed = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased().hasSuffix(".pdf") else { return nil }
        let path = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://storage.courtlistener.com/" + encoded)
    }

    /// The richest HTML available, preferring CourtListener's citation-linked
    /// markup, then the harmonized/lawbox/columbia variants.
    public var bestHTML: String? {
        for candidate in [htmlWithCitations, html, htmlLawbox, htmlColumbia] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }

    /// Plain opinion text, falling back to HTML stripped of tags so callers always
    /// have something to extract a passage from.
    public var bodyText: String? {
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        return CourtListenerText.clean(bestHTML)
    }
}
