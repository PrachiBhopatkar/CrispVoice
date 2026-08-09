# Amazon Bedrock Rewrite Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Amazon Bedrock as an explicitly selected rewrite provider, alongside the existing Anthropic API path, so a signed Finder-launched CrispVoice can use a user's standard AWS profile and Claude Opus 4.8 without asking for or storing AWS credentials.

**Architecture:** Keep `CrispEngine` provider-neutral behind a single `TextCompleter` contract. Anthropic continues to use the user's Keychain API key; Bedrock uses AWS SDK for Swift `AWSBedrockRuntime` `Converse` with an explicitly selected `ProfileAWSCredentialIdentityResolver`. Provider-specific drafts live in `SettingsModel`, persisted configuration lives in `Preferences`, and `AppDelegate` constructs only the active provider. All SDK/provider failures cross into the app as a closed safe error type before UI or `DebugLog` sees them.

**Tech Stack:** Swift 5.9, AppKit + SwiftUI, macOS 13+, XCTest, XcodeGen, `URLSession` for Anthropic, AWS SDK for Swift `1.7.47` products `AWSBedrockRuntime` and `AWSSDKIdentity`, AWS Bedrock Runtime `Converse`, macOS Keychain, existing direct-distribution signing scripts.

## Global Constraints

- Preserve the approved design in `docs/superpowers/specs/2026-08-09-amazon-bedrock-provider-design.md`.
- Do not enable App Sandbox or alter the existing microphone, Speech Recognition, Accessibility, Slack insertion, hotkey, Hardened Runtime, or Audio Input behavior.
- Do not add a developer backend, proxy, telemetry, analytics, AWS CLI subprocess, Claude Code subprocess, login shell, `PATH` mutation, executable discovery, model-listing call, or app-managed SSO flow.
- Audio and transcription stay on device. Only rewrite content goes to the provider explicitly selected by the user.
- Never ask for, store, copy, post in notifications, display, or log AWS credentials, account IDs, user/identity ARNs, credential-process commands/output, raw AWS errors, request/response bodies, transcripts, prompts, or variants. A model or application inference-profile ARN is permitted only as the opaque user-entered `bedrockModelID` draft/persisted setting; do not echo it into application logs, success messages, or error messages.
- Keep the Anthropic API key Keychain-only, with the existing development-only `ANTHROPIC_API_KEY` fallback remaining Anthropic-only.
- Execute tasks strictly in order. Dispatch a fresh implementation subagent for exactly one task, then perform Stage A spec conformance review and Stage B code-quality review before accepting it.
- For each code task, follow red-green-refactor: add the stated failing test, run it and observe the stated failure, implement the minimum change, then run the focused test and the complete XCTest suite.
- A task is not complete until its verification output is observed and it is committed with the task's exact commit message. Preserve unrelated work and the existing untracked `.dev/` directory.
- Live AWS access is forbidden in XCTest. The only live AWS checks are explicit manual acceptance steps on the office laptop.
- Keep AWS/Smithy SwiftLog at its default error threshold and Bedrock `clientLogMode: .none`. CrispVoice must not call `SDKLoggingSystem.initialize` with `.debug`/`.trace`, bootstrap a verbose SwiftLog handler, or set an AWS SDK verbose logging environment in development/release launch scripts; the SDK profile resolver internally emits raw failure descriptions at debug level.

---

## File Structure

Files marked `(new)` are introduced by this plan.

```text
CrispVoice/
├── AGENTS.md
├── project.yml
├── README.md
├── docs/
│   ├── privacy.md                                      (new)
│   ├── troubleshooting.md                              (new)
│   └── superpowers/
│       └── specs/2026-06-12-crispvoice-design.md
├── scripts/
│   └── privacy-smoke-test.sh                           (new)
├── Sources/CrispVoice/
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   └── DebugLog.swift
│   ├── Crisp/
│   │   ├── AnthropicClient.swift
│   │   ├── BedrockSDKCompileProbe.swift               (new in Task 2; deleted in Task 5)
│   │   ├── BedrockClient.swift                        (new)
│   │   ├── BedrockClientFactory.swift                 (new)
│   │   ├── CrispEngine.swift
│   │   ├── RewriteCompleterFactory.swift              (new)
│   │   ├── RewriteProviderError.swift                 (new)
│   │   ├── SafeErrorPresenter.swift                   (new)
│   │   └── TextCompleter.swift                        (new)
│   └── Settings/
│       ├── BedrockConfiguration.swift                  (new)
│       ├── BedrockModelOption.swift                    (new)
│       ├── Preferences.swift
│       ├── RewriteProvider.swift                      (new)
│       ├── SettingsModel.swift                        (new; extracted)
│       └── SettingsView.swift
├── Tests/CrispVoiceTests/
│   ├── AnthropicClientTests.swift
│   ├── AWSCredentialProviderContractTests.swift       (new)
│   ├── BedrockClientTests.swift                       (new)
│   ├── CrispEngineTests.swift
│   ├── PreferencesTests.swift
│   ├── RewriteCompleterFactoryTests.swift             (new)
│   ├── RewriteProviderErrorTests.swift                (new)
│   ├── SettingsModelTests.swift                       (new)
│   └── Fixtures/
│       └── credential-process-fixture.sh              (new)
└── Tests/ReleaseScripts/
    ├── InstallerTests.sh
    └── PrivacyInvariantTests.sh                       (new)
```

Task 11 also creates a non-sensitive verification record at:

```text
docs/superpowers/verification/2026-08-09-amazon-bedrock-provider.md
```

## Shared Interfaces

These names and signatures are authoritative across tasks. Do not introduce a parallel provider abstraction.

```swift
enum RewriteProvider: String, CaseIterable, Identifiable {
    case anthropic
    case bedrock
}

protocol TextCompleter {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

protocol BedrockClientBuilding {
    func make(configuration: BedrockConfiguration) throws -> TextCompleter
}

enum RewriteProviderError: LocalizedError, Equatable {
    case missingConfiguration
    case credentialsUnavailable
    case accessDenied
    case invalidModelOrRegion
    case throttled
    case network
    case invalidResponse

    var diagnosticCode: String { get }
}

struct BedrockConfiguration: Equatable {
    let profileName: String
    let region: String
    let modelID: String

    init(profileName: String, region: String, modelID: String) throws
}
```

The exact persisted keys are `rewriteProvider`, `anthropicModelName`, `bedrockProfileName`, `bedrockRegion`, `bedrockModelID`, and existing `variantCount`. Legacy `modelName` is migration input only.

---

## Task 1: Amend the governing privacy invariant before network code

**Files:**

