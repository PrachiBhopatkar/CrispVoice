#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/release-lib.sh"

TEST_TEMP="$(mktemp -d -t crispvoice-build-release-tests)"
trap '/bin/rm -rf "$TEST_TEMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_release_fixture() {
  local fixture_root="$1"

  /bin/mkdir -p "$fixture_root/scripts" "$fixture_root/release" "$fixture_root/Sources/CrispVoice/App"
  /bin/cp "$ROOT_DIR/scripts/build-release.sh" "$fixture_root/scripts/build-release.sh"
  /bin/cp "$ROOT_DIR/scripts/release-lib.sh" "$fixture_root/scripts/release-lib.sh"
  /bin/cp "$ROOT_DIR/release/config.sh" "$fixture_root/release/config.sh"
  /bin/cp "$ROOT_DIR/release/CrispVoice-Early-Access-Release.cer" \
    "$fixture_root/release/CrispVoice-Early-Access-Release.cer"
  if [[ -f "$ROOT_DIR/Sources/CrispVoice/App/CrispVoice.entitlements" ]]; then
    /bin/cp "$ROOT_DIR/Sources/CrispVoice/App/CrispVoice.entitlements" \
      "$fixture_root/Sources/CrispVoice/App/CrispVoice.entitlements"
  fi
}

test_failing_git_status_stops_production_release() {
  local fixture_root="$TEST_TEMP/failing-git-status"
  local fake_bin="$fixture_root/fake-bin"
  local preflight_marker="$fixture_root/preflight-reached"
  local output
  local status

  make_release_fixture "$fixture_root"
  /bin/mkdir "$fake_bin"

  /bin/echo '#!/usr/bin/env bash' > "$fake_bin/git"
  /bin/echo 'if [[ "${1:-}" == "status" && "${2:-}" == "--porcelain" ]]; then' >> "$fake_bin/git"
  /bin/echo '  exit 73' >> "$fake_bin/git"
  /bin/echo 'fi' >> "$fake_bin/git"
  /bin/echo 'if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--verify" ]]; then' >> "$fake_bin/git"
  /bin/echo '  exit 0' >> "$fake_bin/git"
  /bin/echo 'fi' >> "$fake_bin/git"
  /bin/echo 'if [[ "${1:-}" == "rev-parse" ]]; then' >> "$fake_bin/git"
  /bin/echo '  echo FEEDFACE' >> "$fake_bin/git"
  /bin/echo '  exit 0' >> "$fake_bin/git"
  /bin/echo 'fi' >> "$fake_bin/git"
  /bin/echo 'exit 88' >> "$fake_bin/git"
  /bin/chmod +x "$fake_bin/git"

  /bin/echo '#!/usr/bin/env bash' > "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo ': > "$TEST_PREFLIGHT_MARKER"' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo 'exit 97' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/chmod +x "$fixture_root/scripts/check-release-signing.sh"

  set +e
  output="$(
    PATH="$fake_bin:$PATH" TEST_PREFLIGHT_MARKER="$preflight_marker" \
      /bin/bash "$fixture_root/scripts/build-release.sh" 0.2.0 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "failing git status unexpectedly succeeded"
  [[ "$output" == *"Unable to inspect the worktree."* ]] \
    || fail "failing git status did not report an inspection error: $output"
  [[ ! -e "$preflight_marker" ]] \
    || fail "signing preflight ran after git status failed"
}

