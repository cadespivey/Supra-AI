import Foundation

// Typed WordprocessingML value types (design: SupraExports impl §2 / NoticeAppearance §4.2).
// These serialize 1:1 to WML via `OoxmlWriter`. Geometry is in twips; font sizes in half-points.

public enum Jc: String, Sendable, Equatable {
    case left, center, right, both
}

public struct TabStop: Sendable, Equatable {
    public var positionTwips: Int
    public var alignment: Jc

    public init(positionTwips: Int, alignment: Jc = .left) {
        self.positionTwips = positionTwips
        self.alignment = alignment
    }
}

public enum FieldCharType: String, Sendable, Equatable {
    case begin, separate, end
}

public struct Border: Sendable, Equatable {
    public var val: String           // "single", "nil", …
    public var size: Int?            // eighths of a point (w:sz)
    public var space: Int?          // points (w:space)
    public var color: String?       // "auto" or hex

    public init(val: String, size: Int? = nil, space: Int? = nil, color: String? = nil) {
        self.val = val
        self.size = size
        self.space = space
        self.color = color
    }

    public static let nilBorder = Border(val: "nil")

    /// The closing caption rule / letterhead rule (LOCKED against goldens).
    public static let rule = Border(val: "single", size: 6, space: 1, color: "auto")
}

public struct Borders: Sendable, Equatable {
    public var top: Border?
    public var left: Border?
    public var bottom: Border?
    public var right: Border?
    public var insideH: Border?
    public var insideV: Border?

    public init(top: Border? = nil, left: Border? = nil, bottom: Border? = nil,
                right: Border? = nil, insideH: Border? = nil, insideV: Border? = nil) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
        self.insideH = insideH
        self.insideV = insideV
    }

    /// All sides explicitly suppressed (the borderless caption table).
    public static let none = Borders(
        top: .nilBorder, left: .nilBorder, bottom: .nilBorder,
        right: .nilBorder, insideH: .nilBorder, insideV: .nilBorder
    )
}

public struct RunProps: Sendable, Equatable {
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var caps: Bool
    public var fontHalfPoints: Int?

    public init(bold: Bool = false, italic: Bool = false, underline: Bool = false,
                caps: Bool = false, fontHalfPoints: Int? = nil) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.caps = caps
        self.fontHalfPoints = fontHalfPoints
    }

    public var isEmpty: Bool {
        !bold && !italic && !underline && !caps && fontHalfPoints == nil
    }
}

public enum RunContent: Sendable, Equatable {
    case text(String)
    case tab
    case fieldChar(FieldCharType)
    case instrText(String)
}

public struct OoxmlRun: Sendable, Equatable {
    public var content: RunContent
    public var props: RunProps

    public init(_ content: RunContent, props: RunProps = RunProps()) {
        self.content = content
        self.props = props
    }

    public static func text(_ s: String, props: RunProps = RunProps()) -> OoxmlRun {
        OoxmlRun(.text(s), props: props)
    }
}

public struct ParaProps: Sendable, Equatable {
    public var jc: Jc?
    public var indFirstLineTwips: Int?
    public var indLeftTwips: Int?
    public var hangingTwips: Int?
    public var spacingLineUnits: Int?
    public var spacingLineRule: String?   // "auto" / "atLeast"
    public var spaceAfterTwips: Int?
    public var tabStops: [TabStop]
    public var bottomBorder: Border?

    public init(jc: Jc? = nil, indFirstLineTwips: Int? = nil, indLeftTwips: Int? = nil,
                hangingTwips: Int? = nil, spacingLineUnits: Int? = nil, spacingLineRule: String? = nil,
                spaceAfterTwips: Int? = nil, tabStops: [TabStop] = [], bottomBorder: Border? = nil) {
        self.jc = jc
        self.indFirstLineTwips = indFirstLineTwips
        self.indLeftTwips = indLeftTwips
        self.hangingTwips = hangingTwips
        self.spacingLineUnits = spacingLineUnits
        self.spacingLineRule = spacingLineRule
        self.spaceAfterTwips = spaceAfterTwips
        self.tabStops = tabStops
        self.bottomBorder = bottomBorder
    }