- Modify: `AGENTS.md`
- Modify: `docs/superpowers/specs/2026-06-12-crispvoice-design.md`
- Create: `Tests/ReleaseScripts/PrivacyInvariantTests.sh`

- [ ] **Step 1: Write the failing invariant check**

Create `Tests/ReleaseScripts/PrivacyInvariantTests.sh` as a strict shell test (`set -euo pipefail`) that checks both governing documents for all of these concepts:

- user-selected Anthropic or Amazon Bedrock rewrite destination;
- AWS authentication traffic may use SSO/OIDC/STS or a configured `credential_process`;
- no developer backend, proxy, telemetry, or content-bearing logging;
- audio and transcription stay local;
- AWS credentials are never stored by CrispVoice.

The test must also fail if `AGENTS.md` still says the only outbound call is unconditionally `api.anthropic.com`.

- [ ] **Step 2: Run the check and confirm it fails**

Run:

```bash
bash Tests/ReleaseScripts/PrivacyInvariantTests.sh
```

Expected: nonzero exit identifying the old Anthropic-only invariant.

- [ ] **Step 3: Update both authoritative documents**

Replace the Anthropic-only network invariant with the selected-provider boundary. State explicitly that:

- Anthropic content goes directly to `api.anthropic.com` with the user's key;
- Bedrock content goes directly to the configured Bedrock Runtime endpoint with the user's AWS identity;
- standard AWS profile authentication may contact AWS identity endpoints or invoke the administrator-configured local credential process;
- credential-process behavior is outside CrispVoice's control and never receives transcript content from CrispVoice;
- no developer-controlled service is introduced.

Do not change the instruction to keep App Sandbox disabled.

- [ ] **Step 4: Run documentation checks**

Run:

```bash
bash Tests/ReleaseScripts/PrivacyInvariantTests.sh
rg -n "api\.anthropic\.com|Bedrock Runtime|credential_process|developer backend|audio.*device|credentials.*never" AGENTS.md docs/superpowers/specs/2026-06-12-crispvoice-design.md
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
git diff --check
```

Expected: shell test exits 0; each invariant is visible in both documents; the complete XCTest suite passes; `git diff --check` is silent.

- [ ] **Step 5: Perform both review stages**

Stage A: compare the language with design sections 8 and 11 and confirm it permits only the two selected content destinations plus non-content AWS authentication. Stage B: confirm no text promises that an external credential process itself has no network/storage behavior.

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md docs/superpowers/specs/2026-06-12-crispvoice-design.md Tests/ReleaseScripts/PrivacyInvariantTests.sh
git commit -m "docs: permit user-selected Bedrock provider"
```

---

## Task 2: Pin AWS SDK 1.7.47 and prove the macOS credential/runtime API compiles

**Files:**

- Modify: `project.yml`
- Create: `Sources/CrispVoice/Crisp/BedrockSDKCompileProbe.swift`
- Create: `Tests/CrispVoiceTests/AWSCredentialProviderContractTests.swift`

- [ ] **Step 1: Add a compile-spike test using an explicit profile**

Add an app-internal compile probe that imports `AWSBedrockRuntime` and `AWSSDKIdentity`, then add a test that invokes the probe. The probe creates:

```swift
let resolver = ProfileAWSCredentialIdentityResolver(
    profileName: "office",
    configFilePath: "/tmp/not-read-by-this-test",
    credentialsFilePath: "/tmp/not-read-by-this-test"
)
let config = try BedrockRuntimeClient.BedrockRuntimeClientConfig(
    awsCredentialIdentityResolver: resolver,
    region: "us-west-2"
)
_ = BedrockRuntimeClient(config: config)
```

The probe returns `Void` after constructing the client. This test is compile-only: it must not call `getIdentity()` or make a network request.

- [ ] **Step 2: Run project generation and confirm dependency symbols fail**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/AWSCredentialProviderContractTests test
```

Expected: compilation fails because the two AWS products are not yet dependencies.

- [ ] **Step 3: Pin the verified package and products**

Add to `project.yml`:

```yaml
packages:
  AWSSDKSwift:
    url: https://github.com/awslabs/aws-sdk-swift.git
    exactVersion: 1.7.47
```

Add these dependencies to both `CrispVoice` and `CrispVoiceTests` so production code and SDK-modeled-error tests import the modules directly:

```yaml
      - package: AWSSDKSwift
        product: AWSBedrockRuntime
      - package: AWSSDKSwift
        product: AWSSDKIdentity
```

Do not add Bedrock control-plane packages or model-listing services.

- [ ] **Step 4: Add the compile probe**

Create `BedrockSDKCompileProbe.swift` with:

```swift
enum BedrockSDKCompileProbe {
    static func constructClient(profileName: String, region: String) throws {
        let resolver = ProfileAWSCredentialIdentityResolver(profileName: profileName)
        let config = try BedrockRuntimeClient.BedrockRuntimeClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region,
            clientLogMode: .none
        )
        _ = BedrockRuntimeClient(config: config)
    }
}
```

The test calls `constructClient(profileName: "office", region: "us-west-2")`. Explicitly provide the selected profile; never rely on `AWS_PROFILE`. Version 1.7.47 uses `BedrockRuntimeClientConfig` and `clientLogMode: .none`; use those non-deprecated APIs exactly.

- [ ] **Step 5: Regenerate and run the spike plus full suite**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/AWSCredentialProviderContractTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
git diff --check
```

Expected: package resolution pins 1.7.47, compile-spike test passes without network access, full suite passes, and build reports `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Review dependency scope and generated linkage**

Stage A: verify only runtime and identity products were added and deployment remains macOS 13. Stage B: inspect the resolved package version, confirm no App Sandbox setting or signing entitlement changed, and confirm the test cannot contact AWS.

Also verify from the pinned SDK source that `clientLogMode: .none` disables request/response logging and that the default SDK log threshold suppresses the profile resolver's debug messages. Record this in a short comment next to factory logging configuration; do not initialize SwiftLog globally in CrispVoice.

- [ ] **Step 7: Commit**

```bash
git add project.yml Sources/CrispVoice/Crisp/BedrockSDKCompileProbe.swift Tests/CrispVoiceTests/AWSCredentialProviderContractTests.swift
git commit -m "build: add AWS Bedrock runtime SDK"
```

---

## Task 3: Add provider preferences, model configuration, and legacy migration

**Files:**

- Create: `Sources/CrispVoice/Settings/RewriteProvider.swift`
- Create: `Sources/CrispVoice/Settings/BedrockConfiguration.swift`
- Create: `Sources/CrispVoice/Settings/BedrockModelOption.swift`
- Create: `Sources/CrispVoice/Crisp/RewriteProviderError.swift`
- Modify: `Sources/CrispVoice/Settings/Preferences.swift`
- Modify: `Tests/CrispVoiceTests/PreferencesTests.swift`
- Create: `Tests/CrispVoiceTests/RewriteProviderErrorTests.swift`

