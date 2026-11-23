output "vpc_id" {
  description = "ID of the project VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 range of the project VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets (NAT instance only)"
  value       = [for k, s in aws_subnet.this : s.id if local.subnets[k].tier == "public"]
}

output "app_subnet_ids" {
  description = "Private app subnets (hosts, outbound through the NAT instance)"
  value       = [for k, s in aws_subnet.this : s.id if local.subnets[k].tier == "app"]
}

output "app_subnet_cidrs" {
  description = "IPv4 ranges of the app subnets"
  value       = [for k, s in aws_subnet.this : s.cidr_block if local.subnets[k].tier == "app"]
}

output "db_subnet_ids" {
  description = "Private DB subnets (no route out)"
  value       = [for k, s in aws_subnet.this : s.id if local.subnets[k].tier == "db"]
}

output "app_route_table_id" {
  description = "Route table of the app tier (the stack adds the 0.0.0.0/0 route to the NAT instance)"
  value       = aws_route_table.this["app"].id
}

output "db_route_table_id" {
  description = "Route table of the db tier (no internet route)"
  value       = aws_route_table.this["db"].id
}

output "flow_logs_bucket" {
  description = "S3 bucket with the VPC flow logs"
  value       = aws_s3_bucket.flow_logs.bucket
}

output "app_security_group_id" {
  description = "Security group of the app server"
  value       = aws_security_group.app.id
}
