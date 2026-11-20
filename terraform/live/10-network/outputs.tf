output "vpc_id" {
  description = "ID of the project VPC (read by later stacks through terraform_remote_state)"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "IPv4 range of the project VPC"
  value       = module.network.vpc_cidr
}

output "app_subnet_ids" {
  description = "Private app subnets"
  value       = module.network.app_subnet_ids
}

output "app_subnet_cidrs" {
  description = "IPv4 ranges of the app subnets"
  value       = module.network.app_subnet_cidrs
}

output "db_subnet_ids" {
  description = "Private DB subnets (no route out)"
  value       = module.network.db_subnet_ids
}

output "nat_instance_id" {
  description = "NAT instance"
  value       = module.nat.instance_id
}

output "operator_role_name" {
  description = "Role to switch into for SSM sessions (the ARN goes into your local CLI profile)"
  value       = module.operator.role_name
}

output "test_instance_id" {
  description = "Test instance for the isolation proofs (null when disabled)"
  value       = one(aws_instance.test[*].id)
}

output "flow_logs_bucket" {
  description = "S3 bucket with the VPC flow logs"
  value       = module.network.flow_logs_bucket
}
