#!/usr/bin/env bash
# core/maintenance.sh — Proteccion estricta de disco (10 GB), logrotate, limpieza y backup/restore

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"

# Maximo por archivo de log de nginx antes de truncar en chequeo horario (10 MB)
JOIF_LOG_MAX_BYTES="${JOIF_LOG_MAX_BYTES:-10485760}"
# Maximo de archivos de backup retenidos (cada backup pesa ~3 KB)
JOIF_MAX_BACKUPS="${JOIF_MAX_BACKUPS:-5}"

# Instala protecciones de disco: logrotate (tope ~10 MB total) y limite de systemd-journald (80 MB)
maintenance_install_disk_guards() {
    # 1. logrotate dedicado para logs de joif-smartdns en nginx
    mkdir -p "$(dirname "$JOIF_LOGROTATE_FILE")"
    cat > "$JOIF_LOGROTATE_FILE" <<EOF
# Managed by joif-smartdns — Proteccion de disco para VPS de 10 GB
${JOIF_NGINX_LOG_DIR}/joif-smartdns-*.log {
    daily
    maxsize 5M
    rotate 2
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    chmod 644 "$JOIF_LOGROTATE_FILE"

    # 2. Tope estricto a systemd-journald (evita que Ubuntu use >1 GB en /var/log/journal)
    mkdir -p "$(dirname "$JOIF_JOURNALD_DROPIN")"
    cat > "$JOIF_JOURNALD_DROPIN" <<'EOF'
# Managed by joif-smartdns — Limite de logs del sistema para VPS de 10 GB
[Journal]
SystemMaxUse=80M
RuntimeMaxUse=40M
MaxRetentionSec=7day
EOF
    chmod 644 "$JOIF_JOURNALD_DROPIN"

    if [[ "${JOIF_SKIP_SERVICE_RELOAD:-0}" != "1" ]] && command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        "$JOIF_SYSTEMCTL_BIN" restart systemd-journald >/dev/null 2>&1 || true
    fi

    log_ok "Protecciones de disco instaladas (logrotate <= 5MB x2 + journald <= 80MB)."
}

# Guardia horaria liviana: si algun log de nginx excede 10 MB o hay rotados viejos, recorta sin borrar historial util
maintenance_enforce_log_cap() {
    local f size pruned=0 truncated=0
    shopt -s nullglob

    # Borrar rotados antiguos mas alla de .1 / .1.gz
    for f in "${JOIF_NGINX_LOG_DIR}"/joif-smartdns-*.log.[2-9]* "${JOIF_NGINX_LOG_DIR}"/joif-smartdns-*.log.[1-9][0-9]*; do
        [[ -f "$f" ]] || continue
        rm -f "$f"
        pruned=$((pruned + 1))
    done

    # Si el log activo supera JOIF_LOG_MAX_BYTES, conserva solo las ultimas 500 lineas (mantiene actividad reciente)
    for f in "${JOIF_NGINX_LOG_DIR}"/joif-smartdns-*.log; do
        [[ -f "$f" ]] || continue
        size="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$size" =~ ^[0-9]+$ ]] && (( size > JOIF_LOG_MAX_BYTES )); then
            local tmp_tail
            tmp_tail="$(mktemp)"
            tail -n 500 "$f" > "$tmp_tail" 2>/dev/null || : > "$tmp_tail"
            cat "$tmp_tail" > "$f"
            rm -f "$tmp_tail"
            truncated=$((truncated + 1))
        fi
    done

    shopt -u nullglob
    if (( pruned > 0 || truncated > 0 )); then
        log_info "Control de espacio en logs: ${truncated} recortado(s) a 500 lineas, ${pruned} rotado(s) eliminado(s)."
    fi
}

