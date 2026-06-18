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
    public func save() {
        try? store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        persistComposedPrompt()
        message = "Profile saved."
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
            save()
            message = "Added “\(url.lastPathComponent)”."
        } catch {
            message = (error as? ExtractionError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func removeWritingSample(id: String) {
        profile.writingSamples.removeAll { $0.id == id }
        save()
    }
}
