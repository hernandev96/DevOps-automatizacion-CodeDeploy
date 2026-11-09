# ==============================================================================
# Infraestructura como Código (Terraform) - Proyecto Calculadora
# Arquitectura: ALB + Auto Scaling Group + CodeDeploy + ECR + S3 + IAM
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

  #Configuración para Backend remoto (S3 + lockfile) para trabajo colaborativo
  backend "s3" {
    bucket       = "infraestructura-calculadora-terraform-state"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  public_subnet_names   = ["gh-subnet-a", "gh-subnet-b"]
  route_table_name      = "gh-route-table"
  elb_security_group    = "gh-security-group-elb"
  ec2_security_group    = "gh-security-group-ec2"
  gateway_name          = "gh-gateway"
  target_group_name     = "gh-tg"
  load_balancer_name    = "gh-elb"
  asg_name              = "gh-asg"
  launch_template_name  = "gh-template"
  codedeploy_app_name   = "mi-app"
  deployment_group_name = "produccion"
}

# ==============================================================================
# Data Sources
# ==============================================================================

# Zonas de disponibilidad disponibles en la región
data "aws_availability_zones" "available" {
  state = "available"
}

# AMI más reciente de Amazon Linux 2023 (evita IDs hardcodeados)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ==============================================================================
# 1. Red (VPC, Subnets Públicas, Internet Gateway y Rutas)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-vpc"
    Environment = var.environment
  }
}

# Subredes públicas distribuidas en distintas AZs (mínimo 2 para ALB y HA)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = local.public_subnet_names[count.index]
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = local.gateway_name
    Environment = var.environment
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = local.route_table_name
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ==============================================================================
# 2. Security Groups
# ==============================================================================

# SG para el Application Load Balancer: expuesto a Internet en HTTP (80) y HTTPS (443)
resource "aws_security_group" "alb_sg" {
  name        = local.elb_security_group
  description = "Security Group para el ALB - Permite trafico publico de entrada"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS desde Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Permitir todo el trafico de salida hacia las instancias"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = local.elb_security_group
    Environment = var.environment
  }
}

# SG para las instancias del ASG:
# IMPORTANTE: Nunca acepta trafico directo desde 0.0.0.0/0 en el puerto de la app.
# Solo permite conexiones originadas desde el Security Group del ALB.
resource "aws_security_group" "instance_sg" {
  name        = local.ec2_security_group
  description = "Security Group para las instancias del ASG (acceso restringido via ALB)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Trafico de la app SOLO desde el ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Acceso SSH opcional (se recomienda Session Manager sin puertos abiertos)
  dynamic "ingress" {
    for_each = length(var.allowed_ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH desde rangos CIDR autorizados"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidrs
    }
  }

  egress {
    description = "Egress abierto para descargar imagenes de ECR, paquetes y comunicarse con S3/AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = local.ec2_security_group
    Environment = var.environment
  }
}

# ==============================================================================
# 3. Roles y Políticas IAM para las Instancias EC2
# ==============================================================================

resource "aws_iam_role" "ec2_app_role" {
  name = "${var.project_name}-ec2-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ec2-app-role"
    Environment = var.environment
  }
}

# Acceso seguro mediante AWS Systems Manager (SSM) sin necesidad de abrir puerto 22 (SSH)
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}



# Política con principio de menor privilegio para leer bundles de S3
resource "aws_iam_policy" "ec2_s3_codedeploy_policy" {
  name        = "${var.project_name}-ec2-s3-codedeploy-policy"
  description = "Permisos de lectura exclusivos para el bucket de revisiones de CodeDeploy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.codedeploy_bucket.arn,
          "${aws_s3_bucket.codedeploy_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_s3_codedeploy" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = aws_iam_policy.ec2_s3_codedeploy_policy.arn
}

# Política con principio de menor privilegio para autenticación y pull de imágenes ECR
resource "aws_iam_policy" "ec2_ecr_pull_policy" {
  name        = "${var.project_name}-ec2-ecr-pull-policy"
  description = "Permisos de pull de imagenes ECR para las instancias de la aplicacion"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = [
          aws_ecr_repository.backend.arn,
          aws_ecr_repository.frontend.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ecr_pull" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = aws_iam_policy.ec2_ecr_pull_policy.arn
}

# Perfil de instancia IAM asignado al Launch Template
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_app_role.name
}

