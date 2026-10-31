# Database Terraform state handoff

## Purpose and current status

The Terraform configuration now has one shared root and separate HML/PRD roots. The live backend still has the pre-split ownership recorded in the infrastructure audit: the staging state at serial 7 owns the shared RDS/network/bootstrap resources and the existing HML/PRD runtime and Lambda secret metadata, Lambda read policies, and environment name/secret/policy SSM parameters. Migration secret resources, migration policies/parameters, environment bootstrap policies/roles/attachments, and environment bootstrap-role ARN parameters are absent from that live state.

**Status: pending.** No state migration was performed as part of the configuration split. Keep `DATABASE_INFRA_STATE_HANDOFF_COMPLETE` unset or false and `DATABASE_INFRA_DEPLOYMENT_READY` false. The workflows fail closed while the handoff flag is false.

## Blocker: existing HML secret ownership

The audited staging state at serial 7 currently owns the HML runtime and Lambda secret metadata. The HML root also declares those same named secrets as managed resources through `module.secrets`. Do not run an HML plan/apply or mark the handoff complete while this overlap is unresolved. Before the later #04 credential rollout, the owner must choose and review one path: transfer the exact existing resource bindings to HML and remove their staging ownership, or keep them in staging and change HML to data-source references. The second option must still create only the missing HML migration secret. This configuration has not made that ownership choice; the blocker is recorded here for review.

The PRD root has the analogous runtime/Lambda declarations while PRD apply remains disabled. Resolve its ownership consistently before PRD can be enabled. This note does not authorize state changes or a deployment.

This runbook describes the bindings that must be transferred. It does not authorize an apply, import, destroy, or state migration. Never read or print resource attribute values, secret payloads, credentials, or full state JSON for this procedure.

## Bindings to transfer

Move each existing environment binding out of `database-infra/staging/terraform.tfstate` and into exactly one matching environment state. Preserve the Terraform resource address shown below. The state inventory commands and validator operate on addresses only.

| Destination | Existing Terraform address |
|---|---|
| HML | `module.secrets.aws_secretsmanager_secret.runtime["hml"]` |
| HML | `module.secrets.aws_secretsmanager_secret.lambda["hml"]` |
| HML | `aws_iam_policy.lambda_hml_secret_read` |
| HML | `module.ssm_contract.aws_ssm_parameter.string["database/names/hml"]` |
| HML | `module.ssm_contract.aws_ssm_parameter.string["database/secrets/runtime-hml-arn"]` |
| HML | `module.ssm_contract.aws_ssm_parameter.string["database/secrets/lambda-hml-arn"]` |
| HML | `module.ssm_contract.aws_ssm_parameter.string["database/iam/lambda-read-policy-arn/hml"]` |
| PRD | `module.secrets.aws_secretsmanager_secret.runtime["prd"]` |
| PRD | `module.secrets.aws_secretsmanager_secret.lambda["prd"]` |
| PRD | `aws_iam_policy.lambda_prd_secret_read` |
| PRD | `module.ssm_contract.aws_ssm_parameter.string["database/names/prd"]` |
| PRD | `module.ssm_contract.aws_ssm_parameter.string["database/secrets/runtime-prd-arn"]` |
| PRD | `module.ssm_contract.aws_ssm_parameter.string["database/secrets/lambda-prd-arn"]` |
| PRD | `module.ssm_contract.aws_ssm_parameter.string["database/iam/lambda-read-policy-arn/prd"]` |

Do not try to move resources that are absent from the audited live state. The new migration secrets, migration read policies and SSM parameters, and per-environment bootstrap secret policies/roles/attachments/role-ARN parameters are created by their environment roots after the existing bindings have one owner. They must not be imported or copied from the old state.

## Shared bindings retained in staging

The following remain owned only by `database-infra/staging/terraform.tfstate`:

- `module.network.aws_db_subnet_group.this` and `module.network.aws_security_group.this` plus the network module's managed rules.
- `module.instance.aws_db_parameter_group.this` and `module.instance.aws_db_instance.this`.
- `aws_iam_role.db_bootstrap`, `aws_iam_role_policy.db_bootstrap`, and `aws_eks_pod_identity_association.db_bootstrap` (the retained legacy role can read only the shared RDS owner secret).
- Common SSM parameters for `database/host`, `database/port`, `database/security-group-id`, and `database/secrets/owner-arn`.

All shared RDS, network, legacy role, and legacy Pod Identity addresses remain in staging. Neither environment state may contain any shared binding. `k8s-infra` owns per-environment ServiceAccounts and Pod Identity associations; the database roots own only the selected bootstrap IAM roles, policies/attachments, and role ARN SSM parameters. Their exact matching names are documented in [database delivery](database-delivery.md).

## Controlled handoff procedure

1. Pause every writer that can change these backend keys, including delivery and lifecycle workflows. Confirm no Terraform run is active and retain the existing S3 state object versions and lock support.
2. Recheck the live state serial and address inventory immediately before handoff. If the staging serial or the listed address inventory differs from the audit baseline, stop and reconcile the new inventory before proceeding. Do not display `terraform state show`, state JSON, outputs, or secret values.
3. Make restricted, encrypted recovery copies of all three state objects using the approved backend procedure. Keep copies and temporary files private, do not upload them to CI artifacts, and do not print their contents.
4. Transfer only the exact addresses in the table to their corresponding destination state using a reviewed cross-state migration procedure that preserves resource identity. Do not run `terraform import` or a plan/apply between the source and destination writes. Keep a record of state object versions, serials, and address lists only.
5. Obtain address-only inventories for the staging, HML, and PRD states. Confirm every table address appears exactly once in its intended state, none remains in the staging state, and no shared address appears in HML or PRD. Run `scripts/validate_database_state_ownership.py` against those inventories in a controlled environment.
6. If any step fails or ownership is ambiguous, stop before Terraform plan/apply and restore/reconcile only from the protected state copies under operator review. Do not clear state or remove bindings automatically.
7. After an independent review confirms the inventories and state object versions, an authorized repository administrator may set `DATABASE_INFRA_STATE_HANDOFF_COMPLETE=true`. Keep `DATABASE_INFRA_DEPLOYMENT_READY` false until the separate deployment-role/OIDC readiness review is complete.

After the gate is opened, the first environment plans may add only new migration and bootstrap metadata/policy/role resources absent from the original state. Review those plans; any deletion or replacement remains blocked by the workflows. Before bootstrap runs, `k8s-infra` must provision the selected ServiceAccount and Pod Identity association using the selected environment's SSM role ARN.
