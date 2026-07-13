import Foundation

/// Approved, explicit resource ceilings for every document-import parser.
///
/// These values are deliberately finite. Callers may tighten them for a
/// particular workflow or test, but there is no unbounded fallback.
public struct ImportPolicy: Sendable, Equatable {
    public static let `default` = ImportPolicy()

    public var maxTreeDepth: Int
    public var maxFileCount: Int
    public var maxInputBytes: Int
    public var maxAggregateSourceBytes: Int
    public var maxParserDurationSeconds: Double
    public var maxDecodedTextBytes: Int
    public var maxPages: Int
    public var maxPixels: Int
    public var maxArchiveEntries: Int
    public var maxArchiveExpandedBytes: Int
    public var maxArchiveCompressionRatio: Double
    public var maxMIMEDepth: Int
    public var maxAttachments: Int
    public var maxXMLNodes: Int

    public init(
        maxTreeDepth: Int = 32,
        maxFileCount: Int = 10_000,
        maxInputBytes: Int = 512 * 1_024 * 1_024,
        maxAggregateSourceBytes: Int = 2 * 1_024 * 1_024 * 1_024,
        maxParserDurationSeconds: Double = 30,
        maxDecodedTextBytes: Int = 64 * 1_024 * 1_024,
        maxPages: Int = 10_000,
        maxPixels: Int = 250_000_000,
        maxArchiveEntries: Int = 50_000,
        maxArchiveExpandedBytes: Int = 1_024 * 1_024 * 1_024,
        maxArchiveCompressionRatio: Double = 100,
        maxMIMEDepth: Int = 20,
        maxAttachments: Int = 5_000,
        maxXMLNodes: Int = 1_000_000
    ) {
        self.maxTreeDepth = max(0, maxTreeDepth)
        self.maxFileCount = max(1, maxFileCount)
        self.maxInputBytes = max(1, maxInputBytes)
        self.maxAggregateSourceBytes = max(1, maxAggregateSourceBytes)
        self.maxParserDurationSeconds = max(0.001, maxParserDurationSeconds)
        self.maxDecodedTextBytes = max(1, maxDecodedTextBytes)
        self.maxPages = max(1, maxPages)
        self.maxPixels = max(1, maxPixels)
        self.maxArchiveEntries = max(1, maxArchiveEntries)
        self.maxArchiveExpandedBytes = max(1, maxArchiveExpandedBytes)
        self.maxArchiveCompressionRatio = max(1, maxArchiveCompressionRatio)
        self.maxMIMEDepth = max(0, maxMIMEDepth)
        self.maxAttachments = max(0, maxAttachments)
        self.maxXMLNodes = max(1, maxXMLNodes)
    }

    public func validateSource(at url: URL) throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .fileSizeKey
        ])
        if values.isSymbolicLink == true {
            throw ImportPolicyViolation(.symbolicLink, "Symbolic links are not imported.")
        }
        if values.isAliasFile == true {
            throw ImportPolicyViolation(.alias, "Finder aliases are not imported.")
        }
        if values.isRegularFile == true, (values.fileSize ?? 0) > maxInputBytes {
            throw ImportPolicyViolation(
                .sourceTooLarge,
                "Source exceeds the (maxInputBytes)-byte per-file limit."
            )
        }
    }

    public func validateDecodedText(_ text: String) throws {
        if text.utf8.count > maxDecodedTextBytes {
            throw ImportPolicyViolation(
                .decodedTextLimit,
                "Decoded text exceeds the (maxDecodedTextBytes)-byte limit."
            )
        }
    }

    /// Counts XML markup tokens before FoundationXML receives the bytes. This
    /// conservative preflight counts both opening and closing tags, keeping the
    /// parser's node allocation bounded even for malformed XML.
    public func validateXMLData(_ data: Data) throws {
        var markupCount = 0
        for byte in data where byte == 0x3C { // "<"
            markupCount += 1
            if markupCount > maxXMLNodes {
                throw ImportPolicyViolation(
                    .xmlNodeLimit,
                    "XML exceeds the (maxXMLNodes)-node limit."
                )
            }
        }
    }

    public func validateExtractionResult(_ result: ExtractionResult) throws {
        try validateDecodedText(result.combinedText)
        if result.parts.count > maxPages {
            throw ImportPolicyViolation(.pageLimit, "Document exceeds the (maxPages)-part limit.")
        }
        if result.attachments.count > maxAttachments {
            throw ImportPolicyViolation(
                .attachmentCountLimit,
                "Message exceeds the (maxAttachments)-attachment limit."
            )
        }
        var expanded = result.combinedText.utf8.count
        for attachment in result.attachments {
            let (next, overflow) = expanded.addingReportingOverflow(attachment.data.count)
            if overflow || next > maxArchiveExpandedBytes {
                throw ImportPolicyViolation(
                    .expandedBytesLimit,
                    "Decoded content exceeds the (maxArchiveExpandedBytes)-byte aggregate limit."
                )
            }
            expanded = next
        }
    }
}

/// A stable, report-safe reason for rejecting one import item.
public struct ImportPolicyViolation: Error, LocalizedError, Sendable, Equatable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case symbolicLink = "symbolic_link"
        case alias
        case hardLink = "hard_link"
        case duplicateFileIdentity = "duplicate_file_identity"
        case outsideRoot = "outside_root"
        case rootChanged = "root_changed"
        case candidateChanged = "candidate_changed"
        case treeDepth = "tree_depth"
        case fileCount = "file_count"
        case sourceTooLarge = "source_too_large"
        case aggregateSourceBytes = "aggregate_source_bytes"
        case typeMismatch = "type_mismatch"
        case unsafeArchivePath = "unsafe_archive_path"
        case duplicateArchiveEntry = "duplicate_archive_entry"
        case archiveEntryLimit = "archive_entry_limit"
        case archiveCompressionRatio = "archive_compression_ratio"
        case archiveSpecialEntry = "archive_special_entry"
        case expandedBytesLimit = "expanded_bytes_limit"
        case mimeDepthLimit = "mime_depth_limit"
        case attachmentCountLimit = "attachment_count_limit"
        case xmlNodeLimit = "xml_node_limit"
        case decodedTextLimit = "decoded_text_limit"
        case pageLimit = "page_limit"
        case pixelLimit = "pixel_limit"
        case parserTimeLimit = "parser_time_limit"
        case cancelled
    }

    public let code: Code
    public let reason: String

    public init(_ code: Code, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}
