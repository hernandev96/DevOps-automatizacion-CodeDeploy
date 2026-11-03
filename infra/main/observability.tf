# ==============================================================================
# Observabilidad con CloudWatch - Práctica 9
# ==============================================================================
# Este archivo vive en infra/main, junto a main.tf. Terraform carga todos los
# .tf de la carpeta como UN solo módulo, así que aquí se pueden referenciar
# recursos declarados en main.tf (aws_lb.main, aws_autoscaling_group.app_asg...).
#
# Secciones:
#   0. Variables y locals
#   1. Permisos IAM para el CloudWatch Agent
#   2. Configuración del agente en SSM Parameter Store
#   3. Log group de los contenedores
#   4. Alarmas
#   5. Dashboard
# ==============================================================================



locals {
  # Nombre del parámetro de SSM donde vive la configuración del agente.
  # Se pasa también al user_data.sh para que cada instancia sepa dónde leerla.
  cw_agent_ssm_param = "/${var.project_name}/cloudwatch-agent/config"

  # Log group de CloudWatch donde llegarán los logs de los contenedores.
  app_log_group_name = "/${var.project_name}/calculadora"

  # Archivo que el agente lee (tail). ES EL PUNTO MÁS DELICADO DE LA PRÁCTICA:
  # esta ruta debe ser IDÉNTICA a la que usa el docker-compose.yml en el `tee`.
  # Si no coinciden, el agente corre sin errores pero el log group queda vacío.
  # Se define una sola vez aquí para no desincronizar la config del agente
  # y el user_data.sh.
  app_log_file_path = "/var/log/calculadora/calculadora.log"

  # Etiquetas comunes para los recursos de observabilidad
  obs_tags = {
    App         = var.project_name
    Environment = var.environment
  }
}

# ------------------------------------------------------------------------------
# 1. Permisos IAM para el CloudWatch Agent
# ------------------------------------------------------------------------------
# Sin estos permisos el agente arranca pero NO publica nada y no muestra ningún
# error: el clásico "agente mudo". Ambas políticas se adjuntan al rol que ya
# usan las instancias del ASG (ec2_app_role, definido en main.tf).

# Política administrada de AWS: permite al agente publicar métricas
# (cloudwatch:PutMetricData) y escribir logs (logs:CreateLogStream, PutLogEvents...).
resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_agent" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# La política anterior NO cubre la lectura de nuestro parámetro de SSM (solo
# cubre parámetros llamados AmazonCloudWatch-*). Por eso se crea una política
# propia, con mínimo privilegio: acotada al ARN exacto de ese único parámetro.
resource "aws_iam_policy" "ec2_read_cw_agent_config" {
  name        = "${var.project_name}-ec2-cw-agent-config-policy"
  description = "Permite a las instancias leer la configuración del CloudWatch Agent desde SSM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.cloudwatch_agent_config.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_read_cw_agent_config" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = aws_iam_policy.ec2_read_cw_agent_config.arn
}

# ------------------------------------------------------------------------------
# 2. Configuración del agente en SSM Parameter Store
# ------------------------------------------------------------------------------
# La configuración (qué métricas recolectar y qué logs seguir) se guarda UNA vez
# aquí y todas las instancias la leen al arrancar (fetch-config en el user_data).
# Así una instancia nueva creada por el ASG nace ya observada, sin intervención.

resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name        = local.cw_agent_ssm_param
  description = "Configuración del CloudWatch Agent (métricas y logs) para las instancias del ASG"
  type        = "String"
  tier        = "Standard"
  tags        = local.obs_tags

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
    }

    # --- Métricas del sistema operativo (el hipervisor no las ve) ---
    metrics = {
      namespace = "CWAgent"

      # Dimensiones que se agregan a cada métrica. OJO con el "$$": en HCL
      # "${...}" es interpolación de Terraform. "$${...}" produce el literal
      # ${aws:AutoScalingGroupName}, que es el marcador que resuelve el agente.
      append_dimensions = {
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
        InstanceId           = "$${aws:InstanceId}"
      }

      # Además de la métrica por instancia, publica una agregada por ASG.
      # Es la que usan la alarma de memoria y el dashboard.
      aggregation_dimensions = [["AutoScalingGroupName"]]

      metrics_collected = {
        mem = {
          measurement = ["used_percent", "available_percent"]
        }
        disk = {
          measurement = ["used_percent"]
          resources   = ["*"]
          drop_device = true
        }
        swap = {
          measurement = ["used_percent"]
        }
      }
    }

    # --- Logs: el agente hace tail del archivo y lo envía al log group ---
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = local.app_log_file_path
              log_group_name  = local.app_log_group_name
              log_stream_name = "{instance_id}" # un stream por instancia
            }
          ]
        }
      }
    }
  })
}

# ------------------------------------------------------------------------------
# 3. Log group de los contenedores
# ------------------------------------------------------------------------------
# El agente podría crearlo solo, pero declararlo en Terraform tiene ventajas:
#   - define la retención (por defecto CloudWatch guarda los logs para siempre
#     y se paga por almacenamiento),
#   - se destruye junto con el resto de la infraestructura (terraform destroy),
#     en vez de quedar huérfano.

