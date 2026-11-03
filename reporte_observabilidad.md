# 🔭 Reporte de Validación de Observabilidad y Monitoreo (CloudWatch & CodeDeploy)

> **Fecha y Hora:** 2026-10-27 20:42:10 UTC  
> **Estado General:** 🔴 **FALLIDO (Anomalías o Fallos Críticos Detectados)**  
> **Proyecto:** Calculadora Monorepo DevOps (AWS CloudWatch + CodeDeploy + ALB)  
> **Región AWS:** `us-east-1`  

---

## 1. 📌 Resumen Ejecutivo

Este informe consolida los resultados de las comprobaciones de **observabilidad, métricas, logs, alarmas y rollback automático** en AWS para garantizar la estabilidad operativa del entorno.

| Parámetro Evaluado | Valor / Estado |
| :--- | :--- |
| **Veredicto General** | 🔴 **FALLIDO (Anomalías o Fallos Críticos Detectados)** |
| **Endpoint del ALB** | `http://gh-elb-1589169135.us-east-1.elb.amazonaws.com` |
| **Aplicación CodeDeploy** | `mi-app` / Grupo: `produccion` |
| **Alarma Principal Rollback (5xx)** | `gh-alb-5xx` |
| **Log Group de Contenedores** | `/calculadora/calculadora` |
| **Dashboard de CloudWatch** | `gh-miAppEstado` |
| **Instancias Saludables (Target Group)** | **2 / 2** |
| **Éxito de Peticiones HTTP al ALB** | **30 / 30** (205.68 ms latencia prom.) |
| **Fallos Críticos Detectados** | **1** |
| **Advertencias** | **1** |

---

## 2. 🚨 Diagnóstico de Errores y Razones de Fallo

> [!CAUTION]
> ### 🚨 Fallos Críticos Detectados
> El sistema de observabilidad o infraestructura presenta fallas que requieren atención inmediata:
>
> - ❌ CodeDeploy Despliegue Fallido (`d-CWU249RHM`): Estado `Stopped`. Código de error: `ALARM_ACTIVE`. Razón: "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <gh-alb-5xx>". Rollback ejecutado: {
  "rollbackMessage": "No auto rollback triggered since deployment terminated before adding any instances"
}.

> [!WARNING]
> ### ⚠️ Advertencias Operacionales
> - ⚠️ No se pudo verificar la transición a ALARM para `gh-alb-5xx` (estado obtenido: `OK`).

### Verificaciones Exitosas Registradas
- ✅ CodeDeploy tiene el rollback automático habilitado para eventos: `["DEPLOYMENT_FAILURE","DEPLOYMENT_STOP_ON_ALARM"]`.
- ✅ CodeDeploy tiene la alarma de CloudWatch `gh-alb-5xx` correctamente configurada para disparar rollback ante errores 5xx.
- ✅ Alarma CloudWatch `gh-alb-5xx` en estado saludable (`OK`).
- ✅ Alarma CloudWatch `gh-tg-healthy` en estado saludable (`OK`).
- ✅ Alarma CloudWatch `gh-alb-p99` en estado saludable (`OK`).
- ✅ Alarma CloudWatch `gh-asg-cpu-high` en estado saludable (`OK`).
- ✅ Alarma CloudWatch `gh-asg-mem-high` en estado saludable (`OK`).
- ✅ CloudWatch Log Group `/calculadora/calculadora` existe con retención de 7 días.
- ✅ Se detectaron 2 streams de log activos en `/calculadora/calculadora`, confirmando que el agente de CloudWatch está recolectando logs de los contenedores.
- ✅ CloudWatch Dashboard `gh-miAppEstado` validado exitosamente con 6 widgets de monitoreo.
- ✅ Todas las instancias del Target Group (2/2) reportan estado saludable (`healthy`).
- ✅ Tráfico al ALB 100% exitoso: 30/30 peticiones respondieron HTTP 200 en `/api/health` con latencia promedio de 205.68 ms.

---

## 3. ⏰ Estado de Alarmas de CloudWatch

A continuación se detalla el estado actual de cada una de las alarmas aprovisionadas para el sistema:

| Alarma | Métrica | Condición / Umbral | Estado Actual | Razón del Estado |
| :--- | :--- | :--- | :--- | :--- |
| `gh-alb-5xx` | `HTTPCode_Target_5XX_Count` | GreaterThanThreshold 0.0 | 🟢 OK | Threshold Crossed: no datapoints were received for 1 period and 1 missing datapoint was treated as [NonBreaching].  |
| `gh-tg-healthy` | `HealthyHostCount` | LessThanThreshold 2.0 | 🟢 OK | Threshold Crossed: 1 out of the last 2 datapoints [2.0 (27/10/26 20:20:00)] was not less than the threshold (2.0) (minimum 1 datapoint for ALARM -> OK transition).  |
| `gh-alb-p99` | `TargetResponseTime` | GreaterThanThreshold 0.5 | 🟢 OK | Threshold Crossed: no datapoints were received for 2 periods and 2 missing datapoints were treated as [NonBreaching].  |
| `gh-asg-cpu-high` | `CPUUtilization` | GreaterThanThreshold 80.0 | 🟢 OK | Threshold Crossed: 2 out of the last 2 datapoints [0.0016679464431181 (27/10/26 19:45:00), 1.901881985473619 (27/10/26 19:40:00)] were not greater than the threshold (80.0) (minimum 1 datapoint for ALARM -> OK transition).  |
| `gh-asg-mem-high` | `mem_used_percent` | GreaterThanThreshold 80.0 | 🟢 OK | Threshold Crossed: 1 out of the last 2 datapoints [40.86883794155269 (27/10/26 19:40:00)] was not greater than the threshold (80.0) and 1 missing datapoint was treated as [NonBreaching] (minimum 1 datapoint for ALARM -> OK transition).  |

