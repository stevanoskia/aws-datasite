output "app_instance_id" {
  description = "App server (target of SSM sessions)"
  value       = module.app_host.instance_id
}

output "deploy_documents" {
  description = "SSM documents the pipeline runs on the app server"
  value       = module.deploy.document_names
}
