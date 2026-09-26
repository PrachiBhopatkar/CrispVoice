#!/usr/bin/env bash
#
# Operator-guided privacy smoke test for an installed, running CrispVoice.
#
# What this script does:
#   1. Finds the running CrispVoice process.
#   2. Samples its established TCP connections (destination address/port and
#      process metadata only, via `lsof -nP -iTCP`) while you perform one
#      explicitly initiated rewrite.
#   3. Asks you to classify each observed destination as either your
#      selected provider's content endpoint or an AWS identity/authentication
#      endpoint, and fails immediately on anything else.
#   4. Scans /tmp/crispvoice-debug.log for canary strings you choose, to
#      confirm CrispVoice's diagnostic log never captured your content.
#
# What this script deliberately does NOT do:
#   - It never asks for, reads, or prints an AWS access key, secret key,
#     session token, or any other AWS credential.
#   - It never inspects TCP payload/packet bodies — only connection
#     metadata (`lsof` output columns: command, pid, user, fd/type, and the
#     local/remote address pair), which is standard host/port information,
#     not application content.
#   - It does NOT audit or vouch for the private behavior of your
#     organization's external credential_process (its own network calls,
#     storage, or logging). That process is trusted user/administrator
#     configuration outside CrispVoice's control; this script can only
#     confirm which network destinations CrispVoice's own process contacted.
#
# Run this after installing CrispVoice and granting permissions, once with
# Anthropic selected and once with Amazon Bedrock selected.

set -euo pipefail

SAMPLE_SECONDS="${SAMPLE_SECONDS:-15}"
DEBUG_LOG="/tmp/crispvoice-debug.log"
SAMPLE_FILE="$(mktemp -t crispvoice-privacy-smoke)"
trap 'rm -f "$SAMPLE_FILE"' EXIT

fail() {
  echo "" >&2
  echo "PRIVACY SMOKE TEST FAILED: $1" >&2
  exit 1
}

info() {
  echo "$1"
}

prompt() {
  local message="$1"
  local reply
  read -r -p "$message" reply
  printf '%s' "$reply"
}

# --- Step 1: find the installed CrispVoice PID. ---------------------------

info "Looking for a running CrispVoice process..."
pid="$(pgrep -x CrispVoice | head -n1 || true)"
if [[ -z "$pid" ]]; then
  fail "No running CrispVoice process found. Launch the installed app (not a Terminal-run build) and try again."
fi
info "Found CrispVoice at PID $pid."

# --- Step 2: collect canary strings before the sampled rewrite. -----------

info ""
info "This test checks that CrispVoice's diagnostic log ($DEBUG_LOG) never"
info "captures your dictated content or the rewritten result."
info ""
canary_input="$(prompt "Enter one or more unique, made-up canary strings (space-separated, not real content) that you will speak and/or expect to see echoed back during this test: ")"
[[ -n "$canary_input" ]] || fail "No canary strings provided; cannot verify the diagnostic log is content-free."
read -r -a canaries <<< "$canary_input"

# --- Step 3: sample TCP connection metadata during one rewrite. -----------

info ""
info "Next: trigger exactly ONE CrispVoice rewrite (hotkey, dictate a"
info "sentence that includes your canary string, hotkey again to stop)."
info "This script will sample destination connection metadata for"
info "$SAMPLE_SECONDS seconds starting now. Perform the rewrite during that window."
prompt "Press Enter to start sampling, then immediately perform the rewrite... " >/dev/null

: > "$SAMPLE_FILE"
end=$((SECONDS + SAMPLE_SECONDS))
while (( SECONDS < end )); do
  lsof -nP -a -p "$pid" -iTCP 2>/dev/null >> "$SAMPLE_FILE" || true
  sleep 1
done

info ""
info "Sampling complete."

# Extract unique ESTABLISHED destination lines (full lsof line — command,
# pid, user, fd/type, and the local/remote address pair — never packet
# bodies). lsof's NAME column for a TCP socket looks like
# "local_addr:local_port->remote_addr:remote_port (ESTABLISHED)".
#
# `mapfile`/`readarray` are bash 4+ builtins and are NOT available in
# macOS's shipped /bin/bash 3.2, so a plain `while read` loop is used
# instead to stay compatible with the bash CrispVoice users actually run
# this script under.
destinations=()
while IFS= read -r line; do
  destinations+=("$line")
done < <(
  awk '/->/ && /ESTABLISHED/ { print }' "$SAMPLE_FILE" | sort -u
)

if [[ "${#destinations[@]}" -eq 0 ]]; then
  info ""
  info "No established outbound TCP connections were observed from CrispVoice"
  info "during the sample window. If you expected a rewrite to happen, rerun"
  info "this script and perform the rewrite promptly after sampling starts."
  info ""
  info "Continuing to the diagnostic-log canary scan."
else
  info ""
  info "Observed destination(s) contacted by CrispVoice (PID $pid) during the sample window:"
  for dest in "${destinations[@]}"; do
    info "  - $dest"
  done

  # --- Step 4: operator classifies each destination. -----------------------

  info ""
  info "Classify each destination. CrispVoice has no developer-operated"
  info "backend, so only two categories are expected:"
  info "  [1] Your selected provider's content endpoint"
  info "      (e.g. api.anthropic.com, or an AWS Bedrock Runtime endpoint)"
  info "  [2] An AWS identity/authentication endpoint"
  info "      (e.g. AWS SSO/OIDC/STS, reached only when Bedrock is selected)"
  info "Anything else — including a CrispVoice/developer-controlled endpoint,"
  info "or a destination you don't recognize — fails this test."

  for dest in "${destinations[@]}"; do
    choice="$(prompt "Classify $dest [1=provider content, 2=AWS identity, anything else=fail]: ")"
    case "$choice" in
      1)
        info "  -> recorded as selected-provider content endpoint."
        ;;
      2)
        info "  -> recorded as AWS identity/authentication endpoint."
        ;;
      *)
        fail "Destination $dest was not classified as a selected-provider content endpoint or an AWS identity endpoint. This may be a CrispVoice/developer-controlled endpoint, which must never exist."
        ;;
    esac
  done
fi

# --- Step 5: scan the diagnostic log for the canary strings. --------------

info ""
info "Scanning $DEBUG_LOG for your canary string(s)..."
if [[ -f "$DEBUG_LOG" ]]; then
  for canary in "${canaries[@]}"; do
    if grep -F -q -- "$canary" "$DEBUG_LOG"; then
      fail "Canary string \"$canary\" was found in $DEBUG_LOG. The diagnostic log must never contain dictated content or rewritten results."
    fi
  done
  info "No canary strings were found in the diagnostic log."
else
  info "$DEBUG_LOG does not exist yet on this machine; nothing to scan."
fi

info ""
info "PRIVACY SMOKE TEST PASSED."
info "Reminder: this result covers CrispVoice's own observed network"
info "destinations and its own diagnostic log. It does not audit the"
info "private network, storage, or logging behavior of an external AWS"
info "credential_process — that remains trusted user/administrator"
info "configuration outside CrispVoice's control."