- [ ] **Step 1: Write failing preference and model tests**

Cover each requirement in a separate XCTest:

1. Missing provider defaults to `.anthropic`.
2. Unknown stored provider falls back to `.anthropic` without deleting either provider's data.
3. `anthropicModelName`, Bedrock profile/Region/model, and `variantCount` persist independently.
4. First initialization copies legacy `modelName` to absent `anthropicModelName` and leaves `modelName` untouched.
5. Existing `anthropicModelName` wins over legacy `modelName`.
6. Both model keys absent return the current Anthropic default `claude-haiku-4-5-20251001`.
7. Blank/whitespace Bedrock profile reads as `default`.
8. Absent Bedrock model reads as `us.anthropic.claude-opus-4-8`.
9. The Opus preset resolves exactly to that ID.
10. Custom model normalization trims only leading/trailing whitespace and preserves internal characters exactly.
11. Blank Region or model causes `bedrockConfiguration()` to throw `.missingConfiguration`.

In `RewriteProviderErrorTests`, assert all seven cases expose the exact stable diagnostic codes listed in Task 5, have actionable safe localized messages, and have no associated storage for a raw/source error.

- [ ] **Step 2: Run tests and confirm missing types/properties fail**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/PreferencesTests -only-testing:CrispVoiceTests/RewriteProviderErrorTests test
```

Expected: compilation fails for `RewriteProvider`, Bedrock model/configuration, or the new preference properties.

- [ ] **Step 3: Implement the provider and model types**

`RewriteProvider` has exactly raw cases `anthropic` and `bedrock` and user-facing titles `Anthropic API` and `Amazon Bedrock`.

`BedrockModelOption` exposes:

```swift
enum BedrockModelOption: Equatable {
    static let opus48USModelID = "us.anthropic.claude-opus-4-8"
    case opus48US
    case custom(String)

    var resolvedModelID: String { get }
    static func from(modelID: String) -> BedrockModelOption
}
```

Use only leading/trailing `.whitespacesAndNewlines` normalization. Do not infer Region or rewrite custom identifiers.

Create `BedrockConfiguration` with exactly the three immutable String properties from Shared Interfaces. Its initializer normalizes a blank/whitespace profile to `default`, trims leading/trailing whitespace from Region and model ID, and throws `.missingConfiguration` if Region or model becomes empty. It must not validate identifier punctuation, infer Region, or inspect AWS files.

Create the complete seven-case `RewriteProviderError` from Shared Interfaces now so preference validation and every later layer share one type. Give each case the stable diagnostic code listed in Task 5 and the safe, provider-neutral localized message defined by design section 9. Do not add an associated raw/source error value.

- [ ] **Step 4: Implement exact preferences and one-time copy behavior**

Expose:

```swift
var rewriteProvider: RewriteProvider
var anthropicModelName: String
var bedrockProfileName: String
var bedrockRegion: String
var bedrockModelID: String
var variantCount: Int
func bedrockConfiguration() throws -> BedrockConfiguration
```

Perform the legacy copy in `init` only when `anthropicModelName` is absent. Never delete or rewrite `modelName`. Store a blank displayed profile as `default`. Treat an unknown provider raw value as Anthropic on read without rewriting/deleting stored provider-specific values.

- [ ] **Step 5: Run focused and full verification**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/PreferencesTests -only-testing:CrispVoiceTests/RewriteProviderErrorTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
git diff --check
```

Expected: all preference tests and the complete suite pass.

- [ ] **Step 6: Review migration safety**

Stage A: inspect raw keys and exact default IDs against design sections 5, 6, and 12. Stage B: verify no setter erases the other provider, no environment variable selects Bedrock, and tests isolate `UserDefaults` suites.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrispVoice/Settings/RewriteProvider.swift Sources/CrispVoice/Settings/BedrockConfiguration.swift Sources/CrispVoice/Settings/BedrockModelOption.swift Sources/CrispVoice/Crisp/RewriteProviderError.swift Sources/CrispVoice/Settings/Preferences.swift Tests/CrispVoiceTests/PreferencesTests.swift Tests/CrispVoiceTests/RewriteProviderErrorTests.swift
git commit -m "feat: add rewrite provider preferences"
```

---

## Task 4: Standardize the provider-neutral completion contract

**Files:**

- Create: `Sources/CrispVoice/Crisp/TextCompleter.swift`
- Modify: `Sources/CrispVoice/Crisp/CrispEngine.swift`
- Modify: `Tests/CrispVoiceTests/CrispEngineTests.swift`

- [ ] **Step 1: Change the test double first**

Update `SequencedCompleter` to implement the three-argument contract and capture `maxTokens`. Add assertions that:

- a normal rewrite passes `1024`;
- the repair rewrite also passes `1024`;
- two parse failures produce exactly `Rewrite provider returned invalid message variants twice. Please try again.`

- [ ] **Step 2: Run the focused tests and observe protocol mismatch/failing wording**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/CrispEngineTests test
```

Expected: compile failure until the protocol changes, followed by assertion failures until both calls pass 1024 and the wording is provider-neutral.

- [ ] **Step 3: Extract and standardize `TextCompleter`**

Move the protocol into `TextCompleter.swift` with exactly:

```swift
protocol TextCompleter {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}
```

Remove the two-argument Anthropic extension. `AnthropicClient` already satisfies this exact signature. Pass `maxTokens: 1024` in both `CrispEngine` calls and update `OutputError` without changing retry behavior.

- [ ] **Step 4: Verify focused and full tests**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/CrispEngineTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
git diff --check
```

Expected: focused and complete suites pass; captures are `[1024]` and `[1024, 1024]` for the relevant cases.

- [ ] **Step 5: Review the abstraction**

Stage A: confirm the signature exactly matches the approved design and no provider name remains in `CrispEngine`. Stage B: confirm the retry count and parse-only retry rule did not change.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrispVoice/Crisp/TextCompleter.swift Sources/CrispVoice/Crisp/CrispEngine.swift Tests/CrispVoiceTests/CrispEngineTests.swift
git commit -m "refactor: standardize text completer contract"
```

---

## Task 5: Implement Bedrock Converse behind a safe error boundary

**Files:**

