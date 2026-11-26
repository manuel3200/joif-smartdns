#!/usr/bin/env bash
# core/dnsmasq_gen.sh — Generador de configuracion dnsmasq con anti-fuga IPv6/HTTPS y rollback

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/domains.sh
source "${SCRIPT_DIR}/domains.sh"

dnsmasq_detect_version() {
    if [[ -n "${JOIF_DNSMASQ_VERSION_OVERRIDE:-}" ]]; then
        printf '%s\n' "$JOIF_DNSMASQ_VERSION_OVERRIDE"
        return 0
    fi
    if ! command -v "$JOIF_DNSMASQ_BIN" >/dev/null 2>&1; then
        printf 'unknown\n'
        return 1
    fi
    local line ver
    line="$("$JOIF_DNSMASQ_BIN" --version 2>/dev/null | head -n1 || true)"
    ver="$(printf '%s' "$line" | sed -nE 's/.*[Vv]ersion[[:space:]]+([0-9]+(\.[0-9]+)*).*/\1/p')"
    if [[ -n "$ver" ]]; then
        printf '%s\n' "$ver"
        return 0
    fi
    printf 'unknown\n'
    return 1
}

# Verifica dinamicamente si el binario de dnsmasq soporta filter-rr=HTTPS,SVCB
dnsmasq_supports_filter_rr() {
    local mode="${JOIF_DNSMASQ_FILTER_RR:-auto}"
    case "$mode" in
        yes|true|1) return 0 ;;
        no|false|0) return 1 ;;
    esac

    # Si existe el binario real (o un mock ejecutable en tests), probamos con --test
    if [[ -z "${JOIF_DNSMASQ_VERSION_OVERRIDE:-}" ]] && command -v "$JOIF_DNSMASQ_BIN" >/dev/null 2>&1; then
        local probe_tmp
        probe_tmp="$(mktemp)"
        cat > "$probe_tmp" <<'EOF'
no-resolv
filter-rr=AAAA,HTTPS,SVCB
EOF
        if "$JOIF_DNSMASQ_BIN" --test --conf-file="$probe_tmp" >/dev/null 2>&1; then
            rm -f "$probe_tmp"
            return 0
        fi
        rm -f "$probe_tmp"
        return 1
    fi

    # Fallback por version (dnsmasq 2.90+ introdujo --filter-rr nativamente;
    # Ubuntu 24.04 trae 2.90, Ubuntu 26.04 trae 2.91+, Ubuntu 22.04 trae 2.86)
    local ver
    ver="$(dnsmasq_detect_version || true)"
    if [[ "$ver" != "unknown" ]] && joif_version_ge "$ver" "2.90"; then
        return 0
    fi
    return 1
}

# Genera el contenido de la configuracion de dnsmasq en stdout (o archivo destino $2)
dnsmasq_render_config() {
    local public_ip="${1:-}"
    local output_file="${2:-}"

    if ! joif_validate_ipv4 "$public_ip"; then
        log_error "IP publica IPv4 invalida para dnsmasq: '${public_ip}'"
        return 1
    fi

    local ver filter_rr_enabled="no"
    ver="$(dnsmasq_detect_version || printf 'unknown')"
    if dnsmasq_supports_filter_rr; then
        filter_rr_enabled="yes"
    fi

    local -a domains=()
    local d
    while IFS= read -r d; do
        [[ -n "$d" ]] && domains+=("$d")
    done < <(domains_collect_active)

    local rendered
    rendered="$(mktemp)"
    {
        cat <<EOF
# ==============================================================================
# joif-smartdns — Configuracion generada automaticamente para dnsmasq
# NO editar a mano: usa 'smartdns' o edita /etc/joif-smartdns/domains.d/*.list
# Generado: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# IP Publica VPS AR: ${public_ip}
# Version dnsmasq detectada: ${ver}
# Soporte filter-rr=HTTPS,SVCB: ${filter_rr_enabled}
# Total dominios interceptados: ${#domains[@]}
# ==============================================================================

# Escuchar en puerto 53 en todas las interfaces (compatible con VPS tras NAT 1:1/DHCP)
# 'interface=*' ademas desactiva '--local-service' por defecto de Ubuntu para aceptar
# consultas remotas desde las IPs autorizadas en ipset/iptables (JOIF_SMARTDNS)
port=53
interface=*

# Seguridad y limpieza basica de consultas
domain-needed
bogus-priv
no-resolv
no-poll
no-hosts

# Rendimiento para trafico concurrente desde nodos VPN
cache-size=10000
dns-forward-max=4096
edns-packet-max=1232
neg-ttl=60
min-cache-ttl=60

# Resolvers upstream para dominios NO interceptados (~95% del trafico normal)
server=${JOIF_UPSTREAM_DNS_1}
server=${JOIF_UPSTREAM_DNS_2}
server=${JOIF_UPSTREAM_DNS_3}
server=${JOIF_UPSTREAM_DNS_4}
EOF

        if [[ "$filter_rr_enabled" == "yes" ]]; then
            cat <<'EOF'

# Anti-fuga IPv6 (AAAA) y HTTPS/SVCB (Tipo 65/64): evita que Android/Chrome use IPv6/ipv4hint/ECH
# y salte el Smart DNS hacia la IP real del proveedor
filter-rr=AAAA,HTTPS,SVCB
EOF
        else
            cat <<EOF

# AVISO: dnsmasq ${ver} no soporta 'filter-rr=HTTPS,SVCB' (requiere >= 2.90 o parche 2.87+).
# Los registros AAAA de dominios interceptados siguen bloqueados via address=/dominio/IPv4 (NODATA).
# Para filtrado completo de tipo 65 (HTTPS/SVCB), se recomienda Ubuntu 24.04/26.04 LTS.
EOF
        fi

        printf '\n# Dominios argentinos interceptados (A -> %s, AAAA -> NODATA sin fuga IPv6)\n' "$public_ip"
        for d in "${domains[@]}"; do
            printf 'address=/%s/%s\n' "$d" "$public_ip"
        done
    } > "$rendered"

    if [[ -n "$output_file" ]]; then
        mkdir -p "$(dirname "$output_file")"
        chmod 644 "$rendered"
        mv -f "$rendered" "$output_file"
    else
        cat "$rendered"
        rm -f "$rendered"
    fi
}

