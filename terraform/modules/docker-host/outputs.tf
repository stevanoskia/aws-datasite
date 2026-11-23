output "instance_id" {
  description = "ID of the server"
  value       = aws_instance.host.id
}

output "private_ip" {
  description = "Private address of the server"
  value       = aws_instance.host.private_ip
}

output "role_name" {
  description = "IAM role of the server"
  value       = aws_iam_role.host.name
}
