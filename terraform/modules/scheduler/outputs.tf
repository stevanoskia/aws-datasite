output "role_name" {
  description = "Role the schedules use"
  value       = aws_iam_role.scheduler.name
}
