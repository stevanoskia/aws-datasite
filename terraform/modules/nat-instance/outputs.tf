output "instance_id" {
  description = "ID of the NAT instance"
  value       = aws_instance.nat.id
}

output "network_interface_id" {
  description = "Primary network interface: the target of the private subnets' 0.0.0.0/0 route"
  value       = aws_instance.nat.primary_network_interface_id
}

output "security_group_id" {
  description = "Security group of the NAT instance"
  value       = aws_security_group.nat.id
}
