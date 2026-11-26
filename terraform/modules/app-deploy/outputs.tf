output "repository_url" {
  description = "Address of the image registry"
  value       = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  description = "ARN of the image registry"
  value       = aws_ecr_repository.app.arn
}

output "document_names" {
  description = "SSM documents: deploy, migrate"
  value       = { for key, document in aws_ssm_document.this : key => document.name }
}
