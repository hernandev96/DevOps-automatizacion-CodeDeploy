#!/bin/bash
# ==============================================================================
# Script para probar rollback en despliegue Blue/Green con AWS CodeDeploy
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra/main"

usage() {
  cat << 'EOF'
Uso: ./scripts/test_rollback.sh [OPCIÓN]

Opciones:
  trigger-fail    Despliega una revisión nueva forzando fallo en ValidateService
                  (establece VALIDATE_SLEEP_SECONDS>0 para dar tiempo a alarma/rollback)
  monitor         Monitorea el último despliegue creado (o el ID dado)
  status          Muestra estado del último despliegue y configuración
  manual-rollback Detiene el despliegue en curso y fuerza rollback (si está en progreso)
  help            Muestra esta ayuda

Variables de entorno:
  VALIDATE_SLEEP_SECONDS  Segundos que espera validate_service.sh (default: 120)
  DEPLOYMENT_ID           ID de despliegue a monitorizar/actuar sobre él

Ejemplos:
  # 1) Disparar despliegue que provocará rollback (demo)
  VALIDATE_SLEEP_SECONDS=120 ./scripts/test_rollback.sh trigger-fail

  # 2) Monitorear el despliegue
  ./scripts/test_rollback.sh monitor

  # 3) Detener y forzar rollback manualmente si está corriendo
  ./scripts/test_rollback.sh manual-rollback
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta: $1"; exit 1; }
}

get_tf_outputs() {
  cd "$INFRA_DIR"
  TF_JSON=$(terraform output -json 2>/dev/null || echo '{}')
  AWS_REGION=$(echo "$TF_JSON" | jq -r '.aws_region.value // "us-east-1"')
  ECR_REGISTRY=$(echo "$TF_JSON" | jq -r '.ecr_registry_url.value // empty')
  BACKEND_ECR_REPO=$(echo "$TF_JSON" | jq -r '.ecr_backend_repository_url.value // empty')
  FRONTEND_ECR_REPO=$(echo "$TF_JSON" | jq -r '.ecr_frontend_repository_url.value // empty')
  S3_BUCKET=$(echo "$TF_JSON" | jq -r '.s3_bucket_name.value // empty')
  CODEDEPLOY_APP=$(echo "$TF_JSON" | jq -r '.codedeploy_app_name.value // empty')
  CODEDEPLOY_GROUP=$(echo "$TF_JSON" | jq -r '.codedeploy_deployment_group_name.value // empty')
  ALB_DNS=$(echo "$TF_JSON" | jq -r '.alb_dns_name.value // empty')
}

check_prereqs() {
  require aws
  require docker
  require terraform
  require jq
  require git
  require curl
}

show_status() {
  get_tf_outputs
  echo "========================================================"
  echo "📊 Estado actual (Blue/Green + CodeDeploy)"
  echo "========================================================"
  echo "Región:        $AWS_REGION"
  echo "App:           $CODEDEPLOY_APP"
  echo "Deployment Grp:$CODEDEPLOY_GROUP"
  echo "S3 Bucket:     $S3_BUCKET"
  echo "ALB:           ${ALB_DNS:-N/A}"
  echo "========================================================"
  echo ""
  echo "🔍 Deployment Group:"
  aws deploy get-deployment-group \
    --application-name "$CODEDEPLOY_APP" \
    --deployment-group-name "$CODEDEPLOY_GROUP" \
    --region "$AWS_REGION" \
    --query 'deploymentGroupInfo.{deploymentStyle:deploymentStyle,blueGreen:blueGreenDeploymentConfiguration,alarms:alarmConfiguration,autoRollback:autoRollbackConfiguration}' \
    --output json || true
  echo ""
  echo "📜 Últimos despliegues:"
  aws deploy list-deployments \
    --application-name "$CODEDEPLOY_APP" \
    --deployment-group-name "$CODEDEPLOY_GROUP" \
    --region "$AWS_REGION" \
    --max-items 5 \
    --query 'deployments' \
    --output table || true
}

