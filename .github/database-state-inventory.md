# Terraform state inventory for the database handoff

## Purpose

This procedure gathers the minimum read-only evidence needed before transferring HML and PRD database resources from the staging Terraform state. It does not authorize or perform Terraform plans, applies, imports, state moves, or migrations.

## Inventory workflow

Run **Database state inventory** manually from the **main** branch using the trusted lifecycle operator. The workflow checks the **aws-plan** GitHub Environment, assumes only **arn:aws:iam::035611741563:role/auto-shop/gh-plan-database-infra**, and reads only these versioned state objects from **auto-shop-tfstate-035611741563-use1**:

- **database-infra/staging/terraform.tfstate**
- **database-infra/hml/terraform.tfstate**
- **database-infra/prd/terraform.tfstate**

The job pins each read to the VersionId returned by HeadObject, enforces a 10 MiB limit, stores temporary files with owner-only permissions, and removes them at job exit. It does not upload artifacts. The summary contains only fixed catalog labels, state serials, managed-binding counts, and presence statuses for those labels. Raw addresses, state values, outputs, secrets, ARNs, and object version IDs must not be copied into logs, artifacts, or reports.

The inventory script is deliberately limited to a fixed catalog derived from the repository Terraform configuration and ownership validator. It reports uncatalogued managed-binding counts without exposing their addresses. Any malformed state or uncatalogued bindings require investigation in a protected operator-controlled environment before ownership is concluded.

## IAM policy prerequisite

The current plan-role policy denies reads of the HML and PRD state objects. The reviewed policy document in **.github/iam/auto-shop-plan-state-database-infra.json** changes only the explicit-deny exception list to those three exact object ARNs; it does not add bucket listing, write, delete, or Terraform apply permissions. Applying a new IAM policy version is a separate security-sensitive action and requires explicit operator confirmation at action time. Verify the live policy and default version before any update; do not apply this file automatically from CI.

## Review and handoff

Treat the workflow summary as evidence, not as an ownership decision. Reconcile every expected HML and PRD transfer binding against the inventory and the handoff checklist; confirm shared resources remain owned only by staging, and investigate any missing, duplicate, or uncatalogued binding. Have an independent reviewer verify the mapping before changing any Terraform state.

Keep DATABASE_INFRA_STATE_HANDOFF_COMPLETE and DATABASE_INFRA_DEPLOYMENT_READY false until the state ownership handoff and its independent review are complete. Do not plan or apply Terraform, import resources, move state, migrate databases, or enable deployment gates as part of this inventory procedure.
