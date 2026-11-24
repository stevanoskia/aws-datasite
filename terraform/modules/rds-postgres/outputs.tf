output "instance_id" {
  description = "Identifier of the database instance"
  value       = aws_db_instance.this.identifier
}

output "address" {
  description = "Private DNS name of the database"
  value       = aws_db_instance.this.address
}

output "security_group_id" {
  description = "Security group of the database"
  value       = aws_security_group.db.id
}