# Aplica la configuracion de dnsmasq con validacion previa (--test) y rollback automatico
dnsmasq_apply() {
    joif_load_config
    local public_ip="${1:-${JOIF_PUBLIC_IP:-}}"
    if [[ -z "$public_ip" ]]; then
        public_ip="$(joif_get_public_ip)" || {
            log_error "No se pudo determinar la IP publica de la VPS Argentina."
            return 1
        }
    fi

    mkdir -p "$(dirname "$JOIF_DNSMASQ_CONF")"
    local tmp_conf backup_conf had_backup=0
    tmp_conf="$(mktemp)"
    backup_conf="$(mktemp)"

    if ! dnsmasq_render_config "$public_ip" "$tmp_conf"; then
        rm -f "$tmp_conf" "$backup_conf"
        return 1
    fi

    # Pre-validacion aislada antes de tocar la config activa
    if command -v "$JOIF_DNSMASQ_BIN" >/dev/null 2>&1; then
        if ! "$JOIF_DNSMASQ_BIN" --test --conf-file="$tmp_conf" >/dev/null 2>&1; then
            log_error "La configuracion generada de dnsmasq fallo la validacion (--test):"
            "$JOIF_DNSMASQ_BIN" --test --conf-file="$tmp_conf" >&2 || true
            rm -f "$tmp_conf" "$backup_conf"
            return 1
        fi
    else
        log_warn "Binario '${JOIF_DNSMASQ_BIN}' no encontrado; omitiendo validacion binaria."
    fi

    if [[ -f "$JOIF_DNSMASQ_CONF" ]]; then
        cp -p "$JOIF_DNSMASQ_CONF" "$backup_conf"
        had_backup=1
    fi

    chmod 644 "$tmp_conf"
    mv -f "$tmp_conf" "$JOIF_DNSMASQ_CONF"

    # Validacion global de dnsmasq (si se usa la ruta real del sistema o si el mock la soporta)
    if command -v "$JOIF_DNSMASQ_BIN" >/dev/null 2>&1; then
        local test_cmd_ok=0
        if [[ "$JOIF_DNSMASQ_CONF" == "/etc/dnsmasq.d/"* ]]; then
            "$JOIF_DNSMASQ_BIN" --test >/dev/null 2>&1 && test_cmd_ok=1
        else
            "$JOIF_DNSMASQ_BIN" --test --conf-file="$JOIF_DNSMASQ_CONF" >/dev/null 2>&1 && test_cmd_ok=1
        fi

        if [[ "$test_cmd_ok" -ne 1 ]]; then
            log_error "dnsmasq --test fallo tras instalar la configuracion. Ejecutando rollback..."
            if [[ "$had_backup" -eq 1 ]]; then
                mv -f "$backup_conf" "$JOIF_DNSMASQ_CONF"
            else
                rm -f "$JOIF_DNSMASQ_CONF" "$backup_conf"
            fi
            return 1
        fi
    fi

    rm -f "$backup_conf"

    if [[ "${JOIF_SKIP_SERVICE_RELOAD:-0}" != "1" ]] && command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        # dnsmasq requiere restart (no SIGHUP/reload) para releer directivas address=/.../
        if ! "$JOIF_SYSTEMCTL_BIN" restart dnsmasq; then
            log_error "Fallo al reiniciar el servicio dnsmasq."
            return 1
        fi
    fi

    log_ok "Configuracion de dnsmasq validada y aplicada (${JOIF_DNSMASQ_CONF})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-apply}"
    shift || true
    case "$cmd" in
        render) dnsmasq_render_config "${1:-}" "${2:-}" ;;
        apply)  dnsmasq_apply "${1:-}" ;;
        probe)
            ver="$(dnsmasq_detect_version || printf 'unknown')"
            if dnsmasq_supports_filter_rr; then
                printf 'version=%s filter_rr=yes\n' "$ver"
            else
                printf 'version=%s filter_rr=no\n' "$ver"
            fi
            ;;
        *)
            echo "Uso: $0 {render <public_ip> [out_file]|apply [public_ip]|probe}" >&2
            exit 1
            ;;
    esac
fi
