#!/bin/sh
#
# Deterministic, synthetic `credential_process` fixture used ONLY by
# CredentialProviderContractTests (vendor/BedrockSDKBridge). It is copied
# into a private temporary directory by each test and referenced from a
# throwaway AWS config file via an absolute, no-space path -- it must
# never be pointed at from `~/.aws/config` or invoked outside those tests.
#
# All values emitted below are obviously synthetic test data. This script
# never handles, forwards, or fabricates a real AWS credential or ARN.
#
# Usage: credential-process-fixture.sh <mode> <state-file>
#   mode:
#     success        - emit standard `Version: 1` process-credential JSON.
#                       Each invocation increments the counter kept in
#                       <state-file> and embeds it in a distinct synthetic
#                       AccessKeyId/SecretAccessKey/SessionToken, so two
#                       calls are observably different (proves refresh).
#                       The first invocation's Expiration is already in
#                       the past (simulates an expired credential that
#                       forces the next call to re-invoke this process);
#                       later invocations expire comfortably in the future.
#     nonzero        - exit non-zero, emitting nothing usable on stdout.
#     malformed      - exit 0 but emit invalid/truncated JSON.
#     leak-then-fail - exit non-zero while writing fake secret-shaped
#                       text (a key, a session token, and this fixture's
#                       own invocation command) to stderr, to prove that
#                       content can never reach a mapped error.

mode="$1"
state_file="$2"

if [ -z "$mode" ] || [ -z "$state_file" ]; then
    echo "credential-process-fixture: usage: $0 <mode> <state-file>" >&2
    exit 64
fi

count=0
if [ -f "$state_file" ]; then
    count=$(cat "$state_file")
fi
count=$((count + 1))
echo "$count" > "$state_file"

case "$mode" in
    success)
        if [ "$count" -eq 1 ]; then
            expiration=$(date -u -v-30S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-30 seconds" +"%Y-%m-%dT%H:%M:%SZ")
        else
            expiration=$(date -u -v+900S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+900 seconds" +"%Y-%m-%dT%H:%M:%SZ")
        fi
        suffix=$(printf '%04d' "$count")
        cat <<EOF
{
  "Version": 1,
  "AccessKeyId": "ASIAFIXTURETEST$suffix",
  "SecretAccessKey": "fixture-secret-access-key-$suffix",
  "SessionToken": "fixture-session-token-$suffix",
  "Expiration": "$expiration"
}
EOF
        exit 0
        ;;
    nonzero)
        echo "credential-process-fixture: synthetic nonzero-exit failure (test-only, not a real credential)" >&2
        exit 7
        ;;
    malformed)
        printf '{ "Version": 1, "AccessKeyId": "fixture-truncated-response"'
        exit 0
        ;;
    leak-then-fail)
        cat >&2 <<EOF
FAKE_ACCESS_KEY_ID=AKIAFAKEFIXTURELEAK0
FAKE_SESSION_TOKEN=fake-fixture-session-token-that-must-never-surface
FAKE_COMMAND=$0 leak-then-fail $state_file
EOF
        exit 9
        ;;
    *)
        echo "credential-process-fixture: unknown mode '$mode'" >&2
        exit 64
        ;;
esac
