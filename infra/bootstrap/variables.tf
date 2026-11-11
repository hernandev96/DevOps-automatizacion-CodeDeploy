# ==============================================================================
# Variables de Configuración - Bootstrap
# ==============================================================================

variable "aws_region" {
  type        = string
  description = "Región de AWS donde se alojarán el bucket S3 y la tabla DynamoDB"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Nombre base del proyecto para identificar los recursos"
  default     = "calculadora"
}

variable "environment" {
  type        = string
  description = "Entorno de trabajo (ej. dev, staging, prod)"
  default     = "dev"
}

variable "state_bucket_name" {
  type        = string
  description = "Nombre específico para el bucket S3 del estado remoto. Si se deja vacío, se generará uno aleatorio único con prefijo {project_name}-terraform-state-{random}."
  default     = "infraestructura-calculadora-terraform-state"
}

variable "state_bucket_force_destroy" {
  type        = bool
  description = "Permitir la eliminación del bucket S3 de estado incluso si contiene versiones de estado (útil para destruir entornos de prueba/taller)."
  default     = false
}

variable "dynamodb_table_name" {
  type        = string
  description = "Nombre de la tabla DynamoDB para distributed locking del estado. Si se deja vacío, se usará {project_name}-terraform-locks."
  default     = ""
}

variable "create_oidc_provider" {
  type        = bool
  description = "Indica si se debe crear el proveedor OIDC de GitHub en IAM. Si ya existe en la cuenta AWS (arn:aws:iam::<id>:oidc-provider/token.actions.githubusercontent.com), déjalo en false para reutilizarlo."
  default     = false
}

variable "github_repository" {
  type        = string
  description = "Repositorio de GitHub autorizado para asumir el rol OIDC en formato 'organización_o_usuario/nombre_repo'."
  default     = "DevOPS-Practicas/p07_1_asd_alb_codedeploy_terraform"
}

variable "github_branch" {
  type        = string
  description = "Rama permitida en GitHub Actions. Usa '*' para permitir cualquier rama o especifica una rama exacta como 'main'."
  default     = "*"
}

variable "github_subject_claims" {
  type        = list(string)
  description = "Lista exacta de claims sub permitidos por la trust policy de GitHub Actions."
  default = [


    "Aqui van los repositorios a implementar el OIDC"
  ]
}

variable "role_name" {
  type        = string
  description = "Nombre del rol IAM a crear para GitHub Actions OIDC."
  default     = "GitHubActionsMainDeployRole"
}

variable "attach_admin_policy" {
  type        = bool
  description = "Si es true, asocia adicionalmente la política AdministratorAccess al rol de GitHub Actions (útil si se requiere acceso completo en talleres)."
  default     = false
}
