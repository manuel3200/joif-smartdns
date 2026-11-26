#!/usr/bin/env bash
# core/telegram_bot.sh — Instalador y gestor del Bot de Telegram en Rust (joif-tgbot)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"

JOIF_TGBOT_BIN="${JOIF_TGBOT_BIN:-/usr/local/bin/joif-tgbot}"
JOIF_TGBOT_ENV="${JOIF_TGBOT_ENV:-${JOIF_CONFIG_DIR}/telegram.env}"
JOIF_TGBOT_SERVICE="${JOIF_TGBOT_SERVICE:-joif-smartdns-bot.service}"
JOIF_TGBOT_RELEASE_BASE="${JOIF_TGBOT_RELEASE_BASE:-${JOIF_REPO_URL%.git}/releases/download/bot-latest}"

tgbot_save_env() {
    local token="$1"
    local admins="$2"
    local alert_mbps="${3:-8.5}"
    local alert_disk="${4:-85}"

    joif_ensure_dirs
    local tmp
    tmp="$(mktemp "${JOIF_CONFIG_DIR}/.telegram.env.XXXXXX")"
    cat > "$tmp" <<EOF
# joif-smartdns — Configuracion privada del Bot de Telegram (permisos 600, nunca compartir)
TELEGRAM_BOT_TOKEN="${token}"
TELEGRAM_ADMIN_IDS="${admins}"
TELEGRAM_ALERT_MBPS="${alert_mbps}"
TELEGRAM_ALERT_DISK_PCT="${alert_disk}"
TELEGRAM_ALERT_CHECK_SEC="300"
JOIF_SMARTDNS_BIN="/usr/local/bin/smartdns"
JOIF_LICENSES_DB="${JOIF_LICENSES_DB}"
EOF
    chmod 600 "$tmp"
    mv -f "$tmp" "$JOIF_TGBOT_ENV"
    log_ok "Configuracion guardada en ${JOIF_TGBOT_ENV} (permisos 600)."
}

tgbot_download_binary() {
    local arch
    arch="$(uname -m 2>/dev/null || echo x86_64)"
    if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
        log_error "Arquitectura '${arch}' no soportada por el binario precompilado x86_64."
        return 1
    fi

    local bin_url="${JOIF_TGBOT_RELEASE_BASE}/joif-tgbot-linux-x86_64"
    local sha_url="${JOIF_TGBOT_RELEASE_BASE}/joif-tgbot-linux-x86_64.sha256"

    local tmp_dir
    tmp_dir="$(mktemp -d)"

    log_info "Descargando binario estatico Rust (joif-tgbot) desde GitHub Releases..."
    if ! curl -4 -fsSL --connect-timeout 5 --max-time 60 "$bin_url" -o "${tmp_dir}/joif-tgbot-linux-x86_64"; then
        rm -rf "$tmp_dir"
        log_error "No se pudo descargar ${bin_url}. Verifica que el build de GitHub Actions ('bot-latest') haya finalizado."
        return 1
    fi

    if curl -4 -fsSL --connect-timeout 5 --max-time 15 "$sha_url" -o "${tmp_dir}/joif-tgbot-linux-x86_64.sha256" 2>/dev/null; then
        if command -v sha256sum >/dev/null 2>&1; then
            if ! (cd "$tmp_dir" && sha256sum -c joif-tgbot-linux-x86_64.sha256 >/dev/null 2>&1); then
                rm -rf "$tmp_dir"
                log_error "Fallo la verificacion SHA256 del binario joif-tgbot."
                return 1
            fi
            log_ok "Integridad SHA256 verificada."
        fi
    fi

    chmod 755 "${tmp_dir}/joif-tgbot-linux-x86_64"
    mkdir -p "$(dirname "$JOIF_TGBOT_BIN")"
    mv -f "${tmp_dir}/joif-tgbot-linux-x86_64" "$JOIF_TGBOT_BIN"
    rm -rf "$tmp_dir"

    local ver
    ver="$("$JOIF_TGBOT_BIN" --version 2>/dev/null || echo 'instalado')"
    log_ok "Binario instalado en ${JOIF_TGBOT_BIN} (${ver})."
}

tgbot_install_unit() {
    local unit_src="${JOIF_INSTALL_DIR}/systemd/${JOIF_TGBOT_SERVICE}"
    [[ ! -f "$unit_src" ]] && unit_src="${SCRIPT_DIR}/../systemd/${JOIF_TGBOT_SERVICE}"
    if [[ ! -f "$unit_src" ]]; then
        log_error "No se encontro ${unit_src}."
        return 1
    fi
    cp -f "$unit_src" "/etc/systemd/system/${JOIF_TGBOT_SERVICE}"
    chmod 644 "/etc/systemd/system/${JOIF_TGBOT_SERVICE}"
    "$JOIF_SYSTEMCTL_BIN" daemon-reload
    "$JOIF_SYSTEMCTL_BIN" enable "$JOIF_TGBOT_SERVICE" >/dev/null 2>&1 || true
}

