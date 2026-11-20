output "state_bucket_name" {
  description = "Put this into backend.hcl of every stack"
  value       = aws_s3_bucket.state.bucket
}

output "alerts_topic_arn" {
  description = "SNS topic for alarms (used by later stacks)"
  value       = aws_sns_topic.alerts.arn
}

output "ci_plan_user_name" {
  description = "IAM user whose access key goes into the GitHub repository secrets"
  value       = module.ci_access.plan_user_name
}

output "ci_apply_user_name" {
  description = "IAM user whose access key goes into the GitHub 'production' environment secrets"
  value       = module.ci_access.apply_user_name
}

output "ci_plan_role_arn" {
  description = "Role the plan job assumes (stored as a GitHub secret, not in the repo)"
  value       = module.ci_access.plan_role_arn
}

output "ci_apply_role_arn" {
  description = "Role the apply job assumes (stored as a GitHub secret, not in the repo)"
  value       = module.ci_access.apply_role_arn
}

output "permissions_boundary_arn" {
  description = "Every IAM role created by the other stacks must carry this boundary"
  value       = module.ci_access.permissions_boundary_arn
}
