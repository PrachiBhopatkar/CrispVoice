# CrispVoice Privacy

CrispVoice has no developer-operated backend. This page describes exactly what leaves your Mac, where it goes, and what CrispVoice never asks for or stores.

## What never leaves your Mac

- Audio never leaves your Mac. It is captured and processed entirely on-device.
- Transcription is local: CrispVoice transcribes your speech on-device using Apple Speech and never uploads audio or partial transcripts to CrispVoice's developer or any third party.
- CrispVoice has no developer backend, proxy, telemetry, analytics, or content-bearing logging. Diagnostic logging on your Mac never contains audio, transcripts, prompts, responses, message variants, your Anthropic API key, AWS credentials, account IDs, ARNs, or raw output from your AWS SDK or credential process.

## The one content-bearing request: your selected rewrite provider

The only content-bearing network request CrispVoice makes is the rewrite request, sent directly from your Mac to the user-selected Anthropic or Amazon Bedrock rewrite destination you chose in Settings. CrispVoice never receives, stores, or proxies this content itself.

- **Anthropic API selected:** the request goes directly to `api.anthropic.com` using the Anthropic API key you stored in macOS Keychain.
- **Amazon Bedrock selected:** the request goes directly to the configured AWS Bedrock Runtime endpoint in your chosen Region, using your AWS identity. CrispVoice signs this request itself; it does not proxy it through a CrispVoice-operated service.

## The AWS authentication exception

Selecting Amazon Bedrock adds one category of non-content network traffic that Anthropic-only use does not have: authenticating your AWS identity.

Resolving your selected AWS profile's credentials may contact AWS SSO/OIDC/STS endpoints, or invoke an administrator-configured local `credential_process` on your Mac. This traffic is initiated only for the explicitly selected standard AWS profile/provider — CrispVoice does not start an unrelated login flow, and it never sends dictated text, transcripts, or rewrite content to the credential process or to AWS's authentication endpoints. Only the rewrite request itself, described above, carries your content.

A configured `credential_process` is trusted user/administrator configuration external to CrispVoice. CrispVoice does not control, and cannot guarantee, that external process's own network destinations, storage, or logging behavior — only that CrispVoice itself never sends it transcript or rewrite content.

### Midway: a validated office example, not a CrispVoice dependency

Some organizations issue AWS credentials through an internal identity system exposed to the AWS CLI as a `credential_process`. A company Midway login is one such example, and it is the validated office example CrispVoice's Bedrock support was tested against. CrispVoice does not implement, bundle, depend on, or require Midway or any other company-internal authentication system, and it never starts an SSO or Midway login on your behalf. If your organization uses Midway, a similar system, or a different `credential_process`, CrispVoice authenticates through whatever standard AWS profile you configure; CrispVoice has no built-in knowledge of Midway or any company-internal identity system beyond the standard `credential_process` interface AWS defines.

## What CrispVoice never asks you to enter

CrispVoice never asks for, accepts, or stores:

- an AWS access key ID;
- an AWS secret access key;
- an AWS session token;
- an AWS account ID;
- a user or identity ARN.

The sole exception is the Custom model field in Bedrock Settings, which accepts an AWS-supported model or application inference-profile ARN — this identifies which Claude model or inference profile to call, not who you are. It is never treated as a credential.

AWS credentials are never stored by CrispVoice. Credential resolution, expiration, and refresh are owned entirely by the AWS SDK and your configured AWS credential provider (a shared credentials file, IAM Identity Center, or `credential_process`). The existing Anthropic API key remains Keychain-only.

## IAM, model access, and Service Control Policy requirements

CrispVoice does not grant AWS access. The AWS identity your selected profile resolves to must already be allowed to invoke the Bedrock model or inference profile you configure:

- Non-streaming `Converse` requests require `bedrock:InvokeModel` for the applicable model or inference-profile resource.
- Your account must have completed any required Anthropic model-access step for that model in Amazon Bedrock.
- An inference profile (including the Opus 4.8 US preset) may require `bedrock:InvokeModel` permission on the profile itself and on its underlying foundation models in every destination Region the profile can route to.
- Organization Service Control Policies (SCPs) must permit calls to those destination Regions, or requests will be denied even when IAM allows them.

If access is denied, contact your AWS administrator; CrispVoice cannot grant or diagnose AWS permissions on your behalf. See [docs/troubleshooting.md](troubleshooting.md) for the recovery flow.

## Cross-Region routing disclosure

The AWS Region you configure in Settings selects the Bedrock *source* endpoint CrispVoice calls — it is not a guarantee about where your content is ultimately processed. The `Claude Opus 4.8 (US)` preset is a geographic cross-Region inference profile: AWS may route prompt and response content to any destination Region documented for that profile, not only the Region you configured. Custom geographic, global, or application inference profiles are subject to their own AWS-defined routing, which you or your administrator should review before selecting them. CrispVoice makes no single-Region guarantee for Bedrock content; the actual destination Regions are whatever AWS defines for the model or inference profile you selected.

## Summary

- Audio never leaves your device, and transcription stays local.
- The only content-bearing traffic is the rewrite request to your selected provider — Anthropic or Amazon Bedrock.
- Amazon Bedrock adds AWS authentication traffic (SSO/OIDC/STS or a configured `credential_process`), which never carries your content.
- CrispVoice never asks for AWS access keys, secret keys, session tokens, account IDs, or identity ARNs, and never stores AWS credentials.
- Cross-Region inference profiles may route content beyond your configured Region; CrispVoice discloses this rather than promising single-Region processing.
- Midway is documented only as the validated office example of a `credential_process`, not as a supported or required CrispVoice authentication product.
