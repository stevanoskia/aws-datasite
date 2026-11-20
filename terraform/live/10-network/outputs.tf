output "vpc_id" {
  description = "ID of the project VPC (read by later stacks through terraform_remote_state)"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "IPv4 range of the project VPC"
  value       = module.network.vpc_cidr
}
