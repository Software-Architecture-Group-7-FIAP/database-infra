#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/private-tmp.sh
source "$repo_root/scripts/private-tmp.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/private-tmp-contract.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
chmod 700 "$tmp_dir"

private_base="$tmp_dir/private"
mkdir "$private_base"
chmod 700 "$private_base"
resolved_base="$(private_tmp_base "$private_base")"
[[ "$resolved_base" == "$private_base" ]] || { printf 'FAIL: private temp base was not preserved\n' >&2; exit 1; }

chmod 750 "$private_base"
if private_tmp_base "$private_base" >/dev/null; then
  printf 'FAIL: temp base readable by group was accepted\n' >&2
  exit 1
fi

shared_parent="$tmp_dir/shared"
mkdir "$shared_parent"
chmod 777 "$shared_parent"
shared_child="$shared_parent/private"
mkdir "$shared_child"
chmod 700 "$shared_child"
if private_tmp_base "$shared_child" >/dev/null; then
  printf 'FAIL: temp base under a non-sticky shared parent was accepted\n' >&2
  exit 1
fi

printf 'PASS: custom bootstrap temp bases require private ownership and safe parent directories\n'