    public var isEmpty: Bool {
        jc == nil && indFirstLineTwips == nil && indLeftTwips == nil && hangingTwips == nil
            && spacingLineUnits == nil && spaceAfterTwips == nil && tabStops.isEmpty && bottomBorder == nil
    }
}

public struct OoxmlParagraph: Sendable, Equatable {
    public var style: String?
    public var props: ParaProps
    public var runs: [OoxmlRun]

    public init(style: String? = nil, props: ParaProps = ParaProps(), runs: [OoxmlRun] = []) {
        self.style = style
        self.props = props
        self.runs = runs
    }

    /// A single explicitly single-spaced empty paragraph — the 12-pt blank break (design §4.5).
    public static let blankSingleSpaced = OoxmlParagraph(
        props: ParaProps(spacingLineUnits: 240, spacingLineRule: "auto")
    )

    /// A truly empty paragraph (Word's default break).
    public static let empty = OoxmlParagraph()
}

public struct OoxmlCell: Sendable, Equatable {
    public var widthTwips: Int
    public var borders: Borders
    public var content: [OoxmlParagraph]

    public init(widthTwips: Int, borders: Borders = .none, content: [OoxmlParagraph]) {
        self.widthTwips = widthTwips
        self.borders = borders
        self.content = content
    }
}

public struct OoxmlTable: Sendable, Equatable {
    public var widthTwips: Int
    public var borders: Borders
    public var grid: [Int]
    public var rows: [[OoxmlCell]]
    public var layoutFixed: Bool
    public var cellMarginTwips: Int?
    public var indentTwips: Int?

    public init(widthTwips: Int, borders: Borders, grid: [Int], rows: [[OoxmlCell]],
                layoutFixed: Bool = true, cellMarginTwips: Int? = nil, indentTwips: Int? = nil) {
        self.widthTwips = widthTwips
        self.borders = borders
        self.grid = grid
        self.rows = rows
        self.layoutFixed = layoutFixed
        self.cellMarginTwips = cellMarginTwips
        self.indentTwips = indentTwips
    }
}

/// The page section properties emitted at the end of the body.
public struct SectionProps: Sendable, Equatable {
    public var pageWidthTwips: Int
    public var pageHeightTwips: Int
    public var marginTopTwips: Int
    public var marginRightTwips: Int
    public var marginBottomTwips: Int
    public var marginLeftTwips: Int
    public var titlePage: Bool
    public var defaultFooterRelId: String?
    public var firstFooterRelId: String?
    public var pageNumberStart: Int?

    public init(pageWidthTwips: Int, pageHeightTwips: Int,
                marginTopTwips: Int, marginRightTwips: Int, marginBottomTwips: Int, marginLeftTwips: Int,
                titlePage: Bool = false, defaultFooterRelId: String? = nil,
                firstFooterRelId: String? = nil, pageNumberStart: Int? = nil) {
        self.pageWidthTwips = pageWidthTwips
        self.pageHeightTwips = pageHeightTwips
        self.marginTopTwips = marginTopTwips
        self.marginRightTwips = marginRightTwips
        self.marginBottomTwips = marginBottomTwips
        self.marginLeftTwips = marginLeftTwips
        self.titlePage = titlePage
        self.defaultFooterRelId = defaultFooterRelId
        self.firstFooterRelId = firstFooterRelId
        self.pageNumberStart = pageNumberStart
    }
}

public enum BodyElement: Sendable, Equatable {
    case paragraph(OoxmlParagraph)
    case table(OoxmlTable)
}

/// The whole `word/document.xml` body: a stream of paragraphs/tables + the closing sectPr.
public struct OoxmlDocument: Sendable, Equatable {
    public var body: [BodyElement]
    public var section: SectionProps

    public init(body: [BodyElement], section: SectionProps) {
        self.body = body
        self.section = section
    }
}