- Modify: `Sources/CrispVoice/Crisp/RewriteProviderError.swift`
- Create: `Sources/CrispVoice/Crisp/SafeErrorPresenter.swift`
- Create: `Sources/CrispVoice/Crisp/BedrockClient.swift`
- Delete: `Sources/CrispVoice/Crisp/BedrockSDKCompileProbe.swift`
- Create: `Sources/CrispVoice/Crisp/BedrockClientFactory.swift`
- Modify: `Tests/CrispVoiceTests/RewriteProviderErrorTests.swift`
- Create: `Tests/CrispVoiceTests/BedrockClientTests.swift`

- [ ] **Step 1: Extend safe-error tests through the application presentation boundary**

The seven cases from Shared Interfaces retain these stable diagnostic codes:

```text
missing_configuration
credentials_unavailable
access_denied
invalid_model_or_region
throttled
network
invalid_response
```

Assert each localized message is actionable but contains none of synthetic secret-shaped strings supplied in source errors. Credential messaging must tell users to refresh their normal AWS/company login and retry; access messaging must point to the AWS administrator; invalid configuration must mention Region and model/inference profile.

Define:

```swift
struct SafeErrorPresentation: Equatable {
    let diagnosticCode: String
    let userMessage: String
}

struct SafeErrorPresenter {
    let writeDiagnostic: (String) -> Void

    func present(_ error: Error) -> SafeErrorPresentation
}
```

For a `RewriteProviderError`, `present` writes only `AppDelegate.fail code=<diagnosticCode>` and returns its safe message. For any other error, it writes only `AppDelegate.fail code=unexpected` and returns a fixed generic message. Inject an in-memory closure and prove fake credentials, ARNs, commands, stderr, prompts, and response bodies never appear in either output.

- [ ] **Step 2: Write failing request/response tests around a narrow SDK seam**

Define in `BedrockClient.swift`:

```swift
protocol BedrockConverseCalling {
    func converse(input: ConverseInput) async throws -> ConverseOutput
}

extension BedrockRuntimeClient: BedrockConverseCalling {}
```

Use a fake conformer to assert `BedrockClient.complete(system:user:maxTokens:)` produces:

- `modelId` equal to the configured opaque identifier;
- `system == [.text(system)]`;
- one `.user` message containing `.text(user)`;
- `inferenceConfig.maxTokens` equal to the caller's value;
- no request metadata, guardrail, tools, or additional fields.

Add response tests for one text block, joined multiple text blocks, empty content, non-message output, and non-text-only output. Add modeled error tests for `AccessDeniedException`, `ValidationException`, `ResourceNotFoundException`, `ThrottlingException`, `ServiceQuotaExceededException`, and a generic transport error containing fake credentials/ARN/prompt.

- [ ] **Step 3: Run focused tests and confirm missing implementation**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/RewriteProviderErrorTests -only-testing:CrispVoiceTests/BedrockClientTests test
```

Expected: compile failure for the new client/error boundary.

- [ ] **Step 4: Implement the closed error enum and mapper**

The raw SDK `Error` must be consumed inside `BedrockClient`/factory. Map known generated types by type, never by embedding `localizedDescription`:

- profile/identity resolution failures → `.credentialsUnavailable`;
- `AccessDeniedException` → `.accessDenied`;
- `ValidationException`, `ResourceNotFoundException`, `ModelNotReadyException` → `.invalidModelOrRegion`;
- `ThrottlingException`, `ServiceQuotaExceededException` → `.throttled`;
- transport/internal failures → `.network`;
- missing/empty output → `.invalidResponse`.

The mapper may classify unknown errors as `.network`, but it must never retain the source error or source text in a user/loggable value.

Implement this as an internal `BedrockErrorMapper.map(_:) -> RewriteProviderError`. It must classify known AWS identity resolver failures by type as `.credentialsUnavailable`; contract tests will call the same mapper directly after isolated resolver failures.

- [ ] **Step 5: Implement `BedrockClient` and finish the factory**

`BedrockClient` stores only `modelID` and `BedrockConverseCalling`. Construct `ConverseInput` using the exact 1.7.47 types. Extract and concatenate only `.text` blocks; trim solely to decide whether the result is empty, returning the original non-empty text.

`BedrockClientFactory.make` must:

1. create `ProfileAWSCredentialIdentityResolver(profileName:)` with the normalized explicit profile;
2. create `BedrockRuntimeClient.BedrockRuntimeClientConfig(awsCredentialIdentityResolver:region:clientLogMode:)` with SDK HTTP/body logging off;
3. create `BedrockRuntimeClient` and inject it into `BedrockClient`;
4. translate construction errors to the closed safe enum.

Do not call `getIdentity()` separately during every rewrite; allow the SDK resolver/client to own refresh.

Declare `BedrockClientFactory: BedrockClientBuilding` with the exact shared signature.

Move the verified client-construction code out of `BedrockSDKCompileProbe.swift` into this factory, then delete the probe. Move its compile-only assertion into the factory/client tests so SDK construction remains covered without a temporary production type.

- [ ] **Step 6: Verify focused tests, full suite, and clean build**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/RewriteProviderErrorTests -only-testing:CrispVoiceTests/BedrockClientTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
if rg -n "SDKLoggingSystem\.initialize|LoggingSystem\.bootstrap|logLevel.*\.(debug|trace)|AWS.*LOG.*(debug|trace)" Sources scripts; then exit 1; fi
git diff --check
```

Expected: all tests pass and build succeeds without a live AWS call.

- [ ] **Step 7: Review request privacy and error exhaustiveness**

Stage A: compare every input field and error category with design sections 4, 8, 9, and 13. Stage B: inspect for `print`, `dump`, interpolation of raw errors, SDK debug modes, verbose `SDKLoggingSystem`/SwiftLog bootstrap, request/response debug descriptions, and unnecessary AWS dependencies.

- [ ] **Step 8: Commit**

```bash
git add Sources/CrispVoice/Crisp/RewriteProviderError.swift Sources/CrispVoice/Crisp/SafeErrorPresenter.swift Sources/CrispVoice/Crisp/BedrockClient.swift Sources/CrispVoice/Crisp/BedrockClientFactory.swift Sources/CrispVoice/Crisp/BedrockSDKCompileProbe.swift Tests/CrispVoiceTests/AWSCredentialProviderContractTests.swift Tests/CrispVoiceTests/RewriteProviderErrorTests.swift Tests/CrispVoiceTests/BedrockClientTests.swift
git commit -m "feat: add native Bedrock Converse client"
```

---

## Task 6: Prove explicit `credential_process` resolution and refresh without a login shell

**Files:**

- Modify: `Tests/CrispVoiceTests/AWSCredentialProviderContractTests.swift`
- Create: `Tests/CrispVoiceTests/Fixtures/credential-process-fixture.sh`
- Modify: `Sources/CrispVoice/Crisp/BedrockClientFactory.swift`

- [ ] **Step 1: Create a deterministic credential-process fixture**

