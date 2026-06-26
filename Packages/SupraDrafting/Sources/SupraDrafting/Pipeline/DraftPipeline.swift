import Foundation
import SupraDraftingCore

// The orchestrator (NoticeAppearance §6 / MotionToDismiss §2). It wires resolve → assemble →
// verify → pre-file gate → render. The Renderer is injected (the SupraExports CourtFLRenderer /
// LetterheadRenderer conform to the core `Renderer` protocol), so this module needn't import the
// renderer package.

public struct DraftPipeline: Sendable {
    public let verifier: Verifier
    public let gate: PreFileGate
    public let renderer: Renderer

    public init(verifier: Verifier, gate: PreFileGate = PreFileGate(), renderer: Renderer) {
        self.verifier = verifier
        self.gate = gate
        self.renderer = renderer
    }

    // MARK: - noticeAppearance (no LLM)

    public func runNotice(_ inputs: NoticeAppearance.Inputs, profile: FirmProfile,
                          style: HouseStyleSheet) async throws -> DraftResult {
        let model = NoticeAppearance.assemble(inputs, profile: profile)
        let vr = await verifier.verify(.wholeDocument(model), kind: .noticeAppearance, style: style)
        let gateResult = gate.check(court: model, kind: .noticeAppearance, style: style)
        let docx = try renderer.render(.court(model), style: style)
        return DraftResult(docx: docx, followUps: vr.followUps + gateResult.followUps)
    }

    // MARK: - letterDemand (one generation call, voice on; fact firewall after)

    public func runLetter(_ inputs: LetterDemand.Inputs, generated: GeneratedLetter,
                          profile: FirmProfile, style: HouseStyleSheet) async throws -> DraftResult {
        let model = LetterDemand.assemble(inputs, generated: generated, profile: profile, style: style)
        let vr = await verifier.verify(.letter(generated, model: model), kind: .letterDemand, style: style)
        let gateResult = gate.check(letter: model, style: style)
        let docx = try renderer.render(.letter(model), style: style)
        return DraftResult(docx: docx, followUps: vr.followUps + gateResult.followUps)
    }

    // MARK: - motionToDismiss (deterministic spine; sections pre-generated + firewall-sanitized)

    public func runMotion(model: DocumentModel, style: HouseStyleSheet) async throws -> DraftResult {
        let vr = await verifier.verify(.wholeDocument(model), kind: .motionToDismiss, style: style)
        let gateResult = gate.check(court: model, kind: .motionToDismiss, style: style)
        let docx = try renderer.render(.court(model), style: style)
        return DraftResult(docx: docx, followUps: vr.followUps + gateResult.followUps)
    }
}
