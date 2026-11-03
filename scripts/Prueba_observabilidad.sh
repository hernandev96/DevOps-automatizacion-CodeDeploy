#!/usr/bin/env bash
# ==============================================================================
# Script de Validación y Pruebas de Observabilidad (AWS CloudWatch + CodeDeploy)
# Proyecto: Calculadora Monorepo DevOps
# ==============================================================================
# Este script realiza pruebas exhaustivas sobre los componentes de observabilidad:
#   1. Verificación de configuración de alarmas y rollback en CodeDeploy
#   2. Consulta del estado y razones de las alarmas de CloudWatch
#   3. Comprobación del Log Group y Log Streams de CloudWatch Logs
#   4. Verificación de existencia del Dashboard de CloudWatch
#   5. Consulta de salud de las instancias en el Target Group del ALB
#   6. Prueba de tráfico HTTP al ALB (/api/health) con detección de errores
#   7. Simulación de transición de alarma (ALARM -> OK) para probar reactividad
#   8. Diagnóstico de errores de despliegues recientes en CodeDeploy
#   9. Generación de reporte completo en Markdown con diagnóstico de fallos
# ==============================================================================

set -uo pipefail

# Colores para la salida en consola
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Directorios de referencia
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra/main"

# Valores por defecto
ALB_URL=""
AWS_REGION="us-east-1"
CODEDEPLOY_APP="mi-app"
CODEDEPLOY_GROUP="produccion"
TARGET_GROUP_ARN=""
APP_LOG_GROUP="/calculadora/calculadora"
DASHBOARD_NAME="gh-miAppEstado"
ALARM_5XX="gh-alb-5xx"
OUTPUT_FILE="${ROOT_DIR}/reporte_observabilidad.md"
NUM_REQUESTS=30
SIMULATE_ALARM=true

# Listas de diagnóstico
CRITICAL_FAILURES=()
WARNINGS=()
PASSES=()

# ==============================================================================
# Banner y Uso
# ==============================================================================

print_banner() {
  echo -e "${CYAN}${BOLD}"
  echo "=============================================================================="
  echo "  🔭 VALIDACIÓN Y PRUEBAS DE OBSERVABILIDAD - AWS CLOUDWATCH & CODEDEPLOY"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  echo -e "${BOLD}Uso:${NC} $0 [opciones]"
  echo ""
  echo -e "${BOLD}Opciones:${NC}"
  echo "  -u, --url <URL>              URL base o DNS del ALB (ej. http://mi-alb.amazonaws.com)"
  echo "  -r, --region <REGION>        Región de AWS (default: us-east-1 o detectada)"
  echo "  -a, --app <APP>              Nombre de aplicación CodeDeploy (default: mi-app)"
  echo "  -g, --group <GROUP>          Nombre de Deployment Group CodeDeploy (default: produccion)"
  echo "  -t, --target-group <ARN>     ARN del Target Group de ALB"
  echo "  -l, --log-group <NAME>       Nombre del CloudWatch Log Group (default: /calculadora/calculadora)"
  echo "  -d, --dashboard <NAME>       Nombre del Dashboard CloudWatch (default: gh-miAppEstado)"
  echo "  -m, --alarm-name <NAME>      Nombre de la alarma 5xx para rollback (default: gh-alb-5xx)"
  echo "  -n, --requests <NUM>         Número de peticiones HTTP para probar el ALB (default: 30)"
  echo "  -o, --output <FILE>          Ruta del archivo de reporte Markdown (default: reporte_observabilidad.md)"
  echo "      --skip-alarm-simulation  Omitir simulación de disparo manual de alarma con set-alarm-state"
  echo "  -h, --help                   Mostrar esta ayuda"
  echo ""
  exit 0
}

# ==============================================================================
# Procesamiento de Argumentos de Línea de Comandos
# ==============================================================================

while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--url)
      ALB_URL="$2"
      shift 2
      ;;
    -r|--region)
      AWS_REGION="$2"
      shift 2
      ;;
    -a|--app)
      CODEDEPLOY_APP="$2"
      shift 2
      ;;
    -g|--group)
      CODEDEPLOY_GROUP="$2"
      shift 2
      ;;
    -t|--target-group)
      TARGET_GROUP_ARN="$2"
      shift 2
      ;;
    -l|--log-group)
      APP_LOG_GROUP="$2"
      shift 2
      ;;
    -d|--dashboard)
      DASHBOARD_NAME="$2"
      shift 2
      ;;
    -m|--alarm-name)
      ALARM_5XX="$2"
      shift 2
      ;;
    -n|--requests)
      NUM_REQUESTS="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --skip-alarm-simulation)
      SIMULATE_ALARM=false
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo -e "${RED}❌ Opción no reconocida: $1${NC}"
      usage
      ;;
  esac
done

# Asegurar extensión .md en el reporte
if [[ "$OUTPUT_FILE" != *.md ]]; then
  OUTPUT_FILE="${OUTPUT_FILE}.md"
fi

