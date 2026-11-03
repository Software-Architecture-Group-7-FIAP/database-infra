# Terraform state inventory for the database handoff

## Purpose

This procedure gathers the minimum read-only evidence needed before transferring HML and PRD database resources from the staging Terraform state. It does not authorize or perform Terraform plans, applies, imports, state moves, or migrations.

## Inventory workflow

Run **Database state inventory** manually from the **main** branch using the trusted lifecycle operator. The workflow checks the **aws-plan** GitHub Environment, assumes only **arn:aws:iam::035611741563:role/auto-shop/gh-plan-database-infra**, and reads only these versioned state objects from **auto-shop-tfstate-035611741563-use1**:

- **database-infra/staging/terraform.tfstate**
- **database-infra/hml/terraform.tfstate**
- **database-infra/prd/terraform.tfstate**

The workflow downloads each complete state object, not just its resource addresses, into an owner-only, runner-local temporary directory so the summarizer can parse it. Each download is pinned to a non-empty VersionId; absent, empty, or literal `null` versions are rejected before download, and the returned version is checked against the requested version. The workflow enforces a 10 MiB limit and removes all temporary files when the ephemeral job exits.

The workflow processes full state JSON only in that controlled temporary directory. It prints no state contents, Terraform values, raw addresses, outputs, secret metadata, ARNs, or object version IDs, and it does not retain state after cleanup or upload artifacts. Use private runner-local temporary storage only; do not copy state files to shared or public temporary locations. The summary contains only fixed catalog labels, state serials, managed-binding counts, and presence statuses for those labels, and it does not attest to individual values or addresses.

The inventory script is deliberately limited to a fixed catalog derived from the repository Terraform configuration and ownership validator. The staging shared bootstrap role is `aws_iam_role.db_bootstrap`; `aws_iam_role.environment_bootstrap` is specific to HML and PRD, and its presence in staging makes the inventory fail closed. The bootstrap-role ARN is derived from the fixed account/name contract and is not an SSM parameter; any legacy `database/iam/bootstrap-role-arn/{environment}` SSM binding is reported as an unexpected residual, not an approved optional binding. The script reports uncatalogued managed-binding counts without exposing their addresses. Any malformed state, unexpected residual, or uncatalogued binding requires investigation in a protected operator-controlled environment before ownership is concluded.

## IAM policy prerequisite

The current plan-role policy denies reads of the HML and PRD state objects. The reviewed policy document in **.github/iam/auto-shop-plan-state-database-infra.json** changes only the explicit-deny exception list to those three exact object ARNs; it does not add bucket listing, write, delete, or Terraform apply permissions.

The JSON in this repository is review evidence, not the policy source of truth. The `gh-plan-database-infra` role and `auto-shop-plan-state-database-infra` policy are managed in the **k8s-infra** repository at **envs/staging/bootstrap**. Do not dispatch this inventory until a separately reviewed change to that managed source of truth is merged and applied, and the live role and policy have been verified to permit the required reads without Terraform drift. An equivalent reviewed authorization path must preserve the same no-drift requirement. Updating only this repository's JSON does not grant access. This workflow never changes IAM. Verify the live policy and default version before any policy update; do not apply the review JSON automatically from CI.

## Review and handoff

Treat the workflow summary as evidence, not as an ownership decision. Reconcile every expected HML and PRD transfer binding against the inventory and the handoff checklist; confirm shared resources remain owned only by staging, and investigate any missing, duplicate, or uncatalogued binding. Have an independent reviewer verify the mapping before changing any Terraform state.

Keep DATABASE_INFRA_STATE_HANDOFF_COMPLETE and DATABASE_INFRA_DEPLOYMENT_READY false until the state ownership handoff and its independent review are complete. Do not plan or apply Terraform, import resources, move state, migrate databases, or enable deployment gates as part of this inventory procedure.
