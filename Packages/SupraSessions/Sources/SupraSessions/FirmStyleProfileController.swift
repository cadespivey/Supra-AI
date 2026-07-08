import Combine
import Foundation
import SupraDraftingCore
import SupraExports
import SupraStore

/// Owns the firm's `FirmStyleProfile` (Track A structural style): loads it at launch, autosaves
/// every edit, and surfaces a message only if a write fails. Mirrors `AssistantProfileController`
/// (SPEC §4.4). In the app it feeds its `.profile` into `MatterDraftingController`'s
/// `firmStyleProfile` injection point, so a firm's letterhead/caption/signature choices flow
/// deterministically into every draft.
@MainActor
public final class FirmStyleProfileController: ObservableObject {
    /// Every edit autosaves immediately (didSet → persist), so a firm can never lose its style by
    /// forgetting to press a button. didSet does not fire for the initial assignment in `init`, so
    /// loading the stored profile doesn't loop.
    @Published public var profile: FirmStyleProfile { didSet { persist() } }
    @Published public var message: String?

    /// The persistence operation. Defaults to a write into `store.appSettings`; the internal init
    /// swaps in a custom closure so the failure path is unit-testable (there is no store protocol
    /// to stub).
    private let write: (FirmStyleProfile) throws -> Void

    public init(store: SupraStore) {
        self.write = { try store.appSettings.setSetting(FirmStyleProfile.profileKey, value: $0) }
        self.profile = (try? store.appSettings.getSetting(FirmStyleProfile.profileKey, as: FirmStyleProfile.self))
            ?? FirmStyleProfile()
    }

    /// Testing seam: an explicit initial profile + injectable persistence (no store).
    init(initialProfile: FirmStyleProfile, write: @escaping (FirmStyleProfile) throws -> Void) {
        self.write = write
        self.profile = initialProfile
    }

    /// The effective sheet the renderers would consume for this firm — for a Settings preview.
    public var effectiveStyle: HouseStyleSheet {
        profile.resolved(over: .defaultFL).clampedToFloor()
    }

    /// Clears any transient status message.
    public func clearMessage() { message = nil }

    // MARK: - Preview (M3-T3 / T-PARSE-09)

    /// The preview's document.xml — a FIXED, clearly-fictional sample notice rendered through
    /// the production court renderer under the firm's effective sheet. Deterministic: same
    /// profile ⇒ identical WML, so what the user confirms is exactly what every draft renders.
    /// The sheet is floor-clamped first; the renderer's own validateFloor then passes by
    /// construction.
    public func previewDocumentXML() throws -> String {
        try CourtFLRenderer().documentXML(Self.sampleNoticeModel, style: effectiveStyle)
    }

    /// The preview as an openable `.docx` (for "see it in Word/Pages" from Settings).
    public func previewDocx() throws -> Data {
        try CourtFLRenderer().render(.court(Self.sampleNoticeModel), style: effectiveStyle)
    }

    /// The fictional design-render fixture (the "Pearson Specter Litt / McKernon" set used by
    /// the golden suites) — fixed dates and parties so the preview never varies run-to-run.
    private static let sampleNoticeModel = DocumentModel(
        caption: CaptionModel(
            courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
                      PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")],
            caseNumber: "2026-CA-001847",
            division: "CV-G",
            judge: nil
        ),
        title: "NOTICE OF APPEARANCE",
        body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney enters an appearance as counsel for the Defendant in this action.")],
        signature: SignatureBlockModel(
            respectfullySubmitted: nil,
            firmName: "Pearson Specter Litt",
            signingAttorney: "Harvey Specter",
            attorneys: [AttorneyLine(name: "Harvey Specter", barNumber: "Florida Bar No. 100847")],
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "hspecter@pearsonspecterlitt.example",
                                     secondary: ["litdocket@pearsonspecterlitt.example"])
        ),
        certificate: CertificateModel(
            date: DateOnly(year: 2026, month: 6, day: 25),
            clause: .flEPortal,
            documentTitle: "NOTICE OF APPEARANCE",
            recipients: [ServiceRecipient(
                name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                     city: "Jacksonville", state: "Florida", zip: "32202",
                                     phone: "", fax: nil),
                emails: ["dhardman@hardmantanner.example"], role: "Counsel for Plaintiff")],
            signOffAttorney: "Harvey Specter"
        )
    )

    /// Autosaves the profile. Silent on success (no per-keystroke status), but surfaces a message
    /// if the write fails so the firm is never silently losing its style configuration.
    private func persist() {
        do {
            try write(profile)
        } catch {
            message = "Couldn't save your firm style. \(error.localizedDescription)"
        }
    }
}
