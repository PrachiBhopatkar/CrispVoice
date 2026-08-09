# Amazon Bedrock Rewrite Provider Design

**Date:** 2026-08-09
**Status:** Approved for implementation planning

## 1. Context

CrispVoice v0.2.2 can rewrite dictated text only through Anthropic's direct Messages API. The application requires an Anthropic API key stored in macOS Keychain, constructs an `AnthropicClient` directly in `AppDelegate`, and offers only Anthropic models in Settings.

Some enterprise users receive Claude access through Amazon Bedrock instead of Anthropic. They do not have an Anthropic API key. Their employers authenticate them to AWS through short-lived credentials supplied by IAM Identity Center, a shared AWS profile, or a standard `credential_process` backed by an internal identity system.

The validated office-laptop configuration uses:

- the default AWS profile;
- a company Midway login exposed as the AWS CLI credential type `custom-process`;
- AWS Region `us-west-2`;
- the US Claude Opus 4.8 inference profile `us.anthropic.claude-opus-4-8`.

Both `aws sts get-caller-identity` and a direct Bedrock Runtime `Converse` request to Claude Opus 4.8 succeed in Terminal on that laptop. This validates the AWS identity, Region, model, and IAM combination. It does not yet prove that a signed CrispVoice launched by Finder can resolve the same `credential_process`; that remains a release-blocking implementation test because GUI applications do not inherit a login shell's environment.

## 2. Goals

- Add Amazon Bedrock as a first-class rewrite provider while retaining the existing Anthropic API provider.
- Use the AWS SDK for Swift and Amazon Bedrock Runtime `Converse` API for native, signed Bedrock requests.
- Support default and named AWS profiles backed by temporary credentials, IAM Identity Center, or `credential_process`.
- Let users control the Bedrock Region and exact model or inference-profile identifier.
- Ship a friendly Claude Opus 4.8 preset and a custom identifier option that supports future and company-managed models without an app update.
- Keep all AWS credentials outside CrispVoice storage and let the AWS credential provider refresh them.
- Preserve local audio capture, local transcription, the no-developer-backend architecture, and content-free diagnostic logging.
- Preserve existing Anthropic behavior for current users and upgrades.
- Prove that an ordinarily launched signed app can resolve the validated office profile without shell-specific setup.

## 3. Non-goals

- Implementing, bundling, or reverse-engineering Midway or any other company-internal authentication system.
- Asking users to paste AWS access-key IDs, secret-access keys, session tokens, account IDs, user ARNs, or Bedrock bearer tokens into CrispVoice.
- Launching an AWS or company SSO login flow from CrispVoice.
- Depending on the AWS CLI or Claude Code executable at runtime.
- Invoking `aws bedrock-runtime converse` or `claude -p` as a subprocess.
- Starting a login shell, extending `PATH`, or guessing Homebrew or company-tool locations to make a credential process executable.
- Discovering or listing every model available to an AWS account in the first Bedrock release.
- Adding streaming inference, prompt caching, Bedrock Guardrails, model routing, telemetry, or cost reporting.
- Enabling the App Sandbox.
- Removing Anthropic API support or migrating an existing Anthropic user automatically to Bedrock.

## 4. Chosen Approach

Introduce a native `BedrockClient` that conforms to the `TextCompleter` boundary used by `CrispEngine`. Standardize that boundary as:

```swift
func complete(system: String, user: String, maxTokens: Int) async throws -> String
```

`CrispEngine` passes `maxTokens: 1024` for normal and repair requests. Anthropic preserves its current 1024-token behavior through the same interface. Provider Test Connection calls the selected low-level client with `maxTokens: 5`. `CrispEngine.OutputError` becomes provider-neutral and says that the rewrite provider returned invalid message variants rather than naming Anthropic.

`BedrockClient` uses `AWSBedrockRuntime` from the AWS SDK for Swift and sends the system prompt, user prompt, and token limit through Bedrock Runtime `Converse`.

Provider selection happens when `AppDelegate` constructs the `CrispEngine`:

```text
Preferences.rewriteProvider
        |
        +--> anthropic --> Anthropic key from Keychain --> AnthropicClient
        |
        `--> bedrock   --> AWS profile/Region/model   --> BedrockClient
                                                              |
                                                              `--> AWS credential resolver
                                                                   --> profile / SSO / credential_process
```

