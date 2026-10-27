#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/plan-guard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
jq_bin="${JQ_BIN:-jq}"
command -v "$jq_bin" >/dev/null 2>&1 || [[ -x "$jq_bin" ]] || { printf 'FAIL: jq is required\n' >&2; exit 1; }

record_critical_branch() {
  if [[ -n "${SHELL_COVERAGE_BRANCH_REPORT:-}" ]]; then
    printf '%s\n' "$1" >> "$SHELL_COVERAGE_BRANCH_REPORT"
  fi
}

"$jq_bin" -n '
  {
    format_version: "1.2",
    configuration: {
      root_module: {
        module_calls: {
          instance: {
            module: {
              resources: [
                {
                  mode: "managed",
                  type: "aws_db_instance",
                  name: "this",
                  expressions: { storage_encrypted: { constant_value: true } }
                }
              ]
            }
          },
          network: {
            module: {
              resources: [
                {
                  mode: "managed",
                  type: "aws_security_group",
                  name: "this",
                  expressions: { egress: { constant_value: [] } }
                }
              ]
            }
          }
        }
      }
    },
    resource_changes: [
      {
        address: "module.instance.aws_db_instance.this",
        mode: "managed",
        type: "aws_db_instance",
        change: {
          actions: ["create"],
          after: {
            publicly_accessible: false,
            storage_encrypted: true,
            kms_key_id: null,
            engine: "postgres",
            engine_version: "16.15",
            instance_class: "db.t4g.micro",
            allocated_storage: 20,
            max_allocated_storage: 0,
            storage_type: "gp3",
            multi_az: false,
            deletion_protection: false,
            skip_final_snapshot: true,
            delete_automated_backups: true,
            backup_retention_period: 1,
            manage_master_user_password: true,
            password: null,
            db_name: null,
            username: "autoshop_owner"
          },
          after_unknown: {}
        }
      },
      {
        address: "module.network.aws_security_group.this",
        mode: "managed",
        type: "aws_security_group",
        change: { actions: ["create"], after: { ingress: [], egress: [] }, after_unknown: {} }
      },
      {
        address: "module.network.aws_vpc_security_group_ingress_rule.this[\"eks-nodes\"]",
        mode: "managed",
        type: "aws_vpc_security_group_ingress_rule",
        change: {
          actions: ["create"],
          after: {
            security_group_id: "sg-rds12345",
            referenced_security_group_id: "sg-eks12345",
            ip_protocol: "tcp",
            from_port: 5432,
            to_port: 5432,
            cidr_ipv4: null,
            cidr_ipv6: null,
            prefix_list_id: null
          },
          after_unknown: {}
        }
      },
      {
        address: "module.network.aws_vpc_security_group_ingress_rule.this[\"lambda\"]",
        mode: "managed",
        type: "aws_vpc_security_group_ingress_rule",
        change: {
          actions: ["create"],
          after: {
            security_group_id: "sg-rds12345",
            referenced_security_group_id: "sg-lambda123",
            ip_protocol: "tcp",
            from_port: 5432,
            to_port: 5432,
            cidr_ipv4: null,
            cidr_ipv6: null,
            prefix_list_id: null
          },
          after_unknown: {}
        }
      },
      {
        address: "aws_ssm_parameter.host",
        mode: "managed",
        type: "aws_ssm_parameter",
        change: { actions: ["create"], after: { type: "String", value: "db.example.internal" }, after_unknown: {} }
      }
    ],
    output_changes: {
      db_host: { actions: ["create"], after: "db.example.internal", after_unknown: false },
      db_port: { actions: ["create"], after: 5432, after_unknown: false }
    }
  }
' > "$tmp_dir/valid.json"

run_guard() {
  PLAN_JSON_FILE="$1" bash "$guard" "$1"
}

if bash "$guard" > "$tmp_dir/no-arguments.out" 2>&1; then
  printf 'FAIL: guard accepted a call without a plan path\n' >&2
  exit 1
fi
grep -Fq 'FAIL: usage: plan-guard.sh' "$tmp_dir/no-arguments.out" || { printf 'FAIL: guard usage error was not reported\n' >&2; exit 1; }

if run_guard "$tmp_dir/missing.json" > "$tmp_dir/unreadable.out" 2>&1; then
  printf 'FAIL: guard accepted a missing plan file\n' >&2
  exit 1
fi
grep -Fq 'FAIL: plan JSON is not readable' "$tmp_dir/unreadable.out" || { printf 'FAIL: guard unreadable-file error was not reported\n' >&2; exit 1; }

