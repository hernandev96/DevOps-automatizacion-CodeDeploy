#!/bin/bash
set -euo pipefail

# Espera opcional (solo demo de rollback por alarma); la escribe deploy_local.sh.
SLEEP_SECONDS="$(cat /opt/mi-app/scripts/VALIDATE_SLEEP 2>/dev/null || echo 0)"
if [ "$SLEEP_SECONDS" -gt 0 ]; then
  echo "validate_service: esperando ${SLEEP_SECONDS}s para dar tiempo a las alarmas"
  sleep "$SLEEP_SECONDS"
fi

# Validación real: la app debe responder 200 a través de nginx local.
# Reintentos porque "docker compose up -d" vuelve antes de que la app esté lista.
for i in $(seq 1 12); do
  if curl -fsS http://localhost/api/health >/dev/null 2>&1 || curl -fsS http://127.0.0.1/api/health >/dev/null 2>&1; then
    echo "validate_service: OK"
    exit 0
  fi
  sleep 5
done
echo "validate_service: la aplicación no respondió 200 en /api/health"
exit 1