#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == --run-suite ]]; then
  bash "$repo_root/tests/root-contract.sh"
  bash "$repo_root/tests/plan-guard.sh"
  bash "$repo_root/tests/script-contracts.sh"
  bash "$repo_root/tests/sql-permissions.sh"
  bash "$repo_root/tests/workflow-contract.sh"
  exit 0
fi

kcov_bin="${KCOV_BIN:-kcov}"
jq_bin="${JQ_BIN:-jq}"
command -v "$kcov_bin" >/dev/null 2>&1 || [[ -x "$kcov_bin" ]] || fail 'kcov is required to measure executable shell coverage'
command -v "$jq_bin" >/dev/null 2>&1 || [[ -x "$jq_bin" ]] || fail 'jq is required to report executable shell coverage'

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/database-shell-coverage.XXXXXX")"
chmod 700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

branch_report="$tmp_dir/critical-branches.txt"
coverage_output="$tmp_dir/coverage"
export SHELL_COVERAGE_BRANCH_REPORT="$branch_report"

if ! "$kcov_bin" --include-path="$repo_root/scripts" "$coverage_output" \
  "$repo_root/tests/shell-coverage.sh" --run-suite > "$tmp_dir/run.log" 2>&1; then
  cat "$tmp_dir/run.log" >&2
  fail 'shell regression suite failed under kcov'
fi

merged_output="$tmp_dir/merged"
if ! "$kcov_bin" --merge "$merged_output" "$coverage_output" > "$tmp_dir/merge.log" 2>&1; then
  cat "$tmp_dir/merge.log" >&2
  fail 'kcov could not merge the executable shell coverage report'
fi

coverage_json="$(find "$merged_output" -type f -name coverage.json -print -quit)"
[[ -n "$coverage_json" && -r "$coverage_json" ]] || fail 'kcov did not produce a merged coverage.json report'
coverage_percent="$("$jq_bin" -er '.percent_covered' "$coverage_json")" || fail 'kcov coverage.json has no percent_covered metric'
[[ "$coverage_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'kcov reported an invalid coverage percentage'
awk -v percentage="$coverage_percent" 'BEGIN { exit !(percentage >= 80) }' \
  || fail "executable shell line coverage ${coverage_percent}% is below the required 80%"

critical_branches=(
  plan_guard_replacement_unknown_and_redaction
  bootstrap_runtime_preflight_fails_closed
  smoke_full_runtime_job_preflight
  smoke_partial_metadata_failure
  secret_absent_metadata
  secret_pending_then_absent
  secret_pending_timeout_closed
  secret_query_error_closed
  fake_aws_forbids_secret_and_broad_ssm_reads
  workflow_apply_authorization_contract
)

for branch in "${critical_branches[@]}"; do
  grep -Fxq "$branch" "$branch_report" || fail "critical authorization/sanitization branch was not exercised: $branch"
done

critical_total="${#critical_branches[@]}"
printf 'Executable shell line coverage: %s%% (target >=80%%)\n' "$coverage_percent"
printf 'Critical authorization/sanitization branches: %s/%s (100%%)\n' "$critical_total" "$critical_total"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf -- '- Executable shell line coverage: **%s%%** (target >=80%%)\n- Critical authorization/sanitization branches: **%s/%s (100%%)**\n' \
    "$coverage_percent" "$critical_total" "$critical_total" >> "$GITHUB_STEP_SUMMARY"
fi
