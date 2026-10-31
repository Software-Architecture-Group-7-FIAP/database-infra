# Changelog

All notable changes to this repository are recorded here.

## [Unreleased]

- **Breaking:** split `envs/hml/database` and `envs/prd/database` into their own Terraform roots and states (`database-infra/hml/terraform.tfstate`, `database-infra/prd/terraform.tfstate`), each owning only its environment's secret metadata, read policies, and bootstrap role. The shared `envs/staging/database` root no longer declares the `db-secrets` module directly; it keeps sole ownership of the RDS instance, network, and bootstrap role, and reads the existing per-environment secrets via data source.
- Require manual dispatch for staging apply and enforce the breaking database contract label/changelog policy in CI.
- Add the single ephemeral staging PostgreSQL root, network, secret metadata, IAM and SSM contract from ADR-0071 rev. 2026-10-25.
- Add least-privilege bootstrap SQL and local integration checks for `hml` and `prd` databases.
- Add CI, deployment guards, operational scripts, and security decisions for the staging database lifecycle.
- Implement the Pod Identity database Job with aws-cli and postgres:16 init containers, asm-exec secret resolution, SCRAM verifiers, PutSecretValue publication, and sensitive runtime files confined to memory-backed emptyDir.
- Add the post-migration full smoke for TLS hostname verification, role authentication, least privilege, and logical database isolation.
- Add separate HML/PRD migration credential metadata, database-scoped PostgreSQL roles, and exact-ARN read policies; keep the RDS master secret exclusive to bootstrap.