trigger_fail() {
  check_prereqs
  get_tf_outputs
  
  if [ -z "${CODEDEPLOY_APP:-}" ] || [ -z "${CODEDEPLOY_GROUP:-}" ] || [ -z "${S3_BUCKET:-}" ]; then
    echo "❌ Faltan outputs de Terraform. Ejecuta 'terraform apply' en infra/main/"
    exit 1
  fi
  
  SLEEP="${VALIDATE_SLEEP_SECONDS:-120}"
  echo "========================================================"
  echo "🧪 PRUEBA DE ROLLBACK - Despliegue con fallo forzado"
  echo "========================================================"
  echo "ValidateService esperará ${SLEEP}s antes de validar"
  echo "Esto da tiempo a que las alarmas (gh-alb-5xx) actúen"
  echo "y CodeDeploy ejecute rollback automático (Blue/Green)"
  echo "========================================================"
  echo ""
  
  # Construir y subir imágenes con tag nuevo para forzar revisión distinta
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
  cd "$ROOT_DIR"
  IMAGE_TAG="rollback-test-$(date +%s)"
  
  echo "🐳 Construyendo imágenes con tag: $IMAGE_TAG"
  docker build --platform linux/amd64 -t "${BACKEND_ECR_REPO}:${IMAGE_TAG}" ./backend >/dev/null
  docker build --platform linux/amd64 -t "${FRONTEND_ECR_REPO}:${IMAGE_TAG}" ./frontend >/dev/null
  docker push "${BACKEND_ECR_REPO}:${IMAGE_TAG}" >/dev/null
  docker push "${FRONTEND_ECR_REPO}:${IMAGE_TAG}" >/dev/null
  
  # Empaquetar bundle con VALIDATE_SLEEP
  echo "📦 Empaquetando bundle con VALIDATE_SLEEP=${SLEEP}"
  BUNDLE_FILE="/tmp/bundle-${IMAGE_TAG}.zip"
  STAGE_DIR="$(mktemp -d)"
  cp appspec.yml docker-compose.yml "$STAGE_DIR/"
  mkdir -p "$STAGE_DIR/scripts"
  cp scripts/before_install.sh scripts/after_install.sh scripts/start_app.sh scripts/validate_service.sh "$STAGE_DIR/scripts/"
  echo "$IMAGE_TAG" > "$STAGE_DIR/scripts/VERSION"
  echo "$SLEEP" > "$STAGE_DIR/scripts/VALIDATE_SLEEP"
  (cd "$STAGE_DIR" && zip -r "$BUNDLE_FILE" appspec.yml docker-compose.yml scripts/ >/dev/null)
  rm -rf "$STAGE_DIR"
  
  echo "☁️  Subiendo a S3..."
  aws s3 cp "$BUNDLE_FILE" "s3://${S3_BUCKET}/releases/app-${IMAGE_TAG}.zip" --region "$AWS_REGION" >/dev/null
  rm -f "$BUNDLE_FILE"
  
  echo "🚀 Creando despliegue que fallará intencionalmente..."
  DEPLOYMENT_ID=$(aws deploy create-deployment \
    --application-name "$CODEDEPLOY_APP" \
    --deployment-group-name "$CODEDEPLOY_GROUP" \
    --s3-location "bucket=${S3_BUCKET},key=releases/app-${IMAGE_TAG}.zip,bundleType=zip" \
    --description "ROLLBACK-TEST: fallo forzado con VALIDATE_SLEEP=${SLEEP}" \
    --query "deploymentId" \
    --output text \
    --region "$AWS_REGION")
  
  echo "✅ Deployment ID: $DEPLOYMENT_ID"
  echo ""
  echo "💡 Monitorea con:"
  echo "   DEPLOYMENT_ID=$DEPLOYMENT_ID ./scripts/test_rollback.sh monitor"
  echo "   o"
  echo "   aws deploy get-deployment --deployment-id $DEPLOYMENT_ID --region $AWS_REGION"
  echo ""
}

monitor() {
  check_prereqs
  get_tf_outputs
  DEP_ID="${DEPLOYMENT_ID:-}"
  if [ -z "$DEP_ID" ]; then
    echo "🔍 Buscando último despliegue..."
    DEP_ID=$(aws deploy list-deployments \
      --application-name "$CODEDEPLOY_APP" \
      --deployment-group-name "$CODEDEPLOY_GROUP" \
      --region "$AWS_REGION" \
      --max-items 1 \
      --query 'deployments[0]' \
      --output text)
  fi
  if [ -z "$DEP_ID" ] || [ "$DEP_ID" = "None" ]; then
    echo "❌ No hay despliegues para monitorear"
    exit 1
  fi
  echo "========================================================"
  echo "👀 Monitoreando despliegue: $DEP_ID"
  echo "========================================================"
  for i in {1..60}; do
    INFO=$(aws deploy get-deployment --deployment-id "$DEP_ID" --region "$AWS_REGION" --output json)
    STATUS=$(echo "$INFO" | jq -r '.deploymentInfo.status')
    ERROR=$(echo "$INFO" | jq -r '.deploymentInfo.errorInformation.message // empty')
    ROLLBACK=$(echo "$INFO" | jq -r '.deploymentInfo.rollbackInfo.rollbackDeploymentId // empty')
    echo "[$(date +%H:%M:%S)] Estado: $STATUS${ERROR:+ | Error: $ERROR}${ROLLBACK:+ | Rollback dep: $ROLLBACK}"
    if [ "$STATUS" = "Succeeded" ] || [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Stopped" ]; then
      echo "========================================================"
      echo "$INFO" | jq '.deploymentInfo.{status,creator,errorInformation,rollbackInfo,completeTime}'
      break
    fi
    sleep 10
  done
}

manual_rollback() {
  check_prereqs
  get_tf_outputs
  DEP_ID="${DEPLOYMENT_ID:-}"
  if [ -z "$DEP_ID" ]; then
    echo "🔍 Buscando despliegue en curso..."
    DEP_ID=$(aws deploy list-deployments \
      --application-name "$CODEDEPLOY_APP" \
      --deployment-group-name "$CODEDEPLOY_GROUP" \
      --region "$AWS_REGION" \
      --include-only-statuses "InProgress" \
      --max-items 1 \
      --query 'deployments[0]' \
      --output text)
  fi
  if [ -z "$DEP_ID" ] || [ "$DEP_ID" = "None" ]; then
    echo "❌ No hay despliegue en progreso para detener"
    exit 1
  fi
  echo "🛑 Deteniendo despliegue $DEP_ID con rollback automático habilitado..."
  aws deploy stop-deployment \
    --deployment-id "$DEP_ID" \
    --auto-rollback-enabled \
    --region "$AWS_REGION" || true
  echo "✅ Solicitud enviada. Usa 'monitor' para seguir el estado."
}

case "${1:-help}" in
  trigger-fail) trigger_fail ;;
  monitor) monitor ;;
  status) show_status ;;
  manual-rollback) manual_rollback ;;
  help|*) usage ;;
esac
