#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/release/config.sh"
source "$ROOT_DIR/scripts/release-lib.sh"

development=0
if [[ "${1:-}" == "--development" ]]; then
  development=1
  shift
fi

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 [--development] VERSION" >&2
  exit 1
fi

VERSION="$1"
cv_validate_version "$VERSION" || cv_die "Version must use MAJOR.MINOR.PATCH without leading zeroes."

cd "$ROOT_DIR"

if [[ "$development" -eq 0 ]]; then
  worktree_status="$(git status --porcelain)" \
    || cv_die "Unable to inspect the worktree."
  [[ -z "$worktree_status" ]] || cv_die "Production releases require a clean worktree."

  release_tag="v$VERSION"
  git rev-parse --verify --quiet "refs/tags/$release_tag^{commit}" >/dev/null \
    || cv_die "Production releases require tag $release_tag."
  head_commit="$(git rev-parse HEAD)" || cv_die "Unable to resolve HEAD."
  [[ -n "$head_commit" ]] || cv_die "Unable to resolve HEAD."
  tag_commit="$(git rev-parse "refs/tags/$release_tag^{commit}")" \
    || cv_die "Unable to resolve tag $release_tag."
  [[ -n "$tag_commit" ]] || cv_die "Unable to resolve tag $release_tag."
  [[ "$head_commit" == "$tag_commit" ]] \
    || cv_die "Tag $release_tag must resolve to HEAD."
fi

DIST_DIR="$ROOT_DIR/dist"
cv_require_real_directory_or_absent "$DIST_DIR"
ENTITLEMENTS_PATH="$ROOT_DIR/Sources/CrispVoice/App/CrispVoice.entitlements"
[[ -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" ]] \
  || cv_die "Audio Input entitlement file is missing or invalid."

"$ROOT_DIR/scripts/check-release-signing.sh" --require-private-key

BUILD_NUMBER="$(git rev-list --count HEAD)"
ARCHIVE_PATH="$DIST_DIR/$CRISPVOICE_APP_NAME-$VERSION-macos-universal.zip"
temporary_dir="$(mktemp -d -t crispvoice-release-build)"
trap '/bin/rm -rf "$temporary_dir"' EXIT
BUILD_DIR="$temporary_dir/DerivedData"

xcodegen generate
xcodebuild \
  -project CrispVoice.xcodeproj \
  -scheme CrispVoice \
  -destination 'platform=macOS' \
  test

xcodebuild \
  -project CrispVoice.xcodeproj \
  -scheme CrispVoice \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

APP_PATH="$BUILD_DIR/Build/Products/Release/$CRISPVOICE_APP_NAME.app"
[[ -d "$APP_PATH" ]] || cv_die "Release build did not produce $CRISPVOICE_APP_NAME.app."

nested_candidates="$temporary_dir/nested-code.txt"
: > "$nested_candidates"

for relative_root in Frameworks PlugIns XPCServices Helpers; do
  search_root="$APP_PATH/Contents/$relative_root"
  [[ -d "$search_root" ]] || continue

  /usr/bin/find -P "$search_root" \
    \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.bundle' -o -name '*.framework' -o -name '*.plugin' -o -name '*.xpc' \) -o -type f \) \
    -print \
    | while IFS= read -r candidate; do
        if [[ -d "$candidate" ]]; then
          printf '%s\n' "$candidate"
        elif [[ ! -L "$candidate" ]] && /usr/bin/file -b "$candidate" | /usr/bin/grep -q '^Mach-O'; then
          printf '%s\n' "$candidate"
        fi
      done
done \
  | /usr/bin/awk '{ print length($0) "\t" $0 }' \
  | /usr/bin/sort -rn \
  | /usr/bin/cut -f2- \
  > "$nested_candidates"

while IFS= read -r candidate; do
  [[ -n "$candidate" && -e "$candidate" ]] || continue
  /usr/bin/codesign \
    --force \
    --sign "$CRISPVOICE_SIGNING_IDENTITY_SHA1" \
    --options runtime \
    --timestamp=none \
    "$candidate"
done < "$nested_candidates"

cv_sign_release_app \
  /usr/bin/codesign \
  "$CRISPVOICE_SIGNING_IDENTITY_SHA1" \
  "$ENTITLEMENTS_PATH" \
  "=designated => certificate leaf = H\"$CRISPVOICE_SIGNING_IDENTITY_SHA1\" and identifier \"$CRISPVOICE_BUNDLE_ID\"" \
  "$APP_PATH"

"$ROOT_DIR/scripts/verify-release-app.sh" "$APP_PATH" "$VERSION"

cv_package_verify_publish \
  "$APP_PATH" \
  "$VERSION" \
  "$CRISPVOICE_APP_NAME" \
  "$DIST_DIR" \
  "$temporary_dir" \
  "$ROOT_DIR/scripts/verify-release-app.sh"

echo "Release archive created at $ARCHIVE_PATH."
