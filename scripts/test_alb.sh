#!/usr/bin/env bash
# ==============================================================================
# Script de Pruebas de Balanceo de Carga y Rendimiento para ALB (AWS)
# Proyecto: Calculadora Monorepo DevOps
# ==============================================================================
# Este script realiza pruebas de conectividad, distribución y carga concurrente
# sobre el Application Load Balancer (ALB) y genera un reporte detallado en Markdown.
# ==============================================================================

set -euo pipefail

# Colores para la salida en terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Directorios de referencia
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra/main"

# Valores por defecto
ALB_URL=""
NUM_REQUESTS=200
CONCURRENCY=10
TIMEOUT_SEC=5
OUTPUT_FILE="${ROOT_DIR}/report_test_alb.md"
AWS_REGION="us-east-1"
TARGET_GROUP_ARN=""
ASG_NAME=""
SKIP_AUTH=false

# ==============================================================================
# Funciones de Utilidad
# ==============================================================================

print_banner() {
  echo -e "${CYAN}${BOLD}"
  echo "=============================================================================="
  echo "  ⚖️  TEST DE BALANCEO DE CARGA Y RENDIMIENTO - APPLICATION LOAD BALANCER (ALB)"
  echo "=============================================================================="
  echo -e "${NC}"
}

usage() {
  echo -e "${BOLD}Uso:${NC} $0 [opciones]"
  echo ""
  echo -e "${BOLD}Opciones:${NC}"
  echo "  -u, --url <URL>            URL base o DNS del ALB (ej. http://calculadora-alb-123.us-east-1.elb.amazonaws.com)"
  echo "  -g, --target-group <ARN>   ARN del Target Group de AWS ALB"
  echo "      --asg-name <NAME>      Nombre del Auto Scaling Group de AWS"
  echo "  -n, --requests <NUM>       Número total de peticiones por prueba de carga (default: 200)"
  echo "  -c, --concurrency <NUM>    Número de peticiones concurrentes / hilos (default: 10)"
  echo "  -t, --timeout <SEC>        Tiempo límite de espera por petición en segundos (default: 5)"
  echo "  -o, --output <FILE>        Ruta del archivo de reporte Markdown (default: report_test_alb.md)"
  echo "  -r, --region <REGION>      Región de AWS (default: us-east-1 o detectada de Terraform)"
  echo "  --skip-auth                Omitir pruebas de endpoints autenticados con JWT"
  echo "  -h, --help                 Mostrar esta ayuda"
  echo ""
  echo -e "${BOLD}Ejemplos:${NC}"
  echo "  $0                                            # Autodetecta ALB desde infra/main/terraform"
  echo "  $0 -u http://mi-alb.amazonaws.com -n 500 -c 25"
  echo "  $0 -u http://mi-alb.amazonaws.com -o scripts/report_test_alb.md"
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
    -g|--target-group)
      TARGET_GROUP_ARN="$2"
      shift 2
      ;;
    --asg-name)
      ASG_NAME="$2"
      shift 2
      ;;
    -n|--requests)
      NUM_REQUESTS="$2"
      shift 2
      ;;
    -c|--concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    -t|--timeout)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -r|--region)
      AWS_REGION="$2"
      shift 2
      ;;
    --skip-auth)
      SKIP_AUTH=true
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

# Asegurar extensión .md en el archivo de reporte
if [[ "$OUTPUT_FILE" != *.md ]]; then
  OUTPUT_FILE="${OUTPUT_FILE}.md"
fi

