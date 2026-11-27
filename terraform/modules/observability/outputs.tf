output "instance_id" {
  description = "Monitoring server (target of SSM sessions and of the schedule)"
  value       = module.host.instance_id
}

output "security_group_id" {
  description = "Security group of the monitoring server (the database will allow it for its exporter)"
  value       = aws_security_group.obs.id
}

output "document_names" {
  description = "SSM documents that configure the two servers"
  value       = { for key, document in aws_ssm_document.stack : key => document.name }
}
