output "vpc_id" {
  description = "ID of the project VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 range of the project VPC"
  value       = aws_vpc.this.cidr_block
}