test_failing_commit_resolution_stops_production_release() {
  local fixture_root="$TEST_TEMP/failing-commit-resolution"
  local fake_bin="$fixture_root/fake-bin"
  local preflight_marker="$fixture_root/preflight-reached"
  local output
  local status

  make_release_fixture "$fixture_root"
  /bin/mkdir "$fake_bin"

  /bin/echo '#!/usr/bin/env bash' > "$fake_bin/git"
  /bin/echo 'if [[ "${1:-}" == "status" && "${2:-}" == "--porcelain" ]]; then' >> "$fake_bin/git"
  /bin/echo '  exit 0' >> "$fake_bin/git"
  /bin/echo 'fi' >> "$fake_bin/git"
  /bin/echo 'if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--verify" ]]; then' >> "$fake_bin/git"
  /bin/echo '  exit 0' >> "$fake_bin/git"
  /bin/echo 'fi' >> "$fake_bin/git"
  /bin/echo 'if [[ "${1:-}" == "rev-parse" ]]; then' >> "$fake_bin/git"
  /bin/echo '  exit 74' >> "$fake_bin/git"
  /bin/echo 'fi' >> "$fake_bin/git"
  /bin/echo 'exit 88' >> "$fake_bin/git"
  /bin/chmod +x "$fake_bin/git"

  /bin/echo '#!/usr/bin/env bash' > "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo ': > "$TEST_PREFLIGHT_MARKER"' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo 'exit 97' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/chmod +x "$fixture_root/scripts/check-release-signing.sh"

  set +e
  output="$(
    PATH="$fake_bin:$PATH" TEST_PREFLIGHT_MARKER="$preflight_marker" \
      /bin/bash "$fixture_root/scripts/build-release.sh" 0.2.0 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "failing commit resolution unexpectedly succeeded"
  [[ "$output" == *"Unable to resolve HEAD."* ]] \
    || fail "failing commit resolution did not report a resolution error: $output"
  [[ ! -e "$preflight_marker" ]] \
    || fail "signing preflight ran after commit resolution failed"
}

test_symlink_validator_returns_failure_when_status_is_handled() {
  local outside_dir="$TEST_TEMP/validator-outside"
  local symlink_path="$TEST_TEMP/validator-dist"
  local output
  local status

  /bin/mkdir "$outside_dir"
  /bin/ln -s "$outside_dir" "$symlink_path"

  set +e
  output="$(cv_require_real_directory_or_absent "$symlink_path" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] \
    || fail "symlink validator returned success after rejection: $output"
}

test_symlinked_dist_stops_before_preflight() {
  local fixture_root="$TEST_TEMP/symlinked-dist"
  local outside_dir="$TEST_TEMP/outside-dist"
  local protected_archive="$outside_dir/CrispVoice-0.2.0-macos-universal.zip"
  local preflight_marker="$fixture_root/preflight-reached"
  local output
  local status

  make_release_fixture "$fixture_root"
  /bin/mkdir "$outside_dir"
  /bin/echo 'prior-good-artifact' > "$protected_archive"
  /bin/ln -s "$outside_dir" "$fixture_root/dist"

  /bin/echo '#!/usr/bin/env bash' > "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo ': > "$TEST_PREFLIGHT_MARKER"' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo 'exit 97' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/chmod +x "$fixture_root/scripts/check-release-signing.sh"

  set +e
  output="$(
    TEST_PREFLIGHT_MARKER="$preflight_marker" \
      /bin/bash "$fixture_root/scripts/build-release.sh" --development 0.2.0 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "symlinked dist unexpectedly succeeded"
  [[ "$output" == *"Release destination must not be a symlink."* ]] \
    || fail "symlinked dist did not report a destination error: $output"
  [[ ! -e "$preflight_marker" ]] \
    || fail "signing preflight ran with a symlinked dist"
  [[ "$(/bin/cat "$protected_archive")" == 'prior-good-artifact' ]] \
    || fail "symlinked dist changed the protected artifact"
}

