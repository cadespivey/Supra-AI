import Foundation
import SupraDraftingCore

// The `letterDemand` kind — routed-skill: the model writes the whole letter (voice ON, tone-only),
// then the fact-firewall runs. The slice ships a deterministic assembler that takes an already-
// generated (and firewall-sanitized) GeneratedLetter and builds the LetterModel. Identity = slots.

public enum LetterDemand {
    public struct Inputs: Sendable {
        public var recipient: AddressBlock
        public var reSubject: String
        public var salutation: String
        public var date: DateOnly
        public var deliveryNotation: String?          // "Via Certified Mail, Return Receipt Requested"
        public var enclosures: [String]
        public var cc: [String]

        public init(recipient: AddressBlock, reSubject: String, salutation: String, date: DateOnly,
                    deliveryNotation: String? = nil, enclosures: [String] = [], cc: [String] = []) {
            self.recipient = recipient
            self.reSubject = reSubject
            self.salutation = salutation
            self.date = date
            self.deliveryNotation = deliveryNotation
            self.enclosures = enclosures
            self.cc = cc
        }
    }

    /// voice is ON for letters but tone-only; the fact gate (not voice's absence) is the guard.
    public static func voiceContext(_ profile: AssistantVoiceProfile) -> VoiceContext {
        VoiceContext(profile: profile, toneOnly: true)
    }

    public static func promptParts(facts: [GroundedFact], profile: AssistantVoiceProfile) -> PromptParts {
        PromptParts(
            taskInstruction: "Draft a demand letter that recites the matter facts and demands payment by the stated deadline.",
            voice: voiceContext(profile),
            sectionContract: .wholeLetter,
            facts: facts,
            authorities: [],
            decoding: .creative
        )
    }

    public static func assemble(_ inputs: Inputs, generated: GeneratedLetter,
                               profile: FirmProfile, style: HouseStyleSheet) -> LetterModel {
        let closing = style.letterhead?.closing ?? "Respectfully,"
        return LetterModel(
            letterhead: LetterheadFill(firmName: profile.firmName, office: profile.office),
            date: inputs.date,
            recipient: inputs.recipient,
            reLine: inputs.reSubject,
            salutation: inputs.salutation,
            body: generated.paragraphs,
            closing: closing,
            signerName: profile.signingAttorney,
            signerTitle: nil,
            enclosures: inputs.enclosures,
            cc: inputs.cc
        )
    }
}
