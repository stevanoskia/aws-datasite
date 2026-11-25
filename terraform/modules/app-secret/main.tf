# An empty secret that exactly one role may read. The value is set outside Terraform, so it is never in the
# code or in the state.

resource "aws_secretsmanager_secret" "this" {
  name        = "${var.name_prefix}/${var.name}"
  description = var.description

  recovery_window_in_days = 0 # the value can be made again; a deleted secret must not block its name
}

# Right to read: this secret only
resource "aws_iam_role_policy" "reader" {
  name = "read-secret-${var.name}"
  role = var.reader_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.this.arn
    }]
  })
}

# ... and nobody else, not even administrators: a deny wins over every allow
resource "aws_secretsmanager_secret_policy" "reader_only" {
  secret_arn = aws_secretsmanager_secret.this.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyReadingExceptOneRole"
      Effect    = "Deny"
      Principal = "*"
      Action    = "secretsmanager:GetSecretValue"
      Resource  = "*"
      Condition = {
        StringNotEquals = { "aws:PrincipalArn" = var.reader_role_arn }
      }
    }]
  })
}