The fixture accepts a mode and a state-file path. In success mode it emits standard process credential JSON with `Version: 1`, synthetic access key, secret, session token, and ISO-8601 expiration. Each invocation increments the state and emits a distinct synthetic access key so refresh is observable. Additional modes must produce:

- nonzero exit;
- malformed JSON;
- secret-shaped stderr.

Use obvious test-only values. Never use a real credential or ARN.

- [ ] **Step 2: Add failing contract tests with private temporary AWS files**

Each test creates a private temporary directory, copies the fixture to an absolute no-space path, marks it executable, and writes an AWS config containing a named profile with `credential_process = <absolute path> ...`. Point `ProfileAWSCredentialIdentityResolver` explicitly to that config and an empty temporary credentials file.

Test:

1. named-profile resolution succeeds with no `AWS_PROFILE` and no login shell;
2. two resolutions after first-expiration/fixture advancement obtain different synthetic credentials;
3. nonzero exit is caught and passed to the production `BedrockErrorMapper.map(_:)`, producing `.credentialsUnavailable` without a live Bedrock call;
4. malformed JSON follows the same mapper path and produces `.credentialsUnavailable`;
5. each safe error is passed to `SafeErrorPresenter` with an injected in-memory `writeDiagnostic` closure; stderr containing fake key/token/command text is absent from the captured application log line and user message.

Capture the actual application-boundary `SafeErrorPresentation` and diagnostic line in memory. Do not redirect or expose SDK credential output through production code.

- [ ] **Step 3: Run contract tests and observe failures**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/AWSCredentialProviderContractTests test
```

Expected: new refresh/failure assertions fail before fixture-aware resolver construction and safe translation are complete.

- [ ] **Step 4: Add testable resolver inputs without changing production defaults**

Allow `BedrockClientFactory` internal/test initialization to accept optional `configFilePath` and `credentialsFilePath`; production initialization passes nil so the SDK uses standard `~/.aws/config` and `~/.aws/credentials`. Always pass `profileName` explicitly. Do not add shell execution code to CrispVoice.

- [ ] **Step 5: Verify contract and complete suite**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/AWSCredentialProviderContractTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
git diff --check
```

Expected: deterministic contract tests and full suite pass without AWS network access.

- [ ] **Step 6: Review the trust boundary**

Stage A: confirm the tests prove the standard SDK profile resolver—not app-authored process execution—and match design sections 5.3 and 13. Stage B: confirm the injected application log contains only the stable code, no command line is logged, paths are absolute, and temporary permissions are private.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrispVoice/Crisp/BedrockClientFactory.swift Tests/CrispVoiceTests/AWSCredentialProviderContractTests.swift Tests/CrispVoiceTests/Fixtures/credential-process-fixture.sh
git commit -m "test: verify AWS profile credential process"
```

---

## Task 7: Implement transactional Settings drafts, Save, and Test Connection

**Files:**

- Create: `Sources/CrispVoice/Settings/SettingsModel.swift`
- Modify: `Sources/CrispVoice/Settings/SettingsView.swift`
- Create: `Tests/CrispVoiceTests/SettingsModelTests.swift`

- [ ] **Step 1: Define an injected connection-testing seam in the model file**

```swift
protocol RewriteConnectionTesting {
    func testAnthropic(apiKey: String, model: String) async throws
    func testBedrock(configuration: BedrockConfiguration) async throws
}
```

Implement the production type with explicit injection:

```swift
struct RewriteConnectionTester: RewriteConnectionTesting {
    let makeAnthropic: (String, String) -> TextCompleter
    let bedrockBuilder: BedrockClientBuilding

    func testAnthropic(apiKey: String, model: String) async throws
    func testBedrock(configuration: BedrockConfiguration) async throws
}
```

Both methods construct the draft-selected low-level completer and call it with system `Reply with OK.`, user `ping`, and `maxTokens: 5`. They accept any response containing non-whitespace text and throw `.invalidResponse` for empty/whitespace output; exact `OK` equality is forbidden.

- [ ] **Step 2: Write failing model tests for draft semantics**

Cover:

- initialization loads both provider drafts and the persisted active provider;
- editing provider/fields/variants does not mutate `UserDefaults` or Keychain;
- close/cancel followed by a new model discards drafts;
- Test Anthropic uses draft key/model and token limit 5 without persisting;
- Test Bedrock normalizes blank profile to `default`, uses draft Region/model, and token limit 5 without persisting;
- any non-empty test response succeeds;
- failed test keeps persisted provider/settings/Keychain unchanged;
- Save rejects missing Anthropic key when activating Anthropic;
- Save rejects blank Bedrock Region/model when activating Bedrock;
- successful Save persists both providers' drafts and `variantCount`, updates Keychain, then activates the selected provider;
- Save is allowed without a prior successful network test;
- notification name is `.crispVoiceRewriteConfigurationDidChange`, object nil, and `userInfo == nil`;
- switching drafts never deletes the other provider's data.

Test `RewriteConnectionTester` directly with a recording `TextCompleter` and fake `BedrockClientBuilding`, independently of `SettingsModel`, so the tests observe the exact system/user/maxTokens tuple, the draft construction inputs, arbitrary non-empty success, and empty-response rejection for both providers.

- [ ] **Step 3: Run the model tests and confirm the old eager-save model fails**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/SettingsModelTests test
```

Expected: missing test target types or failures showing current eager preference writes and credential-bearing notification.

- [ ] **Step 4: Extract and implement `SettingsModel`**

Move model logic out of `SettingsView.swift`. Published draft properties are:

```swift
var selectedProvider: RewriteProvider
var anthropicAPIKey: String
var anthropicModelName: String
var bedrockProfileName: String
var bedrockRegion: String
var bedrockModelOption: BedrockModelOption
var bedrockCustomModelID: String
var variantCount: Int
var validationMessage: String
var isTesting: Bool
```

`save()` performs all local validation before changing storage. It performs the only throwing write—the Anthropic Keychain set/delete—first; after that succeeds, it writes both providers' non-secret drafts and `variantCount` to `UserDefaults`, sets `rewriteProvider` last, and posts the content-free notification. If Keychain throws, no preference or active-provider value changes. `testConnection()` uses drafts and the injected tester only. Translate provider errors to their safe localized messages; use a generic safe message for unknown errors.

- [ ] **Step 5: Verify model and full tests**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/SettingsModelTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
git diff --check
```

Expected: model tests and full suite pass; no notification contains `apiKey` or configuration values.

- [ ] **Step 6: Review transaction behavior**

Stage A: trace Test, Save, failed Save, provider switch, and close-without-Save against design sections 5.2 and 7. Stage B: inspect write ordering and error paths for partial Keychain/preferences mutation; if atomic rollback is needed, test and implement it before acceptance.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrispVoice/Settings/SettingsModel.swift Sources/CrispVoice/Settings/SettingsView.swift Tests/CrispVoiceTests/SettingsModelTests.swift
git commit -m "feat: add transactional provider settings"
```

