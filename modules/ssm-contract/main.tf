# Cross-repository contract (ADR-0071): plain String/StringList only; secrets never go to SSM.
resource "aws_ssm_parameter" "string" {
  #checkov:skip=CKV2_AWS_34:Standard String parameters contain only non-secret network metadata, database names, and secret ARNs.
  for_each = var.strings

  name  = "${var.prefix}/${each.key}"
  type  = "String"
  tier  = "Standard"
  value = each.value
  tags  = var.tags
}

resource "aws_ssm_parameter" "list" {
  #checkov:skip=CKV2_AWS_34:Standard StringList parameters contain only non-secret subnet IDs and other network metadata.
  for_each = var.lists

  name  = "${var.prefix}/${each.key}"
  type  = "StringList"
  tier  = "Standard"
  value = join(",", each.value)
  tags  = var.tags
}
