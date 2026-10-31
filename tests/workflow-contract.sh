#!/usr/bin/env bash
# shellcheck disable=SC2016
# This file greps for literal YAML/Markdown text containing '$'; single quotes are intentional.
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
grep -Fq 'environment-policy:' "$workflows/ci.yml" || fail 'CI must assert protected environment branch policies'
grep -Fq 'require_main_only_environment staging' "$workflows/ci.yml" || fail 'lifecycle environment must allow only main'
grep -Fq 'require_main_only_environment aws-plan' "$workflows/ci.yml" || fail 'plan environment must allow only main'
grep -Fq 'id-token: write' "$workflows/ci.yml" || fail 'read-only plan job must use OIDC'
grep -Fq "if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'" "$workflows/ci.yml" \
  || fail 'state-backed plans must remain manual and restricted to main'
[[ "$(grep -Fc 'id-token: write' "$workflows/ci.yml")" -eq 1 ]] \
  || fail 'only the manually dispatched plan job may request an OIDC token'
if sed -n '/^  static:/,/^  plan:/p' "$workflows/ci.yml" \
  | rg -n 'id-token: write|aws-actions/configure-aws-credentials@|terraform[^\n]*[[:space:]]plan([[:space:]]|$)'; then
  fail 'PR static and SQL CI jobs must not receive AWS credentials or run a state-backed plan'
fi
plan_job="$(sed -n '/^  plan:/,$p' "$workflows/ci.yml")"
grep -Fq 'environment: aws-plan' <<< "$plan_job" || fail 'read-only plan must use the isolated aws-plan environment'
grep -Fq 'needs: [static, sql, environment-policy]' "$workflows/ci.yml" || fail 'plan must wait for static, SQL, and environment branch policy checks'
[[ "$(grep -Fc 'id-token: write' "$workflows/ci.yml")" -eq 1 ]] || fail 'only the manual plan job may request an OIDC token'
if [[ -f "$workflows/database-delivery.yml" ]] && rg -n 'id-token: write|role-to-assume|AWS_DEPLOY_ROLE_ARN|AWS_PLAN_ROLE_ARN' "$workflows/database-delivery.yml"; then
  fail 'static database-delivery workflow must not have AWS role trust'
fi
grep -Fq 'The PR plan requirement in issue #01 remains a deliberate security exception' \
  "$repo_root/.github/database-delivery.md" \
  || fail 'database delivery docs must explain why state-backed PR plans remain disabled'
grep -Fq 'independent review and merge to protected `main`' "$repo_root/.github/database-delivery.md" \
  || fail 'database delivery docs must specify the reviewed post-merge plan path'
grep -Fq '"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"' \
  "$repo_root/.github/oidc/plan-trust-policy.json" || fail 'plan OIDC trust must pin its audience'
grep -Fq 'repo:Software-Architecture-Group-7-FIAP@279547328/database-infra@1420971567:environment:aws-plan' \
  "$repo_root/.github/oidc/plan-trust-policy.json" \
  || fail 'plan OIDC trust must bind the immutable repository and aws-plan environment'
