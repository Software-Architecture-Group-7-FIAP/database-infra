#!/usr/bin/env bash
# Print resource addresses and actions from an existing saved-plan JSON file.
# Attribute values are deliberately excluded from the summary.
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail 'usage: plan-summary.sh <terraform-plan.json>'
fi

plan_json="$1"
[[ -r "$plan_json" ]] || fail 'plan JSON is not readable'
jq_bin="${JQ_BIN:-jq}"
command -v "$jq_bin" >/dev/null 2>&1 || [[ -x "$jq_bin" ]] || fail 'jq is required'

"$jq_bin" -e '(.format_version | type) == "string" and (.resource_changes | type) == "array"' "$plan_json" >/dev/null \
  || fail 'plan JSON has an invalid shape'

# shellcheck disable=SC2016
"$jq_bin" -r '
  # LCOV_EXCL_START
  [.resource_changes[]? | select((.change.actions // ["no-op"]) != ["no-op"])] as $changes
  | "Changes: \($changes | length)",
    "",
    ($changes[] | "- `\(.change.actions | join("/"))` \(.address)")
  # LCOV_EXCL_STOP
' "$plan_json"
