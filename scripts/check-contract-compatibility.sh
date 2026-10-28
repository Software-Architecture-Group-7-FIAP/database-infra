#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
  exit 0
fi

: "${GH_TOKEN:?GitHub token is required for pull request contract checks}"
: "${GITHUB_REPOSITORY:?GitHub repository is required for pull request contract checks}"
: "${PR_NUMBER:?Pull request number is required for contract checks}"

pull_request="repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}"
files_endpoint="${pull_request}/files"
changed_files="$(gh api --paginate "$files_endpoint" --jq '.[].filename')"
contract_files=(
  "envs/staging/database/main.tf"
  "envs/staging/database/outputs.tf"
  "envs/staging/database/variables.tf"
  "modules/db-instance/main.tf"
  "modules/db-secrets/main.tf"
  "modules/db-secrets/variables.tf"
  "modules/ssm-contract/main.tf"
)
breaking_contract_change=false

for file in "${contract_files[@]}"; do
  if ! grep -Fxq "$file" <<< "$changed_files"; then
    continue
  fi

  patch="$(CONTRACT_FILE="$file" gh api --paginate "$files_endpoint" --jq '.[] | select(.filename == env.CONTRACT_FILE) | .patch // empty')"
  if [[ -z "$patch" ]] || grep -Eq '^[+-][^+-].*(output[[:space:]]+"[^\"]+"|database/[^\"]+|/auto-shop/staging|name[[:space:]]*=|prefix[[:space:]]*=|app-runtime|lambda-auth)' <<< "$patch"; then
    breaking_contract_change=true
    break
  fi
done

if [[ "$breaking_contract_change" != "true" ]]; then
  exit 0
fi

labels="$(gh api "$pull_request" --jq '.labels[].name')"
if ! grep -Fxq "breaking-change" <<< "$labels"; then
  echo "::error::Database contract names changed; add the breaking-change label."
  exit 1
fi

if ! grep -Fxq "CHANGELOG.md" <<< "$changed_files"; then
  echo "::error::Database contract names changed; add a CHANGELOG.md entry under [Unreleased]."
  exit 1
fi

echo "Database contract change is labeled and documented in CHANGELOG.md."
