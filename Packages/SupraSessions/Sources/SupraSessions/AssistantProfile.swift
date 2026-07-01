import Foundation

/// The user's personalization profile. Structured inputs (who they are, how they
/// write, how they cite) plus excerpts of their own writing are assembled into the
/// assistant's "soul document" — the system prompt that shapes every response.
public struct AssistantProfile: Codable, Equatable, Sendable {
    /// Persistence keys in the app-settings store.
    public static let profileKey = "assistant.profile"
    /// The composed system prompt the chat/matter controllers read at send time.
    public static let systemPromptKey = "assistant.systemPrompt"

    public enum Formality: String, Codable, CaseIterable, Sendable, Identifiable {
        case formal, balanced, plainSpoken
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .formal: "Formal"
            case .balanced: "Balanced"
            case .plainSpoken: "Plain-spoken"
            }
        }
    }

    public enum Length: String, Codable, CaseIterable, Sendable, Identifiable {
        case concise, balanced, thorough
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .concise: "Concise"
            case .balanced: "Balanced"
            case .thorough: "Thorough"
            }
        }
    }

    /// An excerpt of the user's own writing, used to learn their voice/formatting.
    public struct WritingSample: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var excerpt: String

        public init(id: String = UUID().uuidString, name: String, excerpt: String) {
            self.id = id
            self.name = name
            self.excerpt = excerpt
        }
    }

    /// One bar admission: the jurisdiction (a `BarJurisdictionCatalog` id, or free text
    /// for an unlisted bar) and the attorney's number in it. A user can hold several;
    /// the one matching a filing's court prints on that filing's signature block.
    public struct BarLicense: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// `BarJurisdictionCatalog` id (USPS abbreviation, e.g. "fl"); may be a free-text
        /// value for a jurisdiction not in the catalog.
        public var jurisdictionID: String
        public var barNumber: String

        public init(id: String = UUID().uuidString, jurisdictionID: String, barNumber: String) {
            self.id = id
            self.jurisdictionID = jurisdictionID
            self.barNumber = barNumber
        }
    }

    // Who you are
    public var fullName: String = ""
    public var role: String = ""
    public var organization: String = ""
    public var jurisdictions: String = ""
    public var practiceAreas: String = ""
    // Firm identity for document drafting (slot-only; never baked into a template).
    // These populate the signature block / letterhead of generated filings & letters.
    /// Legacy single bar number. Superseded by `barLicenses` (kept for back-compat and
    /// as a fallback when no structured licenses exist). Decoding migrates a non-empty
    /// value into `barLicenses`.
    public var barNumber: String = ""
    /// The attorney's bar admissions. One is matched to a filing's court at draft time.
    public var barLicenses: [BarLicense] = []
    /// The `BarLicense.id` to print when no admission matches the filing's court.
    /// Empty falls back to the first license.
    public var primaryBarLicenseID: String = ""
    public var officeStreet: String = ""
    public var officeSuite: String = ""
    public var officeCity: String = ""
    public var officeState: String = ""
    public var officeZip: String = ""
    /// The firm's main office line — used in the drafting signature block.
    public var officePhone: String = ""
    /// The attorney's direct line.
    public var officePhoneDirect: String = ""
    /// The attorney's mobile / cell number.
    public var officeCell: String = ""
    public var officeFax: String = ""
    public var primaryEmail: String = ""
    /// Up to two secondary service e-mail designations (Fla. R. Jud. Admin. 2.516).
    public var secondaryEmails: [String] = []
    // How to write
    public var formality: Formality = .balanced
    public var length: Length = .balanced
    public var voiceNotes: String = ""
    // Citations
    public var citationStyle: String = ""
    public var citationNotes: String = ""
    // Anything else
    public var additionalInstructions: String = ""
    // Reference writing
    public var writingSamples: [WritingSample] = []

    public init() {}

    public static let empty = AssistantProfile()

    public var isConfigured: Bool {
        !fullName.isEmpty || !role.isEmpty || !organization.isEmpty || !jurisdictions.isEmpty
            || !practiceAreas.isEmpty || !voiceNotes.isEmpty || !citationStyle.isEmpty
            || !citationNotes.isEmpty || !additionalInstructions.isEmpty || !writingSamples.isEmpty
            || formality != .balanced || length != .balanced
    }

    /// True when the profile carries at least one usable bar number (a structured
    /// license or the legacy single field).
    public var hasAnyBarLicense: Bool {
        !usableBarLicenses.isEmpty || (barLicenses.isEmpty && !trimmed(barNumber).isEmpty)
    }

    /// The license to print when no admission matches a filing's court: the explicitly
    /// chosen primary, else the first license.
    public var primaryBarLicense: BarLicense? {
        usableBarLicenses.first { $0.id == primaryBarLicenseID } ?? usableBarLicenses.first
    }

    /// Resolves which bar admission prints on a filing in the given jurisdiction
    /// (free text — a matter's `jurisdiction` or `court`). Prefers the license whose
    /// jurisdiction matches the court, falls back to the primary license, and finally
    /// synthesizes one from the legacy `barNumber` (jurisdiction inferred from the
    /// office state) so existing single-bar profiles keep working. Returns nil only
    /// when no bar information exists at all.
    public func resolvedBarLicense(forJurisdiction jurisdiction: String) -> BarLicense? {
        if !barLicenses.isEmpty {
            if let matched = BarJurisdictionCatalog.match(jurisdiction),
               let license = usableBarLicenses.first(where: { $0.jurisdictionID.lowercased() == matched.id }) {
                return license
            }
            return primaryBarLicense
        }
        guard !trimmed(barNumber).isEmpty else { return nil }
        let inferred = BarJurisdictionCatalog.match(jurisdiction)?.id
            ?? BarJurisdictionCatalog.match(officeState)?.id
            ?? ""
        return BarLicense(jurisdictionID: inferred, barNumber: trimmed(barNumber))
    }

    /// Whether the profile carries enough firm identity to populate a court signature
    /// block / letterhead without inventing anything (drafting slot readiness).
    public var hasDraftingIdentity: Bool {
        !trimmed(fullName).isEmpty && !trimmed(organization).isEmpty && hasAnyBarLicense
            && !trimmed(officeStreet).isEmpty && !trimmed(officeCity).isEmpty && !trimmed(officeState).isEmpty
            && !trimmed(officeZip).isEmpty && !trimmed(officePhone).isEmpty && !trimmed(primaryEmail).isEmpty
    }

    /// The firm-identity fields that are still blank, for a precise "complete your
    /// profile to draft" prompt (never guessed/auto-filled — design §8.6).
    public var missingDraftingIdentityFields: [String] {
        var missing: [String] = []
        if trimmed(fullName).isEmpty { missing.append("full name") }
        if trimmed(organization).isEmpty { missing.append("firm/organization") }
        if !hasAnyBarLicense { missing.append("bar number") }
        if trimmed(officeStreet).isEmpty { missing.append("office street") }
        if trimmed(officeCity).isEmpty { missing.append("office city") }
        if trimmed(officeState).isEmpty { missing.append("office state") }
        if trimmed(officeZip).isEmpty { missing.append("office ZIP") }
        if trimmed(officePhone).isEmpty { missing.append("office phone") }
        if trimmed(primaryEmail).isEmpty { missing.append("primary e-mail") }
        return missing
    }

    private var usableBarLicenses: [BarLicense] {
        barLicenses.compactMap { license in
            let number = trimmed(license.barNumber)
            guard !number.isEmpty else { return nil }
            return BarLicense(
                id: license.id,
                jurisdictionID: trimmed(license.jurisdictionID).lowercased(),
                barNumber: number
            )
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Resilient decoding so adding fields later never drops a saved profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        organization = try c.decodeIfPresent(String.self, forKey: .organization) ?? ""
        jurisdictions = try c.decodeIfPresent(String.self, forKey: .jurisdictions) ?? ""
        practiceAreas = try c.decodeIfPresent(String.self, forKey: .practiceAreas) ?? ""
        barNumber = try c.decodeIfPresent(String.self, forKey: .barNumber) ?? ""
        officeStreet = try c.decodeIfPresent(String.self, forKey: .officeStreet) ?? ""
        officeSuite = try c.decodeIfPresent(String.self, forKey: .officeSuite) ?? ""
        officeCity = try c.decodeIfPresent(String.self, forKey: .officeCity) ?? ""
        officeState = try c.decodeIfPresent(String.self, forKey: .officeState) ?? ""
        officeZip = try c.decodeIfPresent(String.self, forKey: .officeZip) ?? ""
        officePhone = try c.decodeIfPresent(String.self, forKey: .officePhone) ?? ""
        officePhoneDirect = try c.decodeIfPresent(String.self, forKey: .officePhoneDirect) ?? ""
        officeCell = try c.decodeIfPresent(String.self, forKey: .officeCell) ?? ""
        officeFax = try c.decodeIfPresent(String.self, forKey: .officeFax) ?? ""
        primaryEmail = try c.decodeIfPresent(String.self, forKey: .primaryEmail) ?? ""
        secondaryEmails = try c.decodeIfPresent([String].self, forKey: .secondaryEmails) ?? []
        formality = try c.decodeIfPresent(Formality.self, forKey: .formality) ?? .balanced
        length = try c.decodeIfPresent(Length.self, forKey: .length) ?? .balanced
        voiceNotes = try c.decodeIfPresent(String.self, forKey: .voiceNotes) ?? ""
        citationStyle = try c.decodeIfPresent(String.self, forKey: .citationStyle) ?? ""
        citationNotes = try c.decodeIfPresent(String.self, forKey: .citationNotes) ?? ""
        additionalInstructions = try c.decodeIfPresent(String.self, forKey: .additionalInstructions) ?? ""
        writingSamples = try c.decodeIfPresent([WritingSample].self, forKey: .writingSamples) ?? []
        barLicenses = try c.decodeIfPresent([BarLicense].self, forKey: .barLicenses) ?? []
        primaryBarLicenseID = try c.decodeIfPresent(String.self, forKey: .primaryBarLicenseID) ?? ""
        // Migrate a legacy single bar number into a structured license (jurisdiction
        // inferred from the office state) so older saved profiles surface in the editor
        // and resolve a proper bar label.
        if barLicenses.isEmpty, !barNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let migrated = BarLicense(
                jurisdictionID: BarJurisdictionCatalog.match(officeState)?.id ?? "",
                barNumber: barNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            barLicenses = [migrated]
            if primaryBarLicenseID.isEmpty { primaryBarLicenseID = migrated.id }
            // Once surfaced as a structured row, the legacy hidden field must stop
            // satisfying readiness or reappearing after the user edits admissions.
            barNumber = ""
        }
    }

    /// The "soul document": the base prompt augmented with everything the user told
    /// us. Empty sections are omitted so a sparse profile stays focused.
    ///
    /// `includeWritingSamples` gates the verbatim writing-style excerpts. They belong
    /// only in drafting/voice contexts; in grounded factual ones (research, Q&A,
    /// structured outputs) they must be omitted, because the model otherwise mines
    /// their prose as fact and can let it override the matter's actual documents.
    public func composedSystemPrompt(base: String?, includeWritingSamples: Bool = true) -> String {
        var profile: [String] = []

        var identity: [String] = []
        if !fullName.isEmpty {
            identity.append("You are assisting \(fullName)\(role.isEmpty ? "" : ", \(role)")\(organization.isEmpty ? "" : " at \(organization)").")
        } else if !role.isEmpty {
            identity.append("You are assisting a \(role)\(organization.isEmpty ? "" : " at \(organization)").")
        }
        if !jurisdictions.isEmpty { identity.append("Primary jurisdiction(s): \(jurisdictions).") }
        if !practiceAreas.isEmpty { identity.append("Practice area(s): \(practiceAreas).") }
        if !identity.isEmpty { profile.append("## About the user\n" + identity.joined(separator: " ")) }

        // Only describe style when the user actually deviated from the defaults or
        // added notes — otherwise an untouched profile would inject a redundant
        // "Balanced / Balanced" block on every request.
        var style: [String] = []
        if formality != .balanced { style.append("- Formality: \(formality.label).") }
        if length != .balanced { style.append("- Default length: \(length.label).") }
        if !voiceNotes.isEmpty { style.append("- Voice and style: \(voiceNotes)") }
        if !style.isEmpty {
            profile.append("## How to write for this user\n" + style.joined(separator: "\n"))
        }

        var cites: [String] = []
        if !citationStyle.isEmpty {
            cites.append("- Citation style: \(citationStyle).")
            // Fold in the baked-in guidance for a recognized style/state so the
            // assistant cites the way that jurisdiction expects.
            if let guidance = CitationStyleCatalog.style(named: citationStyle)?.guidance {
                cites.append("- \(guidance)")
            }
        }
        if !citationNotes.isEmpty { cites.append("- \(citationNotes)") }
        if !cites.isEmpty { profile.append("## Citations\n" + cites.joined(separator: "\n")) }

        if !additionalInstructions.isEmpty {
            // The user's free-text instructions are standing preferences for tone,
            // format, and emphasis. They are framed (not pasted raw) so they can't be
            // read as granting capabilities the assistant lacks — e.g. an instruction
            // to "log your time" or "note actions taken" must shape wording, never
            // license the model to claim it searched, reviewed, or filed anything, and
            // never override the sources or grounding for a task.
            profile.append(
                "## Additional instructions\nApply the following standing preferences to tone, format, "
                + "and emphasis. They do not grant any capability or authority to take actions, and they "
                + "never override the factual grounding or sources for a task:\n\n\(additionalInstructions)"
            )
        }

        if includeWritingSamples, !writingSamples.isEmpty {
            var samples = [
                "## The user's writing style",
                "The following are excerpts of the user's OWN past writing, provided solely as STYLE EXEMPLARS so you can emulate their voice, tone, structure, and formatting. They are not part of the current matter and are not evidence: never treat their content as fact, never reuse their parties, names, dates, figures, or holdings, and never let them override or substitute for the matter's documents or your cited sources. Match the style only; draw all substance from the actual sources for the task at hand."
            ]
            for sample in writingSamples {
                samples.append("")
                samples.append("### \(sample.name)")
                samples.append(sample.excerpt)
            }
            profile.append(samples.joined(separator: "\n"))
        }

        var sections: [String] = []
        if let base, !base.isEmpty { sections.append(base) }
        if !profile.isEmpty {
            sections.append("# User profile\nApply the following to every response for this user.\n\n" + profile.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n---\n\n")
    }
}