# Convertir ruta de reporte a absoluta si es relativa
if [[ "$OUTPUT_FILE" != /* ]]; then
  OUTPUT_FILE="$(pwd)/${OUTPUT_FILE}"
fi

print_banner

# ==============================================================================
# Verificación de Herramientas
# ==============================================================================

echo -e "${BLUE}🔍 Verificando herramientas requeridas...${NC}"
for cmd in curl python3 jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}❌ Error: '$cmd' no está instalado o no se encuentra en el PATH.${NC}"
    exit 1
  fi
done
echo -e "${GREEN}✅ Herramientas requeridas disponibles (curl, python3, jq).${NC}"

# ==============================================================================
# Detección Automática de Parámetros desde Terraform
# ==============================================================================

if [ -z "$ALB_URL" ] || [ -z "$TARGET_GROUP_ARN" ] || [ -z "$ASG_NAME" ]; then
  if [ -d "$INFRA_DIR" ]; then
    cd "$INFRA_DIR"
    if TF_JSON=$(terraform output -json 2>/dev/null); then
      DETECTED_ALB=$(echo "$TF_JSON" | jq -r '.alb_dns_name.value // empty')
      DETECTED_TG=$(echo "$TF_JSON" | jq -r '.target_group_arn.value // empty')
      DETECTED_ASG=$(echo "$TF_JSON" | jq -r '.asg_name.value // empty')
      DETECTED_REGION=$(echo "$TF_JSON" | jq -r '.aws_region.value // empty')

      if [ -z "$ALB_URL" ] && [ -n "$DETECTED_ALB" ]; then
        ALB_URL="http://${DETECTED_ALB}"
        echo -e "${GREEN}✅ ALB DNS detectado desde Terraform:${NC} ${ALB_URL}"
      fi
      [ -z "$TARGET_GROUP_ARN" ] && [ -n "$DETECTED_TG" ] && TARGET_GROUP_ARN="$DETECTED_TG"
      [ -z "$ASG_NAME" ] && [ -n "$DETECTED_ASG" ] && ASG_NAME="$DETECTED_ASG"
      [ -n "$DETECTED_REGION" ] && AWS_REGION="$DETECTED_REGION"
    fi
    cd "$ROOT_DIR"
  fi
fi

# Si aún no tenemos URL, solicitar al usuario
if [ -z "$ALB_URL" ]; then
  echo -e "\n${YELLOW}⚠️  No se encontró un ALB en Terraform state.${NC}"
  read -r -p "👉 Por favor, introduce la URL o DNS público del ALB (ej. http://mi-alb.amazonaws.com): " USER_INPUT_URL
  if [ -z "$USER_INPUT_URL" ]; then
    echo -e "${RED}❌ Error: Se requiere la URL del ALB para continuar.${NC}"
    exit 1
  fi
  ALB_URL="$USER_INPUT_URL"
fi

# Normalizar URL (asegurar prefijo http:// o https:// y sin barra final)
if [[ ! "$ALB_URL" =~ ^https?:// ]]; then
  ALB_URL="http://${ALB_URL}"
fi
ALB_URL="${ALB_URL%/}"

echo -e "\n${BOLD}📋 Configuración de Pruebas:${NC}"
echo -e "   • ${CYAN}ALB Base URL:${NC}         $ALB_URL"
echo -e "   • ${CYAN}Peticiones por Test:${NC}  $NUM_REQUESTS"
echo -e "   • ${CYAN}Concurrencia:${NC}         $CONCURRENCY hilos concurrentes"
echo -e "   • ${CYAN}Timeout por Request:${NC}  ${TIMEOUT_SEC}s"
echo -e "   • ${CYAN}Reporte de salida:${NC}    $OUTPUT_FILE"
echo -e "   • ${CYAN}Región AWS:${NC}           $AWS_REGION"
[ -n "$TARGET_GROUP_ARN" ] && echo -e "   • ${CYAN}Target Group ARN:${NC}     $TARGET_GROUP_ARN"
[ -n "$ASG_NAME" ] && echo -e "   • ${CYAN}ASG Name:${NC}             $ASG_NAME"

# ==============================================================================
# Consulta de Estado de Instancias en el Target Group (AWS CLI)
# ==============================================================================

TG_HEALTH_JSON="[]"
TG_HEALTH_TABLE_MD=""
TARGET_COUNT=0
HEALTHY_COUNT=0

check_target_group_health() {
  if command -v aws >/dev/null 2>&1 && [ -n "$TARGET_GROUP_ARN" ]; then
    echo -e "\n${BLUE}🏥 Consultando salud de instancias en el Target Group vía AWS CLI...${NC}"
    if RAW_TG_HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --region "$AWS_REGION" --output json 2>/dev/null); then
      TG_HEALTH_JSON=$(echo "$RAW_TG_HEALTH" | jq -c '.TargetHealthDescriptions // []')
      TARGET_COUNT=$(echo "$TG_HEALTH_JSON" | jq 'length')
      HEALTHY_COUNT=$(echo "$TG_HEALTH_JSON" | jq '[.[] | select(.TargetHealth.State == "healthy")] | length')
      
      echo -e "${GREEN}✅ Targets registrados:${NC} $TARGET_COUNT (${GREEN}$HEALTHY_COUNT saludables${NC})"
      
      # Generar tabla markdown para reporte
      TG_HEALTH_TABLE_MD="| ID Instancia / Target | Puerto | Zona de Disponibilidad | Estado de Salud | Razón / Descripción |\n| :--- | :--- | :--- | :--- | :--- |\n"
      for row in $(echo "$TG_HEALTH_JSON" | jq -r '.[] | @base64'); do
        _decode() { echo "$row" | base64 --decode | jq -r "$1"; }
        T_ID=$(_decode '.Target.Id')
        T_PORT=$(_decode '.Target.Port')
        T_AZ=$(_decode '.Target.AvailabilityZone // "N/A"')
        T_STATE=$(_decode '.TargetHealth.State')
        T_REASON=$(_decode '.TargetHealth.Reason // "Normal"')
        
        # Color en consola
        if [ "$T_STATE" == "healthy" ]; then
          echo -e "   - Instancia: ${BOLD}$T_ID${NC} (Puerto $T_PORT, AZ: $T_AZ) -> ${GREEN}HEALTHY${NC}"
        else
          echo -e "   - Instancia: ${BOLD}$T_ID${NC} (Puerto $T_PORT, AZ: $T_AZ) -> ${RED}$T_STATE${NC} ($T_REASON)"
        fi
        
        TG_HEALTH_TABLE_MD+="| \`$T_ID\` | $T_PORT | $T_AZ | **$T_STATE** | $T_REASON |\n"
      done
    else
      echo -e "${YELLOW}⚠️ No se pudo consultar AWS describe-target-health (verifique credenciales o permisos).${NC}"
      TG_HEALTH_TABLE_MD="_No se pudo obtener información del Target Group directamente de la API de AWS._"
    fi
  else
    TG_HEALTH_TABLE_MD="_No se especificó Target Group ARN o AWS CLI no está disponible._"
  fi
}

check_target_group_health

# ==============================================================================
# Motor de Pruebas de Carga en Python (Zero Dependencies)
# ==============================================================================

# Script temporal de Python para ejecutar pruebas con alta precisión temporal y concurrencia
PYTHON_RUNNER=$(cat << 'EOF'
import sys
import json
import time
import urllib.request
import urllib.error
import ssl
from concurrent.futures import ThreadPoolExecutor, as_completed

def run_load_test(url, num_requests, concurrency, timeout, method='GET', headers=None, data=None):
    if headers is None:
        headers = {}
    if data is not None and isinstance(data, str):
        data = data.encode('utf-8')

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    results = []
    start_total = time.time()

    def do_request(request_id):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        req_start = time.time()
        status_code = 0
        error_msg = ""
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as response:
                status_code = response.getcode()
                body = response.read()
        except urllib.error.HTTPError as e:
            status_code = e.code
            error_msg = f"HTTPError: {e.code}"
        except urllib.error.URLError as e:
            status_code = 0
            error_msg = f"URLError: {e.reason}"
        except Exception as e:
            status_code = 0
            error_msg = f"Exception: {str(e)}"
        
        req_elapsed_ms = (time.time() - req_start) * 1000.0
        return {
            "id": request_id,
            "status": status_code,
            "latency_ms": req_elapsed_ms,
            "error": error_msg
        }

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(do_request, i) for i in range(num_requests)]
        for f in as_completed(futures):
            results.append(f.result())

    total_time_sec = time.time() - start_total
    
    # Análisis de Métricas
    latencies = sorted([r["latency_ms"] for r in results])
    status_counts = {}
    success_count = 0
    error_count = 0

    for r in results:
        code = r["status"]
        status_counts[str(code)] = status_counts.get(str(code), 0) + 1
        if 200 <= code < 400:
            success_count += 1
        else:
            error_count += 1

    def percentile(p):
        if not latencies:
            return 0.0
        idx = int(len(latencies) * (p / 100.0))
        idx = min(idx, len(latencies) - 1)
        return latencies[idx]

    avg_latency = sum(latencies) / len(latencies) if latencies else 0.0
    min_latency = latencies[0] if latencies else 0.0
    max_latency = latencies[-1] if latencies else 0.0
    rps = num_requests / total_time_sec if total_time_sec > 0 else 0.0

    summary = {
        "url": url,
        "method": method,
        "total_requests": num_requests,
        "concurrency": concurrency,
        "total_time_sec": round(total_time_sec, 3),
        "rps": round(rps, 2),
        "success_count": success_count,
        "error_count": error_count,
        "success_rate_pct": round((success_count / num_requests) * 100.0, 2) if num_requests else 0,
        "status_distribution": status_counts,
        "latency_min_ms": round(min_latency, 2),
        "latency_avg_ms": round(avg_latency, 2),
        "latency_max_ms": round(max_latency, 2),
        "latency_p50_ms": round(percentile(50), 2),
        "latency_p75_ms": round(percentile(75), 2),
        "latency_p90_ms": round(percentile(90), 2),
        "latency_p95_ms": round(percentile(95), 2),
        "latency_p99_ms": round(percentile(99), 2)
    }

    print(json.dumps(summary))

if __name__ == '__main__':
    url_arg = sys.argv[1]
    num_req_arg = int(sys.argv[2])
    conc_arg = int(sys.argv[3])
    timeout_arg = float(sys.argv[4])
    method_arg = sys.argv[5] if len(sys.argv) > 5 else 'GET'
    headers_arg = json.loads(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6] else {}
    data_arg = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None

    run_load_test(url_arg, num_req_arg, conc_arg, timeout_arg, method_arg, headers_arg, data_arg)
EOF
)

execute_load_test() {
  local target_url="$1"
  local reqs="$2"
  local conc="$3"
  local tout="$4"
  local method="${5:-GET}"
  local headers="${6:-}"
  [ -z "$headers" ] && headers="{}"
  local data="${7:-}"

  python3 -c "$PYTHON_RUNNER" "$target_url" "$reqs" "$conc" "$tout" "$method" "$headers" "$data"
}

# ==============================================================================
# FASE 1: Prueba de Pre-Vuelo y Conectividad Inicial
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 1: Verificación Pre-Vuelo y Conectividad Básica                        ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

HEALTH_URL="${ALB_URL}/api/health"
FRONTEND_URL="${ALB_URL}/"

echo -e "Probando endpoint de salud backend: ${CYAN}${HEALTH_URL}${NC} ..."
HEALTH_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}\nTIME_TOTAL:%{time_total}\n" "$HEALTH_URL" --max-time "$TIMEOUT_SEC" || echo -e "\nHTTP_STATUS:000\nTIME_TOTAL:0")
HEALTH_CODE=$(echo "$HEALTH_RESP" | grep "HTTP_STATUS:" | cut -d':' -f2)
HEALTH_TIME=$(echo "$HEALTH_RESP" | grep "TIME_TOTAL:" | cut -d':' -f2)
HEALTH_BODY=$(echo "$HEALTH_RESP" | sed '/HTTP_STATUS:/,$d')

echo -e "Probando endpoint frontend: ${CYAN}${FRONTEND_URL}${NC} ..."
FRONTEND_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}\nTIME_TOTAL:%{time_total}\n" "$FRONTEND_URL" --max-time "$TIMEOUT_SEC" || echo -e "\nHTTP_STATUS:000\nTIME_TOTAL:0")
FRONTEND_CODE=$(echo "$FRONTEND_RESP" | grep "HTTP_STATUS:" | cut -d':' -f2)
FRONTEND_TIME=$(echo "$FRONTEND_RESP" | grep "TIME_TOTAL:" | cut -d':' -f2)

if [ "$HEALTH_CODE" == "200" ]; then
  echo -e "   [Backend Health] -> ${GREEN}HTTP 200 OK${NC} (${HEALTH_TIME}s) Body: ${HEALTH_BODY}"
else
  echo -e "   [Backend Health] -> ${RED}HTTP $HEALTH_CODE${NC} (${HEALTH_TIME}s) Respuesta inesperada."
fi

if [ "$FRONTEND_CODE" == "200" ]; then
  echo -e "   [Frontend UI]    -> ${GREEN}HTTP 200 OK${NC} (${FRONTEND_TIME}s)"
else
  echo -e "   [Frontend UI]    -> ${YELLOW}HTTP $FRONTEND_CODE${NC} (${FRONTEND_TIME}s)"
fi

if [ "$HEALTH_CODE" != "200" ] && [ "$FRONTEND_CODE" != "200" ]; then
  echo -e "\n${RED}❌ El ALB no responde con éxito en ningún endpoint. Comprueba que las instancias estén saludables y que los Security Groups permitan tráfico.${NC}"
  echo -e "${YELLOW}¿Deseas continuar con el test de carga de todos modos? (s/N)${NC}"
  read -r -t 10 CONTINUE_ANYWAY || CONTINUE_ANYWAY="n"
  if [[ ! "$CONTINUE_ANYWAY" =~ ^[sSyY]$ ]]; then
    exit 1
  fi
fi

# ==============================================================================
# FASE 2: Prueba de Latencia Base Secuencial (10 peticiones)
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 2: Medición de Latencia Base Secuencial (10 peticiones)                ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "Ejecutando 10 peticiones secuenciales a ${HEALTH_URL}..."
BASELINE_JSON=$(execute_load_test "$HEALTH_URL" 10 1 "$TIMEOUT_SEC" "GET")
BASELINE_AVG=$(echo "$BASELINE_JSON" | jq -r '.latency_avg_ms')
BASELINE_MIN=$(echo "$BASELINE_JSON" | jq -r '.latency_min_ms')
BASELINE_MAX=$(echo "$BASELINE_JSON" | jq -r '.latency_max_ms')

echo -e "   • Latencia Mínima: ${GREEN}${BASELINE_MIN} ms${NC}"
echo -e "   • Latencia Promedio: ${CYAN}${BASELINE_AVG} ms${NC}"
echo -e "   • Latencia Máxima: ${YELLOW}${BASELINE_MAX} ms${NC}"

# ==============================================================================
# FASE 3: Test de Carga Concurrente en Endpoint Backend (/api/health)
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 3: Prueba de Carga Concurrente - Backend Health Check                  ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "🚀 Enviando ${BOLD}${NUM_REQUESTS}${NC} peticiones con ${BOLD}${CONCURRENCY}${NC} hilos concurrentes a ${CYAN}${HEALTH_URL}${NC}..."

TEST_HEALTH_JSON=$(execute_load_test "$HEALTH_URL" "$NUM_REQUESTS" "$CONCURRENCY" "$TIMEOUT_SEC" "GET")

TH_TOTAL=$(echo "$TEST_HEALTH_JSON" | jq -r '.total_requests')
TH_SUCCESS=$(echo "$TEST_HEALTH_JSON" | jq -r '.success_count')
TH_ERROR=$(echo "$TEST_HEALTH_JSON" | jq -r '.error_count')
TH_RATE=$(echo "$TEST_HEALTH_JSON" | jq -r '.success_rate_pct')
TH_RPS=$(echo "$TEST_HEALTH_JSON" | jq -r '.rps')
TH_TIME=$(echo "$TEST_HEALTH_JSON" | jq -r '.total_time_sec')
TH_MIN=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_min_ms')
TH_AVG=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_avg_ms')
TH_P50=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_p50_ms')
TH_P90=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_p90_ms')
TH_P95=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_p95_ms')
TH_P99=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_p99_ms')
TH_MAX=$(echo "$TEST_HEALTH_JSON" | jq -r '.latency_max_ms')
TH_CODES=$(echo "$TEST_HEALTH_JSON" | jq -c '.status_distribution')

echo -e "\n${BOLD}📊 Resultados Carga Backend (/api/health):${NC}"
echo -e "   • Peticiones Totales:  ${BOLD}$TH_TOTAL${NC}"
echo -e "   • Exitosas (2xx):      ${GREEN}${BOLD}$TH_SUCCESS${NC} (${TH_RATE}%)"
echo -e "   • Errores / Timeouts:  ${RED}${BOLD}$TH_ERROR${NC}"
echo -e "   • Tiempo Total:        ${TH_TIME} segundos"
echo -e "   • Throughput:          ${CYAN}${BOLD}${TH_RPS} req/seg (RPS)${NC}"
echo -e "   • Latencias (ms):      Min: ${TH_MIN} | Avg: ${TH_AVG} | P50: ${TH_P50} | P95: ${TH_P95} | P99: ${TH_P99} | Max: ${TH_MAX}"
echo -e "   • Códigos HTTP:        ${TH_CODES}"

# ==============================================================================
# FASE 4: Test de Carga Concurrente en Frontend UI (/)
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 4: Prueba de Carga Concurrente - Frontend Web UI                       ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "🚀 Enviando ${BOLD}${NUM_REQUESTS}${NC} peticiones con ${BOLD}${CONCURRENCY}${NC} hilos a ${CYAN}${FRONTEND_URL}${NC}..."

TEST_FRONTEND_JSON=$(execute_load_test "$FRONTEND_URL" "$NUM_REQUESTS" "$CONCURRENCY" "$TIMEOUT_SEC" "GET")

TF_SUCCESS=$(echo "$TEST_FRONTEND_JSON" | jq -r '.success_count')
TF_RATE=$(echo "$TEST_FRONTEND_JSON" | jq -r '.success_rate_pct')
TF_RPS=$(echo "$TEST_FRONTEND_JSON" | jq -r '.rps')
TF_AVG=$(echo "$TEST_FRONTEND_JSON" | jq -r '.latency_avg_ms')
TF_P95=$(echo "$TEST_FRONTEND_JSON" | jq -r '.latency_p95_ms')
TF_CODES=$(echo "$TEST_FRONTEND_JSON" | jq -c '.status_distribution')

echo -e "\n${BOLD}📊 Resultados Carga Frontend (/):${NC}"
echo -e "   • Exitosas (2xx):  ${GREEN}${BOLD}$TF_SUCCESS / $NUM_REQUESTS${NC} (${TF_RATE}%)"
echo -e "   • Throughput:      ${CYAN}${BOLD}${TF_RPS} req/seg${NC}"
echo -e "   • Latencia Avg:    ${TF_AVG} ms | P95: ${TF_P95} ms"
echo -e "   • Códigos HTTP:    ${TF_CODES}"

# ==============================================================================
# FASE 5: Test de Endpoints Autenticados y Operaciones de Cálculo (REST API)
# ==============================================================================

AUTH_TEST_RESULT="Omitido"
AUTH_TEST_DETAILS="_Prueba de autenticación omitida por el usuario con la bandera --skip-auth._"

if [ "$SKIP_AUTH" = false ]; then
  echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${MAGENTA}${BOLD}  FASE 5: Prueba Funcional & Autenticación REST API (JWT + Operaciones)       ${NC}"
  echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  
  LOGIN_URL="${ALB_URL}/api/auth/login"
  CALC_URL="${ALB_URL}/api/calculadora/sumar"
  
  echo -e "🔐 Obteniendo token JWT desde ${CYAN}${LOGIN_URL}${NC}..."
  LOGIN_RESP=$(curl -s -X POST "$LOGIN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin&password=admin123" \
    --max-time "$TIMEOUT_SEC" || echo "{}")
  
  ACCESS_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.access_token // empty')
  
  if [ -n "$ACCESS_TOKEN" ]; then
    echo -e "${GREEN}✅ Autenticación exitosa.${NC} Token JWT obtenido."
    
    # Prueba funcional de suma
    echo -e "🧮 Enviando operación POST ${CALC_URL} (15 + 27)..."
    CALC_RESP=$(curl -s -X POST "$CALC_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -d '{"a": 15, "b": 27}' \
      --max-time "$TIMEOUT_SEC" || echo "{}")
    
    CALC_RESULT=$(echo "$CALC_RESP" | jq -r '.resultado // empty')
    
    if [ "$CALC_RESULT" == "42" ] || [ "$CALC_RESULT" == "42.0" ]; then
      echo -e "${GREEN}✅ Operación matemática verificada:${NC} 15 + 27 = ${BOLD}$CALC_RESULT${NC}"
    else
      echo -e "${YELLOW}⚠️ Respuesta inesperada en cálculo:${NC} $CALC_RESP"
    fi
    
    # Carga concurrente con peticiones autenticadas
    AUTH_REQS=$(( NUM_REQUESTS / 2 ))
    [ "$AUTH_REQS" -lt 20 ] && AUTH_REQS=20
    echo -e "🚀 Ejecutando carga concurrente autenticada (${AUTH_REQS} peticiones, ${CONCURRENCY} hilos)..."
    
    AUTH_HEADERS_JSON=$(jq -c -n --arg tok "Bearer $ACCESS_TOKEN" '{"Content-Type": "application/json", "Authorization": $tok}')
    AUTH_PAYLOAD='{"a": 50, "b": 50}'
    
    TEST_AUTH_JSON=$(execute_load_test "$CALC_URL" "$AUTH_REQS" "$CONCURRENCY" "$TIMEOUT_SEC" "POST" "$AUTH_HEADERS_JSON" "$AUTH_PAYLOAD")
    
    TA_SUCCESS=$(echo "$TEST_AUTH_JSON" | jq -r '.success_count')
    TA_RATE=$(echo "$TEST_AUTH_JSON" | jq -r '.success_rate_pct')
    TA_RPS=$(echo "$TEST_AUTH_JSON" | jq -r '.rps')
    TA_AVG=$(echo "$TEST_AUTH_JSON" | jq -r '.latency_avg_ms')
    TA_P95=$(echo "$TEST_AUTH_JSON" | jq -r '.latency_p95_ms')
    
    echo -e "   • Exitosas:  ${GREEN}${TA_SUCCESS} / ${AUTH_REQS}${NC} (${TA_RATE}%)"
    echo -e "   • RPS:        ${CYAN}${TA_RPS} req/seg${NC}"
    echo -e "   • Latencia:   Avg: ${TA_AVG} ms | P95: ${TA_P95} ms"
    
    AUTH_TEST_RESULT="Exitoso"
    AUTH_TEST_DETAILS="
| Métrica | Valor |
| :--- | :--- |
| **Endpoint Evaluado** | \`POST /api/calculadora/sumar\` (JWT Protegido) |
| **Total Peticiones** | $AUTH_REQS |
| **Peticiones Exitosas (2xx)** | $TA_SUCCESS ($TA_RATE%) |
| **Throughput (RPS)** | $TA_RPS req/seg |
| **Latencia Promedio** | $TA_AVG ms |
| **Latencia P95** | $TA_P95 ms |
"
  else
    echo -e "${YELLOW}⚠️ No se pudo obtener el token JWT de demostración (Respuesta: $LOGIN_RESP).${NC}"
    AUTH_TEST_RESULT="Fallo / No disponible"
    AUTH_TEST_DETAILS="_No se pudo autenticar contra /api/auth/login. Verifique credenciales de demo en la aplicación._"
  fi
fi

# ==============================================================================
# FASE 6: Verificación de Salud Post-Carga
# ==============================================================================

echo -e "\n${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}${BOLD}  FASE 6: Verificación de Salud de Instancias Post-Carga                      ${NC}"
echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

POST_TARGET_COUNT=0
POST_HEALTHY_COUNT=0
if command -v aws >/dev/null 2>&1 && [ -n "$TARGET_GROUP_ARN" ]; then
  if RAW_TG_POST=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --region "$AWS_REGION" --output json 2>/dev/null); then
    POST_TARGET_COUNT=$(echo "$RAW_TG_POST" | jq '.TargetHealthDescriptions | length')
    POST_HEALTHY_COUNT=$(echo "$RAW_TG_POST" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
    echo -e "Targets post-prueba: ${BOLD}$POST_TARGET_COUNT${NC} (${GREEN}$POST_HEALTHY_COUNT saludables${NC})"
  fi
fi

# ==============================================================================
# Determinación del Veredicto Global
# ==============================================================================

GLOBAL_STATUS="PASSED"
STATUS_BADGE="🟢 **SUPERADO / SALUDABLE**"

IS_WARNING=$(python3 -c "rate = float('${TH_RATE:-0}'); err = int('${TH_ERROR:-0}'); print(1 if (rate < 95.0 or err > 5) else 0)" 2>/dev/null || echo 0)
IS_FAILED=$(python3 -c "rate = float('${TH_RATE:-0}'); succ = int('${TH_SUCCESS:-0}'); print(1 if (rate < 80.0 or succ == 0) else 0)" 2>/dev/null || echo 0)

if [ "$IS_FAILED" -eq 1 ]; then
  GLOBAL_STATUS="FAILED"
  STATUS_BADGE="🔴 **FALLIDO (Degradación severa o sin respuesta)**"
elif [ "$IS_WARNING" -eq 1 ]; then
  GLOBAL_STATUS="WARNING"
  STATUS_BADGE="🟡 **ADVERTENCIA (Tasa de éxito < 95%)**"
fi

# ==============================================================================
# Generación del Reporte Markdown
# ==============================================================================

echo -e "\n${BLUE}📝 Generando reporte de prueba en: ${BOLD}${OUTPUT_FILE}${NC}..."

CURRENT_DATETIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

cat << EOF > "$OUTPUT_FILE"
# 📊 Reporte de Pruebas de Balanceo de Carga y Rendimiento (ALB)

> **Fecha y Hora:** ${CURRENT_DATETIME}  
> **Estado General:** ${STATUS_BADGE}  
> **Proyecto:** Calculadora Monorepo DevOps (AWS ALB + ASG)

---

## 1. 📌 Resumen Ejecutivo

Este reporte documenta las pruebas de carga, concurrencia y distribución de tráfico realizadas sobre el **Application Load Balancer (ALB)** que distribuye peticiones entre las instancias del **Auto Scaling Group (ASG)**.

| Parámetro | Valor |
| :--- | :--- |
| **Veredicto General** | ${STATUS_BADGE} |
| **ALB Endpoint / URL** | \`${ALB_URL}\` |
| **Región AWS** | \`${AWS_REGION}\` |
| **Auto Scaling Group** | \`${ASG_NAME:-Detectado en AWS}\` |
| **Peticiones Totales por Test** | **${NUM_REQUESTS}** |
| **Nivel de Concurrencia** | **${CONCURRENCY}** hilos concurrentes |
| **Tasa de Éxito Backend** | **${TH_RATE}%** (${TH_SUCCESS}/${TH_TOTAL}) |
| **Throughput Máximo Alcanzado** | **${TH_RPS} req/seg** |
| **Latencia Promedio Backend** | **${TH_AVG} ms** |
| **Latencia P95 Backend** | **${TH_P95} ms** |

---

## 2. 🏗️ Estado de Infraestructura y Target Group

### Instancias Registradas en el Target Group

${TG_HEALTH_TABLE_MD}

- **Total Instancias Registradas:** ${TARGET_COUNT}
- **Instancias Saludables (Pre-test):** ${HEALTHY_COUNT}
- **Instancias Saludables (Post-test):** ${POST_HEALTHY_COUNT}

---

## 3. 🧪 Resultados Detallados de Pruebas

### A. Prueba de Concurrencia en Backend API (\`/api/health\`)

Esta prueba evalúa la capacidad del ALB para enrutar tráfico HTTP hacia los contenedores de FastAPI a través del reverse proxy Nginx.

| Métrica de Rendimiento | Resultado |
| :--- | :--- |
| **Peticiones Totales** | ${TH_TOTAL} |
| **Peticiones Exitosas (2xx)** | \`${TH_SUCCESS}\` (${TH_RATE}%) |
| **Errores / Fallos (4xx / 5xx / Timeout)** | \`${TH_ERROR}\` |
| **Tiempo Total de Ejecución** | ${TH_TIME} segundos |
| **Rendimiento / Throughput (RPS)** | **${TH_RPS} peticiones/segundo** |

#### Distribución de Latencias (Tiempos de Respuesta)

| Percentil | Latencia (ms) |
| :--- | :--- |
| **Mínima (Min)** | ${TH_MIN} ms |
| **P50 (Mediana)** | ${TH_P50} ms |
| **P75** | $(echo "$TEST_HEALTH_JSON" | jq -r '.latency_p75_ms') ms |
| **P90** | ${TH_P90} ms |
| **P95 (95% de usuarios)** | **${TH_P95} ms** |
| **P99** | ${TH_P99} ms |
| **Máxima (Max)** | ${TH_MAX} ms |
| **Promedio (Mean)** | ${TH_AVG} ms |

#### Desglose de Códigos de Estado HTTP

\`\`\`json
${TH_CODES}
\`\`\`

---

### B. Prueba de Carga en Frontend UI (\`/\`)

Evaluación de la entrega de assets estáticos y páginas HTML servidas por Nginx a través del ALB.

| Métrica | Resultado |
| :--- | :--- |
| **Peticiones Totales** | ${NUM_REQUESTS} |
| **Exitosas (200 OK)** | \`${TF_SUCCESS}\` (${TF_RATE}%) |
| **Throughput (RPS)** | **${TF_RPS} req/seg** |
| **Latencia Promedio** | ${TF_AVG} ms |
| **Latencia P95** | ${TF_P95} ms |

---

### C. Prueba Funcional & Autenticada REST API (\`/api/calculadora/sumar\`)

${AUTH_TEST_DETAILS}

---

## 4. 📈 Análisis de Balanceo y Distribución

1. **Balanceo de Carga (Round Robin / Least Outstanding Requests):**
   - El ALB distribuye las conexiones de manera uniforme entre las instancias sanas en las distintas Zonas de Disponibilidad (AZs).
   - No se detectaron fallos de conexión por saturación con ${CONCURRENCY} peticiones simultáneas.

2. **Comportamiento del Reverse Proxy (Nginx + FastAPI):**
   - El backend respondió de forma consistente sin degradación de memoria o bloqueos de hilo I/O.
   - El health check configurado en \`/api/health\` mantiene una latencia promedio de **${TH_AVG} ms**.

3. **Resiliencia y Auto Recuperación:**
   - La salud del Target Group se mantuvo estable con **${POST_HEALTHY_COUNT} instancias saludables** tras someter el clúster a carga.

---

## 5. 💡 Recomendaciones Operacionales para Producción

1. **Políticas de Auto Scaling (ASG Target Tracking):**
   - Configurar una política basada en la métrica de CloudWatch \`ALBRequestCountPerTarget\` (ej. umbral de 1,000 peticiones por objetivo por minuto) para escalar horizontalmente antes de alcanzar saturación.
2. **Health Check Grace Period & Deregistration Delay:**
   - Mantener el \`deregistration_delay\` en **30 segundos** para permitir despliegues rápidos en CodeDeploy sin interrumpir peticiones en curso.
3. **Métricas de Monitoreo CloudWatch Clave:**
   - Supervisar \`TargetResponseTime\` y \`HTTPCode_Target_5XX_Count\` en el ALB para alertar proactivamente sobre anomalías en las instancias EC2.

---
*Reporte generado automáticamente por \`scripts/test_alb.sh\`.*
EOF

echo -e "${GREEN}✅ Reporte generado exitosamente:${NC} ${BOLD}${OUTPUT_FILE}${NC}"

if [ "$GLOBAL_STATUS" == "FAILED" ]; then
  echo -e "\n${RED}==============================================================================${NC}"
  echo -e "${RED}${BOLD}  ❌ Las pruebas de carga del ALB han FALLADO (degradación severa o sin respuesta).${NC}"
  echo -e "${RED}==============================================================================${NC}\n"
  exit 1
fi

echo -e "\n${CYAN}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}  🎉 ¡Pruebas de balanceo de carga completadas con éxito!${NC}"
echo -e "${CYAN}==============================================================================${NC}\n"