grep -Fq './scripts/plan-guard.sh' "$workflows/ci.yml" || fail 'CI plan must use the plan guard'
grep -Fq 'services:' "$workflows/ci.yml" || fail 'SQL CI must use an ephemeral PostgreSQL service'
grep -Fq 'postgres:16-alpine' "$workflows/ci.yml" || fail 'SQL CI must pin PostgreSQL 16 Alpine'
grep -Fq 'terraform test (root SSM sensitivity regression)' "$workflows/ci.yml" || fail 'CI must run the root provider-sensitivity regression'
grep -Fq 'roots=(envs/staging/database envs/hml/database envs/prd/database)' "$workflows/ci.yml" || fail 'CI must validate all three shared/HML/PRD Terraform roots without a backend'
grep -Fq 'terraform -chdir="$root" init -backend=false -input=false' "$workflows/ci.yml" || fail 'CI root validation must not initialize the remote backend'
grep -Fq 'terraform -chdir="$root" validate' "$workflows/ci.yml" || fail 'CI must run Terraform validate for every declared database root'
grep -Fq 'kcov v42' "$workflows/ci.yml" || fail 'CI must pin the shell coverage tool release'
grep -Fq 'runs-on: ubuntu-22.04' "$workflows/ci.yml" || fail 'kcov v42 must run on its compatible Ubuntu 22.04 userspace'
grep -Fq 'tests/shell-coverage.sh' "$workflows/ci.yml" || fail 'CI must enforce measured shell coverage'
if rg -n 'skip-check|skip_check' "$repo_root/.checkov.yaml"; then
  fail 'unverified global Checkov suppressions are prohibited'
fi

grep -Fq 'STAGING_ACTIVE' "$workflows/apply.yml" || fail 'apply must require an active staging session'
grep -Fq 'STAGING_SESSION_AUTHORIZED' "$workflows/apply.yml" || fail 'apply must require explicit session authorization'
grep -Fq 'REQUESTED_SESSION_ID' "$workflows/apply.yml" || fail 'manual apply must match the active session ID'
grep -Fq 'DATABASE_INFRA_STATE_HANDOFF_COMPLETE' "$workflows/apply.yml" || fail 'apply must remain blocked until state ownership is handed off'
grep -Fq 'DATABASE_INFRA_DEPLOYMENT_READY' "$workflows/apply.yml" || fail 'apply must remain blocked until the deployment role and OIDC trust are reviewed'
grep -Fq 'scripts/validate_database_state_ownership.py' "$workflows/apply.yml" || fail 'apply must verify shared/HML/PRD state ownership before planning'
grep -Fq -- '--environment hml' "$workflows/apply.yml" || fail 'HML apply must require its transferred environment bindings in the isolated state'
grep -Fq 'environment_root="envs/$TARGET_ENVIRONMENT/database"' "$workflows/apply.yml" || fail 'HML provision, bootstrap, and grants must target only the selected environment root'
grep -A5 -F '      session_mode:' "$workflows/apply.yml" | grep -Fq 'options: [hml]' || fail 'database apply must expose HML as its sole selectable mode'
if grep -Fq 'prd-window' "$workflows/apply.yml"; then
  fail 'PRD database apply must remain disabled during the HML spend-cap window'
fi
grep -Fq 'TARGET_ENVIRONMENT: hml' "$workflows/apply.yml" || fail 'database apply must target only HML'
grep -A5 -F '      phase:' "$workflows/apply.yml" | grep -Fq 'options: [provision, bootstrap, grants]' \
  || fail 'HML infrastructure provisioning, credential bootstrap, and grants must be explicit phases'
if rg -n '^[[:space:]]+deploy:|id-token: write|aws-actions/configure-aws-credentials@|terraform[^\n]*(plan|apply|destroy|state list)' "$workflows/database-delivery.yml"; then
  fail 'branch delivery must never assume AWS credentials, access state, plan, or apply'
fi
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
apply_credentials_line="$(grep -nF 'uses: aws-actions/configure-aws-credentials@' "$workflows/apply.yml" | cut -d: -f1 | head -n 1)"
[[ -n "$apply_replay_line" && -n "$apply_credentials_line" && "$apply_replay_line" -lt "$apply_credentials_line" ]] \
  || fail 'apply replay validation must run before AWS credentials are requested'
