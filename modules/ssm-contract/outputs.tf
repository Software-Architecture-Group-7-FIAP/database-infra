output "parameter_names" {
  description = "Every parameter name published by this contract."
  value       = sort(concat([for parameter in aws_ssm_parameter.string : parameter.name], [for parameter in aws_ssm_parameter.list : parameter.name]))
}
