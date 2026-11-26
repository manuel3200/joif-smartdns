#!/usr/bin/env bash
# install.sh — Instalador idempotente de joif-smartdns para Ubuntu 22.04 / 24.04 / 26.04 LTS
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${REPO_DIR}/core/common.sh"

ARG_PUBLIC_IP=""
ARG_ALLOW_IP=""
ARG_ALLOW_ALIAS="Nodo JOIF Inicial"
NON_INTERACTIVE=0

usage() {
    cat <<'EOF'
Uso: sudo ./install.sh [opciones]

Opciones:
  --public-ip <IPv4>       Especifica la IP publica de esta VPS Argentina
  --allow-ip <IPv4[/CIDR]> Autoriza automaticamente una IP inicial (ej. VPS Brasil/USA)
  --allow-alias <NOMBRE>   Alias para la IP inicial (por defecto: "Nodo JOIF Inicial")
  --non-interactive        Ejecuta sin preguntas interactivas
  -h, --help               Muestra esta ayuda
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --public-ip)       ARG_PUBLIC_IP="${2:-}"; shift 2 ;;
            --allow-ip)        ARG_ALLOW_IP="${2:-}"; shift 2 ;;
            --allow-alias)     ARG_ALLOW_ALIAS="${2:-}"; shift 2 ;;
            --non-interactive) NON_INTERACTIVE=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)
                log_error "Argumento desconocido: $1"
                usage
                exit 1
                ;;
        esac
    done
}

check_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        log_info "Sistema detectado: ${PRETTY_NAME:-${ID:-Linux}}"
        if [[ "${ID:-}" == "ubuntu" ]]; then
            case "${VERSION_ID:-}" in
                22.04|24.04|26.04)
                    log_ok "Ubuntu ${VERSION_ID} LTS verificado como soportado oficialmente."
                    ;;
                *)
                    log_warn "Ubuntu ${VERSION_ID:-desconocido} detectado. El soporte oficial es 22.04, 24.04 y 26.04 LTS."
                    ;;
            esac
        elif [[ "${ID_LIKE:-}" == *debian* || "${ID:-}" == "debian" ]]; then
            log_warn "Sistema basado en Debian (${PRETTY_NAME:-Debian}). Continuando con flujo compatible."
        else
            log_error "Este instalador esta disenado para Ubuntu 22.04/24.04/26.04 LTS (o derivados Debian con apt/systemd)."
            exit 1
        fi
    fi
}

free_port_53_safely() {
    log_info "Liberando puerto 53 de forma segura (systemd-resolved -> DNSStubListener=no)..."
    joif_ensure_dirs

    # Respaldar /etc/resolv.conf original solo una vez (para desinstalacion limpia)
    if [[ ! -f "${JOIF_BACKUP_DIR}/resolv.conf.saved" ]]; then
        if [[ -L /etc/resolv.conf ]]; then
            readlink /etc/resolv.conf > "${JOIF_BACKUP_DIR}/resolv.conf.link"
        elif [[ -f /etc/resolv.conf ]]; then
            cp -p /etc/resolv.conf "${JOIF_BACKUP_DIR}/resolv.conf.orig"
        fi
        date -u '+%Y-%m-%dT%H:%M:%SZ' > "${JOIF_BACKUP_DIR}/resolv.conf.saved"
    fi

    # Configurar drop-in de systemd-resolved
    mkdir -p "$(dirname "$JOIF_RESOLVED_DROPIN")"
    cat > "$JOIF_RESOLVED_DROPIN" <<EOF
[Resolve]
DNSStubListener=no
DNS=${JOIF_UPSTREAM_DNS_1} ${JOIF_UPSTREAM_DNS_2}
FallbackDNS=${JOIF_UPSTREAM_DNS_3} ${JOIF_UPSTREAM_DNS_4}
EOF

    # Reemplazar /etc/resolv.conf ANTES o junto con restart de systemd-resolved
    # para que el propio servidor nunca pierda resolucion DNS
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
# Managed by joif-smartdns — Resolvers directos para el propio sistema (evita bucle con dnsmasq local)
nameserver ${JOIF_UPSTREAM_DNS_1}
nameserver ${JOIF_UPSTREAM_DNS_2}
options edns0 timeout:2 attempts:2
EOF
    chmod 644 /etc/resolv.conf

    if systemctl is-active --quiet systemd-resolved 2>/dev/null || systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
        systemctl restart systemd-resolved || true
    fi

    # Validar resolucion local del propio host
    if getent hosts cloudflare.com >/dev/null 2>&1 || getent hosts ubuntu.com >/dev/null 2>&1; then
        log_ok "Resolucion DNS del propio sistema operativa via ${JOIF_UPSTREAM_DNS_1}/${JOIF_UPSTREAM_DNS_2}."
    else
        log_error "El sistema no pudo resolver DNS tras actualizar /etc/resolv.conf. Verifica conectividad a 1.1.1.1 / 8.8.8.8."
        exit 1
    fi

    # Validar que systemd-resolved ya no ocupe el puerto 53
    if command -v ss >/dev/null 2>&1; then
        local holder
        holder="$(ss -H -tulnp 'sport = :53' 2>/dev/null | grep -v 'dnsmasq' || true)"
        if [[ -n "$holder" ]]; then
            log_error "El puerto 53 sigue ocupado por otro proceso distinto de dnsmasq:"
            printf '%s\n' "$holder" >&2
            exit 1
        fi
    fi
    log_ok "Puerto 53 libre y listo para dnsmasq."
}

