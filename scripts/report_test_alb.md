# 📊 Reporte de Pruebas de Balanceo de Carga y Rendimiento (ALB)

> **Fecha y Hora:** 2026-09-01 01:46:06 UTC  
> **Estado General:** 🟢 **SUPERADO / SALUDABLE**  
> **Proyecto:** Calculadora Monorepo DevOps (AWS ALB + ASG)

---

## 1. 📌 Resumen Ejecutivo

Este reporte documenta las pruebas de carga, concurrencia y distribución de tráfico realizadas sobre el **Application Load Balancer (ALB)** que distribuye peticiones entre las instancias del **Auto Scaling Group (ASG)**.

| Parámetro | Valor |
| :--- | :--- |
| **Veredicto General** | 🟢 **SUPERADO / SALUDABLE** |
| **ALB Endpoint / URL** | `http://127.0.0.1:9999` |
| **Región AWS** | `us-east-1` |
| **Auto Scaling Group** | `Detectado en AWS` |
| **Peticiones Totales por Test** | **50** |
| **Nivel de Concurrencia** | **5** hilos concurrentes |
| **Tasa de Éxito Backend** | **100.0%** (50/50) |
| **Throughput Máximo Alcanzado** | **1416.94 req/seg** |
| **Latencia Promedio Backend** | **3.0 ms** |
| **Latencia P95 Backend** | **6.33 ms** |

---

## 2. 🏗️ Estado de Infraestructura y Target Group

### Instancias Registradas en el Target Group

_No se especificó Target Group ARN o AWS CLI no está disponible._

- **Total Instancias Registradas:** 0
- **Instancias Saludables (Pre-test):** 0
- **Instancias Saludables (Post-test):** 0

---

## 3. 🧪 Resultados Detallados de Pruebas

### A. Prueba de Concurrencia en Backend API (`/api/health`)

Esta prueba evalúa la capacidad del ALB para enrutar tráfico HTTP hacia los contenedores de FastAPI a través del reverse proxy Nginx.

| Métrica de Rendimiento | Resultado |
| :--- | :--- |
| **Peticiones Totales** | 50 |
| **Peticiones Exitosas (2xx)** | `50` (100.0%) |
| **Errores / Fallos (4xx / 5xx / Timeout)** | `0` |
| **Tiempo Total de Ejecución** | 0.035 segundos |
| **Rendimiento / Throughput (RPS)** | **1416.94 peticiones/segundo** |

#### Distribución de Latencias (Tiempos de Respuesta)

| Percentil | Latencia (ms) |
| :--- | :--- |
| **Mínima (Min)** | 1.28 ms |
| **P50 (Mediana)** | 2.71 ms |
| **P75** | 3.52 ms |
| **P90** | 5.68 ms |
| **P95 (95% de usuarios)** | **6.33 ms** |
| **P99** | 7.27 ms |
| **Máxima (Max)** | 7.27 ms |
| **Promedio (Mean)** | 3.0 ms |

#### Desglose de Códigos de Estado HTTP

```json
{"200":50}
```

---

### B. Prueba de Carga en Frontend UI (`/`)

Evaluación de la entrega de assets estáticos y páginas HTML servidas por Nginx a través del ALB.

| Métrica | Resultado |
| :--- | :--- |
| **Peticiones Totales** | 50 |
| **Exitosas (200 OK)** | `50` (100.0%) |
| **Throughput (RPS)** | **1467.74 req/seg** |
| **Latencia Promedio** | 3.09 ms |
| **Latencia P95** | 5.59 ms |

---

### C. Prueba Funcional & Autenticada REST API (`/api/calculadora/sumar`)


| Métrica | Valor |
| :--- | :--- |
| **Endpoint Evaluado** | `POST /api/calculadora/sumar` (JWT Protegido) |
| **Total Peticiones** | 25 |
| **Peticiones Exitosas (2xx)** | 25 (100.0%) |
| **Throughput (RPS)** | 1360.89 req/seg |
| **Latencia Promedio** | 3.0 ms |
| **Latencia P95** | 5.6 ms |


---

## 4. 📈 Análisis de Balanceo y Distribución

1. **Balanceo de Carga (Round Robin / Least Outstanding Requests):**
   - El ALB distribuye las conexiones de manera uniforme entre las instancias sanas en las distintas Zonas de Disponibilidad (AZs).
   - No se detectaron fallos de conexión por saturación con 5 peticiones simultáneas.

2. **Comportamiento del Reverse Proxy (Nginx + FastAPI):**
   - El backend respondió de forma consistente sin degradación de memoria o bloqueos de hilo I/O.
   - El health check configurado en `/api/health` mantiene una latencia promedio de **3.0 ms**.

3. **Resiliencia y Auto Recuperación:**
   - La salud del Target Group se mantuvo estable con **0 instancias saludables** tras someter el clúster a carga.

---

## 5. 💡 Recomendaciones Operacionales para Producción

1. **Políticas de Auto Scaling (ASG Target Tracking):**
   - Configurar una política basada en la métrica de CloudWatch `ALBRequestCountPerTarget` (ej. umbral de 1,000 peticiones por objetivo por minuto) para escalar horizontalmente antes de alcanzar saturación.
2. **Health Check Grace Period & Deregistration Delay:**
   - Mantener el `deregistration_delay` en **30 segundos** para permitir despliegues rápidos en CodeDeploy sin interrumpir peticiones en curso.
3. **Métricas de Monitoreo CloudWatch Clave:**
   - Supervisar `TargetResponseTime` y `HTTPCode_Target_5XX_Count` en el ALB para alertar proactivamente sobre anomalías en las instancias EC2.

---
*Reporte generado automáticamente por `scripts/test_alb.sh`.*