- **Total de Alarmas Auditadas:** 5
- **Alarmas Encontradas en AWS:** 5

---

## 4. 🔄 Integración con AWS CodeDeploy & Rollback Automático

Configuración de resiliencia y auto-remediación ante despliegues defectuosos:

| Parámetro | Configuración Detectada | Evaluación |
| :--- | :--- | :--- |
| **Rollback Automático** | `true` | 🟢 Habilitado |
| **Eventos de Disparo de Rollback** | `["DEPLOYMENT_FAILURE","DEPLOYMENT_STOP_ON_ALARM"]` | 🟢 Incluye Alarmas |
| **Monitoreo de Alarmas en Deploy** | `true` | 🟢 Activo |
| **Alarmas Asociadas al Grupo** | `[{"name":"gh-alb-5xx"}]` | 🟢 `gh-alb-5xx` Vinculada |
| **Último Despliegue Evaluado** | `d-CWU249RHM` | **`Stopped`** |


> **Detalle del Último Despliegue:**
> CodeDeploy Despliegue Fallido (`d-CWU249RHM`): Estado `Stopped`. Código de error: `ALARM_ACTIVE`. Razón: "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <gh-alb-5xx>". Rollback ejecutado: {
  "rollbackMessage": "No auto rollback triggered since deployment terminated before adding any instances"
}.

---

## 5. 🏥 Salud del Target Group e Instancias EC2

Distribución de salud de las instancias en el balanceador de carga:

| ID Instancia / Target | Puerto | Zona | Estado de Salud | Razón / Descripción |
| :--- | :--- | :--- | :--- | :--- |
| `i-052a01828aa03c94b` | 80 | N/A | 🟢 **healthy** | Normal |
| `i-09e6daf1b42d47e3a` | 80 | N/A | 🟢 **healthy** | Normal |

- **Instancias Totales:** 2
- **Instancias Saludables (`healthy`):** 2
- **Instancias Degradadas (`unhealthy`):** 0

---

## 6. 🌐 Verificación de Tráfico HTTP y Resiliencia del ALB

Prueba sintética de conectividad al endpoint de salud (`/api/health`):

| Métrica | Resultado |
| :--- | :--- |
| **Total Peticiones Enviadas** | 30 |
| **Respuestas Exitosas (HTTP 200)** | `30` |
| **Errores de Servidor (HTTP 5xx)** | `0` |
| **Otros Códigos / Timeouts** | `0` |
| **Desglose de Códigos Recibidos** | `200: 30,` |
| **Latencia Promedio** | **205.68 ms** |

---

## 7. 📜 Logs de la Aplicación en CloudWatch Logs

El CloudWatch Agent recolecta los logs consolidados de FastAPI y Nginx:

- **Log Group:** `/calculadora/calculadora`
- **Estado del Log Group:** 🟢 Registrado en AWS
- **Streams Activos Detectados:** **2**

#### Muestra de Eventos Recientes de Log:
```text
{"timestamp": "2026-10-27T20:40:37.824300+00:00", "level": "INFO", "message": "← GET /api/health - 200 en 0.001s", "module": "middleware", "function": "dispatch", "line": 56}
INFO:     172.18.0.3:49884 - "GET /api/health HTTP/1.0" 200 OK
10.0.1.121 - - [27/Oct/2026:20:40:37 +0000] "GET /api/health HTTP/1.1" 200 33 "-" "ELB-HealthChecker/2.0" "-"
{"timestamp": "2026-10-27T20:40:37.883602+00:00", "level": "INFO", "message": "→ GET /api/health", "module": "middleware", "function": "dispatch", "line": 30}
{"timestamp": "2026-10-27T20:40:37.884988+00:00", "level": "INFO", "message": "← GET /api/health - 200 en 0.001s", "module": "middleware", "function": "dispatch", "line": 56}
INFO:     172.18.0.3:49894 - "GET /api/health HTTP/1.0" 200 OK
10.0.2.43 - - [27/Oct/2026:20:40:37 +0000] "GET /api/health HTTP/1.1" 200 33 "-" "ELB-HealthChecker/2.0" "-"
{"timestamp": "2026-10-27T20:40:42.412158+00:00", "level": "INFO", "message": "→ GET /api/health", "module": "middleware", "function": "dispatch", "line": 30}
{"timestamp": "2026-10-27T20:40:42.413481+00:00", "level": "INFO", "message": "← GET /api/health - 200 en 0.001s", "module": "middleware", "function": "dispatch", "line": 56}
INFO:     127.0.0.1:43704 - "GET /api/health HTTP/1.1" 200 OK
```

---

## 8. 📊 Dashboard de Monitoreo CloudWatch

- **Dashboard:** `gh-miAppEstado`
- **Estado:** 🟢 Disponible en consola AWS
- **Número de Widgets:** **6** widgets de métricas y logs

---

## 9. 🧪 Simulación de Disparo de Alarma

- **Resultado de la Simulación:** 🟡 No ejecutado / Advertencia
- **Detalle:** No se pudo confirmar la transición al estado ALARM.

---
*Reporte generado automáticamente por `scripts/Prueba_observabilidad.sh`.*
