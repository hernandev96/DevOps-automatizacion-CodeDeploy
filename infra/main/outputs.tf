# ==============================================================================
# Outputs de Infraestructura - Proyecto Calculadora
# ==============================================================================

# --- Balanceador de Carga (ALB) y Red ---
output "alb_dns_name" {
  description = "Nombre DNS público del Application Load Balancer (Punto de entrada único de la aplicación)"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN del Application Load Balancer"
  value       = aws_lb.main.arn
}

output "target_group_arn" {
  description = "ARN del Target Group asociado al ALB y ASG"
  value       = aws_lb_target_group.app_tg.arn
}

output "target_group_name" {
  description = "Nombre del Target Group"
  value       = aws_lb_target_group.app_tg.name
}

output "vpc_id" {
  description = "ID de la VPC principal"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de las subredes públicas donde residen el ALB y el ASG"
  value       = aws_subnet.public[*].id
}

# --- Cómputo y Escalabilidad (ASG y Launch Template) ---
output "asg_name" {
  description = "Nombre del Auto Scaling Group"
  value       = aws_autoscaling_group.app_asg.name
}

output "asg_arn" {
  description = "ARN del Auto Scaling Group"
  value       = aws_autoscaling_group.app_asg.arn
}

output "launch_template_id" {
  description = "ID del Launch Template utilizado por el ASG"
  value       = aws_launch_template.app.id
}

# --- Registro de Contenedores (ECR) ---
output "ecr_backend_repository_url" {
  description = "URL del repositorio ECR para la imagen del backend"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_repository_url" {
  description = "URL del repositorio ECR para la imagen del frontend"
  value       = aws_ecr_repository.frontend.repository_url
}

output "ecr_registry_url" {
  description = "URL base del registro ECR (dominio)"
  value       = split("/", aws_ecr_repository.backend.repository_url)[0]
}

# --- Almacenamiento (S3) y Orquestación (CodeDeploy) ---
output "s3_bucket_name" {
  description = "Nombre del bucket S3 para almacenar los bundles de CodeDeploy"
  value       = aws_s3_bucket.codedeploy_bucket.id
}

output "codedeploy_app_name" {
  description = "Nombre de la aplicación en AWS CodeDeploy"
  value       = aws_codedeploy_app.main.name
}

output "codedeploy_deployment_group_name" {
  description = "Nombre del Deployment Group en AWS CodeDeploy"
  value       = aws_codedeploy_deployment_group.main.deployment_group_name
}

output "aws_region" {
  description = "Región de AWS configurada"
  value       = var.aws_region
}


# Outputs de Observabilidad 
# ------------------------------------------------------------------------------
# 6. Outputs
# ------------------------------------------------------------------------------

output "cloudwatch_dashboard_name" {
  description = "Nombre del dashboard con el estado del sistema"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "app_log_group_name" {
  description = "Log group con los logs de los contenedores"
  value       = aws_cloudwatch_log_group.app.name
}

output "codedeploy_alarm_name" {
  description = "Alarma registrada en el deployment group para el rollback automático"
  value       = aws_cloudwatch_metric_alarm.alb_5xx.alarm_name
}
