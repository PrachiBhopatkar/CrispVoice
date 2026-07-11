import SwiftUI

/// View-model driving the suggestion panel. Observable so the panel updates
/// as transcription/crisping progresses.
final class SuggestionModel: ObservableObject {
    @Published var status: String = "Listening…"
    @Published var transcript: String = ""
    @Published var variants: [String] = []
    @Published var isWorking: Bool = false

    var displayedTexts: [String] {
        if !variants.isEmpty { return variants }
        if !transcript.isEmpty { return [transcript] }
        return []
    }

    var showsVariantButtons: Bool { !variants.isEmpty }

    var onPick: (String) -> Void = { _ in }
    var onTone: (Tone) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
}

struct SuggestionView: View {
    @ObservedObject var model: SuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CrispVoice").font(.headline)
                Spacer()
                if model.isWorking { ProgressView().scaleEffect(0.6) }
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.displayedTexts.isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.showsVariantButtons {
                            ForEach(Array(model.displayedTexts.enumerated()), id: \.offset) { _, variant in
                                Button { model.onPick(variant) } label: {
                                    Text(variant)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(10)
                                        .background(.quaternary)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        } else if let transcript = model.displayedTexts.first {
                            Text(transcript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if model.showsVariantButtons {
                HStack(spacing: 6) {
                    toneButton("Direct", .direct)
                    toneButton("Warmer", .warmer)
                    toneButton("Formal", .formal)
                    Button("Regenerate") { model.onRegenerate() }
                }
                .font(.caption)
            }
        }
        .padding(18)
        .frame(width: 560, height: 320, alignment: .topLeading)
    }

    private func toneButton(_ label: String, _ tone: Tone) -> some View {
        Button(label) { model.onTone(tone) }
    }
}
