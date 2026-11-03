# Database Terraform state handoff

## Purpose and current status

The Terraform configuration now has one shared root and separate HML/PRD roots. The live backend still has the pre-split ownership recorded in the infrastructure audit: the staging state at serial 7 owns the shared RDS/network/bootstrap resources and the existing HML/PRD runtime and Lambda secret metadata, Lambda read policies, and environment name/secret/policy SSM parameters. Migration secret resources, migration policies/parameters, environment bootstrap policies/roles/attachments, and environment bootstrap-role ARN parameters are absent from that live state.

**Status: pending.** No state migration was performed as part of the configuration split. Keep `DATABASE_INFRA_STATE_HANDOFF_COMPLETE` unset or false and `DATABASE_INFRA_DEPLOYMENT_READY` false. The workflows fail closed while the handoff flag is false.

## Blocker: existing HML secret ownership

The audited staging state at serial 7 currently owns the HML runtime and Lambda secret metadata. The HML root also declares those same named secrets as managed resources through `module.secrets`. Do not run an HML plan/apply or mark the handoff complete while this overlap is unresolved. Before the later #04 credential rollout, the owner must choose and review one path: transfer the exact existing resource bindings to HML and remove their staging ownership, or keep them in staging and change HML to data-source references. The second option must still create only the missing HML migration secret. This configuration has not made that ownership choice; the blocker is recorded here for review.

The PRD root has the analogous runtime/Lambda declarations while PRD apply remains disabled. Resolve its ownership consistently before PRD can be enabled. This note does not authorize state changes or a deployment.

This runbook describes the bindings that must be transferred. It does not authorize an apply, import, destroy, or state migration.

## State read boundary

Do not interactively inspect or expose Terraform state. The only routine inventory path is the version-pinned, ephemeral **Read-only database state inventory** workflow in `.github/workflows/database-state-inventory.yml`, manually invoked from **main** by the trusted lifecycle operator after the IAM prerequisite below is satisfied. Its full-object download into a private runner-local temporary directory is the controlled exception to the ban on interactive or exposed state inspection: the workflow may process the complete object only to produce its fixed summary and then remove the temporary files. This does not authorize interactive `terraform state list` or `terraform state show`, other state downloads or decoders, or displaying state contents.

Use the workflow report to reconcile this runbook's known bindings. Require an uncatalogued managed-binding count of `0` for staging, HML, and PRD, and verify the expected presence/absence relationships. A missing or duplicate expected binding, a present unexpected legacy residual, malformed report, or non-zero uncatalogued count means stop and use an approved protected operator procedure before drawing ownership conclusions. The report intentionally contains fixed labels and counts, not raw resource addresses, so it is not the address list for a state transfer. Any exact address-only validation needed for a separately authorized handoff must occur only in that protected procedure.

Never print or place state values, state contents, or raw addresses discovered from the live state in console/job logs, workflow outputs, artifacts, tickets, or model context. Do not retain or upload state files or address-list artifacts. Keep any protected-procedure working material in its approved restricted location and remove temporary files according to that procedure.

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

All shared RDS, network, legacy role, and legacy Pod Identity addresses remain in staging. Neither environment state may contain any shared binding. `k8s-infra` owns per-environment ServiceAccounts and Pod Identity associations; the database roots own only the selected bootstrap IAM roles, policies/attachments, and environment-specific SSM metadata; bootstrap role ARNs are derived from the fixed account/name contract and are not SSM parameters. Their exact matching names are documented in [database delivery](database-delivery.md).

## Controlled handoff procedure

1. Pause every writer that can change these backend keys, including delivery and lifecycle workflows. Confirm no Terraform run is active and retain the existing S3 state object versions and lock support.
2. Recheck the live state serial and fixed-label inventory report immediately before handoff using the state read boundary above. If the staging serial or the known-binding report differs from the audit baseline, stop and reconcile through an approved protected procedure before proceeding. Do not display `terraform state show`, state JSON, outputs, or secret values.
3. Make restricted, encrypted recovery copies of all three state objects using the approved backend procedure. Keep copies and temporary files private, do not upload them to CI artifacts, and do not print their contents.
4. Transfer only the exact addresses in the table to their corresponding destination state using a reviewed cross-state migration procedure that preserves resource identity. Do not run `terraform import` or a plan/apply between the source and destination writes. Keep a record of state object versions, serials, and address lists only.
5. Run the pinned ephemeral inventory workflow and reconcile the known-binding rows as described above. Require the uncatalogued managed-binding count to be `0` in every state; if any check fails or an unexpected legacy residual is present, stop and use an approved protected procedure. The fixed-label report is not an address-only inventory. For the exact ownership checks required before transfer, obtain address-only inventories only through the approved protected procedure; confirm every table address appears exactly once in its intended state, none remains in staging, and no shared address appears in HML or PRD. Keep raw addresses out of logs, artifacts, and model context, and run `scripts/validate_database_state_ownership.py` against those inventories only in that protected environment.
6. If any step fails or ownership is ambiguous, stop before Terraform plan/apply and restore/reconcile only from the protected state copies under operator review. Do not clear state or remove bindings automatically.
7. After an independent review confirms the inventories and state object versions, an authorized repository administrator may set `DATABASE_INFRA_STATE_HANDOFF_COMPLETE=true`. Keep `DATABASE_INFRA_DEPLOYMENT_READY` false until the separate deployment-role/OIDC readiness review is complete.

After the gate is opened, the first environment plans may add only new migration and bootstrap metadata/policy/role resources absent from the original state. Review those plans; any deletion or replacement remains blocked by the workflows. Before bootstrap runs, `k8s-infra` must provision the selected ServiceAccount and Pod Identity association using the selected environment's fixed IAM role-name contract; the ARN is derived locally and is not published to SSM.
