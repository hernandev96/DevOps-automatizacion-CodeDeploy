# ==============================================================================
# Outputs de Configuración - Bootstrap
# ==============================================================================

output "state_bucket_name" {
  description = "Nombre del bucket S3 creado para almacenar el terraform.tfstate de la infraestructura main"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN del bucket S3 del estado remoto"
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB utilizada para state locking"
  value       = aws_dynamodb_table.terraform_locks.id
}

output "dynamodb_table_arn" {
  description = "ARN de la tabla DynamoDB de locking"
  value       = aws_dynamodb_table.terraform_locks.arn
}

output "github_oidc_provider_arn" {
  description = "ARN del proveedor OIDC de GitHub Actions en AWS IAM"
  value       = local.github_oidc_provider_arn
}

output "github_actions_role_name" {
  description = "Nombre del rol IAM asumible por GitHub Actions"
  value       = aws_iam_role.github_actions.name
}

output "github_actions_role_arn" {
  description = "ARN del rol IAM que GitHub Actions debe configurar en la variable de repositorio AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "backend_config_snippet" {
  description = "Bloque de configuración de backend 's3' listo para descomentar y usar en infra/main/main.tf"
  value       = <<-EOT
    # En infra/main/main.tf, descomenta o actualiza el bloque backend dentro de terraform {}:
    backend "s3" {
      bucket         = "${aws_s3_bucket.terraform_state.id}"
      key            = "main/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.terraform_locks.id}"
      encrypt        = true
    }
  EOT
}
