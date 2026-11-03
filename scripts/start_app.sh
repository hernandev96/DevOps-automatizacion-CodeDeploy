#!/bin/bash
set -euo pipefail

# Despliega siempre la imagen más reciente publicada en ECR.
APP_VERSION="$(cat /opt/mi-app/scripts/VERSION 2>/dev/null || echo latest)"
export APP_VERSION

cd /opt/mi-app

# Obtener la región de AWS dinámicamente si no viene en las variables
if [ -z "${AWS_REGION:-}" ]; then
  IMDS_TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")
  if [ -n "$IMDS_TOKEN" ]; then
    AWS_REGION=$(curl -s -S -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep -oP '"region"\s*:\s*"\K[^"]+' || echo "us-east-1")
  else
    AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep -oP '"region"\s*:\s*"\K[^"]+' || echo "us-east-1")
  fi
fi
export AWS_REGION

# Obtener el registro de ECR dinámicamente según la cuenta actual
if [ -z "${ECR_REGISTRY:-}" ]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "")
  if [ -n "$AWS_ACCOUNT_ID" ]; then
    ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  fi
fi
export ECR_REGISTRY

# Autenticar Docker con ECR usando el rol IAM de la instancia
if [ -n "${ECR_REGISTRY:-}" ]; then
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin \
    "$ECR_REGISTRY"
fi

# Descarga las nuevas imágenes (backend + frontend)
docker compose -f docker-compose.yml pull

# Detiene los contenedores actuales y levanta los nuevos
docker compose -f docker-compose.yml down --remove-orphans
docker compose -f docker-compose.yml up -d

# Limpia imágenes antiguas para no llenar el disco
docker image prune -f