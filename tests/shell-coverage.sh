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
  bash "$repo_root/tests/bootstrap-runtime.sh"
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
  || {
    printf 'Per-file shell coverage:\n' >&2
    "$jq_bin" -r '.files[] | "\(.percent_covered)%\t\(.covered_lines)/\(.total_lines)\t\(.file)"' \
      "$coverage_json" >&2
    if find "$merged_output" -type f -name '*.xml' -print -quit | grep -q .; then
      printf 'Uncovered executable shell lines:\n' >&2
      python3 - "$merged_output" <<'PY' >&2
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

expected = {
    "bootstrap-db.sh",
    "orphans.sh",
    "plan-guard.sh",
    "plan-summary.sh",
    "private-tmp.sh",
    "smoke.sh",
    "ssm-get-parameters.sh",
    "rollback_partial_apply.sh",
}
found = set()
uncovered = {filename: set() for filename in expected}
reports = sorted(Path(sys.argv[1]).rglob("*.xml"))
for report in reports:
    try:
        root = ET.parse(report).getroot()
    except ET.ParseError as exc:
        print(f"{report.name}: invalid XML ({exc})")
        continue

    matched_in_report = set()
    for element in root.iter():
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == "class":
            filename = element.get("filename", "")
        elif tag == "file":
            filename = element.get("path", "")
        else:
            continue

        filename = filename.replace("\\", "/").rsplit("/", 1)[-1]
        if filename not in expected:
            continue

        found.add(filename)
        matched_in_report.add(filename)
        for line in element.iter():
            line_tag = line.tag.rsplit("}", 1)[-1]
            if line_tag == "line" and int(line.get("hits", "0")) == 0:
                uncovered[filename].add(line.get("number", "?"))
            elif line_tag == "lineToCover" and line.get("covered") == "false":
                uncovered[filename].add(line.get("lineNumber", "?"))

    if not matched_in_report:
        print(f"{report.name}: root={root.tag}, no matching source files")

for filename in sorted(found):
    missed = sorted(uncovered[filename], key=lambda number: int(number) if number.isdigit() else -1)
    print(f"{filename}: {', '.join(missed) if missed else 'none'}")

for filename in sorted(expected - found):
    print(f"{filename}: no Cobertura class found")
PY
    else
      printf 'Kcov did not produce a Cobertura XML report.\n' >&2
    fi
    fail "executable shell line coverage ${coverage_percent}% is below the required 80%"
  }

critical_branches=(
  plan_guard_replacement_unknown_and_redaction
  bootstrap_runtime_preflight_fails_closed
  smoke_full_runtime_job_preflight
  smoke_partial_metadata_failure
  automated_backup_not_found_is_absent
  automated_backup_response_shape_fails_closed
  automated_backup_query_error_closed
  secret_absent_metadata
  secret_pending_then_absent
  secret_pending_timeout_closed
  secret_query_error_closed
  fake_aws_forbids_secret_and_broad_ssm_reads
  workflow_apply_authorization_contract
  partial_apply_rollback_uses_exact_saved_destroy_plan
  partial_apply_rollback_continues_when_outputs_unavailable
  partial_apply_rollback_verifies_resources_absent_from_state
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
