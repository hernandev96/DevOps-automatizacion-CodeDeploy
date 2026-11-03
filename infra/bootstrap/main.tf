# ==============================================================================
# Infraestructura Bootstrap - Proyecto Calculadora
# Recursos:
# 1. Bucket S3 para Backend Remoto (terraform.tfstate de infra/main) con versionado,
#    encriptación en reposo y bloqueo de acceso público.
# 2. Tabla DynamoDB para Distributed Locking del estado de Terraform.
# 3. Proveedor de Identidad OIDC para GitHub Actions (token.actions.githubusercontent.com).
# 4. Rol IAM para GitHub Actions con política de confianza (Trust Policy OIDC)
#    y permisos para aprovisionar infra/main y desplegar la aplicación.
# ==============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------------------
# Data Sources
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  state_bucket_name   = var.state_bucket_name != "" ? var.state_bucket_name : "${var.project_name}-terraform-state-${random_id.bucket_suffix.hex}"
  dynamodb_table_name = var.dynamodb_table_name != "" ? var.dynamodb_table_name : "${var.project_name}-terraform-locks"
}

# ==============================================================================
# 1. S3 Bucket para Backend Remoto de Terraform (terraform.tfstate de main)
# ==============================================================================

resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.state_bucket_name
  force_destroy = var.state_bucket_force_destroy

  tags = {
    Name        = local.state_bucket_name
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform-Bootstrap"
    Purpose     = "Terraform Remote State Storage"
  }
}

# Habilitar versionado para recuperar estados anteriores en caso de corrupción o sobreescritura
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encriptación del estado en reposo con SSE-S3 (AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bloquear todo acceso público al bucket de estado
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Política de S3 para forzar conexiones seguras HTTPS / SSL (SecureTransport)
resource "aws_s3_bucket_policy" "enforce_tls" {
  bucket     = aws_s3_bucket.terraform_state.id
  depends_on = [aws_s3_bucket_public_access_block.terraform_state]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ==============================================================================
# 2. DynamoDB Table para Distributed State Locking
# ==============================================================================

resource "aws_dynamodb_table" "terraform_locks" {
  name         = local.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = local.dynamodb_table_name
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform-Bootstrap"
    Purpose     = "Terraform State Locking"
  }
}

# ==============================================================================
# 3. Proveedor de Identidad OIDC para GitHub Actions
# ==============================================================================

# Si el proveedor OIDC ya existe en la cuenta de AWS, se referencia con data source.
# Si es una cuenta nueva, var.create_oidc_provider = true lo crea.
data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_oidc_provider ? 0 : 1
  arn   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd2d98bab03faadb97b34396831e3780aea1",
    "1c5860f56b1304399f458174123095b4ee50ee9f"
  ]

  tags = {
    Name        = "github-actions-oidc-provider"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform-Bootstrap"
  }
}

locals {
  github_oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
  github_subject_claims    = length(var.github_subject_claims) > 0 ? var.github_subject_claims : (var.github_branch == "*" ? ["repo:${var.github_repository}:*"] : ["repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"])
}

# ==============================================================================
# 4. IAM Role para GitHub Actions (AssumeRoleWithWebIdentity via OIDC)
# ==============================================================================

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subject_claims
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = var.role_name
  description        = "Rol asumido por GitHub Actions via OIDC para aprovisionar infra/main y desplegar la aplicacion"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = {
    Name        = var.role_name
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform-Bootstrap"
  }
}

# ------------------------------------------------------------------------------
# 5. Políticas IAM para el Rol de GitHub Actions
# ------------------------------------------------------------------------------

# 5.1 Permisos para el backend remoto (S3 State + DynamoDB Locks)
data "aws_iam_policy_document" "terraform_state_access" {
  statement {
    sid    = "TerraformStateS3Bucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning"
    ]
    resources = [aws_s3_bucket.terraform_state.arn]
  }

  statement {
    sid    = "TerraformStateS3Objects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.terraform_state.arn}/*"]
  }

  statement {
    sid    = "TerraformStateDynamoDBLocks"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable"
    ]
    resources = [aws_dynamodb_table.terraform_locks.arn]
  }
}

resource "aws_iam_policy" "terraform_state_access" {
  name        = "${var.project_name}-github-actions-tfstate-policy"
  description = "Permite a GitHub Actions leer y escribir el estado de Terraform y gestionar locks"
  policy      = data.aws_iam_policy_document.terraform_state_access.json
}

