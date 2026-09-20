import SwiftUI

extension Notification.Name {
    // Transitional: `AppDelegate` still observes this name to refresh its
    // cached Anthropic key. Task 9 rewires `AppDelegate` onto the
    // content-free `.crispVoiceRewriteConfigurationDidChange` notification
    // (declared in `SettingsModel.swift`) and removes this one. Nothing in
    // this file posts it anymore.
    static let crispVoiceAPIKeyDidChange = Notification.Name("CrispVoiceAPIKeyDidChange")
}

/// The Anthropic-only Settings form. `SettingsModel` (see
/// `SettingsModel.swift`) already exposes the full Anthropic/Bedrock draft
/// surface; the conditional provider picker and Bedrock-specific controls
/// are added in a later task. All edits here are drafts — nothing persists
/// until Save is pressed (design section 5.2).
struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("sk-ant-…", text: $model.anthropicAPIKey)

                HStack(spacing: 12) {
                    Button("Paste") {
                        model.pasteAnthropicAPIKey()
                    }

                    Button("Save") {
                        model.save()
                    }

                    Button("Test") {
                        Task { await model.testConnection() }
                    }
                    .disabled(model.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTesting)

                    if model.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !model.validationMessage.isEmpty {
                    Text(model.validationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Rewrite") {
                Picker("Model", selection: $model.anthropicModelName) {
                    ForEach(model.anthropicModelOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                Stepper(value: $model.variantCount, in: 1...5) {
                    Text("Variants: \(model.variantCount)")
                }

                Text("Transcription uses Apple Speech. These settings only affect the rewrite step. Select Save to apply changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 420, maxWidth: 420, minHeight: 260)
    }
}