grep -Fq 'timeout-minutes: 90' "$workflows/apply.yml" || fail 'apply job must allow the bounded bootstrap and smoke lifecycle'
grep -Fq "always() &&" "$workflows/apply.yml" || fail 'failure preservation steps must remain eligible after workflow cancellation'
grep -Fq "steps.database_apply.outputs.apply_started == 'true'" "$workflows/apply.yml" || fail 'post-apply failures must be detected for state preservation'
grep -Fq "steps.database_apply.outcome != 'success'" "$workflows/apply.yml" || fail 'successful applies must not trigger failure preservation'
grep -Fq 'rollback_safe=false' "$workflows/apply.yml" || fail 'a single-environment lifecycle must not authorize shared-RDS rollback'
grep -Fq './scripts/bootstrap-db.sh "$PHASE" "$TARGET_ENVIRONMENT"' "$workflows/apply.yml" || fail 'database bootstrap must receive the same selected environment as Terraform'
grep -Fq './scripts/smoke.sh initial "$TARGET_ENVIRONMENT"' "$workflows/apply.yml" || fail 'initial smoke must validate only the selected environment'
grep -Fq './scripts/smoke.sh full "$TARGET_ENVIRONMENT"' "$workflows/apply.yml" || fail 'full smoke must validate only the selected environment'
grep -Fq 'auto-shop-db-bootstrap-{{ENVIRONMENT}}' "$repo_root/scripts/bootstrap/job.yaml" || fail 'bootstrap Job must use an environment-specific Kubernetes service account'
grep -Fq 'expected_role_arn="arn:aws:iam::$ACCOUNT_ID:role/auto-shop/auto-shop-staging-db-bootstrap-$environment"' "$repo_root/scripts/bootstrap-db.sh" \
  || fail 'bootstrap must derive the selected environment role ARN from the fixed account/name contract'
if grep -Fq 'bootstrap-role-arn' "$repo_root/scripts/bootstrap-db.sh"; then
  fail 'bootstrap-role ARNs must not be read from the SSM output contract'
fi
if rg -n 'apply -f .*service-account.yaml|delete .*serviceaccount/auto-shop-db-bootstrap-' "$repo_root/scripts/bootstrap-db.sh"; then
  fail 'database bootstrap must leave ServiceAccount and Pod Identity ownership in k8s-infra'
fi
grep -Fq 'Automatic partial rollback of the shared HML/PRD RDS root is disabled' "$repo_root/scripts/rollback_partial_apply.sh" || fail 'partial rollback must retain the shared RDS for operator review'
grep -Fq 'Preserve database state after failed provisioning or bootstrap' "$workflows/apply.yml" || fail 'failed provisioning or bootstrap must retain database state for review'
grep -Fq "inputs.phase == 'bootstrap' || steps.database_apply.outputs.apply_started == 'true'" "$workflows/apply.yml" \
  || fail 'failed bootstrap must preserve existing database state even though that phase does not run Terraform'
grep -Fq 'Preserve database state after a grants-phase failure' "$workflows/apply.yml" || fail 'failed grants must retain database state for operator review'
if rg -n 'terraform[[:space:]]+(plan|apply|destroy)|validate_destroy_plan\.py|orphans\.sh' "$repo_root/scripts/rollback_partial_apply.sh"; then
  fail 'partial-apply rollback must not destroy or mutate the shared database state'
fi
python3 - "$workflows/apply.yml" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
step = workflow.split(
    "      - name: Apply guarded database roots or run the requested credential phase", 1
)[1].split("      - name: Roll back managed resources after a failed or interrupted database apply", 1)[0]
if 'if [[ "$PHASE" == "provision" ]]; then' not in step or "exit 0" not in step:
    raise SystemExit("FAIL: provisioning must end before the separate credential phase")
provision = step.split('if [[ "$PHASE" == "provision" ]]; then', 1)[1].split("exit 0", 1)[0]
credentials = step.split("exit 0", 1)[1]
guard = "python3 scripts/validate_database_lifecycle.py"
apply = 'terraform -chdir="$stack" apply'
bootstrap = './scripts/bootstrap-db.sh "$PHASE" "$TARGET_ENVIRONMENT"'
if guard not in provision or apply not in provision or provision.index(guard) > provision.index(apply):
    raise SystemExit("FAIL: database provisioning must revalidate the session before Terraform apply")
