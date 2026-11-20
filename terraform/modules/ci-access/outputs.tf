output "plan_user_name" {
  value = aws_iam_user.plan.name
}

output "apply_user_name" {
  value = aws_iam_user.apply.name
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "permissions_boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