install_packages() {
    log_info "Instalando dependencias (dnsmasq, nginx, libnginx-mod-stream, ipset, iptables, dnsutils, curl, openssl)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        dnsmasq \
        nginx \
        libnginx-mod-stream \
        ipset \
        iptables \
        dnsutils \
        curl \
        openssl \
        ca-certificates

    # Evitar que /etc/default/dnsmasq o resolvconf inyecten resolvers locales
    if [[ -f /etc/default/dnsmasq ]]; then
        if grep -q '^#*IGNORE_RESOLVCONF=' /etc/default/dnsmasq; then
            sed -i 's/^#*IGNORE_RESOLVCONF=.*/IGNORE_RESOLVCONF=yes/' /etc/default/dnsmasq
        else
            printf '\nIGNORE_RESOLVCONF=yes\n' >> /etc/default/dnsmasq
        fi
    fi

    # Asegurar que /etc/dnsmasq.conf cargue /etc/dnsmasq.d/
    if [[ -f /etc/dnsmasq.conf ]] && ! grep -Eq '^[[:space:]]*conf-dir=/etc/dnsmasq\.d' /etc/dnsmasq.conf; then
        printf '\n# Incluido por joif-smartdns\nconf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new\n' >> /etc/dnsmasq.conf
    fi

    # Verificar que el modulo stream de nginx existe
    if [[ ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]] && ! ls /etc/nginx/modules-enabled/*stream*.conf >/dev/null 2>&1; then
        log_error "No se detecto el modulo ngx_stream_module.so tras instalar libnginx-mod-stream."
        exit 1
    fi

    log_ok "Paquetes instalados correctamente."
}

deploy_files() {
    log_info "Instalando archivos de joif-smartdns en ${JOIF_INSTALL_DIR}..."
    joif_ensure_dirs
    mkdir -p "${JOIF_INSTALL_DIR}/core" "${JOIF_INSTALL_DIR}/domains.d" "${JOIF_INSTALL_DIR}/systemd"

    if [[ "$(readlink -f "$REPO_DIR")" != "$(readlink -f "$JOIF_INSTALL_DIR")" ]]; then
        cp -f "${REPO_DIR}/install.sh" "${JOIF_INSTALL_DIR}/install.sh"
        cp -f "${REPO_DIR}/uninstall.sh" "${JOIF_INSTALL_DIR}/uninstall.sh"
        cp -f "${REPO_DIR}/menu.sh" "${JOIF_INSTALL_DIR}/menu.sh"
        cp -f "${REPO_DIR}/core/"*.sh "${JOIF_INSTALL_DIR}/core/"
        cp -f "${REPO_DIR}/domains.d/"*.list "${JOIF_INSTALL_DIR}/domains.d/"
        cp -f "${REPO_DIR}/systemd/"* "${JOIF_INSTALL_DIR}/systemd/"
    fi

    chmod 755 "${JOIF_INSTALL_DIR}/install.sh" \
              "${JOIF_INSTALL_DIR}/uninstall.sh" \
              "${JOIF_INSTALL_DIR}/menu.sh" \
              "${JOIF_INSTALL_DIR}/core/"*.sh

    # Copiar listas por defecto sin sobreescribir listas ya personalizadas o desactivadas
    local src base slug
    for src in "${JOIF_INSTALL_DIR}/domains.d/"*.list; do
        [[ -f "$src" ]] || continue
        base="$(basename "$src")"
        slug="${base%.list}"
        if [[ ! -f "${JOIF_DOMAINS_DIR}/${slug}.list" && ! -f "${JOIF_DOMAINS_DIR}/${slug}.list.disabled" ]]; then
            cp -f "$src" "${JOIF_DOMAINS_DIR}/${base}"
            chmod 644 "${JOIF_DOMAINS_DIR}/${base}"
        fi
    done

    # Enlace global /usr/local/bin/smartdns
    ln -sf "${JOIF_INSTALL_DIR}/menu.sh" /usr/local/bin/smartdns
    log_ok "Comando global 'smartdns' instalado en /usr/local/bin/smartdns."
}

configure_nginx_main() {
    if [[ -f "$JOIF_NGINX_MAIN_CONF" && ! -f "${JOIF_BACKUP_DIR}/nginx.conf.orig" ]]; then
        cp -p "$JOIF_NGINX_MAIN_CONF" "${JOIF_BACKUP_DIR}/nginx.conf.orig"
        log_info "Respaldo original de ${JOIF_NGINX_MAIN_CONF} guardado en ${JOIF_BACKUP_DIR}/nginx.conf.orig."
    fi

    # shellcheck source=core/nginx_gen.sh
    source "${JOIF_INSTALL_DIR}/core/nginx_gen.sh"
    nginx_render_main_conf "$JOIF_NGINX_MAIN_CONF"
}

install_systemd_units() {
    log_info "Instalando unidades systemd (firewall persistente + expiracion horaria)..."
    cp -f "${JOIF_INSTALL_DIR}/systemd/joif-smartdns-firewall.service" /etc/systemd/system/joif-smartdns-firewall.service
    cp -f "${JOIF_INSTALL_DIR}/systemd/joif-smartdns-expire.service"   /etc/systemd/system/joif-smartdns-expire.service
    cp -f "${JOIF_INSTALL_DIR}/systemd/joif-smartdns-expire.timer"     /etc/systemd/system/joif-smartdns-expire.timer

    chmod 644 /etc/systemd/system/joif-smartdns-firewall.service \
              /etc/systemd/system/joif-smartdns-expire.service \
              /etc/systemd/system/joif-smartdns-expire.timer

    systemctl daemon-reload
    systemctl enable joif-smartdns-firewall.service
    systemctl enable --now joif-smartdns-expire.timer
    log_ok "Unidades systemd habilitadas (arranque automatico y purga horaria de licencias)."
}

resolve_public_ip_step() {
    local detected=""
    detected="$(joif_detect_public_ip 2>/dev/null || true)"

    if [[ -n "$ARG_PUBLIC_IP" ]]; then
        if ! joif_validate_ipv4 "$ARG_PUBLIC_IP"; then
            log_error "IP publica invalida en --public-ip: '${ARG_PUBLIC_IP}'."
            exit 1
        fi
        JOIF_PUBLIC_IP="$ARG_PUBLIC_IP"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        if joif_validate_ipv4 "$detected"; then
            JOIF_PUBLIC_IP="$detected"
            return 0
        fi
        log_error "No se pudo autodetectar la IP publica en modo --non-interactive. Usa --public-ip <IP>."
        exit 1
    fi

    printf '\n'
    log_info "IP publica detectada para esta VPS Argentina: ${detected:-no detectada}"
    local input_ip
    read -r -p "Confirma o ingresa la IP publica IPv4 del Smart DNS [${detected}]: " input_ip
    input_ip="${input_ip:-$detected}"
    if ! joif_validate_ipv4 "$input_ip"; then
        log_error "IPv4 invalida: '${input_ip}'."
        exit 1
    fi
    JOIF_PUBLIC_IP="$input_ip"
}

setup_initial_license() {
    # shellcheck source=core/licenses.sh
    source "${JOIF_INSTALL_DIR}/core/licenses.sh"
    license_init_db

    if [[ -n "$ARG_ALLOW_IP" ]]; then
        JOIF_AUTO_SYNC_FIREWALL=0 license_add "$ARG_ALLOW_IP" "$ARG_ALLOW_ALIAS" 0 --upsert
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        return 0
    fi

    printf '\n'
    log_info "Recuerda: los puertos 53, 80 y 443 estaran bloqueados para IPs externas no autorizadas (SSH 22 siempre queda intacto)."
    local vps_ip vps_alias
    read -r -p "Quieres autorizar ahora la IP publica de tu VPS de Brasil/USA? (Enter para omitir): " vps_ip
    if [[ -n "$vps_ip" ]]; then
        read -r -p "Alias para esta IP [Nodo JOIF Principal]: " vps_alias
        vps_alias="${vps_alias:-Nodo JOIF Principal}"
        JOIF_AUTO_SYNC_FIREWALL=0 license_add "$vps_ip" "$vps_alias" 0 --upsert || log_warn "No se pudo agregar '${vps_ip}'; podras agregarla luego desde 'smartdns'."
    fi
}

main() {
    parse_args "$@"
    joif_require_root

    printf '\n%b====================================================================%b\n' "$C_CYAN" "$C_RESET"
    printf '%b  Instalador de joif-smartdns (Smart DNS + SNI Proxy AR) v%s%b\n' "$C_BOLD" "$JOIF_VERSION" "$C_RESET"
    printf '%b====================================================================%b\n\n' "$C_CYAN" "$C_RESET"

    check_os
    free_port_53_safely
    install_packages
    resolve_public_ip_step
    deploy_files

    # Guardar config.env
    joif_save_config

    # Configurar NGINX principal + generar y aplicar dnsmasq y nginx
    configure_nginx_main

    # shellcheck source=core/dnsmasq_gen.sh
    source "${JOIF_INSTALL_DIR}/core/dnsmasq_gen.sh"
    # shellcheck source=core/nginx_gen.sh
    source "${JOIF_INSTALL_DIR}/core/nginx_gen.sh"

    systemctl enable dnsmasq nginx >/dev/null 2>&1 || true
    dnsmasq_apply "$JOIF_PUBLIC_IP"
    nginx_apply

    # Inicializar licencias, systemd y firewall seguro (NUNCA toca SSH 22)
    setup_initial_license
    install_systemd_units
    bash "${JOIF_INSTALL_DIR}/core/firewall.sh" apply

    # Ejecutar diagnostico final
    bash "${JOIF_INSTALL_DIR}/core/diagnostics.sh" || true

    printf '%b====================================================================%b\n' "$C_GREEN" "$C_RESET"
    printf '%b  Instalacion completada con exito!%b\n' "$C_BOLD" "$C_RESET"
    printf '  - IP DNS Primaria (VPS AR) : %s\n' "$JOIF_PUBLIC_IP"
    printf '  - Panel administrativo     : sudo smartdns\n'
    printf '  - Diagnostico rapido       : sudo smartdns status\n'
    printf '  - Autorizar VPS Brasil/USA : sudo smartdns ip add <IP_VPS> "Nodo Brasil 01" 0\n'
    printf '%b====================================================================%b\n\n' "$C_GREEN" "$C_RESET"
}

main "$@"
