import Foundation
import SupraDraftingCore

// The `noticeAppearance` kind — a servicePipeline kind: fixed language + slots, NO LLM.
// Body template per NoticeAppearance §5; identity is slot-only (no baked names — §8.6 / §7.2).

public enum NoticeAppearance {
    public struct Inputs: Sendable {
        public var courtHeader: String
        public var parties: [PartyLine]
        public var partyRepresented: String          // "Defendant"
        public var representedPartyName: String       // "Atlantic Ridge Holdings, Inc."
        public var caseNumber: String
        public var division: String?
        public var serviceDate: DateOnly
        public var recipients: [ServiceRecipient]

        public init(courtHeader: String, parties: [PartyLine], partyRepresented: String,
                    representedPartyName: String, caseNumber: String, division: String?,
                    serviceDate: DateOnly, recipients: [ServiceRecipient]) {
            self.courtHeader = courtHeader
            self.parties = parties
            self.partyRepresented = partyRepresented
            self.representedPartyName = representedPartyName
            self.caseNumber = caseNumber
            self.division = division
            self.serviceDate = serviceDate
            self.recipients = recipients
        }
    }

    public static let title = "NOTICE OF APPEARANCE"

    /// Assembles the DocumentModel from resolved slots. No identity literal appears in this
    /// function — every name/email/bar/address arrives via `inputs` or `profile`.
    public static func assemble(_ inputs: Inputs, profile: FirmProfile) -> DocumentModel {
        let caption = CaptionModel(
            courtHeader: inputs.courtHeader,
            parties: inputs.parties,
            caseNumber: inputs.caseNumber,
            division: inputs.division,
            judge: nil
        )

        let intro = "PLEASE TAKE NOTICE that the undersigned attorney, \(profile.signingAttorney) of \(profile.firmName), hereby enters an appearance as counsel of record for \(inputs.partyRepresented), \(inputs.representedPartyName), in the above-styled action, and requests that copies of all pleadings, notices, orders, correspondence, and other documents filed or served in this action be furnished to the undersigned at the addresses set forth below."

        var emailList = profile.primaryEmail
        if !profile.secondaryEmails.isEmpty {
            emailList += "; " + profile.secondaryEmails.joined(separator: "; ")
        }
        let designation = "Pursuant to Florida Rule of General Practice and Judicial Administration 2.516, the undersigned designates the following e-mail addresses for service of all documents in this action: \(emailList)."

        let body: [BodyBlock] = [.paragraph(intro), .paragraph(designation)]

        let signature = SignatureBlockModel(
            respectfullySubmitted: nil,                  // notices carry no "Respectfully submitted:"
            firmName: profile.firmName,
            signingAttorney: profile.signingAttorney,
            attorneys: [AttorneyLine(name: profile.signingAttorney, barNumber: "\(profile.barLabel) \(profile.barNumber)")],
            office: profile.office,
            partyRepresented: inputs.partyRepresented,
            emails: EmailDesignation(primary: profile.primaryEmail, secondary: profile.secondaryEmails)
        )

        let certificate = CertificateModel(
            date: inputs.serviceDate,
            clause: .flEPortal,
            documentTitle: title,
            recipients: inputs.recipients,
            signOffAttorney: profile.signingAttorney
        )

        return DocumentModel(caption: caption, title: title, body: body,
                            signature: signature, certificate: certificate)
    }
}