test_missing_audio_input_entitlement_stops_before_preflight() {
  local fixture_root="$TEST_TEMP/missing-audio-input-entitlement"
  local preflight_marker="$fixture_root/preflight-reached"
  local output
  local status

  make_release_fixture "$fixture_root"
  /bin/rm -f "$fixture_root/Sources/CrispVoice/App/CrispVoice.entitlements"

  /bin/echo '#!/usr/bin/env bash' > "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo ': > "$TEST_PREFLIGHT_MARKER"' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/echo 'exit 97' >> "$fixture_root/scripts/check-release-signing.sh"
  /bin/chmod +x "$fixture_root/scripts/check-release-signing.sh"

  set +e
  output="$(
    TEST_PREFLIGHT_MARKER="$preflight_marker" \
      /bin/bash "$fixture_root/scripts/build-release.sh" --development 0.2.2 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "missing Audio Input entitlement unexpectedly succeeded"
  [[ "$output" == *"Audio Input entitlement file is missing or invalid."* ]] \
    || fail "missing Audio Input entitlement did not report the expected error: $output"
  [[ ! -e "$preflight_marker" ]] \
    || fail "signing preflight ran after the Audio Input entitlement check failed"
}

test_final_artifact_symlinks_are_rejected_without_outside_mutation() {
  local artifact_kind
  local failures=""

  for artifact_kind in archive checksum; do
    local fixture_root="$TEST_TEMP/final-$artifact_kind-symlink"
    local app_path="$fixture_root/CrispVoice.app"
    local dist_dir="$fixture_root/dist"
    local staging_dir="$fixture_root/private-staging"
    local outside_dir="$fixture_root/outside"
    local verifier="$fixture_root/accept-extracted-app.sh"
    local archive_basename="CrispVoice-0.2.0-macos-universal.zip"
    local archive="$dist_dir/$archive_basename"
    local checksum="$archive.sha256"
    local symlink_path
    local outside_target
    local companion_path
    local status

    /bin/mkdir -p "$app_path/Contents" "$dist_dir" "$staging_dir" "$outside_dir"
    /bin/echo 'candidate-app' > "$app_path/Contents/payload"
    /bin/echo '#!/usr/bin/env bash' > "$verifier"
    /bin/echo 'exit 0' >> "$verifier"
    /bin/chmod +x "$verifier"

    if [[ "$artifact_kind" == "archive" ]]; then
      symlink_path="$archive"
      outside_target="$outside_dir/$archive_basename"
      companion_path="$checksum"
    else
      symlink_path="$checksum"
      outside_target="$outside_dir/$archive_basename.sha256"
      companion_path="$archive"
    fi

    /bin/echo "prior-outside-$artifact_kind" > "$outside_target"
    /bin/ln -s "$outside_dir" "$symlink_path"

    set +e
    cv_package_verify_publish \
      "$app_path" \
      0.2.0 \
      CrispVoice \
      "$dist_dir" \
      "$staging_dir" \
      "$verifier" \
      >/dev/null 2>&1
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      failures="$failures $artifact_kind-symlink returned success;"
    fi
    if [[ "$(/bin/cat "$outside_target")" != "prior-outside-$artifact_kind" ]]; then
      failures="$failures $artifact_kind-symlink changed outside target;"
    fi
    if [[ -e "$companion_path" && ! -L "$companion_path" ]]; then
      failures="$failures $artifact_kind-symlink published companion artifact;"
    fi
  done

  [[ -z "$failures" ]] || fail "final artifact symlink rejection:$failures"
}

