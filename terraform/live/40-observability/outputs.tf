output "obs_instance_id" {
  description = "Monitoring server (target of SSM sessions)"
  value       = module.obs.instance_id
}

output "obs_security_group_id" {
  description = "Security group of the monitoring server"
  value       = module.obs.security_group_id
}

output "config_documents" {
  description = "SSM documents that configure the two servers"
  value       = module.obs.document_names
}
