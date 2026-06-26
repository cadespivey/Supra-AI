import Foundation
import SupraDraftingCore

/// Deterministic slot validation for the no-LLM Notice of Appearance template.
/// The renderer should only see complete, attorney-supplied filing data; this gate
/// keeps missing slots from becoming blank signature/certificate/caption language.
public enum NoticeAppearanceInputValidator {
    public static func validate(inputs: NoticeAppearance.Inputs, profile: FirmProfile) -> [String] {
        var missing: [String] = []

        if isBlankOrPlaceholder(inputs.courtHeader) { missing.append("court header") }
        if blank(inputs.caseNumber) { missing.append("case/docket number") }

        let completeParties = inputs.parties.filter { !blank($0.name) && !blank($0.designation) }
        if completeParties.count < 2 {
            missing.append("complete caption parties")
        }
        for (index, party) in inputs.parties.enumerated() {
            if !blank(party.name), blank(party.designation) {
                missing.append("caption party \(index + 1) designation")
            }
            if blank(party.name), !blank(party.designation) {
                missing.append("caption party \(index + 1) name")
            }
        }

        if blank(inputs.partyRepresented) { missing.append("party represented") }
        if blank(inputs.representedPartyName) { missing.append("represented party full name") }

        if blank(profile.firmName) { missing.append("firm/organization") }
        if blank(profile.signingAttorney) { missing.append("signing attorney") }
        if blank(profile.barNumber) { missing.append("bar number") }
        if blank(profile.office.street) { missing.append("office street") }
        if blank(profile.office.city) { missing.append("office city") }
        if blank(profile.office.state) { missing.append("office state") }
        if blank(profile.office.zip) { missing.append("office ZIP") }
        if blank(profile.office.phone) { missing.append("office phone") }
        if blank(profile.primaryEmail) {
            missing.append("primary service e-mail")
        } else if !isValidEmail(profile.primaryEmail) {
            missing.append("valid primary service e-mail")
        }
        for email in profile.secondaryEmails where !blank(email) && !isValidEmail(email) {
            missing.append("valid secondary service e-mail")
        }

        if inputs.recipients.isEmpty {
            missing.append("service recipients")
        }
        for (index, recipient) in inputs.recipients.enumerated() {
            let label = "service recipient \(index + 1)"
            if blank(recipient.name) { missing.append("\(label) name") }
            if blank(recipient.role) { missing.append("\(label) role") }
            if blank(recipient.address.street) { missing.append("\(label) street") }
            if blank(recipient.address.city) { missing.append("\(label) city") }
            if blank(recipient.address.state) { missing.append("\(label) state") }
            if blank(recipient.address.zip) { missing.append("\(label) ZIP") }
            if recipient.emails.filter({ !blank($0) }).isEmpty {
                missing.append("\(label) service e-mail")
            }
            for email in recipient.emails where !blank(email) && !isValidEmail(email) {
                missing.append("valid \(label) service e-mail")
            }
        }

        return unique(missing)
    }

    private static func blank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private static func isBlankOrPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("Unspecified") == .orderedSame
    }

    private static func isValidEmail(_ value: String) -> Bool {
        guard !blank(value) else { return false }
        return SlotValidators.validate(.emailFormat, value: value.trimmingCharacters(in: .whitespacesAndNewlines)) == .ok
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