---

## Task 8: Build the provider-specific Settings interface

**Files:**

- Modify: `Sources/CrispVoice/Settings/SettingsView.swift`
- Modify: `Sources/CrispVoice/Settings/SettingsModel.swift`
- Modify: `Tests/CrispVoiceTests/SettingsModelTests.swift`

- [ ] **Step 1: Add testable UI-state assertions**

Add pure model assertions for:

- preset selection resolves to `us.anthropic.claude-opus-4-8`;
- Custom reveals/uses the custom ID and preserves internal characters;
- the display profile is `Default` while the resolved profile is `default`;
- the cross-Region disclosure flag/text is present for Opus 4.8 and remains a general warning for custom inference profiles;
- the preset success message contains provider, Region, and the Opus display label but no AWS identity;
- a custom model/inference-profile ARN success message says `Custom model` and never echoes the opaque ARN/account component outside its editable Settings field.

- [ ] **Step 2: Run focused tests and observe missing UI-state behavior**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/SettingsModelTests test
```

Expected: failures for the new model-option/disclosure presentation state.

- [ ] **Step 3: Implement the conditional SwiftUI form**

Place a provider picker first. For Anthropic show the secure API-key, Paste, Anthropic model, Save, and Test controls. For Bedrock show:

- AWS Profile field with `Default` presentation;
- required Region field;
- picker entries `Claude Opus 4.8 (US)` and `Custom…`;
- custom ID field only for Custom;
- resolved model ID for the preset;
- text that AWS profile authentication is used and CrispVoice stores no AWS key;
- disclosure that configured Region is the source endpoint and inference profiles may route content to AWS-documented destination Regions;
- Save and Test Connection.

Keep the shared variant Stepper. Remove `.onChange` eager persistence. Disable Test only while testing or when the selected draft is locally incomplete. Save remains the sole persistence action.

- [ ] **Step 4: Build and manually inspect Settings locally**

Run:

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
./scripts/run-dev.sh
```

Expected: tests pass; stable signed dev app launches. Open Settings and observe:

1. switching providers preserves draft entries;
2. Bedrock default form shows Default / Opus 4.8 US / resolved ID;
3. Custom conditionally reveals its field;
4. closing without Save and reopening restores persisted values;
5. Accessibility permission remains associated with the stable dev copy.

- [ ] **Step 5: Review accessibility and copy**

Stage A: compare every visible field/disclosure with design sections 6 and 7. Stage B: inspect layout at default macOS text size, keyboard traversal, progress state, and ensure no field asks for AWS access/secret/session keys, account ID, or user/identity ARN. The Custom model field may accept an AWS-supported model/application inference-profile ARN as opaque configuration.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrispVoice/Settings/SettingsView.swift Sources/CrispVoice/Settings/SettingsModel.swift Tests/CrispVoiceTests/SettingsModelTests.swift
git commit -m "feat: add Bedrock provider settings UI"
```

---

## Task 9: Select the runtime completer and enforce content-free application logging

**Files:**

- Create: `Sources/CrispVoice/Crisp/RewriteCompleterFactory.swift`
- Modify: `Sources/CrispVoice/Crisp/SafeErrorPresenter.swift`
- Modify: `Sources/CrispVoice/App/AppDelegate.swift`
- Modify: `Sources/CrispVoice/Crisp/AnthropicClient.swift`
- Modify: `Sources/CrispVoice/Settings/SettingsModel.swift`
- Modify: `Tests/CrispVoiceTests/AnthropicClientTests.swift`
- Create: `Tests/CrispVoiceTests/RewriteCompleterFactoryTests.swift`
- Modify: `Tests/CrispVoiceTests/RewriteProviderErrorTests.swift`

- [ ] **Step 1: Write provider-construction tests**

Inject Keychain/environment and `BedrockClientBuilding` fakes. Assert:

- Anthropic selection requires the Anthropic key and uses `anthropicModelName`;
- existing `ANTHROPIC_API_KEY` fallback still works only for Anthropic development launches;
- Bedrock selection does not read/require an Anthropic key and passes exact profile/Region/model to the Bedrock builder;
- unknown/missing provider follows Anthropic fallback from `Preferences`;
- neither path mutates preferences.

- [ ] **Step 2: Extend logging-sanitization tests for Anthropic and unknown errors**

Extend `SafeErrorPresenter` tests with fake API keys, AWS credentials, token, identity ARN, credential command, stderr, transcript, and response body. Assert none appear in either output.

Update Anthropic tests so a non-200 raw body may be represented inside `AnthropicClient.ClientError` for immediate Settings handling, but application diagnostic presentation returns only a stable category and never the body. Also test arbitrary unknown errors produce `unexpected` plus a generic user message—not `localizedDescription`.

- [ ] **Step 3: Run focused tests and confirm failures**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/RewriteCompleterFactoryTests -only-testing:CrispVoiceTests/RewriteProviderErrorTests -only-testing:CrispVoiceTests/AnthropicClientTests test
```

Expected: missing factory plus Anthropic/unknown safe-presentation assertions fail.

- [ ] **Step 4: Implement `RewriteCompleterFactory`**

Expose:

```swift
struct RewriteCompleterFactory {
    func make(preferences: Preferences) throws -> TextCompleter
}
```

Use injected closures/stores for tests. Anthropic constructs `AnthropicClient`; Bedrock delegates to `BedrockClientBuilding`. Return `.missingConfiguration` when active provider requirements are absent. Never select a provider from environment variables.

- [ ] **Step 5: Rewire `AppDelegate`**

Replace the hardcoded Anthropic `makeEngine()` branch with the factory, keeping `variantCount`. Ensure configuration-change notification carries no data and only causes future engine construction to use newly persisted settings.

Replace:

```swift
DebugLog.write("AppDelegate.fail error=\(error.localizedDescription)")
```

with the stable diagnostic code from the safe presenter. UI may display only the presenter's safe message. Do not write provider values, profile, Region, model, transcript, or response in the failure log.

- [ ] **Step 6: Make Settings Anthropic failures safe too**

Settings may show safe status-oriented Anthropic errors (HTTP status/category), but not raw server bodies. Test Connection continues to use the draft and `maxTokens: 5`.

