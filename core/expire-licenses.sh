#!/usr/bin/env bash
# core/expire-licenses.sh — Tarea horaria (systemd timer): purga IPs vencidas y controla tamano de logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/licenses.sh
source "${SCRIPT_DIR}/licenses.sh"
# shellcheck source=core/maintenance.sh
source "${SCRIPT_DIR}/maintenance.sh"

joif_load_config
expired="$(joif_with_lock license_expire_overdue --force-sync | tail -n1)"
maintenance_enforce_log_cap
log_info "Chequeo horario completado (licencias vencidas desactivadas: ${expired:-0})."
