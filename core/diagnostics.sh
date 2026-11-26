#!/usr/bin/env bash
# core/diagnostics.sh — Diagnostico integral de servicios, puertos, DNS anti-fuga y SNI proxy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/domains.sh
source "${SCRIPT_DIR}/domains.sh"
# shellcheck source=core/dnsmasq_gen.sh
source "${SCRIPT_DIR}/dnsmasq_gen.sh"
# shellcheck source=core/licenses.sh
source "${SCRIPT_DIR}/licenses.sh"

_diag_badge() {
    local ok="${1:-0}"
    local label="${2:-}"
    if [[ "$ok" == "0" ]]; then
        printf '%b[  OK  ]%b %s\n' "$C_GREEN" "$C_RESET" "$label"
    elif [[ "$ok" == "2" ]]; then
        printf '%b[ WARN ]%b %s\n' "$C_YELLOW" "$C_RESET" "$label"
    else
        printf '%b[ FAIL ]%b %s\n' "$C_RED" "$C_RESET" "$label"
    fi
}

_diag_check_service() {
    local svc="$1"
    if ! command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        _diag_badge 2 "Servicio ${svc}: systemctl no disponible"
        return 0
    fi
    if "$JOIF_SYSTEMCTL_BIN" is-active --quiet "$svc" 2>/dev/null; then
        _diag_badge 0 "Servicio ${svc}: ACTIVO"
    else
        _diag_badge 1 "Servicio ${svc}: INACTIVO"
    fi
}