- [ ] **Step 7: Verify tests and scan logs/source**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' -only-testing:CrispVoiceTests/RewriteCompleterFactoryTests -only-testing:CrispVoiceTests/RewriteProviderErrorTests -only-testing:CrispVoiceTests/AnthropicClientTests test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
rg -n "DebugLog\.write.*localizedDescription|DebugLog\.write.*(apiKey|profile|region|model|transcript|prompt|response|credential|token|ARN)|userInfo:" Sources/CrispVoice
git diff --check
```

Expected: tests pass; scans return no unsafe application error logging or credential-bearing notification.

- [ ] **Step 8: Review runtime selection and failure boundary**

Stage A: trace both provider branches and every approved safe category. Stage B: verify no retain cycle/new engine caching prevents refreshed AWS credentials, no raw SDK/URLSession error reaches `DebugLog`, and Anthropic users see no behavior regression.

- [ ] **Step 9: Commit**

```bash
git add Sources/CrispVoice/Crisp/RewriteCompleterFactory.swift Sources/CrispVoice/Crisp/SafeErrorPresenter.swift Sources/CrispVoice/App/AppDelegate.swift Sources/CrispVoice/Crisp/AnthropicClient.swift Sources/CrispVoice/Settings/SettingsModel.swift Tests/CrispVoiceTests/AnthropicClientTests.swift Tests/CrispVoiceTests/RewriteCompleterFactoryTests.swift Tests/CrispVoiceTests/RewriteProviderErrorTests.swift
git commit -m "feat: select rewrite provider at runtime"
```

---

## Task 10: Add public setup, privacy, troubleshooting, and destination verification

**Files:**

- Modify: `README.md`
- Create: `docs/privacy.md`
- Create: `docs/troubleshooting.md`
- Create: `scripts/privacy-smoke-test.sh`
- Modify: `Tests/ReleaseScripts/PrivacyInvariantTests.sh`

- [ ] **Step 1: Extend the failing documentation invariant test**

Require README/privacy/troubleshooting coverage for:

- Anthropic setup with Keychain key;
- Bedrock inputs: provider, profile/default, Region, model/inference-profile ID;
- no AWS access-key, secret-key, session-token, account ID, or user/identity ARN input; the sole ARN exception is an AWS-supported model/application inference-profile ARN in the Custom model field;
- Opus 4.8 US preset and exact ID;
- IAM `bedrock:InvokeModel`, model access, inference-profile/destination-Region permissions, and SCP considerations;
- SSO/credential-process session refresh outside CrispVoice;
- absolute credential-process path recommendation for Finder launches;
- cross-Region routing disclosure;
- direct selected-provider destinations, AWS authentication exception, local audio/transcription, no developer backend/telemetry/log content;
- Midway described only as a validated office example, never a public dependency.

- [ ] **Step 2: Run the test and confirm docs are absent**

```bash
bash Tests/ReleaseScripts/PrivacyInvariantTests.sh
```

Expected: nonzero exit for missing README/privacy/troubleshooting content.

- [ ] **Step 3: Write public documentation**

Document the exact user flow and safe recovery for credential/session unavailable, access denied, Region/model mismatch, throttling, custom profiles, and Terminal-works/Finder-fails. State that CrispVoice never starts SSO/Midway or repairs PATH; users/admins must make the standard profile usable by GUI apps.

- [ ] **Step 4: Add a privacy smoke-test script**

Create `scripts/privacy-smoke-test.sh` as an operator-guided macOS script that:

1. identifies the installed CrispVoice PID;
2. samples `lsof -nP -a -p "$pid" -iTCP` during one explicitly initiated rewrite and records only remote destination metadata;
3. prints only destination host/process metadata, never packet bodies;
4. prompts the operator to classify selected-provider content endpoints versus AWS identity endpoints;
5. fails if a CrispVoice/developer-controlled endpoint is observed;
6. scans `/tmp/crispvoice-debug.log` for operator-supplied unique canary strings from a synthetic transcript/response and fails if found.

The script must not need or print AWS credentials and must not claim it can audit the private behavior of the external credential process.

- [ ] **Step 5: Verify documentation and shell syntax**

```bash
bash -n Tests/ReleaseScripts/PrivacyInvariantTests.sh
bash -n scripts/privacy-smoke-test.sh
bash Tests/ReleaseScripts/PrivacyInvariantTests.sh
rg -n "Midway|credential_process|InvokeModel|Opus 4\.8|us\.anthropic\.claude-opus-4-8|cross-Region|developer backend" README.md docs/privacy.md docs/troubleshooting.md
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
git diff --check
```

Expected: syntax/invariant tests and the complete XCTest suite pass; Midway is visibly scoped as an example.

- [ ] **Step 6: Review public accuracy**

Stage A: compare docs with design sections 5.3, 6, 10, 11, and 14. Stage B: confirm instructions never ask users to paste credentials, promise all traffic stays in `us-west-2`, or imply CrispVoice supports a company-internal auth product.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/privacy.md docs/troubleshooting.md scripts/privacy-smoke-test.sh Tests/ReleaseScripts/PrivacyInvariantTests.sh
git commit -m "docs: document Anthropic and Bedrock setup"
```

---

## Task 11: Verify signed distribution and complete office-laptop acceptance

**Files:**

- Modify only if a discovered release regression requires it: `scripts/build-release.sh`
- Modify only if a discovered signing regression requires it: `scripts/check-release-signing.sh`
- Modify: `Tests/ReleaseScripts/InstallerTests.sh`
- Create: `docs/superpowers/verification/2026-08-09-amazon-bedrock-provider.md`

- [ ] **Step 1: Write the failing installer-upgrade preservation assertions**

Make `InstallerTests.sh` accept `CRISPVOICE_INSTALLER_TEST_VERSION` (defaulting to its existing fixture version for backward compatibility) and derive its archive/tag names from that value. Before the simulated upgrade, create sentinel preference data beneath the isolated test root containing all six non-secret preference keys and create a separate synthetic Keychain sentinel file. After successful upgrade, rejected archive, and rollback, byte-compare both sentinels with their originals.

Run against the existing fixture before implementing preservation setup:

```bash
CRISPVOICE_INSTALLER_TEST_VERSION=0.2.0 bash Tests/ReleaseScripts/InstallerTests.sh
```

Expected: new preservation assertions fail until fixture setup and post-operation checks are complete. The test must never read or modify the real user's `~/Library/Preferences` or Keychain.

- [ ] **Step 2: Implement and pass the parameterized installer test**

Keep all operations inside the existing `mktemp` test root. Use synthetic values only. Then run:

```bash
CRISPVOICE_INSTALLER_TEST_VERSION=0.2.0 bash Tests/ReleaseScripts/InstallerTests.sh
```

Expected: `InstallerTests: PASS`, including preference/Keychain sentinel preservation through success and rollback.

