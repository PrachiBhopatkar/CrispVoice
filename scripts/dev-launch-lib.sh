#!/usr/bin/env bash

cv_dev_die() {
  echo "Error: $*" >&2
  return 1
}

cv_dev_parse_apple_identity_lines() {
  /usr/bin/sed -n \
    's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F][0-9A-F]*\) "\(Apple Development:[^"]*\)".*$/\1\	\2/p' \
    | /usr/bin/awk -F '\t' 'length($1) == 40 && $1 ~ /^[0-9A-F]+$/ && $2 ~ /^Apple Development:/'
}

cv_dev_require_single_identity() {
  local security_output="$1"
  local parsed
  local count

  parsed="$(printf '%s\n' "$security_output" | cv_dev_parse_apple_identity_lines)" || return 1
  count="$(printf '%s\n' "$parsed" | /usr/bin/awk 'NF { count++ } END { print count+0 }')"
  [[ "$count" == "1" ]] || {
    echo "Expected exactly one valid Apple Development signing identity; found $count." >&2
    return 1
  }
  printf '%s\n' "$parsed"
}

cv_dev_require_stable_signing_text() {
  local signing_text="$1"

  if printf '%s\n' "$signing_text" | /usr/bin/grep -Fq 'Signature=adhoc'; then return 1; fi
  if ! printf '%s\n' "$signing_text" | /usr/bin/grep -Eq '^TeamIdentifier=.+$'; then return 1; fi
  if printf '%s\n' "$signing_text" | /usr/bin/grep -Fq 'TeamIdentifier=not set'; then return 1; fi
  if ! printf '%s\n' "$signing_text" | /usr/bin/grep -Eq '^designated => .+'; then return 1; fi
  if printf '%s\n' "$signing_text" | /usr/bin/grep -Fq 'cdhash '; then return 1; fi
  return 0
}

cv_dev_require_bundle() {
  local app_path="$1"
  local expected_bundle_id="$2"
  local plutil_bin="$3"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_id
  local executable_name
  local executable_path

  [[ -d "$app_path" && ! -L "$app_path" ]] || cv_dev_die "Expected a real app directory: $app_path" || return 1
  [[ -f "$info_plist" && ! -L "$info_plist" ]] || cv_dev_die "Missing regular Info.plist: $info_plist" || return 1
  bundle_id="$("$plutil_bin" -extract CFBundleIdentifier raw -o - "$info_plist")" \
    || cv_dev_die "Could not read bundle identifier from $info_plist" || return 1
  [[ "$bundle_id" == "$expected_bundle_id" ]] \
    || cv_dev_die "Unexpected bundle identifier: $bundle_id" || return 1
  executable_name="$("$plutil_bin" -extract CFBundleExecutable raw -o - "$info_plist")" \
    || cv_dev_die "Could not read executable name from $info_plist" || return 1
  [[ -n "$executable_name" && "$executable_name" != "." && "$executable_name" != ".." && "$executable_name" != *"/"* ]] \
    || cv_dev_die "Unsafe executable name: $executable_name" || return 1
  executable_path="$app_path/Contents/MacOS/$executable_name"
  [[ -f "$executable_path" && ! -L "$executable_path" ]] \
    || cv_dev_die "Missing regular executable: $executable_path" || return 1
  printf '%s\n' "$executable_path"
}

cv_dev_require_signing() {
  local app_path="$1"
  local expected_sha1="$2"
  local codesign_bin="$3"
  local shasum_bin="$4"
  local signing_text
  local temporary_dir
  local certificate_sha1
  local status=0

  [[ "$expected_sha1" =~ ^[0-9A-F]{40}$ ]] \
    || cv_dev_die "Invalid selected signing fingerprint" || return 1
  "$codesign_bin" --verify --deep --strict "$app_path" \
    || cv_dev_die "Code signature verification failed: $app_path" || return 1
  signing_text="$("$codesign_bin" --display --verbose=4 --requirements - "$app_path" 2>&1)" \
    || cv_dev_die "Could not inspect code signature: $app_path" || return 1
  cv_dev_require_stable_signing_text "$signing_text" \
    || cv_dev_die "Code signature is not certificate-backed and stable: $app_path" || return 1
  temporary_dir="$(/usr/bin/mktemp -d -t crispvoice-dev-signing)" \
    || cv_dev_die "Could not create certificate inspection directory" || return 1
  "$codesign_bin" --display --extract-certificates="$temporary_dir/cert" "$app_path" >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 0 && ! -f "$temporary_dir/cert0" ]]; then
    status=1
  fi
  if [[ "$status" -eq 0 ]]; then
    certificate_sha1="$("$shasum_bin" -a 1 "$temporary_dir/cert0" | /usr/bin/awk '{ print toupper($1) }')" || status=$?
  fi
  if [[ "$status" -eq 0 && "$certificate_sha1" != "$expected_sha1" ]]; then
    status=1
  fi
  /bin/rm -rf "$temporary_dir"
  [[ "$status" -eq 0 ]] \
    || cv_dev_die "Signing certificate fingerprint did not match selected Apple Development identity" || return 1
}

cv_dev_physical_path() {
  local path="$1"
  local directory
  local basename

  [[ -e "$path" || -d "$path" ]] || return 1
  directory="$(/usr/bin/dirname "$path")"
  basename="$(/usr/bin/basename "$path")"
  (
    cd -P "$directory" || exit 1
    printf '%s/%s\n' "$(/bin/pwd -P)" "$basename"
  )
}

cv_dev_require_launched_path() {
  local expected_executable="$1"
  local actual_command="$2"
  local expected_physical
  local actual_physical

  [[ "$actual_command" == "$expected_executable" ]] \
    || cv_dev_die "Launched process command differs from expected executable" || return 1
  expected_physical="$(cv_dev_physical_path "$expected_executable")" \
    || cv_dev_die "Expected executable does not exist: $expected_executable" || return 1
  actual_physical="$(cv_dev_physical_path "$actual_command")" \
    || cv_dev_die "Launched executable does not exist: $actual_command" || return 1
  [[ "$actual_physical" == "$expected_physical" ]] \
    || cv_dev_die "Launched process path differs from stable executable" || return 1
}
