#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CrispVoice.app"
STABLE_DIR="$ROOT_DIR/DevBuild"
STABLE_APP="$STABLE_DIR/$APP_NAME"
SIGNING_IDENTITY="$(
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
    | head -1
)"

cd "$ROOT_DIR"

xcodegen generate
xcodebuild -project CrispVoice.xcodeproj -scheme CrispVoice -configuration Debug build

SOURCE_APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*Debug/$APP_NAME" -type d | head -1)"

if [[ -z "${SOURCE_APP:-}" ]]; then
  echo "Could not locate built $APP_NAME in DerivedData." >&2
  exit 1
fi

mkdir -p "$STABLE_DIR"
if [[ -d "$STABLE_APP" ]]; then
  rsync -a --delete "$SOURCE_APP/" "$STABLE_APP/"
else
  ditto "$SOURCE_APP" "$STABLE_APP"
fi

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$STABLE_APP"
else
  echo "Warning: no Apple Development signing identity found; launching ad-hoc signed app." >&2
fi

killall CrispVoice >/dev/null 2>&1 || true
open "$STABLE_APP"

echo "Launched stable dev build from:"
echo "  $STABLE_APP"
