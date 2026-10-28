#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail 'usage: plan-guard.sh <terraform-plan.json>'
fi

plan_json="$1"
[[ -r "$plan_json" ]] || fail 'plan JSON is not readable'
jq_bin="${JQ_BIN:-jq}"
command -v "$jq_bin" >/dev/null 2>&1 || [[ -x "$jq_bin" ]] || fail 'jq is required'

# shellcheck disable=SC2016
violations="$("$jq_bin" -r '
  # LCOV_EXCL_START
  def resources: (.resource_changes // []);
  def after: (.change.after // null);
  def changes_after: after != null and ((.change.actions // []) != ["delete"]);
  def unknown($key): ((.change.after_unknown // {})[$key] // false) == true;
  def rds_has_explicit_kms_key($plan):
    any(($plan.configuration // {}) | .. | objects;
      .type? == "aws_db_instance" and ((.expressions // {}) | has("kms_key_id"))
    );
  def suspicious_text:
    if type == "string" then
      test("postgres(ql)?://|password[[:space:]_]*[:=]|database_url|connection_string|dsn[[:space:]_]*[:=]"; "i")
    else
      false
    end;
  def configured_rule_nonempty($expression):
    if ($expression | type) == "array" then
      ($expression | length) > 0
    elif ($expression | type) == "object" then
      if ($expression | has("constant_value")) then
        if ($expression.constant_value | type) == "array" or ($expression.constant_value | type) == "object" then
          ($expression.constant_value | length) > 0
        else
          $expression.constant_value != null
        end
      else
        true
      end
    else
      true
    end;
  def normalized_address:
    gsub("\\[[^]]+\\]"; "");
  def config_resources($module_obj; $prefix):
    [
      ($module_obj.resources // [])[]?
      | select(.type? != null and .name? != null and .mode? == "managed")
      | {
          address: ($prefix + .type + "." + .name),
          mode: .mode,
          type: .type,
          expressions: (.expressions // {})
        }
    ] + [
      (($module_obj.module_calls // {}) | to_entries[]) as $call
      | config_resources(($call.value.module // {}); ($prefix + "module." + $call.key + "."))
    ] | flatten;
  def sg_has_inline_rules($plan; $resource):
    [config_resources(($plan.configuration.root_module // {}); "")[]
      | select(.type == "aws_security_group" and (.address | normalized_address) == ($resource.address | normalized_address))
    ][0] as $configuration_resource |
    if $configuration_resource == null then
      true
    else
      ($configuration_resource.expressions // {}) as $expressions |
      any(["ingress", "egress"][];
        . as $name |
        ($expressions | has($name)) and configured_rule_nonempty($expressions[$name])
      )
    end;
  def rds_invalid($plan; $resource):
    ($resource | unknown("publicly_accessible")) or
    ($resource | unknown("storage_encrypted")) or
    ($resource | unknown("engine")) or
    ($resource | unknown("engine_version")) or
    ($resource | unknown("instance_class")) or
    ($resource | unknown("allocated_storage")) or
    ($resource | unknown("storage_type")) or
    ($resource | unknown("max_allocated_storage")) or
    ($resource | unknown("multi_az")) or
    ($resource | unknown("deletion_protection")) or
    ($resource | unknown("skip_final_snapshot")) or
    ($resource | unknown("delete_automated_backups")) or
    ($resource | unknown("backup_retention_period")) or
    ($resource | unknown("manage_master_user_password")) or
    ($resource | unknown("password")) or
    rds_has_explicit_kms_key($plan) or
    ($resource.change.after.publicly_accessible != false) or
    ($resource.change.after.storage_encrypted != true) or
    ($resource.change.after.engine != "postgres") or
    ($resource.change.after.engine_version != "16.15") or
    ($resource.change.after.instance_class != "db.t4g.micro") or
    ($resource.change.after.allocated_storage != 20) or
    ($resource.change.after.storage_type != "gp3") or
    ($resource.change.after.max_allocated_storage != 0) or
    ($resource.change.after.multi_az != false) or
    ($resource.change.after.deletion_protection != false) or
    ($resource.change.after.skip_final_snapshot != true) or
    ($resource.change.after.delete_automated_backups != true) or
    ($resource.change.after.backup_retention_period != 1) or
    ($resource.change.after.manage_master_user_password != true) or
    ($resource.change.after.password != null) or
    ($resource.change.after.db_name != null) or
    ($resource.change.after.username != "autoshop_owner");
  . as $plan |
  [
    if (.format_version | type) != "string" or (.resource_changes | type) != "array" then "invalid_plan_shape" else empty end,
    if any(resources[]; (.type | test("(^|_)aws_db_proxy($|_)"))) then "rds_proxy_prohibited" else empty end,
    if any(resources[]; .type == "aws_secretsmanager_secret_version") then "secret_value_resource_prohibited" else empty end,
    if any(resources[]; .type == "random_password") then "password_generator_prohibited" else empty end,
    if any(resources[]; .type == "aws_vpc_security_group_egress_rule" and changes_after) then "egress_rule_prohibited" else empty end,
    if any(resources[]; .type == "aws_security_group_rule" and changes_after) then "legacy_security_group_rule_prohibited" else empty end,
    if any(resources[]; .type == "aws_security_group" and changes_after and (sg_has_inline_rules($plan; .) or unknown("egress") or ((after.egress // []) | length > 0))) then "inline_security_group_rules_prohibited" else empty end,
    if any(resources[]; .type == "aws_db_instance" and (((.change.actions // []) | index("delete")) != null)) then "rds_deletion_prohibited" else empty end,
    if any(resources[]; .type == "aws_db_instance" and changes_after and rds_invalid($plan; .)) then "rds_invariant_failed_or_unknown" else empty end,
    if any(resources[]; .type == "aws_vpc_security_group_ingress_rule" and changes_after and (
      unknown("ip_protocol") or
      unknown("from_port") or
      unknown("to_port") or
      unknown("referenced_security_group_id") or
      unknown("cidr_ipv4") or
      unknown("cidr_ipv6") or
      unknown("prefix_list_id") or
      after.ip_protocol != "tcp" or
      after.from_port != 5432 or
      after.to_port != 5432 or
      after.referenced_security_group_id == null or
      after.cidr_ipv4 != null or
      after.cidr_ipv6 != null or
      after.prefix_list_id != null
    )) then "ingress_must_reference_security_group_on_5432" else empty end,
    if any(resources[]; .type == "aws_ssm_parameter" and changes_after and (
      (after.type != "String" and after.type != "StringList") or
      ((after.name // "") | test("(password|database_url|connection_string|dsn)"; "i")) or
      (after.value | suspicious_text)
    )) then "ssm_secret_or_connection_value_prohibited" else empty end,
    if any(.output_changes // {} | to_entries[]; (.key | test("(password|database_url|connection_string|dsn)"; "i")) or (.value.after | suspicious_text)) then "sensitive_or_connection_output_prohibited" else empty end
  ] | unique | .[]
  # LCOV_EXCL_STOP
' "$plan_json")" || fail 'plan JSON is invalid'

if [[ -n "$violations" ]]; then
  printf 'FAIL: plan rejected (%s)\n' "$(printf '%s' "$violations" | paste -sd ',' -)" >&2
  exit 1
fi

printf 'PASS: plan satisfies the staging database guard\n'
