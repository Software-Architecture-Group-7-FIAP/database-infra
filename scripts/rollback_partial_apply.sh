#!/usr/bin/env bash
set -euo pipefail

stack="envs/staging/database"
umask 077
temp_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/database-apply-rollback.XXXXXX")"
chmod 700 "$temp_dir"
trap 'rm -rf -- "$temp_dir"' EXIT

rollback_failed=false
mark_failure() {
  printf '::error::%s\n' "$1" >&2
  rollback_failed=true
}

printf '{}\n' > "$temp_dir/manifest.json"

terraform_initialized=false
if terraform -chdir="$stack" init -input=false -lock-timeout=120s >"$temp_dir/init.log" 2>&1; then
  terraform_initialized=true
else
  mark_failure "Terraform rollback init failed; private diagnostics were discarded."
fi

state_available=false
if [[ "$terraform_initialized" == true ]]; then
  if terraform -chdir="$stack" state list >"$temp_dir/state-list.txt" 2>"$temp_dir/state.stderr"; then
    state_available=true
  elif grep -q 'No state file was found' "$temp_dir/state.stderr"; then
    echo "No Terraform state exists; checking AWS for resources created before state was persisted." >> "$GITHUB_STEP_SUMMARY"
  else
    mark_failure "Terraform state could not be inspected for rollback."
  fi
else
  echo "Terraform could not initialize; checking AWS for resources left by the partial apply." >> "$GITHUB_STEP_SUMMARY"
fi

has_resources=false
if [[ "$state_available" == true && -s "$temp_dir/state-list.txt" ]]; then
  has_resources=true
fi

if [[ "$has_resources" == true ]]; then
  if terraform -chdir="$stack" output -json >"$temp_dir/manifest.json" 2>"$temp_dir/output.stderr"; then
    chmod 600 "$temp_dir/manifest.json"
  else
    printf '{}\n' > "$temp_dir/manifest.json"
    chmod 600 "$temp_dir/manifest.json"
    echo "Terraform outputs were unavailable; rollback continues with an empty manifest and the scoped AWS resource-tag scan." >> "$GITHUB_STEP_SUMMARY"
  fi

  state_captured=false
  if terraform -chdir="$stack" show -json >"$temp_dir/state.json" 2>"$temp_dir/state-show.stderr"; then
    chmod 600 "$temp_dir/state.json"
    state_captured=true
  else
    mark_failure "Terraform state could not be captured privately for rollback."
  fi

  plan_created=false
  if [[ "$state_captured" == true ]]; then
    if terraform -chdir="$stack" plan -destroy -input=false -lock-timeout=120s \
      -out="$temp_dir/destroy.tfplan" >"$temp_dir/plan.log" 2>&1; then
      plan_created=true
    else
      mark_failure "Terraform could not create the partial-apply rollback plan."
    fi
  fi

  plan_validated=false
  if [[ "$plan_created" == true ]]; then
    if terraform -chdir="$stack" show -json "$temp_dir/destroy.tfplan" \
      >"$temp_dir/plan.json" 2>"$temp_dir/plan-show.stderr"; then
      chmod 600 "$temp_dir/plan.json"
      if python3 scripts/validate_destroy_plan.py "$temp_dir/plan.json" "$temp_dir/state.json" \
        >> "$GITHUB_STEP_SUMMARY"; then
        plan_validated=true
      else
        mark_failure "Terraform rollback plan failed exact-state validation; no deletion was started."
      fi
    else
      mark_failure "Terraform could not render the rollback plan; no deletion was started."
    fi
  fi

  if [[ "$plan_validated" == true ]]; then
    if terraform -chdir="$stack" apply -input=false -auto-approve -lock-timeout=120s \
      "$temp_dir/destroy.tfplan" >"$temp_dir/destroy.log" 2>&1; then
      echo "Terraform removed the exact managed resources left by the failed database apply." >> "$GITHUB_STEP_SUMMARY"
    else
      mark_failure "Applying the exact partial-apply rollback plan failed; private diagnostics were discarded."
    fi
  fi
else
  if [[ "$state_available" == true ]]; then
    echo "Terraform state contains no managed resources; checking AWS for resources absent from state." >> "$GITHUB_STEP_SUMMARY"
  elif [[ "$terraform_initialized" == true ]]; then
    echo "Terraform state was unavailable; checking AWS for resources left by the partial apply." >> "$GITHUB_STEP_SUMMARY"
  fi
fi

if ! bash scripts/orphans.sh "$temp_dir/manifest.json" >> "$GITHUB_STEP_SUMMARY"; then
  mark_failure "The partial-apply rollback could not prove all database session resources are absent."
fi

[[ "$rollback_failed" == false ]] || exit 1
