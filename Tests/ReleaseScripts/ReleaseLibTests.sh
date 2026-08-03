#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/release-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_success() { "$@" >/dev/null 2>&1 || fail "expected success: $*"; }
expect_failure() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

expect_success cv_validate_version "0.2.0"
expect_success cv_validate_version "12.34.56"
expect_failure cv_validate_version "v0.2.0"
expect_failure cv_validate_version "0.2"
expect_failure cv_validate_version "01.2.3"
expect_success cv_require_universal_arches "arm64 x86_64"
expect_success cv_require_universal_arches "x86_64 arm64"
expect_failure cv_require_universal_arches "arm64"
expect_failure cv_require_universal_arches "arm64 x86_64 i386"
[[ "$(cv_uppercase abcdef0123)" == "ABCDEF0123" ]] || fail "uppercase"

echo "ReleaseLibTests: PASS"
