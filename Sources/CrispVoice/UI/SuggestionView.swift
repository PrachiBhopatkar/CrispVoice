import SwiftUI

/// View-model driving the suggestion panel. Observable so the panel updates
/// as transcription/crisping progresses.
final class SuggestionModel: ObservableObject {
    @Published var status: String = "Listening…"
    @Published var transcript: String = ""
    @Published var variants: [String] = []
    @Published var isWorking: Bool = false
    /// True after the rewrite (or transcription) failed, until the next attempt.
    @Published var hasFailed: Bool = false
    /// True after the user copied text, until the next capture.
    @Published var didCopy: Bool = false

    var displayedTexts: [String] {
        if !variants.isEmpty { return variants }
        if !transcript.isEmpty { return [transcript] }
        return []
    }

    var showsVariantButtons: Bool { !variants.isEmpty }

    /// Keeps the dictation recoverable, including after a failed rewrite.
    var showsCopyTranscript: Bool { !transcript.isEmpty }

    /// Offered only when a rewrite failed and the saved transcript can be retried.
    var showsRetry: Bool { hasFailed && !isWorking && variants.isEmpty && !transcript.isEmpty }

    func resetForNewCapture() {
        transcript = ""
        variants = []
        isWorking = false
        hasFailed = false
        didCopy = false
        status = "Listening…"
    }

    var onPick: (String) -> Void = { _ in }
    var onTone: (Tone) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
    var onClose: () -> Void = {}
    var onCopy: (String) -> Void = { _ in }
    var onRetry: () -> Void = {}
}

struct SuggestionView: View {
    @ObservedObject var model: SuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CrispVoice").font(.headline)
                Spacer()
                if model.isWorking { ProgressView().scaleEffect(0.6) }
                Button { model.onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close CrispVoice")
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
                                HStack(alignment: .top, spacing: 6) {
                                    Button { model.onPick(variant) } label: {
                                        Text(variant)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(10)
                                            .background(.quaternary)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    Button("Copy") { model.onCopy(variant) }
                                        .font(.caption)
                                        .padding(.top, 8)
                                }
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

            if model.showsCopyTranscript || model.showsRetry || model.didCopy {
                HStack(spacing: 8) {
                    if model.showsCopyTranscript {
                        Button("Copy transcript") { model.onCopy(model.transcript) }
                    }
                    if model.showsRetry {
                        Button("Try again") { model.onRetry() }
                    }
                    if model.didCopy {
                        Text("Copied").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
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
