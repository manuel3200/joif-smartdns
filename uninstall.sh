#!/usr/bin/env bash
# uninstall.sh — Desinstalador limpio de joif-smartdns (restaura systemd-resolved y limpia firewall sin tocar SSH)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/core/common.sh" ]]; then
    # shellcheck source=core/common.sh
    source "${SCRIPT_DIR}/core/common.sh"
elif [[ -f "/opt/joif-smartdns/core/common.sh" ]]; then
    # shellcheck source=core/common.sh
    source "/opt/joif-smartdns/core/common.sh"
else
    echo "[ERR ] No se encontro core/common.sh." >&2
    exit 1
fi

AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
        -h|--help)
            echo "Uso: sudo $0 [--yes]"
            exit 0
            ;;
    esac
done

joif_require_root

if [[ "$AUTO_YES" -ne 1 ]]; then
    printf '\nEsto desinstalara joif-smartdns, restaurara systemd-resolved y limpiara sus reglas de firewall.\n'
    printf 'El acceso SSH (puerto 22) NO sera modificado ni interrumpido.\n\n'
    read -r -p "Deseas continuar? [s/N]: " ans
    if [[ ! "$ans" =~ ^[sSyY]$ ]]; then
        log_info "Desinstalacion cancelada."
        exit 0
    fi
fi

log_info "Iniciando desinstalacion limpia de joif-smartdns..."

# 1. Limpiar reglas de firewall e ipset (NUNCA toca SSH 22)
if [[ -f "${JOIF_INSTALL_DIR}/core/firewall.sh" ]]; then
    bash "${JOIF_INSTALL_DIR}/core/firewall.sh" teardown || true
elif [[ -f "${SCRIPT_DIR}/core/firewall.sh" ]]; then
    bash "${SCRIPT_DIR}/core/firewall.sh" teardown || true
fi

# 2. Deshabilitar y eliminar unidades systemd propias
for unit in joif-smartdns-bot.service joif-smartdns-expire.timer joif-smartdns-expire.service joif-smartdns-firewall.service; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}"
done
rm -f /usr/local/bin/joif-tgbot
systemctl daemon-reload >/dev/null 2>&1 || true
log_ok "Unidades systemd de joif-smartdns eliminadas."

# 3. Remover configuracion de dnsmasq y detenerlo para liberar puerto 53
rm -f "$JOIF_DNSMASQ_CONF"
if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    systemctl stop dnsmasq >/dev/null 2>&1 || true
    systemctl disable dnsmasq >/dev/null 2>&1 || true
fi
log_ok "Configuracion de dnsmasq eliminada y puerto 53 liberado."

# 4. Restaurar nginx.conf original
if [[ -f "${JOIF_BACKUP_DIR}/nginx.conf.orig" ]]; then
    cp -p "${JOIF_BACKUP_DIR}/nginx.conf.orig" "$JOIF_NGINX_MAIN_CONF"
    if command -v "$JOIF_NGINX_BIN" >/dev/null 2>&1 && "$JOIF_NGINX_BIN" -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
    else
        systemctl stop nginx >/dev/null 2>&1 || true
    fi
    log_ok "Configuracion original de nginx restaurada."
else
    systemctl stop nginx >/dev/null 2>&1 || true
fi

# 5. Restaurar systemd-resolved y /etc/resolv.conf con garantia de conectividad DNS
rm -f "$JOIF_RESOLVED_DROPIN"
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
fi

if [[ -f "${JOIF_BACKUP_DIR}/resolv.conf.link" ]]; then
    orig_link="$(cat "${JOIF_BACKUP_DIR}/resolv.conf.link")"
    rm -f /etc/resolv.conf
    ln -s "$orig_link" /etc/resolv.conf
    log_ok "/etc/resolv.conf restaurado como enlace simbolico -> ${orig_link}."
elif [[ -f "${JOIF_BACKUP_DIR}/resolv.conf.orig" ]]; then
    rm -f /etc/resolv.conf
    cp -p "${JOIF_BACKUP_DIR}/resolv.conf.orig" /etc/resolv.conf
    log_ok "/etc/resolv.conf restaurado desde respaldo original."
elif [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    log_ok "/etc/resolv.conf restaurado a /run/systemd/resolve/stub-resolv.conf."
fi

# Red de seguridad: comprobar que el servidor conserva resolucion DNS activa
if ! getent hosts cloudflare.com >/dev/null 2>&1; then
    log_warn "DNS no respondio tras restaurar resolv.conf; aplicando fallback seguro (1.1.1.1 / 8.8.8.8)."
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
fi

# 6. Eliminar protecciones de disco y archivos de joif-smartdns
rm -f "$JOIF_LOGROTATE_FILE" "$JOIF_JOURNALD_DROPIN"
systemctl restart systemd-journald >/dev/null 2>&1 || true
rm -f /usr/local/bin/smartdns
rm -rf "$JOIF_CONFIG_DIR" "$JOIF_STATE_DIR"
if [[ -d "$JOIF_INSTALL_DIR" ]]; then
    rm -rf "$JOIF_INSTALL_DIR"
fi

log_ok "joif-smartdns desinstalado completamente (SSH 22 intacto y DNS del sistema operativo)."