tgbot_setup_interactive() {
    printf '\n%b--- Configurar Bot de Telegram en Rust (joif-tgbot) ---%b\n' "$C_BOLD" "$C_RESET"
    printf 'Requisitos:\n'
    printf '  1) Crea tu bot en @BotFather y copia el Token (ej. 123456:ABC...)\n'
    printf '  2) Obten tu ID numerico en @userinfobot (solo TU podras usar el bot)\n\n'

    local token admins alert_mbps alert_disk
    read -r -p "Token del bot (@BotFather): " token || return 0
    [[ -z "$token" ]] && { log_warn "Configuracion cancelada."; return 0; }
    if [[ "$token" != *:* ]]; then
        log_error "Token invalido (debe contener ':')."
        return 1
    fi

    read -r -p "Tu Telegram User ID numerico (podes separar varios con coma): " admins || return 0
    [[ -z "$admins" ]] && { log_warn "Configuracion cancelada."; return 0; }
    if [[ ! "$admins" =~ ^[0-9,\ ]+$ ]]; then
        log_error "ID invalido: usa solo numeros (ej. 123456789)."
        return 1
    fi

    read -r -p "Alerta de ancho de banda en Mbps (0 = desactivar) [8.5]: " alert_mbps || return 0
    alert_mbps="${alert_mbps:-8.5}"
    read -r -p "Alerta de uso de disco % (0 = desactivar) [85]: " alert_disk || return 0
    alert_disk="${alert_disk:-85}"

    tgbot_save_env "$token" "$admins" "$alert_mbps" "$alert_disk"

    if [[ ! -x "$JOIF_TGBOT_BIN" ]]; then
        tgbot_download_binary || return 1
    fi

    tgbot_install_unit
    "$JOIF_SYSTEMCTL_BIN" restart "$JOIF_TGBOT_SERVICE"

    log_info "Enviando mensaje de prueba a Telegram..."
    if JOIF_TELEGRAM_ENV="$JOIF_TGBOT_ENV" "$JOIF_TGBOT_BIN" --test-ping; then
        log_ok "Bot conectado y funcionando! Revisa tu chat de Telegram."
    else
        log_warn "El servicio inicio, pero fallo el envio de prueba. Verifica Token, ID y que hayas presionado 'Iniciar' en tu bot."
    fi
}

tgbot_status() {
    printf '\n%b=== Estado del Bot de Telegram (Rust) ===%b\n' "$C_BOLD" "$C_RESET"
    if [[ -x "$JOIF_TGBOT_BIN" ]]; then
        local sz ver
        sz="$(wc -c < "$JOIF_TGBOT_BIN" | tr -d '[:space:]')"
        ver="$("$JOIF_TGBOT_BIN" --version 2>/dev/null || echo 'ok')"
        printf '  Binario : %s (%s, %s)\n' "$JOIF_TGBOT_BIN" "$ver" "$(joif_human_bytes "$sz")"
    else
        printf '  Binario : %bNo instalado%b\n' "$C_YELLOW" "$C_RESET"
    fi
    if [[ -f "$JOIF_TGBOT_ENV" ]]; then
        printf '  Config  : %s (presente)\n' "$JOIF_TGBOT_ENV"
    else
        printf '  Config  : %bNo configurada%b\n' "$C_YELLOW" "$C_RESET"
    fi
    if command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        if "$JOIF_SYSTEMCTL_BIN" is-active --quiet "$JOIF_TGBOT_SERVICE" 2>/dev/null; then
            local mem
            mem="$("$JOIF_SYSTEMCTL_BIN" show "$JOIF_TGBOT_SERVICE" -p MemoryCurrent --value 2>/dev/null || echo 0)"
            printf '  Servicio: %bACTIVO%b (RAM actual: %s)\n' "$C_GREEN" "$C_RESET" "$(joif_human_bytes "${mem:-0}")"
        else
            printf '  Servicio: %bINACTIVO%b\n' "$C_RED" "$C_RESET"
        fi
    fi
    printf '\n'
}

tgbot_remove() {
    if command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        "$JOIF_SYSTEMCTL_BIN" disable --now "$JOIF_TGBOT_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${JOIF_TGBOT_SERVICE}"
        "$JOIF_SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$JOIF_TGBOT_BIN" "$JOIF_TGBOT_ENV"
    log_ok "Bot de Telegram eliminado completamente."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-status}"
    shift || true
    case "$cmd" in
        setup)   tgbot_setup_interactive ;;
        update)  tgbot_download_binary && "$JOIF_SYSTEMCTL_BIN" restart "$JOIF_TGBOT_SERVICE" 2>/dev/null || true ;;
        status)  tgbot_status ;;
        start)   "$JOIF_SYSTEMCTL_BIN" start "$JOIF_TGBOT_SERVICE" && log_ok "Bot iniciado." ;;
        stop)    "$JOIF_SYSTEMCTL_BIN" stop "$JOIF_TGBOT_SERVICE" && log_ok "Bot detenido." ;;
        restart) "$JOIF_SYSTEMCTL_BIN" restart "$JOIF_TGBOT_SERVICE" && log_ok "Bot reiniciado." ;;
        logs)    journalctl -u "$JOIF_TGBOT_SERVICE" -n 30 --no-pager ;;
        remove)  tgbot_remove ;;
        *)
            echo "Uso: $0 {setup|update|status|start|stop|restart|logs|remove}" >&2
            exit 1
            ;;
    esac
fi
