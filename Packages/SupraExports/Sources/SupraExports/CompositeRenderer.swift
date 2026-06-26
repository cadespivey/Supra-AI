import Foundation
import SupraDraftingCore

/// A single `Renderer` that dispatches on the `RenderInput` shell: court filings go
/// to `CourtFLRenderer`, letters to `LetterheadRenderer`. Lets a caller hold one
/// renderer for all drafting kinds (the pipeline picks the shell via RenderInput).
public struct CompositeRenderer: Renderer {
    private let court = CourtFLRenderer()
    private let letter = LetterheadRenderer()

    public init() {}

    public func render(_ input: RenderInput, style: HouseStyleSheet) throws -> Data {
        switch input {
        case .court:
            return try court.render(input, style: style)
        case .letter:
            return try letter.render(input, style: style)
        }
    }
}
