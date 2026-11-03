#!/bin/bash
set -euo pipefail

# ==============================================================================
# Script de inicio (User Data) para instancias Amazon Linux 2023
# Instala Docker, Docker Compose, el Agente de AWS CodeDeploy y el
# Agente de CloudWatch (observabilidad)
# ==============================================================================
# NOTA: este archivo se procesa con templatefile() de Terraform. Las variables
# aws_region, cw_agent_ssm_param y app_log_file_path las reemplaza Terraform.
# Cualquier variable de shell escrita con llaves tendria que escaparse duplicando
# el signo de pesos; aqui se usan sin llaves para evitar el problema.

echo "=== [1/7] Actualizando el sistema e instalando dependencias base ==="
dnf update -y
dnf install -y docker ruby wget unzip

echo "=== [2/7] Verificando e instalando AWS CLI v2 si es necesario ==="
if ! command -v aws &> /dev/null; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

echo "=== [3/7] Configurando el servicio Docker ==="
systemctl enable docker
systemctl start docker
usermod -a -G docker ec2-user

# Instalar Docker Compose v2 (CLI plugin y binario compatible)
DOCKER_CONFIG_DIR="/usr/local/lib/docker/cli-plugins"
mkdir -p "$DOCKER_CONFIG_DIR" /usr/libexec/docker/cli-plugins /usr/local/bin
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
curl -sSL "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose "$DOCKER_CONFIG_DIR/docker-compose"
ln -sf /usr/local/bin/docker-compose /usr/libexec/docker/cli-plugins/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

echo "=== [4/7] Preparando el archivo de logs de los contenedores ==="
# Este paso va ANTES de iniciar el agente de CodeDeploy a proposito: si un
# despliegue llegara primero, Docker crearia la carpeta del volumen como root
# con permisos 755 y backend/frontend no podrian escribir en ella.
# backend y frontend son usuarios distintos que escriben el MISMO archivo
# (con tee), por eso el directorio es 777 y el archivo 666.
# La ruta debe ser identica a la del tee en el docker-compose.yml y a la del
# file_path de la configuracion del agente en SSM.
LOG_DIR="$(dirname "${app_log_file_path}")"
mkdir -p "$LOG_DIR"
chmod 777 "$LOG_DIR"
touch "${app_log_file_path}"
chmod 666 "${app_log_file_path}"

echo "=== [5/7] Instalando y habilitando el Agente de AWS CodeDeploy ==="
cd /tmp
CODE_DEPLOY_INSTALLER="install"
wget -q "https://aws-codedeploy-${aws_region}.s3.${aws_region}.amazonaws.com/latest/$CODE_DEPLOY_INSTALLER"
chmod +x "$CODE_DEPLOY_INSTALLER"
./"$CODE_DEPLOY_INSTALLER" auto
rm -f "$CODE_DEPLOY_INSTALLER"

systemctl enable codedeploy-agent
systemctl start codedeploy-agent

echo "=== [6/7] Creando directorio de trabajo de la aplicación ==="
mkdir -p /opt/mi-app
chown -R ec2-user:ec2-user /opt/mi-app

echo "=== [7/7] Instalando el Agente de CloudWatch (metricas y logs) ==="
# Va al final a proposito: con set -e, si este paso fallara (por ejemplo por
# permisos IAM) no debe impedir que la instancia quede lista para CodeDeploy.
dnf install -y amazon-cloudwatch-agent

# Descarga la configuracion desde SSM Parameter Store y arranca el agente (-s).
# Requiere los permisos IAM de CloudWatchAgentServerPolicy y la lectura del
# parametro de SSM; sin ellos el agente arranca pero no publica nada.
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c "ssm:${cw_agent_ssm_param}"

systemctl enable amazon-cloudwatch-agent

# Informativo: el estado queda registrado en /var/log/cloud-init-output.log
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status || true

echo "=== Inicialización de instancia completada con éxito ==="