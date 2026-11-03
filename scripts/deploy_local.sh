#!/bin/bash
# ==============================================================================
# Script para desplegar la aplicación directamente desde la máquina local
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra/main"

echo "========================================================"
echo "🚀 Despliegue Local de la Aplicación (AWS + CodeDeploy)"
echo "========================================================"

# 1. Validar prerrequisitos
command -v aws >/dev/null 2>&1 || { echo "❌ Error: AWS CLI no está instalado."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "❌ Error: Docker no está instalado."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "❌ Error: Terraform no está instalado."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ Error: jq no está instalado."; exit 1; }

# 2. Obtener outputs de Terraform
echo "🔍 Leyendo variables de infraestructura desde Terraform..."
cd "$INFRA_DIR"
TF_JSON=$(terraform output -json)

AWS_REGION=$(echo "$TF_JSON" | jq -r '.aws_region.value // "us-east-1"')
ECR_REGISTRY=$(echo "$TF_JSON" | jq -r '.ecr_registry_url.value // empty')
BACKEND_ECR_REPO=$(echo "$TF_JSON" | jq -r '.ecr_backend_repository_url.value // empty')
FRONTEND_ECR_REPO=$(echo "$TF_JSON" | jq -r '.ecr_frontend_repository_url.value // empty')
S3_BUCKET=$(echo "$TF_JSON" | jq -r '.s3_bucket_name.value // empty')
CODEDEPLOY_APP=$(echo "$TF_JSON" | jq -r '.codedeploy_app_name.value // empty')
CODEDEPLOY_GROUP=$(echo "$TF_JSON" | jq -r '.codedeploy_deployment_group_name.value // empty')
ALB_DNS=$(echo "$TF_JSON" | jq -r '.alb_dns_name.value // empty')
EC2_IPS=$(echo "$TF_JSON" | jq -r '.ec2_public_ips.value[]? // empty')

if [ -z "$BACKEND_ECR_REPO" ] || [ -z "$FRONTEND_ECR_REPO" ] || [ -z "$S3_BUCKET" ] || [ -z "$CODEDEPLOY_APP" ] || [ -z "$ECR_REGISTRY" ]; then
  echo "❌ Error: No se pudieron obtener los outputs de Terraform. ¿Ya ejecutaste 'terraform apply' en el directorio infra/main/?"
  exit 1
fi

echo "✅ Región: $AWS_REGION"
echo "✅ ECR Registry: $ECR_REGISTRY"
echo "✅ ECR Backend: $BACKEND_ECR_REPO"
echo "✅ ECR Frontend: $FRONTEND_ECR_REPO"
echo "✅ S3 Bucket: $S3_BUCKET"
echo "✅ CodeDeploy App: $CODEDEPLOY_APP"
echo "✅ CodeDeploy Group: $CODEDEPLOY_GROUP"

# 3. Autenticación con ECR
echo ""
echo "🔐 Autenticando Docker con Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# 4. Construcción y subida de imágenes Docker
cd "$ROOT_DIR"

IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
echo ""
echo "🐳 [1/2] Construyendo y subiendo imagen del Backend (Tag: $IMAGE_TAG y latest)..."
docker build --platform linux/amd64 -t "${BACKEND_ECR_REPO}:${IMAGE_TAG}" -t "${BACKEND_ECR_REPO}:latest" ./backend
docker push "${BACKEND_ECR_REPO}:${IMAGE_TAG}"
docker push "${BACKEND_ECR_REPO}:latest"

echo ""
echo "🐳 [2/2] Construyendo y subiendo imagen del Frontend (Tag: $IMAGE_TAG y latest)..."
docker build --platform linux/amd64 -t "${FRONTEND_ECR_REPO}:${IMAGE_TAG}" -t "${FRONTEND_ECR_REPO}:latest" ./frontend
docker push "${FRONTEND_ECR_REPO}:${IMAGE_TAG}"
docker push "${FRONTEND_ECR_REPO}:latest"

# 5. Empaquetar artefacto y subir a S3
echo ""
echo "📦 Empaquetando artefactos de despliegue (appspec.yml, docker-compose.yml, scripts)..."
BUNDLE_FILE="/tmp/bundle-${IMAGE_TAG}.zip"
rm -f "$BUNDLE_FILE"

# Se empaqueta desde una carpeta temporal para añadir archivos generados sin ensuciar el repo
STAGE_DIR="$(mktemp -d)"
cp appspec.yml docker-compose.yml "$STAGE_DIR/"
cp -r scripts "$STAGE_DIR/scripts"
rm -f "$STAGE_DIR/scripts/deploy_local.sh"

# Versión de imagen de ESTA revisión (la lee start_app.sh)
echo "$IMAGE_TAG" > "$STAGE_DIR/scripts/VERSION"
# Espera opcional del hook ValidateService (0 = sin espera). Solo para la demo.
echo "${VALIDATE_SLEEP_SECONDS:-0}" > "$STAGE_DIR/scripts/VALIDATE_SLEEP"

(cd "$STAGE_DIR" && zip -r "$BUNDLE_FILE" appspec.yml docker-compose.yml scripts/)
rm -rf "$STAGE_DIR"

echo "☁️ Subiendo bundle a Amazon S3 (s3://${S3_BUCKET}/releases/app-${IMAGE_TAG}.zip)..."
aws s3 cp "$BUNDLE_FILE" "s3://${S3_BUCKET}/releases/app-${IMAGE_TAG}.zip"
rm -f "$BUNDLE_FILE"

# 6. Crear despliegue en CodeDeploy
echo ""
echo "🚀 Disparando despliegue en AWS CodeDeploy..."
DEPLOYMENT_ID=$(aws deploy create-deployment \
  --application-name "$CODEDEPLOY_APP" \
  --deployment-group-name "$CODEDEPLOY_GROUP" \
  --s3-location "bucket=${S3_BUCKET},key=releases/app-${IMAGE_TAG}.zip,bundleType=zip" \
  --description "Despliegue local tag ${IMAGE_TAG}" \
  --query "deploymentId" \
  --output text)

echo "✅ Despliegue creado con ID: $DEPLOYMENT_ID"
echo ""
echo "⏳ Monitoreando estado del despliegue en CodeDeploy..."
aws deploy wait deployment-successful --deployment-id "$DEPLOYMENT_ID" && DEPLOY_SUCCESS=true || DEPLOY_SUCCESS=false

if [ "$DEPLOY_SUCCESS" = true ]; then
  echo "🎉 ¡Despliegue completado con éxito!"
  echo ""
  echo "🌐 Puedes acceder a la aplicación a través del Application Load Balancer:"
  if [ -n "$ALB_DNS" ]; then
    echo "   👉 App (ALB): http://${ALB_DNS}"
    echo "   👉 Backend Health (ALB): http://${ALB_DNS}/api/health"
  fi
  if [ -n "$EC2_IPS" ]; then
    echo "   (Instancias EC2 individuales:)"
    for IP in $EC2_IPS; do
      echo "   - http://${IP}:3000"
    done
  fi
else
  echo "⚠️ El despliegue falló, fue detenido o sigue en progreso."
  aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
    --query 'deploymentInfo.{estado:status,error:errorInformation}' --output json
  exit 1
fi
