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
grep -Fq 'environment: aws-plan' "$workflows/ci.yml" || fail 'read-only plan job must use the aws-plan environment'
grep -Fq "github.event_name == 'push' && github.ref == 'refs/heads/main'" "$workflows/ci.yml" || fail 'read-only plan must run only on push to main'
grep -Fq './scripts/plan-guard.sh' "$workflows/ci.yml" || fail 'CI plan must use the plan guard'
grep -Fq 'services:' "$workflows/ci.yml" || fail 'SQL CI must use an ephemeral PostgreSQL service'
grep -Fq 'postgres:16-alpine' "$workflows/ci.yml" || fail 'SQL CI must pin PostgreSQL 16 Alpine'
grep -Fq 'terraform test (root SSM sensitivity regression)' "$workflows/ci.yml" || fail 'CI must run the root provider-sensitivity regression'
grep -Fq 'kcov v42' "$workflows/ci.yml" || fail 'CI must pin the shell coverage tool release'
grep -Fq 'runs-on: ubuntu-22.04' "$workflows/ci.yml" || fail 'kcov v42 must run on its compatible Ubuntu 22.04 userspace'
grep -Fq 'tests/shell-coverage.sh' "$workflows/ci.yml" || fail 'CI must enforce measured shell coverage'
if rg -n 'skip-check|skip_check' "$repo_root/.checkov.yaml"; then
  fail 'unverified global Checkov suppressions are prohibited'
fi

grep -Fq 'STAGING_ACTIVE' "$workflows/apply.yml" || fail 'apply must require an active staging session'
grep -Fq 'STAGING_SESSION_AUTHORIZED' "$workflows/apply.yml" || fail 'apply must require explicit session authorization'
grep -Fq 'REQUESTED_SESSION_ID' "$workflows/apply.yml" || fail 'manual apply must match the active session ID'
grep -Fq './scripts/bootstrap-db.sh verify' "$workflows/apply.yml" || fail 'apply must verify the pinned bootstrap bundle before requesting OIDC'
grep -Fq 'staging-database' "$workflows/apply.yml" || fail 'apply must serialize on the staging database concurrency key'
grep -Fq 'plan.tfplan' "$workflows/apply.yml" || fail 'apply must apply a saved, guarded plan'
grep -Fq 'actions: read' "$workflows/apply.yml" || fail 'apply must grant only read access to workflow-run history for replay checks'
grep -A2 -F '      lifecycle_dispatch_id:' "$workflows/apply.yml" | grep -Fq 'required: true' || fail 'apply must require the coordinator lifecycle dispatch ID'
grep -Fq 'scripts/assert_unique_lifecycle_dispatch.py' "$workflows/apply.yml" || fail 'apply must reject a replayed lifecycle dispatch ID before AWS credentials'
# The contract checks the literal GitHub Actions environment reference.
# shellcheck disable=SC2016
grep -Fq -- '--current-run-attempt "$GITHUB_RUN_ATTEMPT"' "$workflows/apply.yml" || fail 'apply must pass the run attempt so reruns can be rejected'
apply_replay_line="$(grep -nF 'name: Reject replayed lifecycle dispatch IDs before AWS credentials' "$workflows/apply.yml" | cut -d: -f1)"
apply_credentials_line="$(grep -nF 'uses: aws-actions/configure-aws-credentials@' "$workflows/apply.yml" | cut -d: -f1)"
[[ -n "$apply_replay_line" && -n "$apply_credentials_line" && "$apply_replay_line" -lt "$apply_credentials_line" ]] \
  || fail 'apply replay validation must run before AWS credentials are requested'
