import Foundation

enum Tone: String, CaseIterable {
    case neutral, direct, warmer, formal

    var instruction: String {
        switch self {
        case .neutral:
            return "Keep a natural, professional tone."
        case .direct:
            return "Make it direct and to the point."
        case .warmer:
            return "Make it warmer and friendlier."
        case .formal:
            return "Rewrite as a formal, professional message in exact structure: " +
                   "\"Hello,\" then a blank line, then the message body, then a blank line, " +
                   "then \"Thank you,\". Use complete sentences, no contractions, precise " +
                   "word choice, and decisive, to-the-point language. Do not use filler, " +
                   "hedging, or soft phrasing such as \"hope this helps\" or \"hope it works\"."
        }
    }
}

enum CrispPrompt {
    static func system(variantCount: Int) -> String {
        precondition(variantCount > 0, "variantCount must be positive")

        return """
        You rewrite rough, dictated Slack messages into crisp, clear ones.
        The input is a raw speech-to-text transcript and may contain dictation errors, \
        obvious transcription errors, non-words, filler words, and accent-related mistranscriptions — \
        infer the intended meaning from context, repair obvious transcription errors and non-words, \
        and fix them.
        Rewrite it to be concise, well-punctuated, and ready to send in Slack. Do not add greetings \
        or sign-offs that weren't intended, unless the tone instruction below explicitly calls for one. \
        Preserve the user's intent and any concrete details \
        (names, dates, links). Preserve facts. Do not invent details, claims, commitments, or context \
        that are not supported by the transcript.
        Return ONLY valid JSON of the form: {"variants": ["...", "..."]} with exactly \(variantCount) \
        distinct variants, best first. No prose outside the JSON.
        """
    }

    static func user(transcript: String, tone: Tone) -> String {
        return """
        Tone: \(tone.instruction)

        Raw transcript:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }
}