_diag_check_port() {
    local proto="$1"
    local port="$2"
    if ! command -v ss >/dev/null 2>&1; then
        _diag_badge 2 "Puerto ${port}/${proto}: comando 'ss' no disponible"
        return 0
    fi
    local flag="-tlnp"
    [[ "$proto" == "udp" ]] && flag="-ulnp"
    local line
    line="$(ss -H "$flag" "sport = :${port}" 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
        local proc
        proc="$(printf '%s' "$line" | sed -nE 's/.*users:\(\("([^"]+)".*/\1/p')"
        _diag_badge 0 "Puerto ${port}/${proto} escuchando (${proc:-activo})"
    else
        _diag_badge 1 "Puerto ${port}/${proto} NO esta escuchando"
    fi
}

diagnostics_run() {
    joif_load_config

    printf '\n%b====================================================================%b\n' "$C_CYAN" "$C_RESET"
    printf '%b  JOIF Smart DNS — Estado y Diagnostico Integral (v%s)%b\n' "$C_BOLD" "$JOIF_VERSION" "$C_RESET"
    printf '%b====================================================================%b\n\n' "$C_CYAN" "$C_RESET"

    # 1. IP Publica Primaria
    local cfg_ip live_ip
    cfg_ip="${JOIF_PUBLIC_IP:-no-configurada}"
    live_ip="$(joif_detect_public_ip 2>/dev/null || printf 'no-detectada')"

    printf '%b[1] Identidad del Servidor Smart DNS (IP Primaria)%b\n' "$C_BOLD" "$C_RESET"
    printf '    IP configurada (config.env) : %b%s%b\n' "$C_GREEN" "$cfg_ip" "$C_RESET"
    printf '    IP publica detectada en vivo: %b%s%b\n' "$C_CYAN" "$live_ip" "$C_RESET"
    if [[ "$live_ip" != "no-detectada" && "$cfg_ip" != "$live_ip" ]]; then
        _diag_badge 2 "La IP configurada (${cfg_ip}) difiere de la IP publica actual (${live_ip}). Actualizala en Configuracion avanzada."
    elif [[ "$cfg_ip" != "no-configurada" ]]; then
        _diag_badge 0 "IP Primaria consistente (${cfg_ip}) — configura esta IP como DNS en tus VPS de Brasil/USA o app JOIF."
    else
        _diag_badge 1 "No hay IP publica configurada en ${JOIF_CONFIG_FILE}."
    fi

    # 2. Servicios Systemd
    printf '\n%b[2] Servicios y Temporizadores%b\n' "$C_BOLD" "$C_RESET"
    _diag_check_service "dnsmasq"
    _diag_check_service "nginx"
    _diag_check_service "joif-smartdns-firewall.service"
    _diag_check_service "joif-smartdns-expire.timer"

    # 3. Puertos en escucha
    printf '\n%b[3] Puertos en Escucha (53 / 80 / 443)%b\n' "$C_BOLD" "$C_RESET"
    _diag_check_port "udp" "53"
    _diag_check_port "tcp" "53"
    _diag_check_port "tcp" "80"
    _diag_check_port "tcp" "443"

    # 4. Firewall + ipset + Licencias
    printf '\n%b[4] Firewall (ipset + iptables) y Licencias%b\n' "$C_BOLD" "$C_RESET"
    local active_db_count ipset_count
    active_db_count="$(license_active_ips | wc -l | tr -d '[:space:]')"
    if command -v "$JOIF_IPSET_BIN" >/dev/null 2>&1 && "$JOIF_IPSET_BIN" list "$JOIF_IPSET_NAME" >/dev/null 2>&1; then
        ipset_count="$("$JOIF_IPSET_BIN" list "$JOIF_IPSET_NAME" 2>/dev/null | awk '/^Members:/{f=1;next} f && NF{c++} END{print c+0}')"
        _diag_badge 0 "ipset '${JOIF_IPSET_NAME}' activo (${ipset_count} en kernel / ${active_db_count} activas en DB)"
    else
        _diag_badge 1 "ipset '${JOIF_IPSET_NAME}' no encontrado en el kernel"
    fi

    if command -v "$JOIF_IPTABLES_BIN" >/dev/null 2>&1 && "$JOIF_IPTABLES_BIN" -L "$JOIF_IPTABLES_CHAIN" -n >/dev/null 2>&1; then
        local jumps=0 spec proto port
        for spec in "udp:53" "tcp:53" "tcp:80" "tcp:443"; do
            proto="${spec%%:*}"
            port="${spec#*:}"
            "$JOIF_IPTABLES_BIN" -C INPUT -p "$proto" --dport "$port" -j "$JOIF_IPTABLES_CHAIN" 2>/dev/null && jumps=$((jumps + 1))
        done
        if (( jumps == 4 )); then
            _diag_badge 0 "Cadena '${JOIF_IPTABLES_CHAIN}' protegiendo 4/4 puertos (53/udp, 53/tcp, 80/tcp, 443/tcp) — SSH 22 intacto"
        else
            _diag_badge 2 "Cadena '${JOIF_IPTABLES_CHAIN}' solo cubre ${jumps}/4 puertos. Reaplica el firewall."
        fi
    else
        _diag_badge 1 "Cadena iptables '${JOIF_IPTABLES_CHAIN}' no aplicada"
    fi

    # 5. Dominios y capacidad dnsmasq
    printf '\n%b[5] Listas de Dominios y Anti-Fuga dnsmasq%b\n' "$C_BOLD" "$C_RESET"
    local total_domains dver
    total_domains="$(domains_collect_active | wc -l | tr -d '[:space:]')"
    dver="$(dnsmasq_detect_version || printf 'desconocida')"
    _diag_badge 0 "Dominios argentinos activos interceptados: ${total_domains}"
    if dnsmasq_supports_filter_rr; then
        _diag_badge 0 "dnsmasq v${dver}: filter-rr=HTTPS,SVCB HABILITADO (sin fuga Tipo 65/64)"
    else
        _diag_badge 2 "dnsmasq v${dver}: filter-rr=HTTPS,SVCB no soportado por esta version (AAAA sigue bloqueado via NODATA)"
    fi

    # 6. Pruebas DNS en vivo contra 127.0.0.1
    printf '\n%b[6] Pruebas DNS Locales en Vivo (@127.0.0.1)%b\n' "$C_BOLD" "$C_RESET"
    local test_domain="mercadopago.com.ar"
    if ! domains_collect_active | grep -Fx "$test_domain" >/dev/null; then
        test_domain="$(domains_collect_active | head -n1 || true)"
    fi

    if ! command -v dig >/dev/null 2>&1; then
        _diag_badge 2 "Herramienta 'dig' (dnsutils) no instalada; omitiendo pruebas DNS en vivo."
    elif [[ -z "$test_domain" ]]; then
        _diag_badge 2 "No hay dominios activos para probar resolucion selectiva."
    else
        local ans_a ans_aaaa ans_https ans_direct
        ans_a="$(dig +short +time=3 +tries=1 @127.0.0.1 "$test_domain" A 2>/dev/null | head -n1 || true)"
        if [[ -n "$ans_a" && "$ans_a" == "$cfg_ip" ]]; then
            _diag_badge 0 "Interceptado ${test_domain} (A) -> ${ans_a} (coincide con VPS AR)"
        else
            _diag_badge 1 "Interceptado ${test_domain} (A) devolvio '${ans_a:-vacio}' (esperado: ${cfg_ip})"
        fi

        ans_aaaa="$(dig +short +time=3 +tries=1 @127.0.0.1 "$test_domain" AAAA 2>/dev/null | head -n1 || true)"
        if [[ -z "$ans_aaaa" ]]; then
            _diag_badge 0 "Anti-fuga IPv6 ${test_domain} (AAAA) -> NODATA (vacio, correcto)"
        else
            _diag_badge 1 "FUGA IPv6 detectada: ${test_domain} (AAAA) devolvio ${ans_aaaa}"
        fi

        ans_https="$(dig +short +time=3 +tries=1 @127.0.0.1 "$test_domain" TYPE65 2>/dev/null | head -n1 || true)"
        if [[ -z "$ans_https" ]]; then
            _diag_badge 0 "Anti-fuga HTTPS/SVCB ${test_domain} (TYPE65) -> vacio (correcto)"
        else
            _diag_badge 2 "TYPE65 (HTTPS) devolvio registro para ${test_domain}: ${ans_https}"
        fi

        ans_direct="$(dig +short +time=3 +tries=1 @127.0.0.1 "cloudflare.com" A 2>/dev/null | head -n1 || true)"
        if [[ -n "$ans_direct" && "$ans_direct" != "$cfg_ip" ]]; then
            _diag_badge 0 "Dominio normal cloudflare.com (A) -> ${ans_direct} (sale directo sin pasar por AR)"
        else
            _diag_badge 1 "Dominio normal cloudflare.com devolvio '${ans_direct:-vacio}'"
        fi
    fi

    # 7. Pruebas SNI Proxy TLS (443) y Anti-Abuso en vivo
    printf '\n%b[7] Pruebas SNI Proxy TLS (127.0.0.1:443) y Anti-Abuso%b\n' "$C_BOLD" "$C_RESET"
    if ! command -v openssl >/dev/null 2>&1; then
        _diag_badge 2 "Herramienta 'openssl' no instalada; omitiendo prueba TLS SNI."
    elif [[ -z "$test_domain" ]]; then
        _diag_badge 2 "Sin dominios activos para probar SNI passthrough."
    else
        local sni_out subj
        sni_out="$(timeout 6 openssl s_client -connect 127.0.0.1:443 -servername "$test_domain" </dev/null 2>&1 || true)"
        subj="$(printf '%s\n' "$sni_out" | grep -m1 '^subject=' || true)"
        if [[ -n "$subj" ]]; then
            _diag_badge 0 "SNI Passthrough OK para ${test_domain} (${subj})"
        else
            _diag_badge 1 "SNI Passthrough fallo para ${test_domain} contra 127.0.0.1:443"
        fi

        # Prueba negativa anti-abuso (dominio fuera de lista debe ser rechazado)
        if ! domains_collect_active | grep -Fx "example.com" >/dev/null; then
            local deny_out
            deny_out="$(timeout 4 openssl s_client -connect 127.0.0.1:443 -servername "example.com" </dev/null 2>&1 || true)"
            if ! printf '%s\n' "$deny_out" | grep '^subject=' >/dev/null; then
                _diag_badge 0 "Anti-abuso SNI (443): dominio no autorizado 'example.com' RECHAZADO correctamente"
            else
                _diag_badge 1 "ALERTA SEGURIDAD: 'example.com' paso por el SNI proxy sin estar en la allowlist"
            fi
        fi
    fi

    printf '\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    diagnostics_run
fi
