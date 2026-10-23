# CrispVoice Troubleshooting

This page covers setup and connection problems for both rewrite providers, especially Amazon Bedrock's AWS-profile authentication. For what CrispVoice sends and where, see [docs/privacy.md](privacy.md).

A guiding rule for everything below: **CrispVoice never starts an SSO or Midway login on your behalf, and CrispVoice does not repair your PATH or reconfigure your shell.** If a standard AWS profile isn't usable by a GUI app yet, that is something you or your AWS administrator make usable — CrispVoice only resolves the profile you already have configured.

## "Your AWS session is unavailable or expired"

CrispVoice shows this when your selected AWS profile's credentials could not be resolved — commonly because an IAM Identity Center (SSO) session or a `credential_process`-backed session has expired.

**Recovery:** refresh your session using your organization's normal mechanism, then retry in CrispVoice. CrispVoice does not initiate this refresh itself:

- If your profile uses IAM Identity Center, run your organization's normal `aws sso login` step (or equivalent) in Terminal.
- If your profile uses a company `credential_process` (for example, one backed by Midway on the validated office configuration), complete your organization's normal login for that identity system outside CrispVoice, then retry.

Once the session is refreshed, select Test Connection in Settings, or just try dictating again — no CrispVoice settings need to change.

## Access Denied

CrispVoice shows this when your AWS identity authenticated successfully but is not allowed to call the model or inference profile you configured.

**Recovery:** contact your AWS administrator. The role behind your AWS profile likely needs one or more of:

- `bedrock:InvokeModel` permission for the model or inference-profile resource;
- model-access approval for that Claude model in the Amazon Bedrock console;
- IAM permission for the inference profile's underlying models in every destination Region it can route to;
- a Service Control Policy (SCP) that permits calls to those destination Regions.

CrispVoice cannot grant AWS permissions and does not attempt to diagnose which specific permission is missing — the "Access Denied" message only tells you that the identity, not the request shape, was rejected.

## Region or model identifier is wrong

If Settings reports an invalid Region or model, verify:

- the **AWS Region** field matches a Region where your selected model or inference profile is actually available (`us-west-2` for the validated `Claude Opus 4.8 (US)` preset);
- the **model or inference-profile identifier** is exactly correct. The Opus 4.8 preset resolves to `us.anthropic.claude-opus-4-8`. A custom identifier is used exactly as typed (only leading/trailing whitespace is trimmed) — CrispVoice does not correct typos, infer a Region from it, or validate its punctuation.

Test Connection is the source of truth for whether your selected profile, Region, model, account permissions, and SCPs actually work together — use it after changing any of these fields.

## Throttling

If Bedrock throttled the request, CrispVoice reports this and lets you retry later. This is expected under high request volume or a low service quota; retrying after a short pause is usually sufficient. If throttling is frequent, ask your AWS administrator about your account's Bedrock service quota for the model or inference profile you use.

## Using a custom AWS profile

CrispVoice defaults the AWS profile field to `default` when left blank. To use a named profile instead (for example, a profile scoped to a specific AWS account or role):

1. Enter the exact profile name in the **AWS Profile** field in Bedrock Settings.
2. Confirm that profile exists in your AWS configuration and resolves credentials the same way your `default` profile does (shared credentials file, IAM Identity Center, or `credential_process`).
3. Select Test Connection to confirm the named profile, Region, and model work together.

CrispVoice does not list, validate, or modify your AWS profiles — it only asks the AWS SDK to resolve the exact profile name you typed.

## A profile works in Terminal, but not from CrispVoice

This is the most common Bedrock setup problem, and it has a specific cause: **Finder-launched apps don't inherit your interactive login shell's environment**, including `PATH` customizations made in `.zshrc`, `.bash_profile`, Homebrew shims, or company-tool installers. CrispVoice, like any other Finder/LaunchServices-launched app, is affected by this.

If `aws sts get-caller-identity` or a Bedrock `Converse` call succeeds when you run it in Terminal, but CrispVoice reports a credential-process launch failure for the same profile, the AWS profile's `credential_process` command is very likely referring to an executable by name only (relying on `PATH` to find it) rather than by an absolute path.

**Recovery — this is configuration you or your AWS administrator control, not something CrispVoice can fix automatically:**

1. Open your AWS config file (commonly `~/.aws/config`) and find the `credential_process` line for the profile CrispVoice is using.
2. Replace the bare command name with its absolute path. For example, change:
   ```
   credential_process = midway-credential-helper
   ```
   to:
   ```
   credential_process = /usr/local/bin/midway-credential-helper
   ```
   Find the absolute path with `which <command-name>` in Terminal.
3. Save the file and select Test Connection in CrispVoice Settings again.

CrispVoice does not invoke a login shell, extend `PATH`, or search common installation directories on your behalf — an absolute path in the profile is the reliable fix so the same profile works identically whether launched from Terminal or from Finder/LaunchServices.

## Nothing here solved it

- Confirm Settings shows the values you expect: provider, AWS profile, AWS Region, and resolved model ID.
- Confirm your Anthropic API key (if using the Anthropic API) is present and not expired/revoked.
- Review [docs/privacy.md](privacy.md) to confirm which destination and authentication traffic is expected for your selected provider.
- CrispVoice's diagnostic log never contains transcripts, prompts, responses, API keys, or AWS credentials, so it cannot be used to recover leaked content — it can only help confirm which safe error category (missing configuration, credentials unavailable, access denied, invalid model/Region, throttled, network, or invalid response) CrispVoice observed.
