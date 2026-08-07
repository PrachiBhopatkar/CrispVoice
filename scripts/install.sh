#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="PrachiBhopatkar/CrispVoice"
readonly APP_NAME="CrispVoice"
readonly BUNDLE_ID="com.crispvoice.app"
readonly MINIMUM_MACOS="13.0"
readonly SIGNING_IDENTITY_SHA1="533D56B942C39F246C7A9ADB4B796AD9E248B0C0"
readonly SIGNING_CERTIFICATE_SHA256="2AF3C18FE2FF0E482AA51ADE58373F2C3C8C74D35AE345924749B5DD9C608DA0"

temp_dir=""
destination=""
backup=""
install_attempted=0
new_app_attempted=0
had_previous=0
installed=0

die() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  local exit_status=$?
  local rollback_failed=0

  trap - EXIT HUP INT TERM

  if [[ "$installed" -eq 0 && "$install_attempted" -eq 1 ]]; then
    if [[ "$new_app_attempted" -eq 1 && ( -e "$destination" || -L "$destination" ) ]]; then
      /bin/rm -rf "$destination" || rollback_failed=1
    fi

    if [[ "$had_previous" -eq 1 ]]; then
      if [[ -e "$backup" && ! -L "$backup" ]]; then
        if [[ "$new_app_attempted" -eq 0 && ( -e "$destination" || -L "$destination" ) ]]; then
          rollback_failed=1
        else
          /bin/mv -f "$backup" "$destination" || rollback_failed=1
        fi
      elif [[ "$new_app_attempted" -eq 0 && -d "$destination" && ! -L "$destination" ]]; then
        : # The move to backup failed before changing the prior installation.
      else
        rollback_failed=1
      fi
    fi

    if [[ "$rollback_failed" -eq 0 && "$had_previous" -eq 1 ]]; then
      echo "The previous CrispVoice installation was restored." >&2
    elif [[ "$rollback_failed" -eq 0 ]]; then
      echo "The partial CrispVoice installation was removed." >&2
    else
      echo "Error: CrispVoice installation failed and rollback could not be completed." >&2
      exit_status=1
    fi
  fi

  if [[ -n "$temp_dir" && -d "$temp_dir" && ! -L "$temp_dir" ]]; then
    /bin/rm -rf "$temp_dir" || exit_status=1
  fi

  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_version() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

require_exact_universal_architectures() {
  case " $1 " in
    " arm64 x86_64 "|" x86_64 arm64 ") return 0 ;;
    *) return 1 ;;
  esac
}

uppercase() {
  /usr/bin/tr '[:lower:]' '[:upper:]'
}

require_system_tool() {
  [[ -x "$1" ]] || die "Required system tool is unavailable: $1"
}

require_real_directory() {
  local path="$1"

  [[ -e "$path" ]] || die "Installation root does not exist: $path"
  [[ ! -L "$path" ]] || die "Installation root must not be a symlink: $path"
  [[ -d "$path" ]] || die "Installation root must be a directory: $path"
}