resource "aws_iam_role_policy_attachment" "terraform_state_attach" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.terraform_state_access.arn
}

# 5.2 Política para aprovisionamiento de infra/main y despliegue de la aplicación
data "aws_iam_policy_document" "main_infra_provisioning" {
  # Red y Cómputo (VPC, Subnets, IGW, Route Tables, Security Groups, EC2, Launch Templates)
  statement {
    sid    = "EC2AndVPCManagement"
    effect = "Allow"
    actions = [
      "ec2:*"
    ]
    resources = ["*"]
  }

  # Balanceo de carga (ALB, Target Groups, Listeners, Rules)
  statement {
    sid    = "ElasticLoadBalancingManagement"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:*"
    ]
    resources = ["*"]
  }

  # Auto Scaling Groups
  statement {
    sid    = "AutoScalingManagement"
    effect = "Allow"
    actions = [
      "autoscaling:*"
    ]
    resources = ["*"]
  }

  # Repositorios ECR (creación, login, push de imágenes)
  statement {
    sid    = "ECRManagement"
    effect = "Allow"
    actions = [
      "ecr:*"
    ]
    resources = ["*"]
  }

  # S3 para artefactos de CodeDeploy y despliegues
  statement {
    sid    = "S3AppBucketManagement"
    effect = "Allow"
    actions = [
      "s3:*"
    ]
    resources = ["*"]
  }

  # AWS CodeDeploy (aplicaciones, grupos de despliegue, despliegues)
  statement {
    sid    = "CodeDeployManagement"
    effect = "Allow"
    actions = [
      "codedeploy:*"
    ]
    resources = ["*"]
  }

  # CloudWatch Logs y Métricas
  statement {
    sid    = "CloudWatchMonitoring"
    effect = "Allow"
    actions = [
      "cloudwatch:*",
      "logs:*"
    ]
    resources = ["*"]
  }

  # Gestión de IAM requerida por infra/main (Roles de EC2 y CodeDeploy, Instance Profiles)
  statement {
    sid    = "IAMManagementForMain"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:ListInstanceProfiles",
      "iam:ListInstanceProfilesForRole"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/EC2-CodeDeploy-Role",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/EC2-CodeDeploy-Role"
    ]
  }

  # Lectura de políticas administradas que se adjuntan a los roles de la infraestructura
  statement {
    sid    = "IAMManagedPolicyRead"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions"
    ]
    resources = [
      "arn:aws:iam::aws:policy/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-*"
    ]
  }

  # Políticas administradas creadas por infra/main y por este módulo
  statement {
    sid    = "IAMCustomerManagedPolicyLifecycle"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-*"
    ]
  }

  # Asociaciones de políticas a los roles administrados por infra/main
  statement {
    sid    = "IAMRolePolicyAttachments"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"
    ]
  }

  # Algunos servicios crean su service-linked role durante el primer despliegue
  statement {
    sid       = "IAMServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values = [
        "elasticloadbalancing.amazonaws.com",
        "autoscaling.amazonaws.com"
      ]
    }
  }

  # PassRole estricto para EC2 y CodeDeploy
  statement {
    sid    = "IAMPassRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/EC2-CodeDeploy-Role"
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "codedeploy.amazonaws.com"
      ]
    }
  }
  # SSM Parameter Store: infra/main crea el parámetro con la config del CloudWatch Agent.
  # Acotado a la ruta /<proyecto>/ (principio de menor privilegio).
  statement {
    sid    = "SSMParameterManagement"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource"
    ]
    resources = [
      "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
    ]
  }

  # DescribeParameters no admite permisos por recurso: tiene que ir sobre "*".
  # Terraform lo usa al leer el parámetro (tier, tipo de dato).
  statement {
    sid       = "SSMDescribeParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "main_infra_provisioning" {
  name        = "${var.project_name}-main-infra-provisioning-policy"
  description = "Permisos necesarios para que GitHub Actions gestione la infraestructura de infra/main"
  policy      = data.aws_iam_policy_document.main_infra_provisioning.json
}

resource "aws_iam_role_policy_attachment" "main_infra_provisioning_attach" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.main_infra_provisioning.arn
}

# 5.3 Opcional: Asociar AdministratorAccess si se requiere control total en laboratorios
resource "aws_iam_role_policy_attachment" "admin_access_optional" {
  count      = var.attach_admin_policy ? 1 : 0
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
