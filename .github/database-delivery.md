# Database infrastructure delivery

The database infrastructure is split across three Terraform roots:

| Root | Backend key | Owner scope |
|---|---|---|
| `envs/staging/database` | `database-infra/staging/terraform.tfstate` | Shared staging VPC references, RDS/network, legacy owner-secret bootstrap role, and common SSM |
| `envs/hml/database` | `database-infra/hml/terraform.tfstate` | HML secret metadata, HML-only bootstrap/read policies and role, and HML SSM |
| `envs/prd/database` | `database-infra/prd/terraform.tfstate` | PRD secret metadata, PRD-only bootstrap/read policies and role, and PRD SSM |

The HML and PRD roots do not own RDS, network resources, the legacy staging role, or Pod Identity associations. Each environment bootstrap role accesses only that environment's runtime, Lambda, and migration credential secrets plus the shared RDS owner secret. Application runtime identities do not receive the owner secret. Environment destroy plans allow only exact environment-owned Terraform addresses and resource names.

## Bootstrap identity handoff to k8s-infra

`database-infra` owns the per-environment IAM role, its exact secret policy and attachment. The role ARN is a Terraform output and is derived by the bootstrap runner from the fixed account and environment role-name contract; it is not published to SSM. `k8s-infra` owns the ServiceAccount and EKS Pod Identity association. It must use the same environment-specific pair:

| Environment | IAM role | K8s namespace/ServiceAccount |
|---|---|---|
| HML | `auto-shop-staging-db-bootstrap-hml` | `auto-shop-ops/auto-shop-db-bootstrap-hml` |
| PRD | `auto-shop-staging-db-bootstrap-prd` | `auto-shop-ops/auto-shop-db-bootstrap-prd` |

The database workflow creates the selected IAM role. The selected K8s association must exist before bootstrap runs. `scripts/bootstrap-db.sh` renders the matching ServiceAccount name into a temporary Job manifest, requires that ServiceAccount to exist, and verifies that AWS credentials belong to the selected role before resolving or publishing credentials. It does not create or delete ServiceAccount objects.

For teardown, first remove the selected bootstrap Job and ConfigMaps, then have `k8s-infra` remove the matching Pod Identity association and ServiceAccount. The database destroy flow verifies the association is absent before destroying the selected IAM role. The post-destroy scanner checks the selected role, association, secrets, policies, and SSM metadata are absent while shared RDS remains available.

## Pull request and branch validation

`database-delivery.yml` runs on pull requests and pushes to `develop` or `main`. It checks formatting and validates each declared Terraform root with `init -backend=false`; it has no AWS credentials, backend access, plan, or apply step. Branch delivery can never change infrastructure.

## Why remote plans stay manual

The `pull_request` checks do not receive AWS OIDC or Terraform backend credentials. The Terraform configuration, provider selection, data sources, and scripts are controlled by the proposed change; a remote plan must initialize the backend and read state. Terraform state is treated as sensitive. A required-reviewer gate does not isolate the code after approval, and `pull_request_target` must not check out and execute PR code with secrets. See GitHub's [pull request workflow security guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target) and HashiCorp's [backend sensitive-data guidance](https://developer.hashicorp.com/terraform/language/backend) and [provider plugin model](https://developer.hashicorp.com/terraform/plugin/how-terraform-works).

The safe path is: run backend-disabled validation and mocked tests in the PR; require an independent review and merge to protected `main`; then let an authorized operator manually dispatch the existing read-only plan from `main`. `.github/oidc/plan-trust-policy.json` records the exact AWS trust for the separate `AWS_PLAN_ROLE_ARN`: audience `sts.amazonaws.com` and immutable repository `sub` bound to `refs/heads/main` and `.github/workflows/ci.yml`. Its permission policy must be reviewed separately, with no infrastructure writes or `secretsmanager:GetSecretValue`, state-object reads limited to this stack, and writes limited to the S3 state lock object. No GitHub or AWS setting was changed here. The PR plan requirement in issue #01 remains a deliberate security exception until the maintainers accept a different trust model.

## Authorized HML lifecycle

`apply.yml` is the only database apply workflow. It is manual-dispatch only, accepts HML as its sole mode, runs from `main` in the protected `staging` GitHub Environment, and applies the shared root followed by only `envs/hml/database`. PRD apply is disabled during the capped HML window. Re-enabling PRD requires a separate review and workflow change.

The apply workflow fails closed unless state handoff and deployment readiness are marked complete, the HML state contains its transferred bindings, and the active protected session matches the requested HML ID, start time, phase, and mode. Before the database deployment role is assumed, it checks the trusted triggering actor, rejects duplicate dispatch IDs, and consumes the coordinator's one-use opening authorization. The ledger item binds the HML session, source operator and dispatch actor, `Apply database staging`, `main`, the exact workflow inputs, and the dispatch ID. Terraform access begins only after that authorization is consumed. The workflow applies saved, guarded plans and never rolls back the shared RDS automatically.

The coordinated `environment-start` flow is the only supported issuer of that opening authorization. It captures fresh Cost Explorer evidence and checks projected gross AWS spend against the approved **US$100 cap through 05/11/2026** before it authorizes the HML session; it revalidates that evidence before authorization. The database workflow relies on the resulting one-use ledger item rather than accepting a separate branch trigger. A manual dispatch without that item cannot apply. No DB workflow independently reads or alters the cost ledger.

The `destroy.yml` workflow remains a separately authorized, one-use teardown path. It selects only `envs/hml/database` or `envs/prd/database` and never destroys the shared staging root. PRD apply remains unavailable; the PRD teardown option is retained only for authorized cleanup of any pre-existing resources. `k8s-infra` must remove the selected Pod Identity association before the database root destroys the matching role. A future shared RDS teardown requires a separately reviewed lifecycle that first proves both environment states are empty and all consumers have stopped.

## GitHub OIDC subject binding

AWS trust uses only `aud` and `sub`. The HML trust template allows exact customized subjects for the authorized manual `apply.yml` and `destroy.yml` workflows, each on `main` in the protected `staging` Environment. It does not trust the branch-validation workflow, and there is no PRD OIDC trust template during the capped HML window. The separate plan-role trust is in `.github/oidc/plan-trust-policy.json`; it allows only the manually dispatched `ci.yml` plan on `main` and does not authorize PR workflow subjects.

After state handoff and role review, configure the repository-level subject template with `PUT /repos/Software-Architecture-Group-7-FIAP/database-infra/actions/oidc/customization/sub` and body `{"use_default":false,"include_claim_keys":["repo","context","workflow_ref"],"use_immutable_subject":true}`. Ensure the `staging` Environment allows `main`, install the exact HML `aud`/`sub` trust from `.github/oidc/hml-trust-policy.json`, then verify the subject with a controlled diagnostic that cannot deploy. To roll back, reset the template with body `{"use_default":true}` and restore the prior environment-only AWS subject trust before any deployment. No GitHub API or repository setting is changed by this work.

The repository API supports `use_default`, `include_claim_keys`, and `use_immutable_subject`; GitHub documents the `repo` + `context` + workflow claim subject format and immutable owner/repository IDs in the [OIDC claim reference](https://docs.github.com/en/actions/reference/security/oidc) and [repository OIDC customization API](https://docs.github.com/en/rest/actions/oidc).

## Readiness status

The configuration split is preparatory. No state handoff or K8s Pod Identity association change is performed here. Keep state-handoff and deployment-readiness variables false/unset until the corresponding independent reviews are complete. PRD remains unavailable for apply while the HML cap window is active.
