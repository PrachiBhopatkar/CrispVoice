#!/usr/bin/env bash

cv_die() {
  echo "Error: $*" >&2
  return 1
}

cv_validate_version() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

cv_require_universal_arches() {
  case " $1 " in
    " arm64 x86_64 "|" x86_64 arm64 ") return 0 ;;
    *) return 1 ;;
  esac
}

cv_uppercase() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

cv_plist_string() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

cv_certificate_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print toupper($1)}'
}

cv_require_real_directory_or_absent() {
  local path="${1:-}"

  [[ -n "$path" ]] || {
    cv_die "Release destination path is empty."
    return 1
  }
  [[ ! -L "$path" ]] || {
    cv_die "Release destination must not be a symlink."
    return 1
  }
  [[ ! -e "$path" || -d "$path" ]] \
    || {
      cv_die "Release destination must be a directory."
      return 1
    }
}

cv_require_regular_file_or_absent() {
  local path="${1:-}"

  [[ -n "$path" ]] || {
    cv_die "Release artifact path is empty."
    return 1
  }
  [[ ! -L "$path" ]] || {
    cv_die "Release artifact path must not be a symlink."
    return 1
  }
  [[ ! -e "$path" || -f "$path" ]] \
    || {
      cv_die "Release artifact path must be a regular file."
      return 1
    }
}

cv_move_no_follow() {
  /bin/mv -f -h "$1" "$2"
}

cv_restore_release_artifact_pair() {
  local had_archive="$1"
  local backup_archive="$2"
  local final_archive="$3"
  local had_checksum="$4"
  local backup_checksum="$5"
  local final_checksum="$6"
  local restore_status=0

  if [[ "$had_archive" -eq 1 ]]; then
    cv_move_no_follow "$backup_archive" "$final_archive" || restore_status=1
  else
    /bin/rm -f "$final_archive" || restore_status=1
  fi

  if [[ "$had_checksum" -eq 1 ]]; then
    cv_move_no_follow "$backup_checksum" "$final_checksum" || restore_status=1
  else
    /bin/rm -f "$final_checksum" || restore_status=1
  fi

  if [[ "$restore_status" -ne 0 ]]; then
    cv_die "Failed to restore the prior release artifact pair."
    return 1
  fi
}

cv_package_verify_publish() {
  local app_path="$1"
  local version="$2"
  local app_name="$3"
  local dist_dir="$4"
  local staging_dir="$5"
  local verifier="$6"
  local archive_basename="$app_name-$version-macos-universal.zip"
  local staged_archive="$staging_dir/$archive_basename"
  local staged_checksum="$staged_archive.sha256"
  local extracted_dir="$staging_dir/extracted"
  local final_archive="$dist_dir/$archive_basename"
  local final_checksum="$final_archive.sha256"
  local backup_archive="$staging_dir/previous-$archive_basename"
  local backup_checksum="$backup_archive.sha256"
  local had_archive=0
  local had_checksum=0
  local publication_status=0

  cv_require_real_directory_or_absent "$dist_dir" || return $?
  cv_require_regular_file_or_absent "$final_archive" || return $?
  cv_require_regular_file_or_absent "$final_checksum" || return $?

  /usr/bin/ditto -c -k --keepParent "$app_path" "$staged_archive" \
    || return $?

  (
    cd "$staging_dir" || exit 1
    /usr/bin/shasum -a 256 "$archive_basename" > "$archive_basename.sha256"
  ) || return $?

  /bin/mkdir "$extracted_dir" || return $?
  /usr/bin/ditto -x -k "$staged_archive" "$extracted_dir" || return $?
  "$verifier" "$extracted_dir/$app_name.app" "$version" || return $?

  cv_require_real_directory_or_absent "$dist_dir" || return $?
  if [[ ! -e "$dist_dir" ]]; then
    /bin/mkdir "$dist_dir" || return $?
  fi
  cv_require_real_directory_or_absent "$dist_dir" || return $?
  cv_require_regular_file_or_absent "$final_archive" || return $?
  cv_require_regular_file_or_absent "$final_checksum" || return $?

  if [[ -e "$final_archive" ]]; then
    /bin/cp -p "$final_archive" "$backup_archive" || return $?
    had_archive=1
  fi
  if [[ -e "$final_checksum" ]]; then
    /bin/cp -p "$final_checksum" "$backup_checksum" || return $?
    had_checksum=1
  fi

  cv_move_no_follow "$staged_archive" "$final_archive" \
    || publication_status=$?
  if [[ "$publication_status" -eq 0 ]]; then
    cv_move_no_follow "$staged_checksum" "$final_checksum" \
      || publication_status=$?
  fi

  if [[ "$publication_status" -ne 0 ]]; then
    cv_restore_release_artifact_pair \
      "$had_archive" \
      "$backup_archive" \
      "$final_archive" \
      "$had_checksum" \
      "$backup_checksum" \
      "$final_checksum" \
      || true
    return "$publication_status"
  fi
}