test_rejected_packaged_candidate_preserves_published_artifacts() {
  local fixture_root="$TEST_TEMP/rejected-package"
  local app_path="$fixture_root/CrispVoice.app"
  local dist_dir="$fixture_root/dist"
  local staging_dir="$fixture_root/private-staging"
  local verifier="$fixture_root/reject-extracted-app.sh"
  local verifier_marker="$fixture_root/post-package-verifier-reached"
  local archive="$dist_dir/CrispVoice-0.2.0-macos-universal.zip"
  local checksum="$archive.sha256"
  local output
  local status

  /bin/mkdir -p "$app_path/Contents" "$dist_dir" "$staging_dir"
  /bin/echo 'candidate-app' > "$app_path/Contents/payload"
  /bin/echo 'prior-good-archive' > "$archive"
  /bin/echo 'prior-good-checksum' > "$checksum"

  /bin/echo '#!/usr/bin/env bash' > "$verifier"
  /bin/echo '[[ -d "$1" ]] || exit 98' >> "$verifier"
  /bin/echo ': > "$TEST_VERIFIER_MARKER"' >> "$verifier"
  /bin/echo 'exit 42' >> "$verifier"
  /bin/chmod +x "$verifier"

  set +e
  output="$(
    TEST_VERIFIER_MARKER="$verifier_marker" \
      cv_package_verify_publish \
        "$app_path" \
        0.2.0 \
        CrispVoice \
        "$dist_dir" \
        "$staging_dir" \
        "$verifier" \
        2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "rejected packaged candidate unexpectedly succeeded"
  [[ -e "$verifier_marker" ]] \
    || fail "rejected candidate never reached post-package verification: $output"
  [[ "$(/bin/cat "$archive")" == 'prior-good-archive' ]] \
    || fail "rejected candidate overwrote the prior good archive"
  [[ "$(/bin/cat "$checksum")" == 'prior-good-checksum' ]] \
    || fail "rejected candidate overwrote the prior good checksum"
}

test_second_publish_failure_restores_prior_artifact_pair() {
  local fixture_root="$TEST_TEMP/second-publish-failure"
  local app_path="$fixture_root/CrispVoice.app"
  local dist_dir="$fixture_root/dist"
  local staging_dir="$fixture_root/private-staging"
  local verifier="$fixture_root/accept-extracted-app.sh"
  local archive_basename="CrispVoice-0.2.0-macos-universal.zip"
  local archive="$dist_dir/$archive_basename"
  local checksum="$archive.sha256"
  local staged_archive="$staging_dir/$archive_basename"
  local staged_checksum="$staged_archive.sha256"
  local first_publish_marker="$fixture_root/first-publish-completed"
  local status

  /bin/mkdir -p "$app_path/Contents" "$dist_dir" "$staging_dir"
  /bin/echo 'candidate-app' > "$app_path/Contents/payload"
  /bin/echo 'prior-good-archive' > "$archive"
  /bin/echo 'prior-good-checksum' > "$checksum"
  /bin/echo '#!/usr/bin/env bash' > "$verifier"
  /bin/echo 'exit 0' >> "$verifier"
  /bin/chmod +x "$verifier"

  set +e
  (
    cv_move_no_follow() {
      if [[ "$1" == "$staged_archive" && "$2" == "$archive" ]]; then
        /bin/mv -f -h "$1" "$2" || return $?
        : > "$first_publish_marker"
        return 0
      fi
      if [[ "$1" == "$staged_checksum" && "$2" == "$checksum" ]]; then
        [[ -e "$first_publish_marker" ]] || return 96
        return 75
      fi
      /bin/mv -f -h "$1" "$2"
    }

    cv_package_verify_publish \
      "$app_path" \
      0.2.0 \
      CrispVoice \
      "$dist_dir" \
      "$staging_dir" \
      "$verifier"
  ) >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "forced second publish failure unexpectedly succeeded"
  [[ -e "$first_publish_marker" ]] \
    || fail "forced failure occurred before the first publish operation"
  [[ "$(/bin/cat "$archive")" == 'prior-good-archive' ]] \
    || fail "second publish failure did not restore the prior archive"
  [[ "$(/bin/cat "$checksum")" == 'prior-good-checksum' ]] \
    || fail "second publish failure did not restore the prior checksum"
}

test_failing_git_status_stops_production_release
test_failing_commit_resolution_stops_production_release
test_symlink_validator_returns_failure_when_status_is_handled
test_symlinked_dist_stops_before_preflight
test_missing_audio_input_entitlement_stops_before_preflight
test_final_artifact_symlinks_are_rejected_without_outside_mutation
test_rejected_packaged_candidate_preserves_published_artifacts
test_second_publish_failure_restores_prior_artifact_pair

echo "BuildReleaseTests: PASS"
