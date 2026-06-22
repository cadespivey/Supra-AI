import Combine
import Foundation
import SupraDocuments
import SupraStore

/// Owns the user's `AssistantProfile`: loads/saves it, extracts text from dropped
/// writing samples, and persists the composed system prompt (the "soul document")
/// that the chat and matter controllers read at send time.
@MainActor
public final class AssistantProfileController: ObservableObject {
    @Published public var profile: AssistantProfile
    @Published public private(set) var isAddingSample = false
    @Published public var message: String?

    /// Per-sample excerpt cap so a long brief doesn't dominate the system prompt.
    private static let sampleExcerptLimit = 2000

    private let store: SupraStore
    private let basePrompt: String?
    private let extraction: ExtractionService

    public init(store: SupraStore, basePrompt: String?, extraction: ExtractionService = ExtractionService()) {
        self.store = store
        self.basePrompt = basePrompt
        self.extraction = extraction
        self.profile = (try? store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self)) ?? .empty
        // Keep the stored soul document current on launch (e.g. after a base-prompt
        // change), so controllers always read an up-to-date prompt.
        persistComposedPrompt()
    }

    /// The assembled soul document, for the Settings preview.
    public var composedSystemPrompt: String {
        profile.composedSystemPrompt(base: basePrompt)
    }

    /// Persists the profile and recomposes the system prompt the model receives.
    /// Returns whether the write succeeded, and reports failure to the user rather
    /// than claiming success.
    @discardableResult
    public func save() -> Bool {
        do {
            try store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
            try store.appSettings.setSetting(AssistantProfile.systemPromptKey, value: composedSystemPrompt)
            message = "Profile saved."
            return true
        } catch {
            message = "Couldn't save your profile. \(error.localizedDescription)"
            return false
        }
    }

    /// Clears any transient status message.
    public func clearMessage() { message = nil }

    private func persistComposedPrompt() {
        try? store.appSettings.setSetting(AssistantProfile.systemPromptKey, value: composedSystemPrompt)
    }

    /// Extracts text from a dropped document and adds it as a writing sample.
    public func addWritingSample(url: URL) async {
        isAddingSample = true
        defer { isAddingSample = false }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try await extraction.extract(fileURL: url)
            let text = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                message = "No text was found in “\(url.lastPathComponent)”."
                return
            }
            let excerpt = String(text.prefix(Self.sampleExcerptLimit))
            profile.writingSamples.append(AssistantProfile.WritingSample(name: url.lastPathComponent, excerpt: excerpt))
            if save() {
                message = "Added “\(url.lastPathComponent)”."
            }
        } catch {
            message = (error as? ExtractionError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func removeWritingSample(id: String) {
        profile.writingSamples.removeAll { $0.id == id }
        save()
    }
}

extension SupraStore {
    /// The user's "soul document" composed over the given base prompt, recomposed
    /// fresh from the saved profile (`AssistantProfile.profileKey`) at send time.
    ///
    /// This keeps the task/route system prompt as the LEAD instruction while the
    /// profile (identity, jurisdiction, citation style, voice) layers on top — so a
    /// legal answer obeys the attorney's configured citation form and jurisdiction
    /// without the profile overriding the task's grounding/structure contract.
    /// Reading the profile fresh means Settings edits apply at the next generation
    /// without reselecting a matter or relaunching. Returns `base` unchanged when no
    /// profile is configured, so callers cleanly fall back to their task prompt.
    ///
    /// `includeWritingSamples` is false for grounded factual tasks (research, Q&A,
    /// structured outputs): the user's verbatim writing-style excerpts are voice
    /// exemplars only and must never enter a context where the model could treat
    /// them as facts or let them displace the matter's own documents.
    func composedAssistantPrompt(base: String?, includeWritingSamples: Bool = true) -> String? {
        guard
            let profile = try? appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self),
            profile.isConfigured
        else { return base }
        let composed = profile.composedSystemPrompt(base: base, includeWritingSamples: includeWritingSamples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return composed.isEmpty ? base : composed
    }
}