grep -Fq 'timeout-minutes: 90' "$workflows/apply.yml" || fail 'apply job must leave time for a bounded partial-apply rollback'
grep -Fq 'timeout-minutes: 35' "$workflows/apply.yml" || fail 'partial-apply rollback must cover RDS deletion and orphan verification'
grep -Fq "always() &&" "$workflows/apply.yml" || fail 'rollback must be eligible after workflow cancellation'
grep -Fq "steps.database_apply.outputs.apply_started == 'true'" "$workflows/apply.yml" || fail 'failed or cancelled applies must start the bounded rollback step'
grep -Fq "steps.database_apply.outcome != 'success'" "$workflows/apply.yml" || fail 'successful applies must not be rolled back'
grep -Fq 'python3 scripts/validate_destroy_plan.py' "$repo_root/scripts/rollback_partial_apply.sh" || fail 'partial-apply rollback must validate the exact saved destroy plan'
# The contract checks literal shell syntax, so parameter expansion is not intended here.
# shellcheck disable=SC2016
grep -Fq 'bash scripts/orphans.sh "$temp_dir/manifest.json"' "$repo_root/scripts/rollback_partial_apply.sh" || fail 'partial-apply rollback must verify AWS resources even when state is empty'
apply_line="$(grep -nF 'Terraform apply completed from the guarded saved plan.' "$workflows/apply.yml" | cut -d: -f1)"
# The contract checks literal shell syntax, so parameter expansion is not intended here.
# shellcheck disable=SC2016
bootstrap_line="$(grep -nF './scripts/bootstrap-db.sh "$PHASE"' "$workflows/apply.yml" | cut -d: -f1)"
if sed -n "$((apply_line + 1)),$((bootstrap_line - 1))p" "$workflows/apply.yml" | grep -Fq -- '--action start'; then
  fail 'an authorized apply must finish its bootstrap phase after the start window closes'
fi

if rg -n '^[[:space:]]+schedule:' "$workflows/destroy.yml"; then
  fail 'database teardown must be dispatched by the coordinated lifecycle workflow, not an independent schedule'
fi
# The contract checks the literal GitHub Actions expression in the workflow.
# shellcheck disable=SC2016
grep -Fq 'run-name: database/${{ inputs.session_id }}/teardown/destroy' "$workflows/destroy.yml" || fail 'database teardown must expose its exact lifecycle session for correlation'
grep -Fq 'actions: read' "$workflows/destroy.yml" || fail 'destroy must grant only read access to workflow-run history for replay checks'
grep -A2 -F '      lifecycle_dispatch_id:' "$workflows/destroy.yml" | grep -Fq 'required: true' || fail 'destroy must require the coordinator lifecycle dispatch ID'
grep -Fq 'scripts/assert_unique_lifecycle_dispatch.py' "$workflows/destroy.yml" || fail 'destroy must reject a replayed lifecycle dispatch ID before AWS credentials'
# The contract checks the literal GitHub Actions environment reference.
# shellcheck disable=SC2016
grep -Fq -- '--current-run-attempt "$GITHUB_RUN_ATTEMPT"' "$workflows/destroy.yml" || fail 'destroy must pass the run attempt so reruns can be rejected'
destroy_replay_line="$(grep -nF 'name: Reject replayed lifecycle dispatch IDs before AWS credentials' "$workflows/destroy.yml" | cut -d: -f1)"
destroy_credentials_line="$(grep -nF 'uses: aws-actions/configure-aws-credentials@' "$workflows/destroy.yml" | cut -d: -f1)"
[[ -n "$destroy_replay_line" && -n "$destroy_credentials_line" && "$destroy_replay_line" -lt "$destroy_credentials_line" ]] \
  || fail 'destroy replay validation must run before AWS credentials are requested'
grep -A8 -F '  destroy:' "$workflows/destroy.yml" | grep -Fq 'timeout-minutes: 35' || fail 'destroy job must fit inside the 35-minute lifecycle budget'
grep -A2 -F 'name: Destroy Terraform root and verify no owned resources remain' "$workflows/destroy.yml" | grep -Fq 'timeout-minutes: 23' || fail 'Terraform teardown step must be bounded inside the lifecycle deadline'
grep -Fq -- '--minimum-remaining-seconds 2100' "$workflows/destroy.yml" || fail 'destroy must require its full runtime budget before any AWS read'
grep -Fq 'delete = "18m"' "$repo_root/modules/db-instance/main.tf" || fail 'RDS deletion timeout must fit inside the bounded Terraform teardown step'
grep -Fq '22:40 BRT' "$repo_root/scripts/validate_database_lifecycle.py" || fail 'database teardown must stop before the audit window'
grep -Fq 'The teardown confirmation must be exactly "destroy".' "$repo_root/scripts/validate_database_lifecycle.py" || fail 'database destroy validator must require exact confirmation'
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