# Convertir ruta a absoluta si es relativa
if [[ "$OUTPUT_FILE" != /* ]]; then
  OUTPUT_FILE="$(pwd)/${OUTPUT_FILE}"
fi

print_banner

# ==============================================================================
# Verificación de Herramientas Requeridas
# ==============================================================================

echo -e "${BLUE}🔍 Verificando herramientas requeridas...${NC}"
for cmd in aws curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}❌ Error: '$cmd' no está instalado o no se encuentra en el PATH.${NC}"
    CRITICAL_FAILURES+=("Herramienta requerida ausente en el entorno: \`$cmd\`.")
  fi
done

# ==============================================================================
# Auto-detección desde Terraform / Variables de Entorno
# ==============================================================================

if [ -d "$INFRA_DIR" ]; then
  cd "$INFRA_DIR"
  if command -v terraform >/dev/null 2>&1; then
    if TF_JSON=$(terraform output -json 2>/dev/null); then
      [ -z "$ALB_URL" ] && ALB_URL=$(echo "$TF_JSON" | jq -r '.alb_dns_name.value // empty' | sed 's|^|http://|')
      [ -z "$TARGET_GROUP_ARN" ] && TARGET_GROUP_ARN=$(echo "$TF_JSON" | jq -r '.target_group_arn.value // empty')
      [ "$AWS_REGION" == "us-east-1" ] && AWS_REGION=$(echo "$TF_JSON" | jq -r '.aws_region.value // "us-east-1"')
      [ "$CODEDEPLOY_APP" == "mi-app" ] && CODEDEPLOY_APP=$(echo "$TF_JSON" | jq -r '.codedeploy_app_name.value // "mi-app"')
      [ "$CODEDEPLOY_GROUP" == "produccion" ] && CODEDEPLOY_GROUP=$(echo "$TF_JSON" | jq -r '.codedeploy_deployment_group_name.value // "produccion"')
      [ "$DASHBOARD_NAME" == "gh-miAppEstado" ] && DASHBOARD_NAME=$(echo "$TF_JSON" | jq -r '.cloudwatch_dashboard_name.value // "gh-miAppEstado"')
      [ "$APP_LOG_GROUP" == "/calculadora/calculadora" ] && APP_LOG_GROUP=$(echo "$TF_JSON" | jq -r '.app_log_group_name.value // "/calculadora/calculadora"')
      [ "$ALARM_5XX" == "gh-alb-5xx" ] && ALARM_5XX=$(echo "$TF_JSON" | jq -r '.codedeploy_alarm_name.value // "gh-alb-5xx"')
    fi
  fi
  cd "$ROOT_DIR"
fi

# Fallback desde variables de entorno si están presentes
[ -n "${ENV_AWS_REGION:-}" ] && AWS_REGION="$ENV_AWS_REGION"
[ -n "${AWS_DEFAULT_REGION:-}" ] && AWS_REGION="$AWS_DEFAULT_REGION"

# Normalizar URL del ALB
if [ -n "$ALB_URL" ]; then
  if [[ ! "$ALB_URL" =~ ^https?:// ]]; then
    ALB_URL="http://${ALB_URL}"
  fi
  ALB_URL="${ALB_URL%/}"
fi

echo -e "${BOLD}📋 Configuración de Validación de Observabilidad:${NC}"
echo -e "   • ${CYAN}Región AWS:${NC}               $AWS_REGION"
echo -e "   • ${CYAN}ALB Endpoint:${NC}             ${ALB_URL:-'No definido (se omitirá prueba HTTP)'}"
echo -e "   • ${CYAN}CodeDeploy App:${NC}           $CODEDEPLOY_APP"
echo -e "   • ${CYAN}CodeDeploy Group:${NC}         $CODEDEPLOY_GROUP"
echo -e "   • ${CYAN}Alarma Rollback (5xx):${NC}    $ALARM_5XX"
echo -e "   • ${CYAN}CloudWatch Log Group:${NC}     $APP_LOG_GROUP"
echo -e "   • ${CYAN}CloudWatch Dashboard:${NC}     $DASHBOARD_NAME"
echo -e "   • ${CYAN}Reporte Destino:${NC}          $OUTPUT_FILE"
echo ""

# ==============================================================================
# FASE 1: Verificación de CodeDeploy y Configuración de Rollback por Alarma
# ==============================================================================

echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 1: Configuración de Rollback Automático y Alarmas en CodeDeploy         ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CD_GROUP_RAW=""
CD_ALARM_ENABLED="false"
CD_ALARMS_LIST="[]"
CD_ROLLBACK_ENABLED="false"
CD_ROLLBACK_EVENTS="[]"

if command -v aws >/dev/null 2>&1; then
  echo -e "Consultando grupo de despliegue ${CYAN}${CODEDEPLOY_APP}/${CODEDEPLOY_GROUP}${NC}..."
  if CD_GROUP_RAW=$(aws deploy get-deployment-group \
      --application-name "$CODEDEPLOY_APP" \
      --deployment-group-name "$CODEDEPLOY_GROUP" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null); then

    CD_ALARM_ENABLED=$(echo "$CD_GROUP_RAW" | jq -r '.deploymentGroupInfo.alarmConfiguration.enabled // false')
    CD_ALARMS_LIST=$(echo "$CD_GROUP_RAW" | jq -c '.deploymentGroupInfo.alarmConfiguration.alarms // []')
    CD_ROLLBACK_ENABLED=$(echo "$CD_GROUP_RAW" | jq -r '.deploymentGroupInfo.autoRollbackConfiguration.enabled // false')
    CD_ROLLBACK_EVENTS=$(echo "$CD_GROUP_RAW" | jq -c '.deploymentGroupInfo.autoRollbackConfiguration.events // []')

    echo -e "   • Alarmas habilitadas en CodeDeploy: ${BOLD}$CD_ALARM_ENABLED${NC}"
    echo -e "   • Alarmas asociadas: ${BOLD}$CD_ALARMS_LIST${NC}"
    echo -e "   • Rollback automático habilitado: ${BOLD}$CD_ROLLBACK_ENABLED${NC}"
    echo -e "   • Eventos de Rollback: ${BOLD}$CD_ROLLBACK_EVENTS${NC}"

    # Validar Rollback
    if [ "$CD_ROLLBACK_ENABLED" == "true" ]; then
      PASSES+=("CodeDeploy tiene el rollback automático habilitado para eventos: \`$CD_ROLLBACK_EVENTS\`.")
    else
      CRITICAL_FAILURES+=("CodeDeploy: El rollback automático NO está habilitado (\`autoRollbackConfiguration.enabled = false\`).")
    fi

    # Validar Alarma de Rollback
    ALARM_ATTACHED=$(echo "$CD_ALARMS_LIST" | jq -r --arg a "$ALARM_5XX" '[.[] | select(.name == $a)] | length')
    if [ "$CD_ALARM_ENABLED" == "true" ] && [ "$ALARM_ATTACHED" -gt 0 ]; then
      PASSES+=("CodeDeploy tiene la alarma de CloudWatch \`$ALARM_5XX\` correctamente configurada para disparar rollback ante errores 5xx.")
    else
      if [ "$CD_ALARM_ENABLED" != "true" ]; then
        WARNINGS+=("CodeDeploy: La configuración de alarmas (\`alarmConfiguration.enabled\`) no está activada en el Deployment Group \`$CODEDEPLOY_GROUP\`.")
      else
        WARNINGS+=("CodeDeploy: La alarma \`$ALARM_5XX\` no figura en la lista de alarmas activas del Deployment Group.")
      fi
    fi
  else
    echo -e "${YELLOW}⚠️ No se pudo obtener información del Deployment Group de CodeDeploy (verifique permisos o si ya fue creado).${NC}"
    WARNINGS+=("No se pudo consultar el Deployment Group de CodeDeploy (\`$CODEDEPLOY_APP / $CODEDEPLOY_GROUP\`) vía AWS CLI.")
  fi
fi

# ==============================================================================
# FASE 2: Estado de las Alarmas de CloudWatch
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 2: Verificación de Alarmas en CloudWatch                                ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALL_ALARMS=("$ALARM_5XX" "gh-tg-healthy" "gh-alb-p99" "gh-asg-cpu-high" "gh-asg-mem-high")
ALARMS_TABLE_MD="| Alarma | Métrica | Condición / Umbral | Estado Actual | Razón del Estado |\n| :--- | :--- | :--- | :--- | :--- |\n"
FOUND_ALARMS_COUNT=0

for alarm_name in "${ALL_ALARMS[@]}"; do
  echo -e "Consultando alarma: ${CYAN}${alarm_name}${NC}..."
  ALARM_DATA=$(aws cloudwatch describe-alarms --alarm-names "$alarm_name" --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
  ALARM_COUNT=$(echo "$ALARM_DATA" | jq '.MetricAlarms | length // 0')

  if [ "$ALARM_COUNT" -gt 0 ]; then
    FOUND_ALARMS_COUNT=$((FOUND_ALARMS_COUNT + 1))
    STATE=$(echo "$ALARM_DATA" | jq -r '.MetricAlarms[0].StateValue // "UNKNOWN"')
    REASON=$(echo "$ALARM_DATA" | jq -r '.MetricAlarms[0].StateReason // "Sin razón provista"')
    METRIC=$(echo "$ALARM_DATA" | jq -r '.MetricAlarms[0].MetricName // "N/A"')
    OP=$(echo "$ALARM_DATA" | jq -r '.MetricAlarms[0].ComparisonOperator // ""')
    THRESH=$(echo "$ALARM_DATA" | jq -r '.MetricAlarms[0].Threshold // ""')

    case "$STATE" in
      "OK")
        STATE_ICON="🟢 OK"
        echo -e "   [${alarm_name}] -> ${GREEN}OK${NC} ($REASON)"
        PASSES+=("Alarma CloudWatch \`$alarm_name\` en estado saludable (\`OK\`).")
        ;;
      "ALARM")
        STATE_ICON="🔴 **ALARM**"
        echo -e "   [${alarm_name}] -> ${RED}ALARM${NC} ($REASON)"
        CRITICAL_FAILURES+=("Alarma CloudWatch \`$alarm_name\` está disparada en estado **ALARM**. Razón reportada por AWS: \"$REASON\".")
        ;;
      "INSUFFICIENT_DATA")
        STATE_ICON="🟡 INSUFFICIENT_DATA"
        echo -e "   [${alarm_name}] -> ${YELLOW}INSUFFICIENT_DATA${NC} ($REASON)"
        if [ "$alarm_name" == "gh-tg-healthy" ]; then
          # Para gh-tg-healthy, INSUFFICIENT_DATA suele tratarse como breaching
          WARNINGS+=("Alarma CloudWatch \`$alarm_name\` en estado INSUFFICIENT_DATA. Razón: \"$REASON\".")
        else
          PASSES+=("Alarma CloudWatch \`$alarm_name\` en espera de métricas (INSUFFICIENT_DATA / normal en entorno nuevo).")
        fi
        ;;
      *)
        STATE_ICON="⚪ $STATE"
        ;;
    esac

    # Limpiar saltos de línea en razón para no romper tabla Markdown
    SAFE_REASON=$(echo "$REASON" | tr '\n' ' ' | sed 's/|/-/g')
    ALARMS_TABLE_MD+="| \`$alarm_name\` | \`$METRIC\` | $OP $THRESH | $STATE_ICON | $SAFE_REASON |\n"
  else
    echo -e "   [${alarm_name}] -> ${RED}NO ENCONTRADA${NC}"
    ALARMS_TABLE_MD+="| \`$alarm_name\` | N/A | N/A | ❌ **NO EXISTE** | No se encontró la alarma en CloudWatch en $AWS_REGION |\n"
    CRITICAL_FAILURES+=("La alarma CloudWatch obligatoria \`$alarm_name\` no existe en la región \`$AWS_REGION\`.")
  fi
done

# ==============================================================================
# FASE 3: Verificación de CloudWatch Logs y Agente de CloudWatch
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 3: Verificación de CloudWatch Logs (Log Group y Streams)                 ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

LOGS_TABLE_MD=""
LOG_EVENTS_SNIPPET=""
LOG_GROUP_FOUND=false
LOG_STREAMS_COUNT=0

echo -e "Verificando log group: ${CYAN}${APP_LOG_GROUP}${NC}..."
LG_INFO=$(aws logs describe-log-groups --log-group-name-prefix "$APP_LOG_GROUP" --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
LG_COUNT=$(echo "$LG_INFO" | jq -r --arg g "$APP_LOG_GROUP" '[.logGroups[]? | select(.logGroupName == $g)] | length')

if [ "$LG_COUNT" -gt 0 ]; then
  LOG_GROUP_FOUND=true
  RETENTION=$(echo "$LG_INFO" | jq -r --arg g "$APP_LOG_GROUP" '.logGroups[] | select(.logGroupName == $g) | .retentionInDays // "Sin límite"')
  echo -e "   • Log Group: ${GREEN}EXISTE${NC} (Retención: $RETENTION días)"
  PASSES+=("CloudWatch Log Group \`$APP_LOG_GROUP\` existe con retención de $RETENTION días.")

  # Consultar streams
  LS_INFO=$(aws logs describe-log-streams --log-group-name "$APP_LOG_GROUP" --order-by LastEventTime --descending --max-items 5 --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
  LOG_STREAMS_COUNT=$(echo "$LS_INFO" | jq '.logStreams | length // 0')

  echo -e "   • Streams de log activos detectados: ${BOLD}$LOG_STREAMS_COUNT${NC}"

  if [ "$LOG_STREAMS_COUNT" -gt 0 ]; then
    PASSES+=("Se detectaron $LOG_STREAMS_COUNT streams de log activos en \`$APP_LOG_GROUP\`, confirmando que el agente de CloudWatch está recolectando logs de los contenedores.")
    FIRST_STREAM=$(echo "$LS_INFO" | jq -r '.logStreams[0].logStreamName // empty')

    if [ -n "$FIRST_STREAM" ]; then
      echo -e "   • Obteniendo eventos recientes del stream: ${CYAN}${FIRST_STREAM}${NC}..."
      EVENTS_JSON=$(aws logs get-log-events --log-group-name "$APP_LOG_GROUP" --log-stream-name "$FIRST_STREAM" --limit 10 --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
      RAW_MSGS=$(echo "$EVENTS_JSON" | jq -r '.events[].message // empty')

      if [ -n "$RAW_MSGS" ]; then
        LOG_EVENTS_SNIPPET=$(echo "$RAW_MSGS" | tail -n 10)
        echo -e "${GREEN}   ✅ Eventos de log obtenidos con éxito.${NC}"
      else
        LOG_EVENTS_SNIPPET="El stream '$FIRST_STREAM' está registrado pero aún no contiene eventos de mensaje."
      fi
    fi
  else
    echo -e "${YELLOW}   ⚠️ No se encontraron streams de log aún en $APP_LOG_GROUP.${NC}"
    WARNINGS+=("CloudWatch Logs: El Log Group \`$APP_LOG_GROUP\` existe pero aún no tiene streams activos (el CloudWatch Agent puede tardar 1-2 minutos en emitir el primer log o no tiene logs nuevos).")
    LOG_EVENTS_SNIPPET="No hay streams de log registrados aún en este Log Group."
  fi
else
  echo -e "${RED}   ❌ El Log Group $APP_LOG_GROUP no existe en CloudWatch.${NC}"
  CRITICAL_FAILURES+=("El Log Group de CloudWatch \`$APP_LOG_GROUP\` no existe. Las instancias no están enviando logs centralizados.")
  LOG_EVENTS_SNIPPET="Log Group no encontrado en CloudWatch."
fi

# ==============================================================================
# FASE 4: Verificación del Dashboard de CloudWatch
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 4: Verificación del Dashboard de CloudWatch                             ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

DASHBOARD_FOUND=false
DASHBOARD_WIDGETS=0
echo -e "Consultando dashboard: ${CYAN}${DASHBOARD_NAME}${NC}..."

if DASH_JSON=$(aws cloudwatch get-dashboard --dashboard-name "$DASHBOARD_NAME" --region "$AWS_REGION" --output json 2>/dev/null); then
  DASHBOARD_FOUND=true
  DASHBOARD_BODY=$(echo "$DASH_JSON" | jq -r '.DashboardBody // "{}"')
  DASHBOARD_WIDGETS=$(echo "$DASHBOARD_BODY" | jq '.widgets | length // 0')
  echo -e "   • Dashboard: ${GREEN}EXISTE${NC} con ${BOLD}${DASHBOARD_WIDGETS}${NC} widgets configurados."
  PASSES+=("CloudWatch Dashboard \`$DASHBOARD_NAME\` validado exitosamente con $DASHBOARD_WIDGETS widgets de monitoreo.")
else
  echo -e "${YELLOW}   ⚠️ No se pudo obtener el dashboard $DASHBOARD_NAME.${NC}"
  WARNINGS+=("El dashboard de CloudWatch \`$DASHBOARD_NAME\` no fue encontrado en la región \`$AWS_REGION\`.")
fi

# ==============================================================================
# FASE 5: Verificación de Salud del Target Group e Instancias EC2
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 5: Verificación de Salud de Instancias en el Target Group               ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

TG_TABLE_MD="| ID Instancia / Target | Puerto | Zona | Estado de Salud | Razón / Descripción |\n| :--- | :--- | :--- | :--- | :--- |\n"
TOTAL_TARGETS=0
HEALTHY_TARGETS=0
UNHEALTHY_TARGETS=0

if [ -n "$TARGET_GROUP_ARN" ]; then
  echo -e "Consultando Target Group ARN: ${CYAN}${TARGET_GROUP_ARN}${NC}..."
  if RAW_TG=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --region "$AWS_REGION" --output json 2>/dev/null); then
    TOTAL_TARGETS=$(echo "$RAW_TG" | jq '.TargetHealthDescriptions | length // 0')
    HEALTHY_TARGETS=$(echo "$RAW_TG" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
    UNHEALTHY_TARGETS=$(echo "$RAW_TG" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State != "healthy")] | length')

    echo -e "   • Instancias registradas: ${BOLD}$TOTAL_TARGETS${NC} (${GREEN}$HEALTHY_TARGETS saludables${NC}, ${RED}$UNHEALTHY_TARGETS no saludables${NC})"

    for row in $(echo "$RAW_TG" | jq -r '.TargetHealthDescriptions[] | @base64'); do
      _dec() { echo "$row" | base64 --decode | jq -r "$1"; }
      T_ID=$(_dec '.Target.Id')
      T_PORT=$(_dec '.Target.Port')
      T_AZ=$(_dec '.Target.AvailabilityZone // "N/A"')
      T_STATE=$(_dec '.TargetHealth.State')
      T_REASON=$(_dec '.TargetHealth.Reason // "Normal"')
      T_DESC=$(_dec '.TargetHealth.Description // ""')

      [ -n "$T_DESC" ] && T_REASON="$T_REASON: $T_DESC"

      if [ "$T_STATE" == "healthy" ]; then
        TG_TABLE_MD+="| \`$T_ID\` | $T_PORT | $T_AZ | 🟢 **$T_STATE** | $T_REASON |\n"
      else
        TG_TABLE_MD+="| \`$T_ID\` | $T_PORT | $T_AZ | 🔴 **$T_STATE** | $T_REASON |\n"
        CRITICAL_FAILURES+=("Target Group: Instancia \`$T_ID\` en estado **$T_STATE**. Causa: \"$T_REASON\".")
      fi
    done

    if [ "$HEALTHY_TARGETS" -gt 0 ] && [ "$UNHEALTHY_TARGETS" -eq 0 ]; then
      PASSES+=("Todas las instancias del Target Group ($HEALTHY_TARGETS/$TOTAL_TARGETS) reportan estado saludable (\`healthy\`).")
    elif [ "$HEALTHY_TARGETS" -eq 0 ]; then
      CRITICAL_FAILURES+=("Target Group: Ninguna instancia se encuentra en estado \`healthy\` ($HEALTHY_TARGETS/$TOTAL_TARGETS saludables). El balanceador no puede enrutar tráfico.")
    fi
  else
    echo -e "${YELLOW}   ⚠️ No se pudo consultar describe-target-health.${NC}"
    TG_TABLE_MD="_No se pudo obtener información de describe-target-health vía AWS CLI._\n"
    WARNINGS+=("No se pudo consultar el estado de salud de las instancias en el Target Group.")
  fi
else
  TG_TABLE_MD="_Target Group ARN no especificado o no detectado._\n"
fi

# ==============================================================================
# FASE 6: Verificación de Tráfico HTTP al ALB y Detección de Errores 5xx
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 6: Prueba de Tráfico HTTP hacia el Application Load Balancer            ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

HTTP_TOTAL=0
HTTP_200=0
HTTP_5XX=0
HTTP_OTHER=0
HTTP_CODES_SUMMARY=""
AVG_LATENCY_MS="0"

if [ -n "$ALB_URL" ]; then
  TEST_ENDPOINT="${ALB_URL}/api/health"
  echo -e "Enviando ${BOLD}${NUM_REQUESTS}${NC} peticiones a ${CYAN}${TEST_ENDPOINT}${NC}..."

  STATUS_ARRAY=()
  TOTAL_TIME_ACC=0

  for i in $(seq 1 "$NUM_REQUESTS"); do
    RESP=$(curl -s -o /dev/null -w "%{http_code}:%{time_total}" "$TEST_ENDPOINT" --max-time 4 || echo "000:0")
    CODE=$(echo "$RESP" | cut -d':' -f1)
    REQ_TIME=$(echo "$RESP" | cut -d':' -f2)

    STATUS_ARRAY+=("$CODE")
    TOTAL_TIME_ACC=$(python3 -c "print(round($TOTAL_TIME_ACC + float('$REQ_TIME'), 4))" 2>/dev/null || echo "$TOTAL_TIME_ACC")

    if [ "$CODE" == "200" ]; then
      HTTP_200=$((HTTP_200 + 1))
      echo -n -e "${GREEN}.${NC}"
    elif [[ "$CODE" =~ ^5[0-9]{2}$ ]]; then
      HTTP_5XX=$((HTTP_5XX + 1))
      echo -n -e "${RED}5${NC}"
    else
      HTTP_OTHER=$((HTTP_OTHER + 1))
      echo -n -e "${YELLOW}?${NC}"
    fi

    # Pausa corta entre peticiones
    sleep 0.1
  done
  echo ""

  HTTP_TOTAL="$NUM_REQUESTS"
  if [ "$HTTP_TOTAL" -gt 0 ]; then
    AVG_LATENCY_MS=$(python3 -c "print(round(($TOTAL_TIME_ACC / $HTTP_TOTAL) * 1000, 2))" 2>/dev/null || echo "0")
  fi

  # Conteo de códigos
  HTTP_CODES_SUMMARY=$(printf '%s\n' "${STATUS_ARRAY[@]}" | sort | uniq -c | awk '{print $2 ": " $1}' | tr '\n' ', ' | sed 's/, $//')

  echo -e "   • Respuestas HTTP 200 (OK): ${GREEN}${BOLD}${HTTP_200}/${HTTP_TOTAL}${NC}"
  echo -e "   • Respuestas HTTP 5xx:      ${RED}${BOLD}${HTTP_5XX}${NC}"
  echo -e "   • Otros códigos / Timeouts: ${YELLOW}${BOLD}${HTTP_OTHER}${NC}"
  echo -e "   • Distribución de códigos:  $HTTP_CODES_SUMMARY"
  echo -e "   • Latencia promedio:        ${AVG_LATENCY_MS} ms"

  if [ "$HTTP_5XX" -gt 0 ]; then
    CRITICAL_FAILURES+=("ALB HTTP 5xx detectados: Se recibieron $HTTP_5XX respuestas HTTP 5xx durante la prueba de tráfico en \`$TEST_ENDPOINT\` (códigos: $HTTP_CODES_SUMMARY).")
  elif [ "$HTTP_200" -eq "$HTTP_TOTAL" ]; then
    PASSES+=("Tráfico al ALB 100% exitoso: $HTTP_200/$HTTP_TOTAL peticiones respondieron HTTP 200 en \`/api/health\` con latencia promedio de ${AVG_LATENCY_MS} ms.")
  elif [ "$HTTP_200" -gt 0 ]; then
    WARNINGS+=("Tráfico al ALB parcialmente degradado: $HTTP_200/$HTTP_TOTAL respuestas exitosas (códigos: $HTTP_CODES_SUMMARY).")
  else
    CRITICAL_FAILURES+=("ALB sin respuesta: 0/$HTTP_TOTAL peticiones respondieron HTTP 200 en \`$TEST_ENDPOINT\`. El endpoint no está disponible (códigos: $HTTP_CODES_SUMMARY).")
  fi
else
  echo -e "${YELLOW}   ⚠️ No se especificó URL del ALB. Omitiendo prueba de tráfico HTTP.${NC}"
  WARNINGS+=("No se realizó la prueba de tráfico HTTP porque no se especificó la URL del ALB.")
fi

# ==============================================================================
# FASE 7: Simulación de Transición de Alarma y Restauración (CloudWatch)
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 7: Simulación de Disparo de Alarma y Auto-Recuperación                   ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALARM_SIM_SUCCESS=false
ALARM_SIM_DETAILS=""

if [ "$SIMULATE_ALARM" = true ] && [ "$FOUND_ALARMS_COUNT" -gt 0 ]; then
  echo -e "Probando reactividad de CloudWatch para la alarma: ${CYAN}${ALARM_5XX}${NC}..."

  # 1. Forzar estado ALARM
  echo -e "   1. Forzando estado ${RED}ALARM${NC} vía set-alarm-state..."
  if aws cloudwatch set-alarm-state \
      --alarm-name "$ALARM_5XX" \
      --state-value ALARM \
      --state-reason "Prueba controlada de observabilidad en CI/CD" \
      --region "$AWS_REGION" 2>/dev/null; then

    sleep 60
    CHECK_ALARM=$(aws cloudwatch describe-alarms --alarm-names "$ALARM_5XX" --region "$AWS_REGION" --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "UNKNOWN")

    if [ "$CHECK_ALARM" == "ALARM" ]; then
      echo -e "      ${GREEN}✅ Alarma pasó a estado ALARM correctamente.${NC}"

      # 2. Restaurar estado OK
      echo -e "   2. Restaurando estado a ${GREEN}OK${NC} vía set-alarm-state..."
      aws cloudwatch set-alarm-state \
        --alarm-name "$ALARM_5XX" \
        --state-value OK \
        --state-reason "Reinicio exitoso tras prueba de observabilidad en CI/CD" \
        --region "$AWS_REGION" 2>/dev/null || true

      sleep 2
      RESTORE_CHECK=$(aws cloudwatch describe-alarms --alarm-names "$ALARM_5XX" --region "$AWS_REGION" --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "UNKNOWN")

      if [ "$RESTORE_CHECK" == "OK" ]; then
        echo -e "      ${GREEN}✅ Alarma restaurada a estado OK correctamente.${NC}"
        ALARM_SIM_SUCCESS=true
        PASSES+=("Simulación de disparo de alarma \`$ALARM_5XX\` ejecutada con éxito (transición forzada a \`ALARM\` y restaurada a \`OK\`).")
        ALARM_SIM_DETAILS="La alarma \`$ALARM_5XX\` respondió adecuadamente a las llamadas de cambio de estado de CloudWatch (\`set-alarm-state\`), verificando que los eventos de alarma son procesables por los sistemas suscriptores (CodeDeploy / SNS)."
      else
        WARNINGS+=("Alarma \`$ALARM_5XX\`: Se forzó el estado ALARM pero no retornó a OK inmediatamente (quedó en \`$RESTORE_CHECK\`).")
        ALARM_SIM_DETAILS="La alarma entró en estado ALARM pero la restauración a OK reportó estado: \`$RESTORE_CHECK\`."
      fi
    else
      WARNINGS+=("No se pudo verificar la transición a ALARM para \`$ALARM_5XX\` (estado obtenido: \`$CHECK_ALARM\`).")
      ALARM_SIM_DETAILS="No se pudo confirmar la transición al estado ALARM."
    fi
  else
    echo -e "${YELLOW}   ⚠️ No se pudo ejecutar set-alarm-state (verifique permisos cloudwatch:SetAlarmState).${NC}"
    WARNINGS+=("Permisos insuficientes o error al ejecutar \`cloudwatch:SetAlarmState\` para \`$ALARM_5XX\`.")
    ALARM_SIM_DETAILS="No se pudo ejecutar la prueba de simulación por falta de permisos o error en la llamada API."
  fi
else
  ALARM_SIM_DETAILS="Simulación de alarma omitida (--skip-alarm-simulation o alarma no encontrada)."
fi

# ==============================================================================
# FASE 8: Auditoría de Despliegues de CodeDeploy (Causas de Fallo si aplica)
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 8: Diagnóstico de Despliegues Recientes en CodeDeploy                   ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

LATEST_DEP_ID=""
LATEST_DEP_STATUS="N/A"
LATEST_DEP_ERROR=""
LATEST_DEP_DETAILS=""

if command -v aws >/dev/null 2>&1; then
  echo -e "Consultando historial de despliegues en ${CYAN}${CODEDEPLOY_APP}/${CODEDEPLOY_GROUP}${NC}..."
  LATEST_DEP_ID=$(aws deploy list-deployments \
    --application-name "$CODEDEPLOY_APP" \
    --deployment-group-name "$CODEDEPLOY_GROUP" \
    --region "$AWS_REGION" \
    --query "deployments[0]" \
    --output text 2>/dev/null || echo "")

  if [ -n "$LATEST_DEP_ID" ] && [ "$LATEST_DEP_ID" != "None" ]; then
    DEP_INFO=$(aws deploy get-deployment --deployment-id "$LATEST_DEP_ID" --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
    LATEST_DEP_STATUS=$(echo "$DEP_INFO" | jq -r '.deploymentInfo.status // "UNKNOWN"')
    LATEST_DEP_ERROR=$(echo "$DEP_INFO" | jq -r '.deploymentInfo.errorInformation.message // empty')
    ERR_CODE=$(echo "$DEP_INFO" | jq -r '.deploymentInfo.errorInformation.code // empty')
    ROLLBACK_INFO=$(echo "$DEP_INFO" | jq -r '.deploymentInfo.rollbackInfo // empty')

    echo -e "   • Último Despliegue ID: ${BOLD}$LATEST_DEP_ID${NC} (Estado: ${BOLD}$LATEST_DEP_STATUS${NC})"

    if [ "$LATEST_DEP_STATUS" == "Succeeded" ]; then
      PASSES+=("Último despliegue de CodeDeploy (\`$LATEST_DEP_ID\`) finalizado con estado exitoso (\`Succeeded\`).")
    elif [ "$LATEST_DEP_STATUS" == "Failed" ] || [ "$LATEST_DEP_STATUS" == "Stopped" ]; then
      FAILURE_MSG="CodeDeploy Despliegue Fallido (\`$LATEST_DEP_ID\`): Estado \`$LATEST_DEP_STATUS\`."
      [ -n "$ERR_CODE" ] && FAILURE_MSG+=" Código de error: \`$ERR_CODE\`."
      [ -n "$LATEST_DEP_ERROR" ] && FAILURE_MSG+=" Razón: \"$LATEST_DEP_ERROR\"."
      [ -n "$ROLLBACK_INFO" ] && FAILURE_MSG+=" Rollback ejecutado: $ROLLBACK_INFO."

      # Buscar hook de ciclo de vida que falló
      FAILED_TARGET=$(aws deploy list-deployment-instances --deployment-id "$LATEST_DEP_ID" --region "$AWS_REGION" --query "instancesList[0]" --output text 2>/dev/null || echo "")
      if [ -n "$FAILED_TARGET" ] && [ "$FAILED_TARGET" != "None" ]; then
        HOOK_DIAG=$(aws deploy get-deployment-instance --deployment-id "$LATEST_DEP_ID" --instance-id "$FAILED_TARGET" --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
        FAILED_HOOK=$(echo "$HOOK_DIAG" | jq -r '.instanceSummary.lifecycleEvents[] | select(.status == "Failed") | .lifecycleEventName' 2>/dev/null || echo "")
        HOOK_ERR=$(echo "$HOOK_DIAG" | jq -r '.instanceSummary.lifecycleEvents[] | select(.status == "Failed") | .diagnostics.message' 2>/dev/null || echo "")
        if [ -n "$FAILED_HOOK" ]; then
          FAILURE_MSG+=" [Lifecycle Hook con Fallo: \`$FAILED_HOOK\` — $HOOK_ERR]"
        fi
      fi

      CRITICAL_FAILURES+=("$FAILURE_MSG")
      LATEST_DEP_DETAILS="$FAILURE_MSG"
    else
      echo -e "   • Despliegue en progreso o estado intermedio: $LATEST_DEP_STATUS"
    fi
  else
    echo -e "   • No se registraron despliegues previos en CodeDeploy."
  fi
fi

# ==============================================================================
# Determinación del Veredicto Global
# ==============================================================================

GLOBAL_STATUS="PASSED"
STATUS_BADGE="🟢 **SUPERADO / SALUDABLE**"

if [ "${#CRITICAL_FAILURES[@]}" -gt 0 ]; then
  GLOBAL_STATUS="FAILED"
  STATUS_BADGE="🔴 **FALLIDO (Anomalías o Fallos Críticos Detectados)**"
elif [ "${#WARNINGS[@]}" -gt 0 ]; then
  GLOBAL_STATUS="WARNING"
  STATUS_BADGE="🟡 **ADVERTENCIA (Comportamiento Parcial o Incompleto)**"
fi

# ==============================================================================
# Generación del Reporte Markdown
# ==============================================================================

echo -e "\n${BLUE}📝 Generando reporte de observabilidad en: ${BOLD}${OUTPUT_FILE}${NC}..."
CURRENT_DATETIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Construir sección de diagnóstico de fallos
DIAGNOSTIC_MD=""
if [ "${#CRITICAL_FAILURES[@]}" -gt 0 ]; then
  DIAGNOSTIC_MD+="> [!CAUTION]\n"
  DIAGNOSTIC_MD+="> ### 🚨 Fallos Críticos Detectados\n"
  DIAGNOSTIC_MD+="> El sistema de observabilidad o infraestructura presenta fallas que requieren atención inmediata:\n>\n"
  for f in "${CRITICAL_FAILURES[@]}"; do
    DIAGNOSTIC_MD+="> - ❌ $f\n"
  done
  DIAGNOSTIC_MD+="\n"
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  DIAGNOSTIC_MD+="> [!WARNING]\n"
  DIAGNOSTIC_MD+="> ### ⚠️ Advertencias Operacionales\n"
  for w in "${WARNINGS[@]}"; do
    DIAGNOSTIC_MD+="> - ⚠️ $w\n"
  done
  DIAGNOSTIC_MD+="\n"
fi

if [ "${#CRITICAL_FAILURES[@]}" -eq 0 ] && [ "${#WARNINGS[@]}" -eq 0 ]; then
  DIAGNOSTIC_MD+="> [!NOTE]\n"
  DIAGNOSTIC_MD+="> ### ✅ Todos los Componentes de Observabilidad se encuentran Saludables\n"
  DIAGNOSTIC_MD+="> Las alarmas de CloudWatch, el rollback en CodeDeploy, los logs de contenedores y los health checks del ALB pasaron las pruebas sin anomalías.\n\n"
fi

# Construir lista de verificaciones exitosas
PASSES_MD=""
for p in "${PASSES[@]}"; do
  PASSES_MD+="- ✅ $p\n"
done

# Escribir archivo Markdown
cat << EOF > "$OUTPUT_FILE"
# 🔭 Reporte de Validación de Observabilidad y Monitoreo (CloudWatch & CodeDeploy)

> **Fecha y Hora:** ${CURRENT_DATETIME}  
> **Estado General:** ${STATUS_BADGE}  
> **Proyecto:** Calculadora Monorepo DevOps (AWS CloudWatch + CodeDeploy + ALB)  
> **Región AWS:** \`${AWS_REGION}\`  

---

## 1. 📌 Resumen Ejecutivo

Este informe consolida los resultados de las comprobaciones de **observabilidad, métricas, logs, alarmas y rollback automático** en AWS para garantizar la estabilidad operativa del entorno.

| Parámetro Evaluado | Valor / Estado |
| :--- | :--- |
| **Veredicto General** | ${STATUS_BADGE} |
| **Endpoint del ALB** | \`${ALB_URL:-'N/A'}\` |
| **Aplicación CodeDeploy** | \`${CODEDEPLOY_APP}\` / Grupo: \`${CODEDEPLOY_GROUP}\` |
| **Alarma Principal Rollback (5xx)** | \`${ALARM_5XX}\` |
| **Log Group de Contenedores** | \`${APP_LOG_GROUP}\` |
| **Dashboard de CloudWatch** | \`${DASHBOARD_NAME}\` |
| **Instancias Saludables (Target Group)** | **${HEALTHY_TARGETS} / ${TOTAL_TARGETS}** |
| **Éxito de Peticiones HTTP al ALB** | **${HTTP_200} / ${HTTP_TOTAL}** (${AVG_LATENCY_MS} ms latencia prom.) |
| **Fallos Críticos Detectados** | **${#CRITICAL_FAILURES[@]}** |
| **Advertencias** | **${#WARNINGS[@]}** |

---

## 2. 🚨 Diagnóstico de Errores y Razones de Fallo

$(echo -e "$DIAGNOSTIC_MD")

### Verificaciones Exitosas Registradas
$(echo -e "$PASSES_MD")

---

## 3. ⏰ Estado de Alarmas de CloudWatch

A continuación se detalla el estado actual de cada una de las alarmas aprovisionadas para el sistema:

$(echo -e "$ALARMS_TABLE_MD")

- **Total de Alarmas Auditadas:** ${#ALL_ALARMS[@]}
- **Alarmas Encontradas en AWS:** ${FOUND_ALARMS_COUNT}

---

## 4. 🔄 Integración con AWS CodeDeploy & Rollback Automático

Configuración de resiliencia y auto-remediación ante despliegues defectuosos:

| Parámetro | Configuración Detectada | Evaluación |
| :--- | :--- | :--- |
| **Rollback Automático** | \`$CD_ROLLBACK_ENABLED\` | $([ "$CD_ROLLBACK_ENABLED" == "true" ] && echo "🟢 Habilitado" || echo "🔴 Deshabilitado") |
| **Eventos de Disparo de Rollback** | \`$CD_ROLLBACK_EVENTS\` | $(echo "$CD_ROLLBACK_EVENTS" | grep -q "DEPLOYMENT_STOP_ON_ALARM" && echo "🟢 Incluye Alarmas" || echo "🟡 Solo fallos directos") |
| **Monitoreo de Alarmas en Deploy** | \`$CD_ALARM_ENABLED\` | $([ "$CD_ALARM_ENABLED" == "true" ] && echo "🟢 Activo" || echo "🟡 Inactivo") |
| **Alarmas Asociadas al Grupo** | \`$CD_ALARMS_LIST\` | $(echo "$CD_ALARMS_LIST" | grep -q "$ALARM_5XX" && echo "🟢 \`$ALARM_5XX\` Vinculada" || echo "🟡 Sin alarma 5xx vinculada") |
| **Último Despliegue Evaluado** | \`${LATEST_DEP_ID:-Ninguno}\` | **\`$LATEST_DEP_STATUS\`** |

$([ -n "$LATEST_DEP_DETAILS" ] && echo -e "\n> **Detalle del Último Despliegue:**\n> $LATEST_DEP_DETAILS\n" || echo "")

---

## 5. 🏥 Salud del Target Group e Instancias EC2

Distribución de salud de las instancias en el balanceador de carga:

$(echo -e "$TG_TABLE_MD")

- **Instancias Totales:** ${TOTAL_TARGETS}
- **Instancias Saludables (\`healthy\`):** ${HEALTHY_TARGETS}
- **Instancias Degradadas (\`unhealthy\`):** ${UNHEALTHY_TARGETS}

---

## 6. 🌐 Verificación de Tráfico HTTP y Resiliencia del ALB

Prueba sintética de conectividad al endpoint de salud (\`/api/health\`):

| Métrica | Resultado |
| :--- | :--- |
| **Total Peticiones Enviadas** | ${HTTP_TOTAL} |
| **Respuestas Exitosas (HTTP 200)** | \`${HTTP_200}\` |
| **Errores de Servidor (HTTP 5xx)** | \`${HTTP_5XX}\` |
| **Otros Códigos / Timeouts** | \`${HTTP_OTHER}\` |
| **Desglose de Códigos Recibidos** | \`${HTTP_CODES_SUMMARY:-'N/A'}\` |
| **Latencia Promedio** | **${AVG_LATENCY_MS} ms** |

---

## 7. 📜 Logs de la Aplicación en CloudWatch Logs

El CloudWatch Agent recolecta los logs consolidados de FastAPI y Nginx:

- **Log Group:** \`${APP_LOG_GROUP}\`
- **Estado del Log Group:** $([ "$LOG_GROUP_FOUND" = true ] && echo "🟢 Registrado en AWS" || echo "🔴 No encontrado")
- **Streams Activos Detectados:** **${LOG_STREAMS_COUNT}**

#### Muestra de Eventos Recientes de Log:
\`\`\`text
${LOG_EVENTS_SNIPPET}
\`\`\`

---

## 8. 📊 Dashboard de Monitoreo CloudWatch

- **Dashboard:** \`${DASHBOARD_NAME}\`
- **Estado:** $([ "$DASHBOARD_FOUND" = true ] && echo "🟢 Disponible en consola AWS" || echo "🟡 No encontrado")
- **Número de Widgets:** **${DASHBOARD_WIDGETS}** widgets de métricas y logs

---

## 9. 🧪 Simulación de Disparo de Alarma

- **Resultado de la Simulación:** $([ "$ALARM_SIM_SUCCESS" = true ] && echo "🟢 Exitoso" || echo "🟡 No ejecutado / Advertencia")
- **Detalle:** ${ALARM_SIM_DETAILS}

---
*Reporte generado automáticamente por \`scripts/Prueba_observabilidad.sh\`.*
EOF

echo -e "${GREEN}✅ Reporte de observabilidad generado exitosamente:${NC} ${BOLD}${OUTPUT_FILE}${NC}"

# ==============================================================================
# Salida Final
# ==============================================================================

if [ "$GLOBAL_STATUS" == "FAILED" ]; then
  echo -e "\n${RED}==============================================================================${NC}"
  echo -e "${RED}${BOLD}  ❌ Las pruebas de observabilidad han detectado FALLOS CRÍTICOS.${NC}"
  echo -e "${RED}  Revisa el reporte para conocer las razones específicas de las fallas.${NC}"
  echo -e "${RED}==============================================================================${NC}\n"
  exit 1
elif [ "$GLOBAL_STATUS" == "WARNING" ]; then
  echo -e "\n${YELLOW}==============================================================================${NC}"
  echo -e "${YELLOW}${BOLD}  ⚠️ Pruebas de observabilidad completadas con ADVERTENCIAS.${NC}"
  echo -e "${YELLOW}==============================================================================${NC}\n"
  exit 0
else
  echo -e "\n${CYAN}==============================================================================${NC}"
  echo -e "${GREEN}${BOLD}  🎉 ¡Todas las pruebas de observabilidad se completaron con ÉXITO!${NC}"
  echo -e "${CYAN}==============================================================================${NC}\n"
  exit 0
fi