resource "aws_cloudwatch_log_group" "app" {
  name              = local.app_log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.obs_tags
}

# ------------------------------------------------------------------------------
# 4. Alarmas
# ------------------------------------------------------------------------------
# Las alarmas se crean aunque su métrica todavía no tenga datos (quedan en
# INSUFFICIENT_DATA, que NO dispara ninguna acción). Las dimensiones del ALB y
# del Target Group se toman con `arn_suffix`, así no hay IDs hardcodeados que
# cambien de una cuenta a otra.

# 4.1 Errores 5xx del ALB: la alarma MÁS IMPORTANTE de la práctica.
# Mide lo que el usuario realmente experimenta y es la que se registra en
# CodeDeploy (ver main.tf) para que dispare el rollback automático.
#   - evaluation_periods/datapoints_to_alarm = 1: se activa con un solo minuto
#     con errores, para que dispare DURANTE el despliegue (el rollback por
#     alarma solo actúa mientras el despliegue está en curso).
#   - treat_missing_data = notBreaching: si no hay errores la métrica ni
#     siquiera se emite; sin datos se considera saludable, no una falla.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "gh-alb-5xx"
  alarm_description   = "Dispara si los targets del ALB devuelven al menos un HTTP 5xx en 1 minuto"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = local.obs_tags

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app_tg.arn_suffix
  }
}

# 4.2 Instancias sanas en el Target Group por debajo del mínimo del ASG.
# Aquí la AUSENCIA de datos ya es mala señal, por eso treat_missing_data =
# breaching (se trata como incumplimiento).
resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  alarm_name          = "gh-tg-healthy"
  alarm_description   = "Dispara si el target group tiene menos instancias sanas que el mínimo del ASG"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.asg_min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_actions
  tags                = local.obs_tags

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app_tg.arn_suffix
  }
}

# 4.3 Latencia p99 del ALB.
# El percentil va en `extended_statistic` (es excluyente con `statistic`).
# TargetResponseTime se mide en SEGUNDOS: 500 ms = 0.5, no 500.
resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "gh-alb-p99"
  alarm_description   = "Dispara si la latencia p99 del ALB supera el umbral (en segundos)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.latency_p99_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = local.obs_tags

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

# 4.4 CPU promedio del ASG (métrica gratuita y automática de EC2).
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "gh-asg-cpu-high"
  alarm_description   = "Dispara si la CPU promedio del ASG supera el umbral"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = local.obs_tags

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app_asg.name
  }
}

# 4.5 Memoria usada promedio del ASG.
# Esta métrica NO existe por defecto en EC2: la publica el CloudWatch Agent en
# el namespace CWAgent (gracias a la aggregation_dimension de la sección 2).
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "gh-asg-mem-high"
  alarm_description   = "Dispara si la memoria usada promedio del ASG supera el umbral"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.memory_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = local.obs_tags

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app_asg.name
  }
}

# ------------------------------------------------------------------------------
# 5. Dashboard
# ------------------------------------------------------------------------------
# Una sola vista con el estado del sistema. El cuerpo es un JSON que se arma con
# jsonencode() para poder referenciar recursos de Terraform (ASG, ALB, log group)
# sin copiar nombres a mano. Cuadrícula de 24 columnas: dos widgets por fila.

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "gh-miAppEstado"

  dashboard_body = jsonencode({
    widgets = [
      # Fila 1, izquierda: CPU del ASG
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Average"
          period  = 60
          title   = "CPU de las instancias (ASG) %"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app_asg.name, { label = "CPU %" }]
          ]
        }
      },
      # Fila 1, derecha: memoria (la publica el CloudWatch Agent)
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Average"
          period  = 60
          title   = "Memoria usada % (CWAgent)"
          metrics = [
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.app_asg.name, { label = "mem_used %" }]
          ]
        }
      },
      # Fila 2, izquierda: errores 5xx (el pico que verás durante la prueba)
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Sum"
          period  = 60
          title   = "Errores 5xx (del ALB)"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, "TargetGroup", aws_lb_target_group.app_tg.arn_suffix, { label = "5xx" }]
          ]
        }
      },
      # Fila 2, derecha: instancias sanas en el target group
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "Minimum"
          period  = 60
          title   = "Instancias sanas en el target group"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.app_tg.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix, { label = "healthy" }]
          ]
        }
      },
      # Fila 3, izquierda: latencia p99 (en segundos)
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          stat    = "p99"
          period  = 60
          title   = "Latencia p99 (segundos)"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { label = "p99" }]
          ]
        }
      },
      # Fila 3, derecha: últimos 50 eventos del log group (consulta Logs Insights)
      {
        type   = "log"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          view   = "table"
          region = var.aws_region
          title  = "Logs del contenedor calculadora"
          query  = "SOURCE '${local.app_log_group_name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      }
    ]
  })
}

