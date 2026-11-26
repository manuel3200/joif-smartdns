#!/usr/bin/env bash
# core/expire-licenses.sh — Tarea horaria (systemd timer / cron) para purgar IPs vencidas
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/licenses.sh
source "${SCRIPT_DIR}/licenses.sh"

joif_load_config
expired="$(joif_with_lock license_expire_overdue --force-sync | tail -n1)"
log_info "Chequeo horario de licencias completado (vencidas desactivadas: ${expired:-0})."