The native SDK approach is preferred because it owns SigV4 signing, temporary session tokens, credential refresh, response decoding, and AWS service error semantics. An AWS CLI subprocess was rejected because it would require an external executable and stable command output. A Claude Code subprocess was rejected because it is a much larger, independently updated dependency with behavior beyond CrispVoice's single rewrite request.

## 5. Provider and Configuration Model

### 5.1 Provider selection

Add a persisted provider value with exactly two cases:

- `anthropic`
- `bedrock`

Existing installations and new installations continue to default to `anthropic`. Selecting Bedrock is always an explicit user action.

### 5.2 Provider-specific settings

Anthropic and Bedrock use separate preference keys so switching providers does not overwrite the other provider's configuration.

The exact `UserDefaults` keys are:

- `rewriteProvider`;
- `anthropicModelName`;
- `bedrockProfileName`;
- `bedrockRegion`;
- `bedrockModelID`;
- the existing `variantCount`.

The current Anthropic model key is `modelName`. On the first `Preferences` initialization after upgrade, if `anthropicModelName` is absent, CrispVoice copies the existing `modelName` value into `anthropicModelName`. It does not delete or rewrite `modelName`. If both keys are absent, it uses the existing Anthropic default. A missing, unknown, or corrupt `rewriteProvider` value resolves safely to `anthropic` without deleting either provider's settings.

Anthropic retains:

- API key in macOS Keychain;
- Anthropic model identifier in `UserDefaults`.

Bedrock adds these non-secret `UserDefaults` values:

- AWS profile name;
- AWS Region;
- Bedrock model or inference-profile identifier.

An empty displayed profile is normalized to the AWS profile name `default`. The Region and model identifier are required before Bedrock can be tested, saved as active, or used for a rewrite.

Settings edits are drafts until Save is selected. Test Connection uses the current drafts but neither persists them nor changes the active runtime provider. Save performs local syntax validation, persists both providers' current drafts, and makes the selected provider active; a successful network test is recommended but is not required so users can configure CrispVoice while offline. Closing Settings without Save discards drafts. A failed Test Connection leaves persisted settings and the active provider unchanged. Provider notifications carry only the fact that persisted configuration changed, never credential or content values.

### 5.3 Credential resolution

The Bedrock client explicitly resolves the selected shared AWS profile through the AWS SDK for Swift. This is required because a Finder-launched macOS app must not depend on shell-only environment variables such as `AWS_PROFILE`.

The selected profile may resolve credentials through profile features supported by the SDK, including:

- a shared credentials file;
- IAM Identity Center after `aws sso login`;
- a standard `credential_process`.

CrispVoice application code never copies, persists, prints, posts in notifications, or logs resolved AWS credential values. The AWS SDK and the configured provider own credential handling, expiration, and refresh.

AWS permits a `credential_process` command to name an executable through either an absolute path or `PATH`. A profile intended for CrispVoice must be independently executable from a normal LaunchServices/Finder environment and must not rely on aliases, shell functions, login-shell initialization, or a shell-only `PATH`. An absolute executable path in the AWS profile is preferred. CrispVoice does not invoke a login shell, edit `PATH`, or search common installation directories. If the same profile works in Terminal but not from CrispVoice, Settings reports a credential-process launch failure and directs the user or administrator to make the configured process GUI-executable.

The first implementation does not initiate authentication. If a session is absent or expired, the user refreshes it using the organization's normal mechanism and retries. For the validated office setup, that mechanism remains the normal Midway login outside CrispVoice.

## 6. Model Selection

The Bedrock Settings model control contains:

1. `Claude Opus 4.8 (US)` mapped to `us.anthropic.claude-opus-4-8`.
2. `Custom…`, which reveals an editable identifier field.

The Opus 4.8 preset is the initial Bedrock selection for a user who has not saved a Bedrock model. The user can change it before activating Bedrock.

The custom value accepts any non-empty Bedrock Runtime `modelId` supported by `Converse`, including:

- a base model ID;
- a geographic or global inference-profile ID;
- an application inference-profile ID or ARN;
- another AWS-supported Claude model identifier.

CrispVoice trims only leading and trailing whitespace from a custom identifier. It otherwise treats the identifier as opaque configuration, does not collapse or rewrite internal characters or prefixes, and does not infer a Region from it. The Test Connection action is the authority for whether the selected profile, Region, model, account permissions, Service Control Policies, and model access work together.