# ==============================================================================
# 4. Application Load Balancer (ALB) y Target Group
# ==============================================================================

resource "aws_lb" "main" {
  name               = local.load_balancer_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = {
    Name        = local.load_balancer_name
    Environment = var.environment
  }
}

# El target group app_tg es el Target group principal que apunta a las instancias del ASG. 
# Se puede cambiar a green para hacer un despliegue Blue/Green.
resource "aws_lb_target_group" "app_tg" {
  name        = local.target_group_name
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # Reducir el tiempo de drenado para acelerar despliegues y pruebas
  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name        = local.target_group_name
    Environment = var.environment
  }
}
# 


resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }

}

# ==============================================================================
# 5. Launch Template y Auto Scaling Group (ASG)
# ==============================================================================

resource "aws_launch_template" "app" {
  name          = local.launch_template_name
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.instance_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  # user_data parametrizado con la región y codificado en Base64

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    aws_region         = var.aws_region
    cw_agent_ssm_param = local.cw_agent_ssm_param
    app_log_file_path  = local.app_log_file_path
  }))


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-asg-instance"
      App         = var.project_name
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app_asg" {
  name                = local.asg_name
  vpc_zone_identifier = aws_subnet.public[*].id
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  min_size         = var.asg_min_size
  desired_capacity = var.asg_desired_capacity
  max_size         = var.asg_max_size

  # CRUCIAL: 'ELB' permite al ASG reemplazar instancias si fallan el health check del ALB
  # Si se dejara en 'EC2', una instancia cuya app muera se consideraría sana indefinidamente.
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Propagación de etiquetas a cada instancia creada por el ASG
  dynamic "tag" {
    for_each = {
      Name        = "${var.project_name}-asg-instance"
      App         = var.project_name
      Environment = var.environment
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================================================
# 6. Repositorios ECR (Backend y Frontend)
# ==============================================================================

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}/backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-ecr-backend"
    App         = var.project_name
    Environment = var.environment
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}/frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-ecr-frontend"
    App         = var.project_name
    Environment = var.environment
  }
}

# ==============================================================================
# 7. S3 Bucket para Artefactos / Bundles de CodeDeploy
# ==============================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "codedeploy_bucket" {
  bucket        = "${var.project_name}-codedeploy-bucket-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-codedeploy-bucket"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "codedeploy" {
  bucket = aws_s3_bucket.codedeploy_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "codedeploy" {
  bucket = aws_s3_bucket.codedeploy_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ==============================================================================
# 8. Integración con AWS CodeDeploy (Deployment Group hacia ASG + ALB)
# ==============================================================================

resource "aws_codedeploy_app" "main" {
  name             = local.codedeploy_app_name
  compute_platform = "Server"
}

resource "aws_iam_role" "codedeploy_service_role" {
  name = "${var.project_name}-codedeploy-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-codedeploy-service-role"
    Environment = var.environment
  }
}
resource "aws_iam_role_policy" "codedeploy_bluegreen_ec2" {
  name = "${var.project_name}-codedeploy-bluegreen-ec2"
  role = aws_iam_role.codedeploy_service_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:RunInstances", "ec2:CreateTags"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.ec2_app_role.arn
      }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "codedeploy_service" {
  role       = aws_iam_role.codedeploy_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# Grupo de despliegue apuntando al Auto Scaling Group y coordinado con el Target Group
resource "aws_codedeploy_deployment_group" "main" {
  app_name              = aws_codedeploy_app.main.name
  deployment_group_name = local.deployment_group_name
  service_role_arn      = aws_iam_role.codedeploy_service_role.arn
  # Config predefinida válida para EC2/On-Premises (incl. blue/green con tráfico controlado)
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  # Despliegue al Auto Scaling Group (en lugar de EC2 fija por tag)
  autoscaling_groups = [aws_autoscaling_group.app_asg.name]

  # Tipo Blue/Green coordinado con el Target Group para drenar tráfico durante la actualización
  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }
  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP" # sin esto el despliegue no puede crear el entorno verde
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.app_tg.name
    }
  }

  # Configuración de alarma CloudWatch para rollback automático
  alarm_configuration {
    alarms  = [aws_cloudwatch_metric_alarm.alb_5xx.alarm_name]
    enabled = true
  }

  # Rollback automático en caso de fallo durante el despliegue o activación de alarma
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
  lifecycle {
    ignore_changes = [autoscaling_groups]
  }
}