if guard not in credentials or bootstrap not in credentials or credentials.index(guard) > credentials.index(bootstrap):
    raise SystemExit("FAIL: database credentials must revalidate the session before bootstrap")
PY

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
destroy_credentials_line="$(grep -nF 'uses: aws-actions/configure-aws-credentials@' "$workflows/destroy.yml" | cut -d: -f1 | head -n 1)"
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
grep -Fq 'DATABASE_INFRA_STATE_HANDOFF_COMPLETE' "$workflows/destroy.yml" || fail 'destroy must remain blocked until state ownership is handed off'
grep -Fq 'envs/hml/database' "$workflows/destroy.yml" || fail 'destroy must support the isolated HML root'
grep -Fq 'envs/prd/database' "$workflows/destroy.yml" || fail 'destroy must support the isolated PRD root'
grep -Fq 'scripts/validate_environment_destroy_plan.py' "$workflows/destroy.yml" || fail 'destroy must reject plans containing shared resources'
grep -Fq 'REQUESTED_ENVIRONMENT" "$temp_dir/plan.json" "$temp_dir/state.json"' "$workflows/destroy.yml" || fail 'destroy guard must validate exact selected-environment resource identities'
grep -Fq './scripts/orphans-environment.sh "$REQUESTED_ENVIRONMENT"' "$workflows/destroy.yml" || fail 'destroy must scan only the selected environment and confirm shared RDS remains'
if rg -n 'terraform -chdir="envs/staging/database".*(plan -destroy|apply .*destroy)' "$workflows/destroy.yml"; then
  fail 'environment teardown must never destroy the shared staging RDS root'
fi
if rg -n 'terraform state rm' "$workflows/destroy.yml"; then
  fail 'destroy must not remove Terraform state automatically'
fi

grep -Fq ':environment:staging:workflow_ref:Software-Architecture-Group-7-FIAP/database-infra/.github/workflows/apply.yml@refs/heads/main' "$repo_root/.github/oidc/hml-trust-policy.json" || fail 'HML OIDC subject must bind the protected staging Environment, authorized apply workflow, and main ref'
grep -Fq ':environment:staging:workflow_ref:Software-Architecture-Group-7-FIAP/database-infra/.github/workflows/destroy.yml@refs/heads/main' "$repo_root/.github/oidc/hml-trust-policy.json" || fail 'HML OIDC subject must bind the authorized teardown workflow and main ref'
if [[ -e "$repo_root/.github/oidc/production-trust-policy.json" ]]; then
  fail 'PRD OIDC trust must remain disabled during the HML spend-cap window'
fi
hml_trust_policy="$repo_root/.github/oidc/hml-trust-policy.json"
grep -Fq '"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"' "$hml_trust_policy" || fail 'AWS OIDC trust must require the standard audience'
if rg -n 'token\.actions\.githubusercontent\.com:(workflow|workflow_ref|ref|job_workflow_ref)' "$hml_trust_policy"; then
  fail 'AWS OIDC trust must bind standard workflow metadata through sub, not unsupported separate claims'
fi
grep -Fq '"include_claim_keys":["repo","context","workflow_ref"]' "$repo_root/.github/database-delivery.md" || fail 'OIDC runbook must specify the exact repository subject customization template'
grep -Fq 'US$100 cap through 05/11/2026' "$repo_root/.github/database-delivery.md" || fail 'database apply runbook must bind authorization to the capped lifecycle window'

printf 'PASS: workflows preserve staging authorization, saved-plan, SQL, and teardown contracts\n'
if [[ -n "${SHELL_COVERAGE_BRANCH_REPORT:-}" ]]; then
  printf '%s\n' workflow_apply_authorization_contract >> "$SHELL_COVERAGE_BRANCH_REPORT"
fi