The Opus 4.8 US preset is a geographic cross-Region inference profile. `us-west-2` is the source endpoint in the validated configuration, but AWS may route prompt and response content to any destination Region documented for that profile. Settings displays this disclosure for the preset. Custom geographic, global, or application inference profiles remain subject to their AWS-defined routing, which the user or administrator must review.

The first implementation intentionally does not call `ListFoundationModels` or `ListInferenceProfiles`. Many enterprise roles allow invocation but not listing, and a Custom option provides forward compatibility without expanding IAM requirements.

## 7. Settings Experience

The Settings window adds a provider picker above provider-specific fields.

When `Anthropic API` is selected, Settings retains the current secure API-key field, Paste, Save, Test, and Anthropic model controls.

When `Amazon Bedrock` is selected, Settings shows:

- AWS profile, defaulting visually to `Default`;
- AWS Region;
- model preset picker;
- custom model identifier only when `Custom…` is selected;
- Save;
- Test Connection;
- a short explanation that authentication is managed by the user's AWS profile and no AWS key is stored by CrispVoice;
- a disclosure that inference-profile identifiers may route content beyond the configured source Region according to AWS's profile definition.

For the validated office configuration, the completed form is:

```text
Provider: Amazon Bedrock
AWS profile: Default
AWS Region: us-west-2
Model: Claude Opus 4.8 (US)
Resolved model ID: us.anthropic.claude-opus-4-8
```

Switching to Bedrock does not delete the stored Anthropic key. Switching back to Anthropic does not delete Bedrock configuration. This makes provider changes reversible and avoids unnecessary credential re-entry.

Test Connection sends a minimal request that asks the selected model to reply with `OK`. Any successful `Converse` response containing non-empty text counts as success; exact string equality is not required. A successful response reports the provider, Region, and model without displaying AWS identity information. Testing never logs the prompt or response body.

## 8. Runtime Data Flow

For Anthropic:

```text
microphone --> local Apple Speech transcript --> CrispEngine prompt
    --> api.anthropic.com using the user's Keychain API key
    --> parsed variants --> local UI / Slack paste
```

For Bedrock:

```text
microphone --> local Apple Speech transcript --> CrispEngine prompt
    --> BedrockClient
        --> selected AWS profile
        --> SSO or credential_process supplies temporary credentials
        --> SigV4-signed Converse request to bedrock-runtime.<source-region>.amazonaws.com
        --> inference profile may route content to AWS-documented destination Regions
    --> parsed variants --> local UI / Slack paste
```

`CrispEngine`, prompt construction, strict variant parsing, one controlled parse retry, inline editing, and Slack insertion remain provider-independent.

## 9. Error Handling

All AWS SDK, Bedrock, SSO, and credential-provider failures are translated inside the Bedrock configuration/client boundary into a closed, app-owned safe error enum before they reach `AppDelegate` or Settings. `AppDelegate` logs only the stable error category identifier. It never logs `error.localizedDescription` for an untrusted SDK or credential-provider error.

The safe user-facing categories are:

- **Missing configuration:** Ask the user to choose a Region and model in Settings.
- **Credential process or SSO failure:** Explain that the AWS session is unavailable or expired and instruct the user to refresh the normal company AWS login, then retry.
- **Access denied:** Explain that the selected AWS role lacks permission for the model or inference profile and recommend contacting the AWS administrator.
- **Invalid model or Region:** Ask the user to verify the Bedrock Region and model/inference-profile identifier.
- **Throttling or quota:** Explain that Bedrock throttled the request and allow a later retry.
- **Network failure:** Report a generic connection failure without embedding the raw SDK or operating-system error description.
- **Unexpected or empty response:** Report an invalid Bedrock response through the same completer boundary used by Anthropic.

Credential process command lines, process stdout/stderr, raw SDK errors, account IDs, ARNs, access-key fragments, session tokens, HTTP headers, request bodies, transcripts, generated variants, and AWS response bodies must never be written to `DebugLog` or shown verbatim to the user. AWS SDK HTTP/body tracing and credential-provider debug logging remain disabled in production and development launches.

## 10. IAM and Administrator Requirements

CrispVoice does not grant AWS access. The user's selected AWS identity must already be allowed to invoke the chosen Bedrock model or inference profile.