printf '{\n' > "$tmp_dir/invalid.json"
if run_guard "$tmp_dir/invalid.json" > "$tmp_dir/invalid.out" 2>&1; then
  printf 'FAIL: guard accepted invalid JSON\n' >&2
  exit 1
fi
grep -Fq 'FAIL: plan JSON is invalid' "$tmp_dir/invalid.out" || { printf 'FAIL: guard invalid-JSON error was not reported\n' >&2; exit 1; }

if JQ_BIN=missing-jq run_guard "$tmp_dir/valid.json" > "$tmp_dir/missing-jq.out" 2>&1; then
  printf 'FAIL: guard accepted an unavailable jq executable\n' >&2
  exit 1
fi
grep -Fq 'FAIL: jq is required' "$tmp_dir/missing-jq.out" || { printf 'FAIL: guard missing-jq error was not reported\n' >&2; exit 1; }

expect_rejected() {
  local name="$1"
  local filter="$2"
  "$jq_bin" "$filter" "$tmp_dir/valid.json" > "$tmp_dir/$name.json"

  if run_guard "$tmp_dir/$name.json" > "$tmp_dir/$name.out" 2>&1; then
    printf 'FAIL: guard accepted invalid fixture %s\n' "$name" >&2
    exit 1
  fi

  if grep -Fq 'CANARY_SECRET_VALUE' "$tmp_dir/$name.out"; then
    printf 'FAIL: guard leaked the fixture value for %s\n' "$name" >&2
    exit 1
  fi
}

run_guard "$tmp_dir/valid.json" > "$tmp_dir/valid.out"
grep -Fq 'PASS' "$tmp_dir/valid.out"

"$jq_bin" '.resource_changes[0].change.after_unknown.kms_key_id = true' \
  "$tmp_dir/valid.json" > "$tmp_dir/initial_managed_kms.json"
run_guard "$tmp_dir/initial_managed_kms.json" > "$tmp_dir/initial_managed_kms.out"
grep -Fq 'PASS' "$tmp_dir/initial_managed_kms.out" || { printf 'FAIL: provider-computed initial KMS key was rejected\n' >&2; exit 1; }

"$jq_bin" '.resource_changes[0].change.after.kms_key_id = "arn:aws:kms:us-east-1:035611741563:key/managed-rds-key"' \
  "$tmp_dir/valid.json" > "$tmp_dir/refreshed_managed_kms.json"
run_guard "$tmp_dir/refreshed_managed_kms.json" > "$tmp_dir/refreshed_managed_kms.out"
grep -Fq 'PASS' "$tmp_dir/refreshed_managed_kms.out" || { printf 'FAIL: provider-computed refreshed AWS-managed KMS key was rejected\n' >&2; exit 1; }

"$jq_bin" '
  .resource_changes[1].change.actions = ["no-op"] |
  .resource_changes[1].change.after.ingress = [
    {from_port:5432,to_port:5432,protocol:"tcp",security_groups:["sg-eks12345"],cidr_blocks:[],ipv6_cidr_blocks:[],prefix_list_ids:[]},
    {from_port:5432,to_port:5432,protocol:"tcp",security_groups:["sg-lambda123"],cidr_blocks:[],ipv6_cidr_blocks:[],prefix_list_ids:[]}
  ] |
  .resource_changes[2].change.actions = ["no-op"] |
  .resource_changes[3].change.actions = ["no-op"]
' "$tmp_dir/valid.json" > "$tmp_dir/refreshed_security_group.json"
run_guard "$tmp_dir/refreshed_security_group.json" > "$tmp_dir/refreshed_security_group.out"
grep -Fq 'PASS' "$tmp_dir/refreshed_security_group.out" || { printf 'FAIL: refreshed standalone ingress rules were rejected as inline rules\n' >&2; exit 1; }

"$jq_bin" '.resource_changes[0].change.actions = ["delete"] | .resource_changes[0].change.after = null' \
  "$tmp_dir/valid.json" > "$tmp_dir/pure_deletion.json"
run_guard "$tmp_dir/pure_deletion.json" > "$tmp_dir/pure_deletion.out"
grep -Fq 'PASS' "$tmp_dir/pure_deletion.out" || { printf 'FAIL: pure deletion was not skipped\n' >&2; exit 1; }

