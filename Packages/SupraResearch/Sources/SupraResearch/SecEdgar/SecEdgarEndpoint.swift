import Foundation

/// URL builders for the SEC EDGAR JSON APIs (`data.sec.gov`). Builders return
/// `URL` (never `String`) and validate every caller-influenced path component
/// strictly enough to block slashes, traversal, and embedded URLs — a taxonomy
/// or concept value must never be able to reshape the request path.
///
/// Archive URLs (`www.sec.gov/Archives/...`) are BUILT for the user's browser,
/// never fetched by the client, which is why `www.sec.gov` is deliberately not
/// on the network allow-list.
enum SecEdgarEndpoint {
    static let apiBase = URL(string: "https://data.sec.gov")!
    static let archiveBaseString = "https://www.sec.gov/Archives/edgar/data"

    /// `https://data.sec.gov/submissions/CIK##########.json` — `normalizedCik`
    /// is already validated as exactly ten digits.
    static func submissions(normalizedCik: String) -> URL {
        apiBase
            .appendingPathComponent("submissions")
            .appendingPathComponent("CIK\(normalizedCik).json")
    }

    /// Historical continuation files listed in `submissions.files`, e.g.
    /// `CIK0000320193-submissions-001.json`. Names come from the SEC payload
    /// but are re-validated so a malformed payload can't redirect the request.
    static func submissionsContinuation(fileName: String, operation: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".json"),
              isSafePathComponent(trimmed) else {
            throw SecEdgarErrorMapping.validationError(
                operation: operation,
                message: "A filing-history continuation file name was not in the expected format and was rejected."
            )
        }
        return apiBase
            .appendingPathComponent("submissions")
            .appendingPathComponent(trimmed)
    }

    static func companyFacts(normalizedCik: String) -> URL {
        xbrlBase()
            .appendingPathComponent("companyfacts")
            .appendingPathComponent("CIK\(normalizedCik).json")
    }

    static func companyConcept(normalizedCik: String, taxonomy: String, concept: String) -> URL {
        xbrlBase()
            .appendingPathComponent("companyconcept")
            .appendingPathComponent("CIK\(normalizedCik)")
            .appendingPathComponent(taxonomy)
            .appendingPathComponent("\(concept).json")
    }

    static func frames(taxonomy: String, concept: String, unit: String, frame: String) -> URL {
        xbrlBase()
            .appendingPathComponent("frames")
            .appendingPathComponent(taxonomy)
            .appendingPathComponent(concept)
            .appendingPathComponent(unit)
            .appendingPathComponent("\(frame).json")
    }

    private static func xbrlBase() -> URL {
        apiBase
            .appendingPathComponent("api")
            .appendingPathComponent("xbrl")
    }

    // MARK: - Component validation

    /// Letters, digits, `.`, `_`, `-` only; no traversal. Covers real XBRL
    /// values (`us-gaap`, `AccountsPayableCurrent`, `USD-per-shares`,
    /// `CY2019Q1I`) while rejecting anything that could escape its path slot.
    /// The rejected value is never echoed into the error message.
    static func validatedPathComponent(_ value: String, field: String, operation: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSafePathComponent(trimmed) else {
            throw SecEdgarErrorMapping.validationError(
                operation: operation,
                message: "The \(field) value is not a valid SEC EDGAR path component; only letters, digits, '.', '_', and '-' are supported."
            )
        }
        return trimmed
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.contains("..") else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-")
        }
    }

    // MARK: - Archive (browser-facing) URLs

    /// `https://www.sec.gov/Archives/edgar/data/{cikNoLeadingZeros}/{accessionNoDashes}/`
    /// — inputs are validated digits, so string assembly is safe. The trailing
    /// slash is part of the documented pattern.
    static func filingArchiveURLString(cikWithoutLeadingZeros: String, undashedAccession: String) -> String {
        "\(archiveBaseString)/\(cikWithoutLeadingZeros)/\(undashedAccession)/"
    }

    /// Percent-encodes a primary-document path segment-by-segment. EDGAR
    /// primary documents can carry an internal directory (e.g. rendered Form 4
    /// paths like `xslF345X05/wf-form4.xml`), so internal slashes are allowed
    /// but empty, `.`/`..`, and scheme-like segments are not.
    static func encodedPrimaryDocumentPath(_ primaryDocument: String, operation: String) throws -> String {
        let trimmed = primaryDocument.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw SecEdgarErrorMapping.validationError(
                operation: operation,
                message: "The primary document name is not a valid archive path."
            )
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        var encoded: [String] = []
        for segment in segments {
            guard let encodedSegment = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw SecEdgarErrorMapping.validationError(
                    operation: operation,
                    message: "The primary document name could not be encoded as a URL path."
                )
            }
            encoded.append(encodedSegment)
        }
        return encoded.joined(separator: "/")
    }
}
