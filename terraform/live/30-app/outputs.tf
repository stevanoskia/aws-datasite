output "app_instance_id" {
  description = "App server (target of SSM sessions)"
  value       = module.app_host.instance_id
}
