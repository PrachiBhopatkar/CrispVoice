# Formal JSON Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover automatically when Anthropic returns an invalid JSON variants payload during Formal regeneration, without heuristically changing message text.

**Architecture:** Keep `CrispResult` strict. Strengthen the initial JSON-output contract, then let `CrispEngine` retry exactly once with a dedicated repair system prompt only after `CrispResult.ParseError`. Convert a second parse failure into a localized engine error; propagate all network and non-parse errors without retrying them.

**Tech Stack:** Swift 5, Foundation `LocalizedError`, XCTest, the existing `TextCompleter` boundary, XcodeGen, Xcode.

## Global Constraints

- Preserve `CrispPrompt.system(variantCount:)` and `CrispEngine.crisp(transcript:tone:)` signatures.
- Keep strict `CrispResult` decoding; do not mutate malformed model output.
- Retry exactly once and only after `CrispResult.ParseError` from the first response.
- Use the same original user prompt for the retry; do not include the malformed response in the retry.
- Do not retry Keychain, cancellation, HTTP, transport, or other non-parse errors.
- Do not log or expose the transcript, generated response, variants, or API key.
- The only outbound endpoint remains `api.anthropic.com` using the user's own API key.
- Do not add a backend, telemetry, analytics, dependencies, or App Sandbox.
- Preserve the stable development launcher and all unrelated working-tree changes.
- Run the full XCTest suite and Debug build, then verify the Formal flow through `./scripts/run-dev.sh`.
- Commit the completed task exactly once with the specified commit message.

## File Structure

- `Sources/CrispVoice/Crisp/CrispPrompt.swift` — owns the normal and repair system-prompt contracts.
- `Sources/CrispVoice/Crisp/CrispEngine.swift` — owns bounded parse-failure retry orchestration and the localized terminal error.
- `Tests/CrispVoiceTests/CrispPromptTests.swift` — verifies strict escaping and repair instructions.
- `Tests/CrispVoiceTests/CrispEngineTests.swift` — verifies one-call success, one retry, retry exhaustion, and non-parse propagation.
- `Tests/CrispVoiceTests/CrispResultTests.swift` — characterizes strict decoding of correctly escaped multiline Formal variants.

---

### Task 1: Recover Once From Invalid Structured Variants

**Files:**
- Modify: `Sources/CrispVoice/Crisp/CrispPrompt.swift`
- Modify: `Sources/CrispVoice/Crisp/CrispEngine.swift`
- Modify: `Tests/CrispVoiceTests/CrispPromptTests.swift`
- Modify: `Tests/CrispVoiceTests/CrispEngineTests.swift`
- Modify: `Tests/CrispVoiceTests/CrispResultTests.swift`

**Interfaces:**
- Preserve: `CrispPrompt.system(variantCount: Int) -> String`
- Add: `CrispPrompt.repairSystem(variantCount: Int) -> String`
- Preserve: `CrispEngine.crisp(transcript: String, tone: Tone) async throws -> CrispResult`
- Add: `CrispEngine.OutputError.invalidStructuredResponse`, conforming to `LocalizedError` and `Equatable`
- Exact localized description: `Anthropic returned invalid message variants twice. Please try again.`

- [ ] **Step 1: Add the strict-decoding characterization test**

Add to `CrispResultTests`:

```swift
func test_parse_acceptsEscapedFormalLineBreaksAndQuotedTerms() throws {
    let json = #"{"variants":["Hello,\n\nPlease use \"pods\" or \"pod pods\".\n\nThank you,"]}"#

    let result = try CrispResult.parse(json)

    XCTAssertEqual(
        result.variants,
        ["Hello,\n\nPlease use \"pods\" or \"pod pods\".\n\nThank you,"]
    )
}
```

- [ ] **Step 2: Run the characterization test**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice \
  -destination 'platform=macOS' \
  -only-testing:CrispVoiceTests/CrispResultTests/test_parse_acceptsEscapedFormalLineBreaksAndQuotedTerms \
  test
