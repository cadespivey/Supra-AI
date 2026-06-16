import AppKit
import SupraCore
import SupraSessions
import SwiftUI

/// Generation defaults, model storage location, and app info.
struct SettingsView: View {
    @ObservedObject var settings: SettingsController

    var body: some View {
        Form {
            Section("Generation Defaults") {
                Picker("Preset", selection: $settings.preset) {
                    ForEach(GenerationPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.2f", settings.temperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                }

                Stepper(
                    "Max output tokens: \(settings.maxOutputTokens)",
                    value: $settings.maxOutputTokens,
                    in: 128...8192,
                    step: 128
                )
            }

            Section("Model Storage") {
                LabeledContent("Downloaded models") {
                    Text(settings.modelsDirectoryPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    revealInFinder(settings.modelsDirectoryPath)
                }
            }

            Section("About") {
                LabeledContent(
                    "Version",
                    value: "\(settings.appVersion.marketingVersion) (\(settings.appVersion.buildNumber))"
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func revealInFinder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