- [ ] **Step 3: Run the remaining automated verification from a clean generated project**

```bash
xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -destination 'platform=macOS' test
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Release clean build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Release clean build ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
bash Tests/ReleaseScripts/PrivacyInvariantTests.sh
./scripts/check-release-signing.sh --require-private-key
git diff --check
```

Expected: all XCTest cases green; Debug, clean arm64 Release, and clean x86_64 Release each report `** BUILD SUCCEEDED **`; the privacy script passes; and signing identity is available. If an unexpected failure occurs, invoke `superpowers:systematic-debugging`; do not weaken the test.

- [ ] **Step 4: Build and inspect a universal signed release candidate**

Build a non-publishing signed development release candidate with a fixed verification-only version:

```bash
./scripts/build-release.sh --development 0.3.0
```

This command creates local candidate artifacts and does not tag or publish a public release. Then verify:

- `lipo -archs` reports both `arm64` and `x86_64` for the main executable and required nested native code;
- `codesign --verify --deep --strict --verbose=4` succeeds;
- entitlements retain Hardened Runtime Audio Input and do not add App Sandbox;
- installer identity pinning and upgrade path pass;
- AWS SDK additions did not leave unsigned nested dylibs/frameworks.

Run the parameterized installer suite against that candidate:

```bash
CRISPVOICE_INSTALLER_TEST_VERSION=0.3.0 bash Tests/ReleaseScripts/InstallerTests.sh
```

Expected: the candidate installs and verifies, preference/Keychain sentinels survive upgrade and rollback, and `InstallerTests: PASS`.

- [ ] **Step 5: Run local Anthropic regression acceptance**

Launch only the stable signed development/release copy, not DerivedData. With an existing Keychain key:

1. record only that the 0.2.2 Anthropic Keychain key/model/variant settings are present, without recording their values;
2. upgrade to the 0.3.0 candidate and confirm the key/model/variants remain usable;
3. select Anthropic and Save;
4. Test Connection;
5. dictate a sentence;
6. observe variants and paste into Slack;
7. save Bedrock draft values, switch back to Anthropic, and confirm both providers retain their settings;
8. inspect the debug log for absence of the spoken canary and provider response.

Expected: existing Anthropic behavior works unchanged.

- [ ] **Step 6: Install the release candidate on the office laptop**

Before app testing, refresh the normal company login and confirm in a normal Terminal:

```bash
aws sts get-caller-identity
```

Do not copy its output into the repo or logs. Install/upgrade CrispVoice, then launch it through Finder/LaunchServices—not Terminal.

Before upgrade, note only the presence—not values—of any existing non-secret preferences. After upgrade, confirm those settings remain. The Anthropic Keychain upgrade case is performed on the local machine in Step 5 because the office laptop is not expected to have an Anthropic key. Record only pass/fail in the verification document.

- [ ] **Step 7: Prove the Finder-launched Bedrock happy path**

Configure and Save:

```text
Provider: Amazon Bedrock
AWS profile: Default
AWS Region: us-west-2
Model: Claude Opus 4.8 (US)
Resolved model ID: us.anthropic.claude-opus-4-8
```

With no Anthropic key required:

1. Test Connection and observe success with provider/Region/model only;
2. dictate a sentence;
3. observe a crisp result pasted into Slack;
4. confirm no shell setup or terminal launch was needed.

This is a release blocker. A Terminal-only success does not satisfy it.

- [ ] **Step 8: Prove recovery and safe failure paths**

On the office laptop:

1. expire/invalidate the AWS session and observe the safe refresh-login instruction;
2. refresh externally and retry without editing Settings; expect success;
3. test an unauthorized/invalid model ID; expect safe access/configuration wording;
4. restore Opus 4.8; expect success;
5. inspect `/tmp/crispvoice-debug.log` and confirm it contains only stable diagnostic category identifiers—not credentials, account/ARN, commands, raw errors, prompts, transcripts, or responses.

- [ ] **Step 9: Run the privacy smoke test for both providers**

Execute `scripts/privacy-smoke-test.sh` once with Anthropic and once with Bedrock. Confirm:

- content-bearing traffic reaches only the selected provider endpoint;
- AWS credential-resolution calls contain no transcript content;
- no CrispVoice/developer endpoint is contacted;
- no canary appears in the debug log;
- the Opus 4.8 US cross-Region disclosure matches the administrator-reviewed AWS destination policy.

- [ ] **Step 10: Perform final two-stage review**

Stage A: walk every goal, non-goal, test, manual check, and completion criterion in the approved design; record evidence for each. Stage B: request a fresh code review of the complete diff, fix findings through TDD, and rerun Steps 1–9 as applicable.

- [ ] **Step 11: Record non-sensitive verification evidence**

Create `docs/superpowers/verification/2026-08-09-amazon-bedrock-provider.md`. Record command names, pass/fail results, app version, architecture/signing result, Finder-launch result, Anthropic/Bedrock end-to-end result, safe recovery result, and privacy-smoke result. Do not include user names, home paths, account IDs, ARNs, credentials, raw logs, hostnames for internal identity systems, prompts, transcripts, or responses.

- [ ] **Step 12: Commit release verification**

Commit the verification record and any release-script fixes with:

```bash
git add docs/superpowers/verification/2026-08-09-amazon-bedrock-provider.md scripts/build-release.sh scripts/check-release-signing.sh Tests/ReleaseScripts/InstallerTests.sh
git commit -m "test: verify Bedrock release distribution"
```

The verification record ensures Task 11 always has one substantive commit. Preserve detailed machine/account evidence outside tracked files.

---

## Final Acceptance Checklist

- [ ] Existing and new installations default to Anthropic; legacy model migration is non-destructive.
- [ ] Anthropic and Bedrock configurations remain independently reversible.
- [ ] Bedrock accepts explicit default/named profiles, Region, Opus 4.8 preset, and opaque custom IDs.
- [ ] The app never requests or stores AWS credentials.
- [ ] Normal and repair rewrites use 1024 tokens; provider tests use 5.
- [ ] Test uses drafts; Save is the only activation/persistence action.
- [ ] AWS errors and raw Anthropic bodies cannot reach `DebugLog`.
- [ ] XCTest and credential-process contracts use no live AWS access.
- [ ] Universal signed distribution and installer verification pass without App Sandbox/signing regressions.
- [ ] Finder-launched office-laptop Test Connection and dictate-to-Slack pass through the real default Midway-backed profile.
- [ ] Expired-session recovery succeeds after external login refresh.
- [ ] Privacy smoke tests confirm selected-provider-only content traffic and no developer endpoint.
- [ ] README/privacy/troubleshooting accurately disclose authentication and cross-Region behavior.
