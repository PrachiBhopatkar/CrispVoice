# Formal JSON Recovery Design

**Date:** 2026-08-06

## Problem

Formal regeneration can fail with `CrispVoice.CrispResult.ParseError error 1` even when the same transcript succeeds for Neutral, Direct, and Warmer. The observed failure occurred twice for the same quote-heavy transcript. Existing diagnostics prove that Anthropic returned a balanced object, but the object did not decode as the required `{"variants": [String]}` payload. A privacy-safe synthetic Formal request returned valid JSON, so the defect is content- or generation-specific rather than a permanent Formal outage.

`CrispResult.parse` intentionally uses strict JSON. Making it guess how malformed quotation marks or multiline strings were intended could silently alter a user's message. The app should instead strengthen the output contract and retry the generation once.

## Approaches Considered

### 1. Strengthen the prompt only

Explicitly require escaped line breaks and embedded quotation marks. This reduces malformed responses but still leaves the user with an error when a probabilistic model violates the instruction.

### 2. Repair malformed JSON locally

Rewrite unescaped line breaks or quotation marks before decoding. This is unsafe because an unescaped quote is ambiguous: it may end a JSON string or be intended message content. A heuristic repair could silently corrupt a Slack message.

### 3. Strengthen the prompt and retry once — selected

Make the initial contract explicit, then retry once with a dedicated repair instruction only when strict response parsing fails. This is focused, preserves strict decoding, adds no dependency, and incurs a second Anthropic request only on the exceptional failure path. It also keeps a bounded execution time and produces a useful final error.

A future schema-bound Anthropic integration may remove the need for a retry, but changing the client response architecture and model compatibility is outside this bug fix.

## Behavior

`CrispPrompt.system(variantCount:)` will retain its signature and all existing content. Its JSON contract will additionally require:

- `variants` must be an array of JSON strings, never objects.
- Line breaks inside a variant must be encoded as `\n`, not literal line breaks inside a JSON string.
- Embedded quotation marks must be encoded as `\"`.

`CrispPrompt.repairSystem(variantCount:) -> String` will return the normal system prompt plus a short instruction that the previous response could not be parsed and the model must try once more using strict JSON escaping. It will not contain the previous generated response, transcript, API key, or other new user data.

`CrispEngine.crisp(transcript:tone:)` will:

1. Make the current completion request.
2. Parse it with `CrispResult.parse`.
3. Return immediately when parsing succeeds.
4. If and only if parsing throws `CrispResult.ParseError`, make one additional completion request with `CrispPrompt.repairSystem` and the same original user prompt.
5. Parse the second response once. Never make a third request.
6. If the second response also has a `CrispResult.ParseError`, throw a localized engine error: `Anthropic returned invalid message variants twice. Please try again.`

Network, HTTP, Keychain, cancellation, and other non-parse errors are never retried by this mechanism. A non-parse error from the retry is propagated unchanged.

## Privacy and Logging

The existing privacy model remains unchanged: the transcript is sent only to `api.anthropic.com` using the user's key. The retry sends the same original prompt to the same endpoint. No developer backend, telemetry, or analytics are added.

The malformed response, repaired response, transcript, variants, and API key must not be written to logs or error messages. Tests use synthetic text only.

## Testing

TDD coverage will prove:

- The initial prompt explicitly specifies strict escaping and string-array shape.
- A valid first response performs exactly one completion request.
- A malformed first response followed by a valid response performs exactly two requests, uses the repair system prompt on the second, and returns the parsed variants.
- Two malformed responses perform exactly two requests and throw the localized engine error.
- Network/non-parse failures are not retried.
- Strict `CrispResult` parsing accepts valid Formal JSON containing escaped blank lines and escaped quoted terms.
- The full XCTest suite and Debug build remain green.

Manual verification will regenerate a Formal result from a transcript containing quoted terms and confirm that variants appear without the raw `ParseError` message. If the model violates the contract once, the automatic retry must recover without user action.

## Out of Scope

- Heuristic mutation of malformed model output.
- Unbounded retries or backoff.
- Retrying HTTP, authentication, network, or Keychain failures.
- Changing models or adding a developer backend.
- Changing the Formal message structure or visual panel design.
