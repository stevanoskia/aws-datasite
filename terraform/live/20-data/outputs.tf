output "db_instance_id" {
  description = "Identifier of the database instance"
  value       = module.postgres.instance_id
}

output "db_address" {
  description = "Private DNS name of the database (resolves only to a private address)"
  value       = module.postgres.address
  sensitive   = true # an internal name; Terraform's output is public in the pipeline
}