expect_rejected public_db '.resource_changes[0].change.after.publicly_accessible = true'
expect_rejected cmk_configured '.resource_changes[0].change.after.kms_key_id = "arn:aws:kms:us-east-1:035611741563:key/customer-managed" | .configuration.root_module.module_calls.instance.module.resources[0].expressions.kms_key_id = {constant_value:"arn:aws:kms:us-east-1:035611741563:key/customer-managed"}'
expect_rejected public_db_create_then_delete '.resource_changes[0].change.actions = ["create", "delete"] | .resource_changes[0].change.after.publicly_accessible = true'
expect_rejected public_db_delete_then_create '.resource_changes[0].change.actions = ["delete", "create"] | .resource_changes[0].change.after.publicly_accessible = true'
expect_rejected public_db_no_op '.resource_changes[0].change.actions = ["no-op"] | .resource_changes[0].change.after.publicly_accessible = true'
expect_rejected inline_ingress '.configuration.root_module.module_calls.network.module.resources[0].expressions.ingress = [{from_port:{constant_value:5432},to_port:{constant_value:5432},protocol:{constant_value:"tcp"},cidr_blocks:{constant_value:["0.0.0.0/0"]}}]'
expect_rejected inline_egress '.configuration.root_module.module_calls.network.module.resources[0].expressions.egress = [{from_port:{constant_value:0},to_port:{constant_value:0},protocol:{constant_value:"-1"},cidr_blocks:{constant_value:["0.0.0.0/0"]}}]'
expect_rejected ingress_ipv4 '.resource_changes[2].change.after.cidr_ipv4 = "0.0.0.0/0" | .resource_changes[2].change.after.referenced_security_group_id = null'
expect_rejected ingress_ipv6 '.resource_changes[2].change.after.cidr_ipv6 = "::/0" | .resource_changes[2].change.after.referenced_security_group_id = null'
expect_rejected wrong_protocol '.resource_changes[2].change.after.ip_protocol = "-1"'
expect_rejected wrong_port '.resource_changes[2].change.after.to_port = 5433'
expect_rejected missing_origin '.resource_changes[2].change.after.referenced_security_group_id = null'
expect_rejected egress_resource '.resource_changes += [{address:"module.network.egress",mode:"managed",type:"aws_vpc_security_group_egress_rule",change:{actions:["create"],after:{cidr_ipv4:"10.0.0.0/8"},after_unknown:{}}}]'
expect_rejected legacy_public_ingress '.resource_changes += [{address:"module.network.aws_security_group_rule.public_ingress",mode:"managed",type:"aws_security_group_rule",change:{actions:["create"],after:{type:"ingress",protocol:"tcp",from_port:5432,to_port:5432,cidr_blocks:["0.0.0.0/0"]},after_unknown:{}}}]'
expect_rejected legacy_all_protocol_egress '.resource_changes += [{address:"module.network.aws_security_group_rule.all_egress",mode:"managed",type:"aws_security_group_rule",change:{actions:["create"],after:{type:"egress",protocol:"-1",from_port:0,to_port:0,cidr_blocks:["0.0.0.0/0"]},after_unknown:{}}}]'
expect_rejected proxy_resource '.resource_changes += [{address:"aws_db_proxy.this",mode:"managed",type:"aws_db_proxy",change:{actions:["create"],after:{},after_unknown:{}}}]'
expect_rejected secret_version_resource '.resource_changes += [{address:"aws_secretsmanager_secret_version.bad",mode:"managed",type:"aws_secretsmanager_secret_version",change:{actions:["create"],after:{},after_unknown:{}}}]'
expect_rejected secret_version_data '.resource_changes += [{address:"data.aws_secretsmanager_secret_version.bad",mode:"data",type:"aws_secretsmanager_secret_version",change:{actions:["read"],after:{},after_unknown:{}}}]'
expect_rejected password_generator '.resource_changes += [{address:"random_password.bad",mode:"managed",type:"random_password",change:{actions:["create"],after:{},after_unknown:{}}}]'
expect_rejected dsn_in_ssm '.resource_changes[4].change.after.value = "postgresql://app:CANARY_SECRET_VALUE@db.example/autoshop_hml"'
expect_rejected password_in_ssm '.resource_changes[4].change.after.value = "password=CANARY_SECRET_VALUE"'
expect_rejected dsn_in_output '.output_changes.db_host.after = "postgresql://app:CANARY_SECRET_VALUE@db.example/autoshop_hml"'
expect_rejected unknown_rds_public_flag '.resource_changes[0].change.after_unknown.publicly_accessible = true'

printf 'PASS: valid, refreshed managed-key/security-group, and deletion fixtures accepted; %s invalid fixtures rejected without printing canary values\n' 23
record_critical_branch plan_guard_replacement_unknown_and_redaction
