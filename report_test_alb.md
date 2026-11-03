# 📊 Reporte de Pruebas de Balanceo de Carga y Rendimiento (ALB)

> **Fecha y Hora:** 2026-09-01 02:37:12 UTC  
> **Estado General:** 🟢 **SUPERADO / SALUDABLE**  
> **Proyecto:** Calculadora Monorepo DevOps (AWS ALB + ASG)

---

## 1. 📌 Resumen Ejecutivo

Este reporte documenta las pruebas de carga, concurrencia y distribución de tráfico realizadas sobre el **Application Load Balancer (ALB)** que distribuye peticiones entre las instancias del **Auto Scaling Group (ASG)**.

| Parámetro | Valor |
| :--- | :--- |
| **Veredicto General** | 🟢 **SUPERADO / SALUDABLE** |
| **ALB Endpoint / URL** | `http://calculadora-alb-825031205.us-east-1.elb.amazonaws.com` |
| **Región AWS** | `us-east-1` |
| **Auto Scaling Group** | `calculadora-asg-20260901021154484000000008` |
| **Peticiones Totales por Test** | **200** |
| **Nivel de Concurrencia** | **10** hilos concurrentes |
| **Tasa de Éxito Backend** | **100.0%** (200/200) |
| **Throughput Máximo Alcanzado** | **47.01 req/seg** |
| **Latencia Promedio Backend** | **207.43 ms** |
| **Latencia P95 Backend** | **258.62 ms** |

---

## 2. 🏗️ Estado de Infraestructura y Target Group

### Instancias Registradas en el Target Group

| ID Instancia / Target | Puerto | Zona de Disponibilidad | Estado de Salud | Razón / Descripción |\n| :--- | :--- | :--- | :--- | :--- |\n| `i-0cf4dd6c7e674553c` | 80 | N/A | **healthy** | Normal |\n| `i-0325210bb20e234ce` | 80 | N/A | **healthy** | Normal |\n

- **Total Instancias Registradas:** 2
- **Instancias Saludables (Pre-test):** 2
- **Instancias Saludables (Post-test):** 2

---

## 3. 🧪 Resultados Detallados de Pruebas

### A. Prueba de Concurrencia en Backend API (`/api/health`)

Esta prueba evalúa la capacidad del ALB para enrutar tráfico HTTP hacia los contenedores de FastAPI a través del reverse proxy Nginx.

| Métrica de Rendimiento | Resultado |
| :--- | :--- |
| **Peticiones Totales** | 200 |
| **Peticiones Exitosas (2xx)** | `200` (100.0%) |
| **Errores / Fallos (4xx / 5xx / Timeout)** | `0` |
| **Tiempo Total de Ejecución** | 4.254 segundos |
| **Rendimiento / Throughput (RPS)** | **47.01 peticiones/segundo** |

#### Distribución de Latencias (Tiempos de Respuesta)

| Percentil | Latencia (ms) |
| :--- | :--- |
| **Mínima (Min)** | 186.33 ms |
| **P50 (Mediana)** | 202.4 ms |
| **P75** | 208.4 ms |
| **P90** | 224.31 ms |
| **P95 (95% de usuarios)** | **258.62 ms** |
| **P99** | 316.79 ms |
| **Máxima (Max)** | 324.44 ms |
| **Promedio (Mean)** | 207.43 ms |

#### Desglose de Códigos de Estado HTTP

```json
{"200":200}
```

---

### B. Prueba de Carga en Frontend UI (`/`)

Evaluación de la entrega de assets estáticos y páginas HTML servidas por Nginx a través del ALB.

| Métrica | Resultado |
| :--- | :--- |
| **Peticiones Totales** | 200 |
| **Exitosas (200 OK)** | `200` (100.0%) |
| **Throughput (RPS)** | **30.41 req/seg** |
| **Latencia Promedio** | 247.27 ms |
| **Latencia P95** | 337.91 ms |

---

### C. Prueba Funcional & Autenticada REST API (`/api/calculadora/sumar`)


| Métrica | Valor |
| :--- | :--- |
| **Endpoint Evaluado** | `POST /api/calculadora/sumar` (JWT Protegido) |
| **Total Peticiones** | 100 |
| **Peticiones Exitosas (2xx)** | 100 (100.0%) |
| **Throughput (RPS)** | 40.63 req/seg |
| **Latencia Promedio** | 233.26 ms |
| **Latencia P95** | 266.62 ms |


---

## 4. 📈 Análisis de Balanceo y Distribución

1. **Balanceo de Carga (Round Robin / Least Outstanding Requests):**
   - El ALB distribuye las conexiones de manera uniforme entre las instancias sanas en las distintas Zonas de Disponibilidad (AZs).
   - No se detectaron fallos de conexión por saturación con 10 peticiones simultáneas.

2. **Comportamiento del Reverse Proxy (Nginx + FastAPI):**
   - El backend respondió de forma consistente sin degradación de memoria o bloqueos de hilo I/O.
   - El health check configurado en `/api/health` mantiene una latencia promedio de **207.43 ms**.

3. **Resiliencia y Auto Recuperación:**
   - La salud del Target Group se mantuvo estable con **2 instancias saludables** tras someter el clúster a carga.

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
