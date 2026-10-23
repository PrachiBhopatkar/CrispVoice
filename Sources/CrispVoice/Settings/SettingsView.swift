import SwiftUI

/// The Bedrock Settings model picker's two entries. This is purely a view
/// concern: `SettingsModel.bedrockModelOption` (the actual draft, from Task
/// 3/7) already distinguishes the preset from an arbitrary custom
/// identifier — this type only drives which row the `Picker` highlights and
/// whether the custom field is revealed. Selecting `.custom` here always
/// carries the current `bedrockCustomModelID` draft along so the two stay
/// in sync (design section 6/7).
private enum BedrockModelSelection: Hashable, CaseIterable {
    case opus48US
    case custom

    var title: String {
        switch self {
        case .opus48US:
            return "Claude Opus 4.8 (US)"
        case .custom:
            return "Custom…"
        }
    }
}

/// The Settings form. A provider picker selects between Anthropic and
/// Amazon Bedrock; everything below it is provider-specific. All edits here
/// are drafts — nothing persists until Save is pressed (design section
/// 5.2/7). `SettingsModel` owns every field and all validation; this view
/// never eagerly persists anything itself (no `.onChange` writes).
struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Rewrite Provider", selection: $model.selectedProvider) {
                    ForEach(RewriteProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
            }

            switch model.selectedProvider {
            case .anthropic:
                anthropicSection
            case .bedrock:
                bedrockSection
            }

            Section("Rewrite") {
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
        .frame(minWidth: 460, maxWidth: 460, minHeight: 260)
    }

    // MARK: - Anthropic

    @ViewBuilder
    private var anthropicSection: some View {
        Section("Anthropic") {
            SecureField("sk-ant-…", text: $model.anthropicAPIKey)

            Picker("Model", selection: $model.anthropicModelName) {
                ForEach(model.anthropicModelOptions) { option in
                    Text(option.title).tag(option.id)
                }
            }

            HStack(spacing: 12) {
                Button("Paste") {
                    model.pasteAnthropicAPIKey()
                }

                Button("Clear") {
                    model.clearAnthropicAPIKey()
                }
                .disabled(model.anthropicAPIKey.isEmpty)

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

            validationMessageView
        }
    }

    // MARK: - Amazon Bedrock

    @ViewBuilder
    private var bedrockSection: some View {
        Section("Amazon Bedrock") {
            TextField("AWS Profile", text: $model.bedrockProfileName, prompt: Text(model.bedrockProfileDisplayValue))
                .accessibilityHint("Leave blank to use the AWS profile named \"default\".")

            TextField("AWS Region", text: $model.bedrockRegion, prompt: Text("us-west-2"))

            Picker("Model", selection: bedrockModelSelection) {
                ForEach(BedrockModelSelection.allCases, id: \.self) { selection in
                    Text(selection.title).tag(selection)
                }
            }

            if model.isBedrockCustomModelSelected {
                TextField("Custom model or inference-profile ID", text: $model.bedrockCustomModelID)
                    .accessibilityHint("Accepts a Bedrock model ID, inference-profile ID, or inference-profile ARN.")
            }

            Text("Resolved model ID: \(model.bedrockResolvedModelID)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("CrispVoice authenticates using your selected AWS profile. It doesn't store an AWS access key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(model.bedrockCrossRegionDisclosureText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Save") {
                    model.save()
                }

                Button("Test") {
                    Task { await model.testConnection() }
                }
                .disabled(model.isTesting || !model.isBedrockDraftLocallyComplete)

                if model.isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            validationMessageView
        }
    }

    /// Binding adapter between the view-only `BedrockModelSelection` and the
    /// model's actual `BedrockModelOption` draft. Picking "Custom…" carries
    /// the current custom-ID draft along so `model.bedrockModelOption` and
    /// `model.bedrockCustomModelID` never disagree about which case is
    /// active.
    private var bedrockModelSelection: Binding<BedrockModelSelection> {
        Binding(
            get: { model.isBedrockCustomModelSelected ? .custom : .opus48US },
            set: { newValue in
                switch newValue {
                case .opus48US:
                    model.bedrockModelOption = .opus48US
                case .custom:
                    model.bedrockModelOption = .custom(model.bedrockCustomModelID)
                }
            }
        )
    }

    @ViewBuilder
    private var validationMessageView: some View {
        if !model.validationMessage.isEmpty {
            Text(model.validationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
