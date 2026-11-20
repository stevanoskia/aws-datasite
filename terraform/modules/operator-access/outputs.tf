output "role_arn" {
  description = "ARN of the operator role (put into your local AWS CLI profile, not into the repo)"
  value       = aws_iam_role.operator.arn
}

output "role_name" {
  description = "Name of the operator role"
  value       = aws_iam_role.operator.name
}
