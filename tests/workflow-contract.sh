#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflows="$repo_root/.github/workflows"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for file in ci.yml apply.yml destroy.yml; do
  [[ -f "$workflows/$file" ]] || fail "missing workflow: $file"
done

if rg -n 'pull_request_target' "$workflows"; then
  fail 'privileged pull_request_target trigger is prohibited'
fi

grep -Fq 'branches: [main]' "$workflows/ci.yml" || fail 'CI must run for pull requests to main'
grep -Fq 'environment-policy:' "$workflows/ci.yml" || fail 'CI must assert the staging deployment branch policy'
grep -Fq 'id-token: write' "$workflows/ci.yml" || fail 'read-only plan job must use OIDC'
grep -Fq './scripts/plan-guard.sh' "$workflows/ci.yml" || fail 'CI plan must use the plan guard'
grep -Fq 'services:' "$workflows/ci.yml" || fail 'SQL CI must use an ephemeral PostgreSQL service'
grep -Fq 'postgres:16-alpine' "$workflows/ci.yml" || fail 'SQL CI must pin PostgreSQL 16 Alpine'
grep -Fq 'terraform test (root SSM sensitivity regression)' "$workflows/ci.yml" || fail 'CI must run the root provider-sensitivity regression'
grep -Fq 'kcov v42' "$workflows/ci.yml" || fail 'CI must pin the shell coverage tool release'
grep -Fq 'runs-on: ubuntu-22.04' "$workflows/ci.yml" || fail 'kcov v42 must run on its compatible Ubuntu 22.04 userspace'
grep -Fq 'tests/shell-coverage.sh' "$workflows/ci.yml" || fail 'CI must enforce measured shell coverage'
grep -Fq '"$repo_root/tests/shell-coverage.sh" --run-suite' "$repo_root/tests/shell-coverage.sh" || fail 'kcov must execute the Bash script directly to collect line coverage'
if rg -n 'skip-check|skip_check' "$repo_root/.checkov.yaml"; then
  fail 'unverified global Checkov suppressions are prohibited'
fi

grep -Fq 'STAGING_ACTIVE' "$workflows/apply.yml" || fail 'apply must require an active staging session'
grep -Fq 'STAGING_SESSION_AUTHORIZED' "$workflows/apply.yml" || fail 'apply must require explicit session authorization'
grep -Fq 'REQUESTED_SESSION_ID' "$workflows/apply.yml" || fail 'manual apply must match the active session ID'
grep -Fq './scripts/bootstrap-db.sh verify' "$workflows/apply.yml" || fail 'apply must verify the pinned bootstrap bundle before requesting OIDC'
grep -Fq 'staging-database' "$workflows/apply.yml" || fail 'apply must serialize on the staging database concurrency key'
grep -Fq 'plan.tfplan' "$workflows/apply.yml" || fail 'apply must apply a saved, guarded plan'

grep -Fq '30 1 * * *' "$workflows/destroy.yml" || fail 'database destroy must use the planned 01:30 UTC fallback schedule'
grep -Fq "inputs.confirm == 'destroy'" "$workflows/destroy.yml" || fail 'manual destroy must require exact confirmation'
grep -Fq 'has_resources=false' "$workflows/destroy.yml" || fail 'destroy must safely track whether Terraform state contains resources'
# shellcheck disable=SC2016
grep -Fq 'if [[ "$has_resources" == true ]]; then' "$workflows/destroy.yml" || fail 'destroy must skip Terraform destroy when the state is absent or empty'
grep -Fq './scripts/orphans.sh' "$workflows/destroy.yml" || fail 'destroy must run the orphan scan'
if rg -n 'terraform state rm' "$workflows/destroy.yml"; then
  fail 'destroy must not remove Terraform state automatically'
fi

printf 'PASS: workflows preserve staging authorization, saved-plan, SQL, and teardown contracts\n'
if [[ -n "${SHELL_COVERAGE_BRANCH_REPORT:-}" ]]; then
  printf '%s\n' workflow_apply_authorization_contract >> "$SHELL_COVERAGE_BRANCH_REPORT"
fi