# Limpieza agresiva y segura de todo lo que sobra en una VPS de 10 GB
# Opcion --clear-logs vacia tambien el log activo de nginx (tras consultar si se desea)
maintenance_cleanup_disk() {
    local clear_logs=0
    [[ "${1:-}" == "--clear-logs" ]] && clear_logs=1

    local avail_before_kb=0 avail_after_kb=0 freed_kb=0
    if command -v df >/dev/null 2>&1; then
        avail_before_kb="$(df -k -P / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
    fi

    log_info "Iniciando limpieza de disco (optimizado para VPS de 10 GB)..."

    # 1. Cache de APT y paquetes huerfanos (solo si somos root y existe apt-get y no estamos en modo test)
    if [[ "${JOIF_SKIP_SYSTEM_CLEANUP:-0}" != "1" && "${EUID:-$(id -u)}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
        apt-get autoclean -qq >/dev/null 2>&1 || true
        apt-get clean >/dev/null 2>&1 || true
        rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    fi

    # 2. Recortar logs de systemd-journald a 50 MB max
    if [[ "${JOIF_SKIP_SYSTEM_CLEANUP:-0}" != "1" && "${EUID:-$(id -u)}" -eq 0 ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-size=50M >/dev/null 2>&1 || true
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    fi

    # 3. Limpiar logs rotados y opcionalmente vaciar logs de acceso de nginx
    shopt -s nullglob
    local f
    for f in "${JOIF_NGINX_LOG_DIR}"/joif-smartdns-*.log.*; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    if [[ "$clear_logs" -eq 1 ]]; then
        for f in "${JOIF_NGINX_LOG_DIR}"/joif-smartdns-*.log; do
            [[ -f "$f" ]] && : > "$f"
        done
        log_ok "Logs de acceso de joif-smartdns vaciados."
    else
        maintenance_enforce_log_cap
    fi

    # 4. Limpiar temporales residuales de joif-smartdns
    for f in "${JOIF_STATE_DIR}"/*.tmp "${JOIF_CONFIG_DIR}"/*.tmp "${JOIF_CONFIG_DIR}"/.*.XXXXXX; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    shopt -u nullglob

    # 5. Retener como maximo JOIF_MAX_BACKUPS backups
    _maintenance_prune_backups

    if command -v df >/dev/null 2>&1; then
        avail_after_kb="$(df -k -P / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
        if [[ "$avail_after_kb" =~ ^[0-9]+$ && "$avail_before_kb" =~ ^[0-9]+$ ]] && (( avail_after_kb > avail_before_kb )); then
            freed_kb=$(( avail_after_kb - avail_before_kb ))
        fi
    fi

    local freed_human disk_avail_h
    freed_human="$(joif_human_bytes $(( freed_kb * 1024 )))"
    disk_avail_h="$(df -h -P / 2>/dev/null | awk 'NR==2{print $4 " libre (" $5 " usado)"}' || printf 'N/D')"
    log_ok "Limpieza completada. Espacio liberado: ${freed_human} | Disco (/): ${disk_avail_h}"
}

_maintenance_prune_backups() {
    [[ -d "$JOIF_BACKUP_DIR" ]] || return 0
    local -a backups=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && backups+=("$f")
    done < <(find "$JOIF_BACKUP_DIR" -maxdepth 1 -type f -name 'joif-backup-*.tar.gz' 2>/dev/null | LC_ALL=C sort -r)

    local i
    for (( i = JOIF_MAX_BACKUPS; i < ${#backups[@]}; i++ )); do
        rm -f "${backups[$i]}"
    done
}

# Crea backup liviano (~3 KB) unicamente con estado del usuario: config.env, licenses.db y domains.d/
maintenance_backup() {
    local dest="${1:-}"
    joif_ensure_dirs

    if [[ -z "$dest" ]]; then
        local ts
        ts="$(date -u '+%Y%m%d-%H%M%S')"
        dest="${JOIF_BACKUP_DIR}/joif-backup-${ts}.tar.gz"
    fi

    local stage
    stage="$(mktemp -d)"
    mkdir -p "${stage}/domains.d"

    [[ -f "$JOIF_CONFIG_FILE" ]] && cp -p "$JOIF_CONFIG_FILE" "${stage}/config.env"
    [[ -f "$JOIF_LICENSES_DB" ]] && cp -p "$JOIF_LICENSES_DB" "${stage}/licenses.db"
    if [[ -d "$JOIF_DOMAINS_DIR" ]]; then
        shopt -s nullglob
        local f
        for f in "${JOIF_DOMAINS_DIR}"/*.list "${JOIF_DOMAINS_DIR}"/*.list.disabled; do
            [[ -f "$f" ]] && cp -p "$f" "${stage}/domains.d/"
        done
        shopt -u nullglob
    fi

    mkdir -p "$(dirname "$dest")"
    tar -czf "$dest" -C "$stage" .
    chmod 640 "$dest"
    rm -rf "$stage"

    _maintenance_prune_backups

    local sz
    sz="$(wc -c < "$dest" | tr -d '[:space:]')"
    log_ok "Backup creado: ${dest} ($(joif_human_bytes "$sz"))"
    printf '%s\n' "$dest"
}

# Restaura un backup validando estrictamente las rutas dentro del archivo (anti path-traversal)
maintenance_restore() {
    local archive="${1:-}"
    if [[ -z "$archive" || ! -f "$archive" ]]; then
        log_error "Archivo de backup no encontrado: '${archive}'"
        return 1
    fi

    # Validar entradas del tar antes de extraer (rechazar rutas absolutas o ..)
    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == /* || "$entry" == *..* ]]; then
            log_error "Backup rechazado por seguridad (ruta insegura): '${entry}'"
            return 1
        fi
    done < <(tar -tzf "$archive")

    local stage
    stage="$(mktemp -d)"
    if ! tar -xzf "$archive" -C "$stage"; then
        rm -rf "$stage"
        log_error "No se pudo descomprimir el backup '${archive}'."
        return 1
    fi

    joif_ensure_dirs
    if [[ -f "${stage}/config.env" ]]; then
        cp -p "${stage}/config.env" "$JOIF_CONFIG_FILE"
        chmod 644 "$JOIF_CONFIG_FILE"
    fi
    if [[ -f "${stage}/licenses.db" ]]; then
        cp -p "${stage}/licenses.db" "$JOIF_LICENSES_DB"
        chmod 640 "$JOIF_LICENSES_DB"
    fi
    if [[ -d "${stage}/domains.d" ]]; then
        # Reemplazar listas de forma limpia manteniendo el estado exacto del backup
        rm -f "${JOIF_DOMAINS_DIR}"/*.list "${JOIF_DOMAINS_DIR}"/*.list.disabled 2>/dev/null || true
        shopt -s nullglob
        local f
        for f in "${stage}/domains.d"/*.list "${stage}/domains.d"/*.list.disabled; do
            [[ -f "$f" ]] && cp -p "$f" "${JOIF_DOMAINS_DIR}/"
        done
        shopt -u nullglob
    fi

    rm -rf "$stage"
    log_ok "Datos restaurados desde '${archive}'."

    if [[ "${JOIF_SKIP_SERVICE_RELOAD:-0}" != "1" ]]; then
        # shellcheck source=core/dnsmasq_gen.sh
        source "${SCRIPT_DIR}/dnsmasq_gen.sh"
        # shellcheck source=core/nginx_gen.sh
        source "${SCRIPT_DIR}/nginx_gen.sh"
        joif_load_config
        dnsmasq_apply "${JOIF_PUBLIC_IP:-}"
        nginx_apply
        bash "${SCRIPT_DIR}/firewall.sh" apply
    fi
}

maintenance_list_backups() {
    [[ -d "$JOIF_BACKUP_DIR" ]] || return 0
    local f sz
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        sz="$(wc -c < "$f" | tr -d '[:space:]')"
        printf '%s|%s\n' "$f" "$(joif_human_bytes "$sz")"
    done < <(find "$JOIF_BACKUP_DIR" -maxdepth 1 -type f -name 'joif-backup-*.tar.gz' 2>/dev/null | LC_ALL=C sort -r)
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-cleanup}"
    shift || true
    case "$cmd" in
        install-guards) maintenance_install_disk_guards ;;
        enforce-cap)    maintenance_enforce_log_cap ;;
        cleanup)        maintenance_cleanup_disk "${1:-}" ;;
        backup)         maintenance_backup "${1:-}" ;;
        restore)        maintenance_restore "${1:-}" ;;
        list-backups)   maintenance_list_backups ;;
        *)
            echo "Uso: $0 {install-guards|enforce-cap|cleanup [--clear-logs]|backup [archivo]|restore <archivo>|list-backups}" >&2
            exit 1
            ;;
    esac
fi