verify_extracted_app() {
  local app_path="$1"
  local version="$2"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_id
  local bundle_version
  local bundle_executable
  local minimum_macos
  local executable_path
  local architectures
  local certificate_prefix="$temp_dir/certificate"
  local actual_certificate_sha256

  [[ "$(/usr/bin/basename "$app_path")" == "$APP_NAME.app" ]] \
    || die "The extracted application has an unexpected name."
  [[ -d "$app_path" && ! -L "$app_path" ]] \
    || die "The release archive does not contain a regular $APP_NAME.app bundle."
  [[ -f "$info_plist" && ! -L "$info_plist" ]] \
    || die "The extracted application is missing a regular Contents/Info.plist."

  bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")" \
    || die "Unable to read the extracted application's bundle identifier."
  bundle_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")" \
    || die "Unable to read the extracted application's version."
  bundle_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist")" \
    || die "Unable to read the extracted application's executable name."
  minimum_macos="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info_plist")" \
    || die "Unable to read the extracted application's minimum macOS version."

  [[ "$bundle_id" == "$BUNDLE_ID" ]] || die "The release has an unexpected bundle identifier."
  [[ "$bundle_version" == "$version" ]] || die "The release has an unexpected bundle version."
  [[ "$minimum_macos" == "$MINIMUM_MACOS" ]] || die "The release has an unexpected minimum macOS version."
  [[ -n "$bundle_executable" && "$bundle_executable" != */* && "$bundle_executable" != "." && "$bundle_executable" != ".." ]] \
    || die "The release has an invalid executable name."

  executable_path="$app_path/Contents/MacOS/$bundle_executable"
  [[ -f "$executable_path" && ! -L "$executable_path" ]] \
    || die "The release application executable is missing or invalid."

  architectures="$(/usr/bin/lipo -archs "$executable_path")" \
    || die "Unable to inspect the release application's architectures."
  require_exact_universal_architectures "$architectures" \
    || die "The release executable must contain exactly arm64 and x86_64."

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" \
    || die "The release application failed strict code-signature verification."

  /usr/bin/codesign --display --extract-certificates="$certificate_prefix" "$app_path" \
    || die "Unable to extract the release signing certificate."
  [[ -f "${certificate_prefix}0" && ! -L "${certificate_prefix}0" ]] \
    || die "The release signature has no leaf certificate."

  actual_certificate_sha256="$(/usr/bin/shasum -a 256 "${certificate_prefix}0" \
    | /usr/bin/awk '{print toupper($1)}')" \
    || die "Unable to fingerprint the release signing certificate."
  [[ "$actual_certificate_sha256" == "$SIGNING_CERTIFICATE_SHA256" ]] \
    || die "The release signing certificate fingerprint does not match CrispVoice."

  /usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    -R="certificate leaf = H\"$SIGNING_IDENTITY_SHA1\" and identifier \"$BUNDLE_ID\"" \
    "$app_path" \
    || die "The release does not satisfy the pinned CrispVoice signing requirement."
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || die "CrispVoice requires macOS."

for tool in \
  /usr/bin/curl \
  /usr/bin/ditto \
  /usr/bin/shasum \
  /usr/bin/plutil \
  /usr/bin/lipo \
  /usr/bin/codesign \
  /usr/bin/xattr \
  /usr/bin/open \
  /usr/bin/awk \
  /usr/bin/basename \
  /usr/bin/find \
  /usr/bin/id \
  /usr/bin/killall \
  /usr/bin/mktemp \
  /usr/bin/pgrep \
  /usr/bin/sw_vers \
  /usr/bin/tr; do
  require_system_tool "$tool"
done

host_version="$(/usr/bin/sw_vers -productVersion)" \
  || die "Unable to determine the macOS version."
host_major="${host_version%%.*}"
[[ "$host_major" =~ ^[0-9]+$ ]] || die "Unable to parse the macOS version: $host_version"
(( host_major >= 13 )) || die "CrispVoice requires macOS $MINIMUM_MACOS or later."

test_mode=0
if [[ -n "${CRISPVOICE_INSTALLER_TEST_MODE:-}" ]]; then
  [[ "$CRISPVOICE_INSTALLER_TEST_MODE" == "1" ]] \
    || die "CRISPVOICE_INSTALLER_TEST_MODE must be 1 when set."
  test_mode=1
fi

if [[ "$test_mode" -eq 0 ]]; then
  for test_switch in \
    CRISPVOICE_VERSION_OVERRIDE \
    CRISPVOICE_RELEASE_BASE_URL \
    CRISPVOICE_INSTALL_ROOT \
    CRISPVOICE_ASSUME_YES \
    CRISPVOICE_TEST_LAUNCH_FAILURE; do
    if [[ -n "${!test_switch:-}" ]]; then
      die "$test_switch is available only in installer test mode."
    fi
  done
fi

echo "CrispVoice Early Access is self-signed and is not notarized by Apple."
echo "Continuing requires a scoped Gatekeeper bypass: quarantine will be removed only"
echo "from ~/Applications/CrispVoice.app. No other Gatekeeper settings are changed."

if [[ ! ( "$test_mode" -eq 1 && "${CRISPVOICE_ASSUME_YES:-}" == "1" ) ]]; then
  response=""
  if ! IFS= read -r -p "Continue with the CrispVoice installation? [y/N] " response < /dev/tty; then
    die "Unable to read confirmation from /dev/tty."
  fi
  case "$response" in
    y|Y|yes|YES|Yes) ;;
    *) echo "Installation cancelled."; exit 0 ;;
  esac
fi

if [[ "$test_mode" -eq 1 ]]; then
  version="${CRISPVOICE_VERSION_OVERRIDE:-}"
  release_base_url="${CRISPVOICE_RELEASE_BASE_URL:-}"
  install_root="${CRISPVOICE_INSTALL_ROOT:-}"

  validate_version "$version" \
    || die "CRISPVOICE_VERSION_OVERRIDE must use MAJOR.MINOR.PATCH without leading zeroes."
  [[ -n "$release_base_url" ]] || die "CRISPVOICE_RELEASE_BASE_URL is required in installer test mode."
  [[ -n "$install_root" ]] || die "CRISPVOICE_INSTALL_ROOT is required in installer test mode."
  tag="v$version"
else
  effective_url="$(/usr/bin/curl -fsSIL -o /dev/null -w '%{url_effective}' -L \
    "https://github.com/$REPOSITORY/releases/latest")" \
    || die "Unable to resolve the latest CrispVoice release."
  tag="${effective_url##*/}"
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "GitHub returned an invalid latest release tag: $tag"
  version="${tag#v}"
  release_base_url="https://github.com/$REPOSITORY/releases/download"
  install_root="$HOME"
fi

require_real_directory "$install_root"
install_root="$(cd "$install_root" && pwd -P)" \
  || die "Unable to resolve the installation root."

if [[ "$test_mode" -eq 1 ]]; then
  home_root="$(cd "$HOME" && pwd -P)" || die "Unable to resolve the home directory."
  [[ "$install_root" != "$home_root" ]] \
    || die "Installer test mode refuses to modify the real ~/Applications directory."
fi

applications_dir="$install_root/Applications"
destination="$applications_dir/$APP_NAME.app"

temp_dir="$(/usr/bin/mktemp -d -t crispvoice-installer)" \
  || die "Unable to create a private temporary directory."
[[ -d "$temp_dir" && ! -L "$temp_dir" ]] \
  || die "Unable to create a safe private temporary directory."

archive_basename="$APP_NAME-$version-macos-universal.zip"
archive="$temp_dir/$archive_basename"
checksum="$archive.sha256"
extracted_dir="$temp_dir/extracted"
staged_app="$extracted_dir/$APP_NAME.app"
backup="$temp_dir/Previous-$APP_NAME.app"
download_base="${release_base_url%/}/$tag"

echo "Downloading $APP_NAME $version..."
/usr/bin/curl -fsSL "$download_base/$archive_basename" -o "$archive" \
  || die "Unable to download $archive_basename."
/usr/bin/curl -fsSL "$download_base/$archive_basename.sha256" -o "$checksum" \
  || die "Unable to download $archive_basename.sha256."

checksum_record="$(/usr/bin/awk '
  NF {
    count++
    if (NF != 2) invalid=1
    hash=$1
    filename=$2
  }
  END {
    if (count == 1 && !invalid) {
      printf "%s\t%s", hash, filename
    } else {
      exit 1
    }
  }
' "$checksum")" || die "The release checksum file has an invalid format."

IFS=$'\t' read -r expected_checksum checksum_filename <<< "$checksum_record"
[[ "$checksum_filename" == "$archive_basename" ]] \
  || die "The release checksum names an unexpected file."
[[ "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]] \
  || die "The release checksum is not a SHA-256 value."

expected_checksum="$(printf '%s' "$expected_checksum" | uppercase)"
actual_checksum="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print toupper($1)}')" \
  || die "Unable to calculate the release archive checksum."
[[ "$actual_checksum" == "$expected_checksum" ]] \
  || die "The release archive checksum does not match. The installed app was not changed."

/bin/mkdir "$extracted_dir" || die "Unable to create the extraction directory."
/usr/bin/ditto -x -k "$archive" "$extracted_dir" \
  || die "Unable to extract the release archive."

unexpected_entry="$(/usr/bin/find -P "$extracted_dir" -mindepth 1 -maxdepth 1 \
  ! -name "$APP_NAME.app" -print -quit)" \
  || die "Unable to inspect the extracted release."
[[ -z "$unexpected_entry" ]] || die "The release archive contains an unexpected top-level item."

verify_extracted_app "$staged_app" "$version"

[[ ! -L "$applications_dir" ]] \
  || die "The Applications installation directory must not be a symlink."
if [[ ! -e "$applications_dir" ]]; then
  /bin/mkdir "$applications_dir" || die "Unable to create $applications_dir."
fi
[[ -d "$applications_dir" && ! -L "$applications_dir" ]] \
  || die "The Applications installation path must be a real directory."
[[ ! -L "$destination" ]] || die "The existing CrispVoice installation must not be a symlink."
[[ ! -e "$destination" || -d "$destination" ]] \
  || die "The CrispVoice installation path is not an application directory."

if [[ "$test_mode" -eq 0 ]]; then
  current_uid="$(/usr/bin/id -u)" || die "Unable to determine the current user."
  if /usr/bin/pgrep -x -U "$current_uid" "$APP_NAME" >/dev/null 2>&1; then
    if ! /usr/bin/killall "$APP_NAME"; then
      if /usr/bin/pgrep -x -U "$current_uid" "$APP_NAME" >/dev/null 2>&1; then
        die "Unable to stop the running CrispVoice application."
      else
        pgrep_status=$?
        [[ "$pgrep_status" -eq 1 ]] \
          || die "Unable to determine whether CrispVoice is still running."
      fi
    fi
  else
    pgrep_status=$?
    [[ "$pgrep_status" -eq 1 ]] \
      || die "Unable to determine whether CrispVoice is running."
  fi
fi

if [[ -e "$destination" ]]; then
  had_previous=1
  install_attempted=1
  /bin/mv -f "$destination" "$backup" \
    || die "Unable to preserve the existing CrispVoice installation."
else
  install_attempted=1
fi

new_app_attempted=1
/bin/mv -f "$staged_app" "$destination" \
  || die "Unable to move the verified CrispVoice application into place."

/usr/bin/xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true

if [[ "$test_mode" -eq 1 ]]; then
  if [[ "${CRISPVOICE_TEST_LAUNCH_FAILURE:-}" == "1" ]]; then
    die "Injected CrispVoice launch failure."
  fi
else
  /usr/bin/open "$destination" || die "Unable to launch CrispVoice."
fi

installed=1
if [[ "$had_previous" -eq 1 ]]; then
  /bin/rm -rf "$backup" || die "Unable to remove the previous-version backup."
fi

echo "$APP_NAME $version was installed in $destination."
echo "Grant Microphone, Speech Recognition, and Accessibility permissions when prompted,"
echo "then enter your Anthropic API key in CrispVoice Settings."
echo "If macOS blocks the app, use Open Anyway in System Settings or ask your administrator."