At minimum, non-streaming `Converse` requires `bedrock:InvokeModel` for the applicable resources. Inference profiles and cross-Region inference may also require permissions for the profile and its underlying foundation models in all destination Regions. Organization Service Control Policies must permit those destinations. The AWS account must have completed any required Anthropic model-access or first-use steps.

The initial implementation does not require `bedrock:InvokeModelWithResponseStream`, `bedrock:ListFoundationModels`, or `bedrock:ListInferenceProfiles` because it neither streams nor discovers models.

## 11. Security and Privacy Invariants

- App Sandbox remains disabled.
- Audio remains on device and is never sent to Anthropic, AWS, or a developer service.
- Transcription remains local through Apple Speech.
- The only content-bearing runtime request is the rewrite selected by the user.
- With Anthropic selected, that request goes directly to `api.anthropic.com` using the user's key.
- With Bedrock selected, that request goes directly to the configured AWS Bedrock Runtime endpoint using the user's AWS identity.
- The configured Region selects the Bedrock source endpoint. Geographic, global, and application inference profiles may route prompt and response content to other AWS Regions defined by the selected profile.
- Credential resolution may use AWS SSO/OIDC/STS endpoints or invoke the user's configured local `credential_process`. This non-content authentication traffic must be initiated only by the explicitly selected standard AWS profile/provider.
- A configured external credential process is trusted user/administrator configuration. CrispVoice neither controls nor guarantees that process's own network destinations, storage, or logging behavior; CrispVoice never sends transcript or rewrite content to it.
- CrispVoice has no developer backend, proxy, telemetry, analytics, or developer-controlled credential service.
- AWS credentials are never stored by CrispVoice. The existing Anthropic API key remains Keychain-only.
- No logging contains audio, transcripts, prompts, responses, message variants, API keys, AWS credentials, or raw credential-provider output.

This design deliberately evolves the earlier Anthropic-only network invariant. The first implementation-plan task must update `AGENTS.md` and the original product design before any Bedrock network code is added. Before implementation is accepted, README privacy statements and privacy smoke tests must also describe the selected-provider boundary accurately: direct Anthropic traffic for Anthropic users or direct AWS Bedrock and necessary AWS authentication traffic for Bedrock users.

## 12. Migration and Compatibility

- Existing users remain on the Anthropic provider after upgrading.
- Existing Keychain entries remain valid, and the legacy `modelName` value is copied once to `anthropicModelName` without deleting the legacy value.
- Missing or unknown provider values fall back to Anthropic without deleting settings.
- No TCC, Microphone, Speech Recognition, Accessibility, Slack, or hotkey settings change.
- No automatic provider migration occurs based on environment variables or the presence of AWS files.
- Development fallback through `ANTHROPIC_API_KEY` remains Anthropic-only and does not select Bedrock implicitly.
- Release signing, Hardened Runtime, Audio Input entitlement, universal architecture, installer identity pinning, and non-notarized early-access distribution remain unchanged.

## 13. Testing Strategy

Implementation follows test-driven development and keeps live AWS calls out of the unit suite.

### Unit tests

- Provider preference defaults existing and new users to Anthropic.
- Anthropic and Bedrock settings persist independently.
- Blank Bedrock profile normalizes to `default`.
- Missing Region or model prevents Bedrock activation with a specific message.
- Opus 4.8 preset resolves exactly to `us.anthropic.claude-opus-4-8`.
- Custom identifiers pass through unchanged after whitespace normalization.
- `BedrockClient` maps system text, user text, and `maxTokens` into the expected `Converse` input.
- Bedrock response text is extracted correctly.
- Credential, access, model, throttling, network, and malformed-response errors map to safe user-facing messages.
- Provider selection constructs the correct `TextCompleter` without requiring an Anthropic key for Bedrock.
- Existing Anthropic request, parsing, Keychain, and Settings tests remain green.
- Raw Anthropic HTTP error bodies cannot reach `DebugLog`, preserving the strengthened provider-neutral logging invariant.
- Normal and repair rewrites pass `maxTokens: 1024`; Test Connection passes `maxTokens: 5`.
- `CrispEngine.OutputError` is provider-neutral.
- Legacy `modelName` migration, unknown provider fallback, unsaved cancellation, failed Test Connection, and provider switching preserve the specified active and draft state.
- Synthetic SDK/process errors containing fake credentials, tokens, commands, stderr, prompts, ARNs, and response bodies never appear in user messages or `DebugLog`.