```

Expected: PASS. This confirms strict decoding already handles valid escaped Formal content and that the fix belongs at the generation/retry boundary rather than in heuristic parser repair.

- [ ] **Step 3: Write failing prompt-contract tests**

Add to `CrispPromptTests`:

```swift
func test_system_requiresStringVariantsAndEscapedFormatting() {
    let system = CrispPrompt.system(variantCount: 3)

    XCTAssertTrue(system.contains("array of JSON strings"))
    XCTAssertTrue(system.contains(#"\n"#))
    XCTAssertTrue(system.contains(#"\""#))
    XCTAssertTrue(system.contains("not literal line breaks"))
}

func test_repairSystem_preservesBaseContractAndRequestsOneStrictRetry() {
    let base = CrispPrompt.system(variantCount: 3)
    let repair = CrispPrompt.repairSystem(variantCount: 3)

    XCTAssertTrue(repair.hasPrefix(base))
    XCTAssertTrue(repair.contains("previous response could not be parsed"))
    XCTAssertTrue(repair.contains("Try exactly once more"))
    XCTAssertTrue(repair.contains(#"\n"#))
    XCTAssertTrue(repair.contains(#"\""#))
}
```

- [ ] **Step 4: Replace the single-response test stub and add failing retry tests**

In `CrispEngineTests`, retain `PromptCapture` but change it to capture every call:

```swift
private final class PromptCapture {
    var systems: [String] = []
    var users: [String] = []
}

private enum StubError: Error, Equatable {
    case transport
}

private final class SequencedCompleter: TextCompleter {
    private var results: [Result<String, Error>]
    let capture: PromptCapture

    init(results: [Result<String, Error>], capture: PromptCapture = PromptCapture()) {
        self.results = results
        self.capture = capture
    }

    func complete(system: String, user: String) async throws -> String {
        capture.systems.append(system)
        capture.users.append(user)
        guard !results.isEmpty else {
            XCTFail("unexpected completion request")
            throw StubError.transport
        }
        return try results.removeFirst().get()
    }
}
```

Adapt the existing success test to `SequencedCompleter` and assert `capture.systems.count == 1`. Then add:

```swift
func test_crisp_retriesOnceAfterParseFailureAndReturnsSecondResult() async throws {
    let capture = PromptCapture()
    let completer = SequencedCompleter(results: [
        .success("not valid variants JSON"),
        .success(#"{"variants":["Hello,\n\nPlease use \"pods\".\n\nThank you,"]}"#)
    ], capture: capture)
    let engine = CrispEngine(completer: completer, variantCount: 1)

    let result = try await engine.crisp(transcript: "I said pods", tone: .formal)

    XCTAssertEqual(result.variants, ["Hello,\n\nPlease use \"pods\".\n\nThank you,"])
    XCTAssertEqual(capture.systems.count, 2)
    XCTAssertEqual(capture.users.count, 2)
    XCTAssertEqual(capture.users[0], capture.users[1])
    XCTAssertEqual(capture.systems[1], CrispPrompt.repairSystem(variantCount: 1))
}

func test_crisp_stopsAfterSecondParseFailureWithLocalizedError() async {
    let capture = PromptCapture()
    let completer = SequencedCompleter(results: [
        .success("not JSON"),
        .success(#"{"variants":[{"text":"wrong shape"}]}"#)
    ], capture: capture)
    let engine = CrispEngine(completer: completer, variantCount: 1)

    do {
        _ = try await engine.crisp(transcript: "test", tone: .formal)
        XCTFail("expected invalidStructuredResponse")
    } catch let error as CrispEngine.OutputError {
        XCTAssertEqual(error, .invalidStructuredResponse)
        XCTAssertEqual(
            error.localizedDescription,
            "Anthropic returned invalid message variants twice. Please try again."
        )
    } catch {
        XCTFail("unexpected error: \(error)")
    }

    XCTAssertEqual(capture.systems.count, 2)
}

func test_crisp_doesNotRetryNonParseFailure() async {
    let capture = PromptCapture()
    let completer = SequencedCompleter(
        results: [.failure(StubError.transport)],
        capture: capture
    )
    let engine = CrispEngine(completer: completer, variantCount: 1)

    do {
        _ = try await engine.crisp(transcript: "test", tone: .formal)
        XCTFail("expected transport error")
    } catch let error as StubError {
        XCTAssertEqual(error, .transport)
    } catch {
        XCTFail("unexpected error: \(error)")
    }

    XCTAssertEqual(capture.systems.count, 1)
}
```

- [ ] **Step 5: Run the focused tests and confirm RED**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice \
  -destination 'platform=macOS' \
  -only-testing:CrispVoiceTests/CrispPromptTests \
  -only-testing:CrispVoiceTests/CrispEngineTests \
  test
```

Expected: build/test failure because `CrispPrompt.repairSystem` and `CrispEngine.OutputError` do not exist and retry behavior is not implemented. Fix any test syntax/setup errors until the failure is exclusively due to these missing production behaviors.

- [ ] **Step 6: Strengthen the JSON contract and add the repair prompt**

In `CrispPrompt.system`, retain all existing instructions and add immediately after the existing JSON-only sentence:

```swift
Each `variants` item must be a JSON string, never an object. Encode line breaks inside each \
string as \\n and embedded quotation marks as \\"; do not place literal line breaks inside a quoted \
JSON string.
```

Add:

```swift
static func repairSystem(variantCount: Int) -> String {
    system(variantCount: variantCount) + """


    The previous response could not be parsed. Try exactly once more. Return only the required \
    JSON object with an array of JSON strings. Encode line breaks as \\n and embedded quotation \
    marks as \\".
    """
}
```

The resulting runtime prompt must contain the literal two-character sequences `\n` and `\"`; inspect the focused test output if Swift escaping is unclear.

- [ ] **Step 7: Implement the bounded parse-only retry**

In `CrispEngine`, add:

```swift
enum OutputError: LocalizedError, Equatable {
    case invalidStructuredResponse

    var errorDescription: String? {
        "Anthropic returned invalid message variants twice. Please try again."
    }
}
```

Replace `crisp` with:

```swift
func crisp(transcript: String, tone: Tone) async throws -> CrispResult {
    let user = CrispPrompt.user(transcript: transcript, tone: tone)
    let raw = try await completer.complete(
        system: CrispPrompt.system(variantCount: variantCount),
        user: user
    )

    do {
        return try CrispResult.parse(raw)
    } catch is CrispResult.ParseError {
        let retriedRaw = try await completer.complete(
            system: CrispPrompt.repairSystem(variantCount: variantCount),
            user: user
        )
        do {
            return try CrispResult.parse(retriedRaw)
        } catch is CrispResult.ParseError {
            throw OutputError.invalidStructuredResponse
        }
    }
}
```

Do not log either raw response, the transcript, or the variants.

- [ ] **Step 8: Run focused tests and confirm GREEN**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice \
  -destination 'platform=macOS' \
  -only-testing:CrispVoiceTests/CrispResultTests \
  -only-testing:CrispVoiceTests/CrispPromptTests \
  -only-testing:CrispVoiceTests/CrispEngineTests \
  test
```

Expected: all focused tests pass.

- [ ] **Step 9: Run full automated verification**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
git diff --check
```

Expected: all XCTest cases pass with zero failures, `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`, and no whitespace errors.

- [ ] **Step 10: Perform two-stage review**

Stage A checks every requirement in `docs/superpowers/specs/2026-08-06-formal-json-recovery-design.md`: strict parsing, one parse-only retry, same user prompt, no malformed response in the retry, localized terminal error, and unchanged non-parse behavior.

Stage B checks concurrency/state safety, exact retry count, error typing, prompt escaping, test fidelity, no transcript/response/key logging, no backend/telemetry/sandbox changes, and focused scope. Address findings and repeat Steps 8–9.

- [ ] **Step 11: Run live stable-app verification**

Run:

```bash
./scripts/run-dev.sh
```

Use `Control-Option-C` to dictate a synthetic test containing quoted terms such as `pods`, `pod pods`, and `pod pod`. Stop capture, choose Formal, and confirm three Formal variants appear without the raw `CrispResult.ParseError` message. Confirm `/tmp/crispvoice-debug.log` contains only the existing lengths/fingerprints and status metadata, never the transcript, generated variants, malformed response, or API key.

- [ ] **Step 12: Commit the reviewed and live-verified task**

```bash
git add Sources/CrispVoice/Crisp/CrispPrompt.swift \
  Sources/CrispVoice/Crisp/CrispEngine.swift \
  Tests/CrispVoiceTests/CrispPromptTests.swift \
  Tests/CrispVoiceTests/CrispEngineTests.swift \
  Tests/CrispVoiceTests/CrispResultTests.swift
git commit -m "fix: recover from invalid Formal JSON"
```
