import SwiftUI

/// View-model driving the suggestion panel. Observable so the panel updates
/// as transcription/crisping progresses.
final class SuggestionModel: ObservableObject {
    @Published var status: String = "Listening…"
    @Published var variants: [String] = []
    @Published var isWorking: Bool = false

    var onPick: (String) -> Void = { _ in }
    var onTone: (Tone) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
}

struct SuggestionView: View {
    @ObservedObject var model: SuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CrispVoice").font(.headline)
                Spacer()
                if model.isWorking { ProgressView().scaleEffect(0.6) }
            }
            if model.variants.isEmpty {
                Text(model.status).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.variants.enumerated()), id: \.offset) { _, variant in
                    Button { model.onPick(variant) } label: {
                        Text(variant).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    toneButton("Shorter", .shorter)
                    toneButton("Direct", .direct)
                    toneButton("Warmer", .warmer)
                    Button("Regenerate") { model.onRegenerate() }
                }.font(.caption)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func toneButton(_ label: String, _ tone: Tone) -> some View {
        Button(label) { model.onTone(tone) }
    }
}