AWS SDK calls sit behind a narrow protocol so unit tests use deterministic fakes rather than live credentials or Bedrock.

### Credential-provider contract tests

- Use a private temporary AWS config and an absolute-path fixture `credential_process` that emits synthetic expiring credentials in the standard AWS JSON format.
- Verify that the explicitly selected profile resolves the fixture credentials without a login shell.
- Verify refresh after expiration and safe handling of nonzero exit, malformed JSON, and stderr containing secret-shaped test data.
- Run these tests without live AWS access and assert that fixture credential values never reach application logs or user-facing errors.

### Shell and build tests

- XcodeGen resolves the pinned AWS SDK for Swift dependency.
- Before broad UI work, a compile/credential-resolver spike pins a verified `https://github.com/awslabs/aws-sdk-swift` version and records the exact `AWSBedrockRuntime`, `AWSSDKIdentity`, and any required identity-service products for macOS 13.
- The complete XCTest suite passes.
- Clean Intel and Apple Silicon builds and a clean universal Release build succeed.
- Release signing, nested-runtime signing, and entitlement verification continue to pass with the additional dependency.
- Installer upgrade preserves both providers' preferences and the Anthropic Keychain entry.

### Manual verification

1. Validate Anthropic API rewriting with an existing Keychain key.
2. On the office laptop, refresh Midway and confirm `aws sts get-caller-identity` succeeds.
3. Select Bedrock, Default profile, `us-west-2`, and Claude Opus 4.8.
4. Install and launch the signed CrispVoice app through Finder/LaunchServices, not Terminal, and confirm Test Connection resolves the actual office `credential_process` without an Anthropic key or shell setup.
5. Dictate a sentence and confirm a crisp result is pasted into Slack.
6. Expire or invalidate the AWS session and confirm CrispVoice gives a safe refresh-session instruction.
7. Restore the AWS session and confirm retry succeeds without editing settings.
8. Enter an unauthorized model identifier and confirm the error distinguishes access/configuration failure without logging content.
9. Repeat the privacy smoke test and confirm content-bearing traffic goes only to the selected provider endpoint, credential-resolution calls contain no transcript content, and no CrispVoice/developer endpoint is contacted.
10. Confirm the settings/README disclosure matches the destination Regions permitted by the selected Opus 4.8 US inference profile.

## 14. Documentation Requirements

The implementation updates:

- Settings and onboarding copy for provider selection;
- README prerequisites and configuration instructions for both providers;
- privacy documentation and network-destination statements;
- troubleshooting for IAM Identity Center, `credential_process`, expired sessions, access denied, Region mismatch, and custom inference profiles;
- troubleshooting for profiles that work in Terminal but whose credential executable cannot be resolved from a Finder-launched app;
- cross-Region routing disclosure for geographic, global, and application inference profiles;
- `AGENTS.md` hard invariants so they prohibit developer backends and content-bearing traffic anywhere except the user-selected Anthropic or AWS Bedrock provider.

Documentation must describe Midway only as the validated office example, not as a public CrispVoice dependency or supported authentication product.

## 15. Completion Criteria

The feature is complete only when:

- the approved implementation plan is executed one task at a time through TDD and two-stage review;
- both Anthropic and Bedrock provider paths pass the complete unit suite;
- a universal signed release candidate passes the existing release and installer verification;
- the installed, signed office-laptop app launched through Finder completes Opus 4.8 Test Connection and the full dictate-to-Slack loop through the default Midway-backed `credential_process` without shell setup;
- an expired AWS session produces actionable recovery and succeeds after external refresh;
- model selection supports the Opus 4.8 preset and an arbitrary custom Bedrock identifier;
- no AWS credential is requested, stored, logged, or included in a notification;
- privacy documentation and the privacy smoke test reflect the user-selected provider boundary;
- no developer backend, proxy, App Sandbox, telemetry, or content-bearing logging is introduced.

## 16. Authoritative References

- [Amazon Bedrock Converse](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)
- [Amazon Bedrock Runtime examples for AWS SDK for Swift](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/swift_bedrock-runtime_code_examples.html)
- [AWS SDK for Swift credential providers](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/credential-providers.html)
- [AWS `credential_process`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html)
- [IAM Identity Center credential provider](https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html)
- [Claude Opus 4.8 on Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-8.html)
- [Bedrock model-inference prerequisites](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-prereq.html)
- [Geographic cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html)
