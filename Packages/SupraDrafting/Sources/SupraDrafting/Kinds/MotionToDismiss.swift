import Foundation
import SupraDraftingCore

// The `motionToDismiss` kind — contract/Auth: generation per section, authority firewall, the
// houseMotionFL skeleton. The slice ships the deterministic spine (caption/title/skeleton/
// assembly + the firewall plumbing); a live Generator drives the prose.

public enum MotionToDismiss {
    public struct SectionDef: Sendable, Equatable {
        public var id: Section
        public var generate: Bool
        public var decoding: Decoding
        public var numbering: Numbering
        public var headingLevel: Int?
        public var skeletonShape: SkeletonShape
        public var repeatPerGround: Bool
        public var isWhereforePoint: Bool

        public init(id: Section, generate: Bool, decoding: Decoding = .grounded,
                    numbering: Numbering = .none, headingLevel: Int? = nil,
                    skeletonShape: SkeletonShape = .none, repeatPerGround: Bool = false,
                    isWhereforePoint: Bool = false) {
            self.id = id
            self.generate = generate
            self.decoding = decoding
            self.numbering = numbering
            self.headingLevel = headingLevel
            self.skeletonShape = skeletonShape
            self.repeatPerGround = repeatPerGround
            self.isWhereforePoint = isWhereforePoint
        }
    }

    public enum Numbering: Sendable, Equatable { case none, numberedFacts }
    public enum SkeletonShape: Sendable, Equatable { case crac, creac, irac, none }

    public static let houseMotionFL: [SectionDef] = [
        SectionDef(id: .introduction, generate: true, decoding: .grounded),
        SectionDef(id: .statementOfFacts, generate: true, decoding: .grounded, numbering: .numberedFacts),
        SectionDef(id: .memorandumOfLaw, generate: false),
        SectionDef(id: .argument, generate: true, decoding: .grounded, headingLevel: 1, skeletonShape: .crac, repeatPerGround: true),
        SectionDef(id: .conclusion, generate: true, decoding: .grounded, headingLevel: 1, isWhereforePoint: true)
    ]

    public static func title(party: String, partyRole: String, pleading: String) -> String {
        "\(partyRole.uppercased()) \(party.uppercased())'S MOTION TO DISMISS \(pleading.uppercased())"
    }

    /// Assembles the motion body from a deterministic caption + already-generated, firewall-sanitized
    /// sections. `generatedSections` is keyed by Section in skeleton order; the assembler lays out
    /// section headings + the generated blocks (numbered facts, point headings) per the goldens.
    public static func assemble(
        caption: CaptionModel,
        title: String,
        introduction: [BodyBlock],
        numberedFacts: [String],
        argumentPoints: [ArgumentPoint],
        conclusion: String,
        signature: SignatureBlockModel,
        certificate: CertificateModel
    ) -> DocumentModel {
        var body: [BodyBlock] = []

        // Introduction (prose).
        body.append(contentsOf: introduction)

        // Statement of facts — centered bold heading + numbered allegations.
        body.append(.sectionHeading("STATEMENT OF FACTS"))
        for (index, fact) in numberedFacts.enumerated() {
            body.append(.numberedAllegation(number: index + 1, text: fact))
        }

        // Memorandum of law — heading only; argument lives in the points.
        body.append(.sectionHeading("MEMORANDUM OF LAW"))

        // Argument points: I., II., … each with optional A./B. sub-points.
        for (index, point) in argumentPoints.enumerated() {
            let numeral = roman(index + 1) + "."
            body.append(.pointHeading(level: 1, numeral: numeral, text: point.heading))
            for block in point.body { body.append(block) }
            for (subIndex, sub) in point.subPoints.enumerated() {
                let letter = String(UnicodeScalar(UInt8(65 + subIndex))) + "."
                body.append(.pointHeading(level: 2, numeral: letter, text: sub.heading))
                for block in sub.body { body.append(block) }
            }
        }

        // Conclusion — final roman point heading + WHEREFORE paragraph.
        let conclusionNumeral = roman(argumentPoints.count + 1) + "."
        body.append(.pointHeading(level: 1, numeral: conclusionNumeral, text: "CONCLUSION"))
        body.append(.paragraph(conclusion))

        return DocumentModel(caption: caption, title: title, body: body,
                            signature: signature, certificate: certificate)
    }

    public struct ArgumentPoint: Sendable, Equatable {
        public var heading: String
        public var body: [BodyBlock]
        public var subPoints: [ArgumentPoint]

        public init(heading: String, body: [BodyBlock], subPoints: [ArgumentPoint] = []) {
            self.heading = heading
            self.body = body
            self.subPoints = subPoints
        }
    }

    public static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                                      (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                      (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var value = n
        var result = ""
        for (amount, numeral) in table {
            while value >= amount {
                result += numeral
                value -= amount
            }
        }
        return result
    }
}
