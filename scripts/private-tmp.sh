#!/usr/bin/env bash

private_tmp_base() {
  local requested_base="$1"
  local resolved_base
  local current_directory
  local current_user_id
  local owner_id
  local mode

  [[ "$requested_base" == /* && -d "$requested_base" && -w "$requested_base" ]] || return 1
  resolved_base="$(cd -- "$requested_base" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved_base" != / ]] || return 1
  current_directory="$resolved_base"
  current_user_id="$(id -u)" || return 1

  while [[ "$current_directory" != / ]]; do
    [[ ! -L "$current_directory" ]] || return 1

    owner_id="$(stat -c '%u' "$current_directory" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$current_directory" 2>/dev/null)" || return 1

    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    if [[ "$current_directory" == "$resolved_base" ]]; then
      [[ "$owner_id" == "$current_user_id" ]] || return 1
      (( (8#$mode & 0077) == 0 )) || return 1
    else
      (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || return 1
    fi

    current_directory="${current_directory%/*}"
    [[ -n "$current_directory" ]] || current_directory=/
  done

  printf '%s\n' "$resolved_base"
}
