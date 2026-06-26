import Foundation
import SupraDraftingCore

// The final whole-document gate before render (NoticeAppearance §6 / LetterDemand §2).
// Shell-aware: court filings need caption + signature + certificate; letters need only
// letterhead + recipient (NEVER an auto-appended certificate — design §12 guardrail).

public struct PreFileGate: Sendable {
    public init() {}

    public func check(court model: DocumentModel, kind: DraftKindID, style: HouseStyleSheet) -> GateResult {
        var failures: [GateFailure] = []
        var followUps: [FollowUp] = []

        let completeParties = model.caption.parties.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.designation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if model.caption.courtHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || completeParties.count < 2
            || model.caption.caseNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append(GateFailure(gate: .contract, detail: "Caption incomplete.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Caption must be complete before filing."))
        }
        if let signature = model.signature {
            if signature.firmName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || signature.signingAttorney.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || signature.attorneys.isEmpty
                || signature.emails.primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append(GateFailure(gate: .contract, detail: "Signature incomplete.", repair: .regenerate(maxPasses: 1)))
                followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Signature block must be complete before filing."))
            }
        } else {
            failures.append(GateFailure(gate: .contract, detail: "Signature missing.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Signature block required."))
        }
        if let certificate = model.certificate {
            let completeRecipients = certificate.recipients.filter { recipient in
                !recipient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !recipient.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !recipient.emails.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.isEmpty
            }
            if completeRecipients.isEmpty {
                failures.append(GateFailure(gate: .contract, detail: "Certificate recipients missing.", repair: .regenerate(maxPasses: 1)))
                followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Certificate of service requires at least one complete recipient."))
            }
        } else {
            failures.append(GateFailure(gate: .contract, detail: "Certificate missing.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Certificate of service required for a filed document."))
        }

        // Format floor (2.520(a)) — surfaced as a rule-conformance failure rather than thrown here.
        if style.page.fontHalfPoints < 24 {
            failures.append(GateFailure(gate: .ruleConformance, detail: "Font below 12pt floor.", repair: .deterministicFix))
            followUps.append(FollowUp(severity: .blocking, kind: .ruleViolation, message: "Font must be at least 12pt (Fla. R. Jud. Admin. 2.520(a))."))
        }
        let m = style.page.marginTwips
        if min(m.top, m.leading, m.bottom, m.trailing) < 1440 {
            failures.append(GateFailure(gate: .ruleConformance, detail: "Margin below 1\" floor.", repair: .deterministicFix))
            followUps.append(FollowUp(severity: .blocking, kind: .ruleViolation, message: "Margins must be at least 1\" (Fla. R. Jud. Admin. 2.520(a))."))
        }

        return GateResult(failures: failures, followUps: followUps)
    }

    public func check(letter model: LetterModel, style: HouseStyleSheet) -> GateResult {
        var failures: [GateFailure] = []
        var followUps: [FollowUp] = []

        if model.letterhead.firmName.isEmpty {
            failures.append(GateFailure(gate: .contract, detail: "Letterhead firm missing.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Letterhead firm name required."))
        }
        if model.recipient.name.isEmpty {
            failures.append(GateFailure(gate: .contract, detail: "Recipient missing.", repair: .regenerate(maxPasses: 1)))
            followUps.append(FollowUp(severity: .blocking, kind: .structure, message: "Recipient address required."))
        }
        // NB: no certificate-of-service requirement is ever added on the letterhead shell.
        return GateResult(failures: failures, followUps: followUps)
    }
}
