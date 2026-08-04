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
    private let beforeMotionRender: @Sendable () -> Void

    public init(verifier: Verifier, gate: PreFileGate = PreFileGate(), renderer: Renderer) {
        self.init(
            verifier: verifier,
            gate: gate,
            renderer: renderer,
            beforeMotionRender: {}
        )
    }

    init(
        verifier: Verifier,
        gate: PreFileGate = PreFileGate(),
        renderer: Renderer,
        beforeMotionRender: @escaping @Sendable () -> Void
    ) {
        self.verifier = verifier
        self.gate = gate
        self.renderer = renderer
        self.beforeMotionRender = beforeMotionRender
    }

    // MARK: - noticeAppearance (no LLM)

    public func runNotice(_ inputs: NoticeAppearance.Inputs, profile: FirmProfile,
                          style: HouseStyleSheet) async throws -> DraftResult {
        try Task.checkCancellation()
        let model = NoticeAppearance.assemble(inputs, profile: profile)
        let vr = await verifier.verify(.wholeDocument(model), kind: .noticeAppearance, style: style)
        try Task.checkCancellation()
        let gateResult = gate.check(court: model, kind: .noticeAppearance, style: style)
        try Self.requireRenderable(verification: vr, gate: gateResult)
        try Task.checkCancellation()
        let docx = try renderer.render(.court(model), style: style)
        try Task.checkCancellation()
        return DraftResult(
            docx: docx,
            followUps: vr.followUps + gateResult.followUps,
            propositionSupport: vr.propositionSupport,
            verificationReceipt: receipt(for: vr, scope: .documentStructure)
        )
    }

    // MARK: - letterDemand (one generation call, voice on; fact firewall after)

    public func runLetter(_ inputs: LetterDemand.Inputs, generated: GeneratedLetter,
                          facts: [GroundedFact],
                          profile: FirmProfile, style: HouseStyleSheet) async throws -> DraftResult {
        try Task.checkCancellation()
        let model = LetterDemand.assemble(inputs, generated: generated, profile: profile, style: style)
        let vr = await verifier.verify(
            .letter(generated, model: model, facts: facts),
            kind: .letterDemand,
            style: style
        )
        try Task.checkCancellation()
        let gateResult = gate.check(letter: model, style: style)
        try Self.requireRenderable(verification: vr, gate: gateResult)
        try Task.checkCancellation()
        let docx = try renderer.render(.letter(model), style: style)
        try Task.checkCancellation()
        return DraftResult(
            docx: docx,
            followUps: vr.followUps + gateResult.followUps,
            propositionSupport: vr.propositionSupport,
            verificationReceipt: receipt(for: vr, scope: .groundedLetterContentAndStructure)
        )
    }

    // MARK: - motionToDismiss (deterministic spine; sections pre-generated + firewall-sanitized)

    public func runMotion(
        model: DocumentModel,
        evidence: MotionVerificationEvidence,
        style: HouseStyleSheet
    ) async throws -> DraftResult {
        let vr = await verifier.verify(
            .motion(model: model, evidence: evidence),
            kind: .motionToDismiss,
            style: style
        )
        try Task.checkCancellation()
        let gateResult = gate.check(court: model, kind: .motionToDismiss, style: style)
        try Self.requireRenderable(
            verification: vr,
            gate: gateResult,
            requiredPropositionIDs: evidence.requiredPropositionIDs
        )
        beforeMotionRender()
        let docx = try renderer.render(.court(model), style: style)
        return DraftResult(
            docx: docx,
            followUps: vr.followUps + gateResult.followUps,
            propositionSupport: vr.propositionSupport,
            verificationReceipt: receipt(for: vr, scope: .motionSelectedSourceReproductionAndStructure)
        )
    }

    /// The sole render boundary. Every draft kind passes through this method, and any
    /// deterministic failure or blocking follow-up stops before renderer/file side effects.
    private static func requireRenderable(
        verification: VerificationResult,
        gate: GateResult,
        requiredPropositionIDs: [String]? = nil
    ) throws {
        let blockingFollowUps = (verification.followUps + gate.followUps)
            .filter { $0.severity == .blocking }
        let exactSupportCoverage = requiredPropositionIDs.map { requiredIDs in
            !requiredIDs.isEmpty
                && verification.propositionSupport.map(\.propositionID) == requiredIDs
                && verification.propositionSupport.allSatisfy { $0.status == .supported }
        } ?? true
        guard verification.failures.isEmpty,
              gate.failures.isEmpty,
              blockingFollowUps.isEmpty,
              exactSupportCoverage
        else {
            let raw = verification.failures.map(\.detail)
                + gate.failures.map(\.detail)
                + blockingFollowUps.map(\.message)
                + (exactSupportCoverage ? [] : ["Motion verification did not support every selected fact and authority exactly once in order."])
            let summaries = Array(Set(raw.map(sanitizedSummary))).sorted().prefix(8)
            throw DraftError.verificationBlocked(Array(summaries))
        }
    }

    private func receipt(
        for verification: VerificationResult,
        scope: DraftVerificationScope
    ) -> DraftVerificationReceipt {
        DraftVerificationReceipt(
            status: .passed,
            scope: scope,
            supportedPropositionIDs: verification.propositionSupport.map(\.propositionID),
            verifierIdentity: verifier.identity,
            gateIdentity: PreFileGate.identity,
            rendererIdentity: renderer.identity
        )
    }

    private static func sanitizedSummary(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(240))
    }
}
