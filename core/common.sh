#!/usr/bin/env bash
# core/common.sh — Constantes, rutas, validaciones y utilidades comunes para joif-smartdns

[[ -n "${JOIF_COMMON_LOADED:-}" ]] && return 0
JOIF_COMMON_LOADED=1

JOIF_VERSION="1.0.0"

# Rutas principales (sobreescribibles via variables de entorno para pruebas locales)
JOIF_INSTALL_DIR="${JOIF_INSTALL_DIR:-/opt/joif-smartdns}"
JOIF_CONFIG_DIR="${JOIF_CONFIG_DIR:-/etc/joif-smartdns}"
JOIF_STATE_DIR="${JOIF_STATE_DIR:-/var/lib/joif-smartdns}"
JOIF_DOMAINS_DIR="${JOIF_DOMAINS_DIR:-${JOIF_CONFIG_DIR}/domains.d}"
JOIF_GENERATED_DIR="${JOIF_GENERATED_DIR:-${JOIF_CONFIG_DIR}/generated}"
JOIF_CONFIG_FILE="${JOIF_CONFIG_FILE:-${JOIF_CONFIG_DIR}/config.env}"
JOIF_LICENSES_DB="${JOIF_LICENSES_DB:-${JOIF_CONFIG_DIR}/licenses.db}"
JOIF_BACKUP_DIR="${JOIF_BACKUP_DIR:-${JOIF_STATE_DIR}/backups}"
JOIF_LOCK_FILE="${JOIF_LOCK_FILE:-${JOIF_STATE_DIR}/joif-smartdns.lock}"

# Rutas de servicios del sistema
JOIF_DNSMASQ_CONF="${JOIF_DNSMASQ_CONF:-/etc/dnsmasq.d/99-joif-smartdns.conf}"
JOIF_NGINX_MAIN_CONF="${JOIF_NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}"
JOIF_NGINX_STREAM_CONF="${JOIF_NGINX_STREAM_CONF:-${JOIF_GENERATED_DIR}/nginx-stream.conf}"
JOIF_NGINX_HTTP_CONF="${JOIF_NGINX_HTTP_CONF:-${JOIF_GENERATED_DIR}/nginx-http.conf}"
JOIF_NGINX_LOG_DIR="${JOIF_NGINX_LOG_DIR:-/var/log/nginx}"
JOIF_RESOLVED_DROPIN="${JOIF_RESOLVED_DROPIN:-/etc/systemd/resolved.conf.d/99-joif-smartdns.conf}"
JOIF_IPSET_NAME="${JOIF_IPSET_NAME:-joif_smartdns_allow}"
JOIF_IPTABLES_CHAIN="${JOIF_IPTABLES_CHAIN:-JOIF_SMARTDNS}"
JOIF_IP6TABLES_CHAIN="${JOIF_IP6TABLES_CHAIN:-JOIF_SMARTDNS6}"
JOIF_IPSET_SAVE_FILE="${JOIF_IPSET_SAVE_FILE:-${JOIF_STATE_DIR}/ipset.rules}"

# Binarios (sobreescribibles para mocks en tests)
JOIF_DNSMASQ_BIN="${JOIF_DNSMASQ_BIN:-dnsmasq}"
JOIF_NGINX_BIN="${JOIF_NGINX_BIN:-nginx}"
JOIF_IPSET_BIN="${JOIF_IPSET_BIN:-ipset}"
JOIF_IPTABLES_BIN="${JOIF_IPTABLES_BIN:-iptables}"
JOIF_IP6TABLES_BIN="${JOIF_IP6TABLES_BIN:-ip6tables}"
JOIF_SYSTEMCTL_BIN="${JOIF_SYSTEMCTL_BIN:-systemctl}"

# Resolvers upstream por defecto
JOIF_UPSTREAM_DNS_1="${JOIF_UPSTREAM_DNS_1:-1.1.1.1}"
JOIF_UPSTREAM_DNS_2="${JOIF_UPSTREAM_DNS_2:-8.8.8.8}"
JOIF_UPSTREAM_DNS_3="${JOIF_UPSTREAM_DNS_3:-1.0.0.1}"
JOIF_UPSTREAM_DNS_4="${JOIF_UPSTREAM_DNS_4:-8.8.4.4}"

# Colores ANSI (desactivables con NO_COLOR=1 o cuando stdout no es TTY)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
fi

log_info()  { printf '%b[INFO]%b %s\n'  "$C_CYAN"   "$C_RESET" "$*"; }
log_ok()    { printf '%b[ OK ]%b %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[ERR ]%b %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

joif_require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "Este comando requiere privilegios de root (usa sudo)."
        return 1
    fi
}

joif_ensure_dirs() {
    mkdir -p "$JOIF_CONFIG_DIR" "$JOIF_DOMAINS_DIR" "$JOIF_GENERATED_DIR" "$JOIF_STATE_DIR" "$JOIF_BACKUP_DIR"
}

joif_now_epoch() {
    if [[ -n "${JOIF_NOW_EPOCH:-}" ]]; then
        printf '%s\n' "$JOIF_NOW_EPOCH"
    else
        date -u +%s
    fi
}

joif_format_epoch() {
    local epoch="${1:-0}"
    if [[ "$epoch" == "0" || -z "$epoch" ]]; then
        printf 'permanente\n'
        return 0
    fi
    date -u -d "@${epoch}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf '%s\n' "$epoch"
}

# Valida IPv4 estricto (sin ceros a la izquierda ni espacios)
joif_validate_ipv4() {
    local ip="${1:-}"
    local IFS='.'
    local -a octets=()

    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" -eq 4 ]] || return 1

    local o
    for o in "${octets[@]}"; do
        # Rechazar ceros a la izquierda (ej. 01, 001)
        if [[ "${#o}" -gt 1 && "${o:0:1}" == "0" ]]; then
            return 1
        fi
        if (( 10#$o < 0 || 10#$o > 255 )); then
            return 1
        fi
    done
    return 0
}

# Normaliza y valida IPv4 o IPv4/CIDR. Rechaza 0.0.0.0/0 para evitar open resolver.
joif_normalize_cidr() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"

    local ip prefix
    if [[ "$raw" == */* ]]; then
        ip="${raw%%/*}"
        prefix="${raw#*/}"
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
        if [[ "${#prefix}" -gt 1 && "${prefix:0:1}" == "0" ]]; then
            return 1
        fi
        if (( 10#$prefix < 1 || 10#$prefix > 32 )); then
            return 1
        fi
    else
        ip="$raw"
        prefix="32"
    fi

    joif_validate_ipv4 "$ip" || return 1

    # Rechazar 0.0.0.0 como origen
    if [[ "$ip" == "0.0.0.0" ]]; then
        return 1
    fi

    printf '%s/%s\n' "$ip" "$prefix"
}

# Normaliza y valida un dominio RFC 1123 (sin protocolo, sin rutas, sin caracteres peligrosos)
joif_normalize_domain() {
    local raw="${1:-}"
    # Quitar BOM UTF-8, CR y comentarios inline
    raw="${raw#$'\xef\xbb\xbf'}"
    raw="${raw//$'\r'/}"
    raw="${raw%%#*}"
    # Trim espacios
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -z "$raw" ]] && return 1

    # Minusculas (nativo Bash 4+, evita fork de 'tr' por cada linea)
    raw="${raw,,}"

    # Permitir opcionalmente prefijo "*." o "." y punto final
    if [[ "$raw" == \*.* ]]; then
        raw="${raw#\*.}"
    fi
    while [[ "$raw" == .* ]]; do
        raw="${raw#.}"
    done
    while [[ "$raw" == *. ]]; do
        raw="${raw%.}"
    done

    # Longitud maxima DNS = 253
    (( ${#raw} >= 4 && ${#raw} <= 253 )) || return 1

    # Rechazar puntos consecutivos
    [[ "$raw" == *..* ]] && return 1

    # Debe ser un FQDN valido con al menos un punto y TLD alfabetico o punycode (xn--)
    if [[ ! "$raw" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{2,59})$ ]]; then
        return 1
    fi

    # Rechazar IPs literales disfrazadas de dominio
    if joif_validate_ipv4 "$raw"; then
        return 1
    fi

    printf '%s\n' "$raw"
}

joif_sanitize_alias() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\n'/ }"
    raw="${raw//|/-}"
    # Quitar caracteres de control
    raw="$(printf '%s' "$raw" | tr -d '[:cntrl:]')"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ -z "$raw" ]]; then
        raw="Sin alias"
    fi
    # Limitar longitud a 64 caracteres
    printf '%s\n' "${raw:0:64}"
}

# Compara versiones numericas dot-separated: retorna 0 si v1 >= v2
joif_version_ge() {
    local v1="${1:-0}"
    local v2="${2:-0}"

    # Extraer parte numerica principal (ej: 2.90-2ubuntu1 -> 2.90)
    v1="$(printf '%s' "$v1" | sed -nE 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*$/\1/p')"
    v2="$(printf '%s' "$v2" | sed -nE 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*$/\1/p')"
    [[ -n "$v1" && -n "$v2" ]] || return 1

    local IFS='.'
    local -a a1=() a2=()
    read -r -a a1 <<< "$v1"
    read -r -a a2 <<< "$v2"

    local max="${#a1[@]}"
    (( ${#a2[@]} > max )) && max="${#a2[@]}"

    local i n1 n2
    for (( i = 0; i < max; i++ )); do
        n1="${a1[$i]:-0}"
        n2="${a2[$i]:-0}"
        if (( 10#$n1 > 10#$n2 )); then
            return 0
        elif (( 10#$n1 < 10#$n2 )); then
            return 1
        fi
    done
    return 0
}

joif_detect_public_ip() {
    local url ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com" "https://ipv4.icanhazip.com"; do
        ip="$(curl -4 -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
        if joif_validate_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

# Carga segura de config.env (sin eval arbitrario)
joif_load_config() {
    [[ -f "$JOIF_CONFIG_FILE" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        # Quitar comillas simples o dobles exteriores
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        case "$key" in
            PUBLIC_IP)          JOIF_PUBLIC_IP="$val" ;;
            UPSTREAM_DNS_1)     JOIF_UPSTREAM_DNS_1="$val" ;;
            UPSTREAM_DNS_2)     JOIF_UPSTREAM_DNS_2="$val" ;;
            UPSTREAM_DNS_3)     JOIF_UPSTREAM_DNS_3="$val" ;;
            UPSTREAM_DNS_4)     JOIF_UPSTREAM_DNS_4="$val" ;;
            INSTALL_DIR)        JOIF_INSTALL_DIR="$val" ;;
            DNSMASQ_FILTER_RR)  JOIF_DNSMASQ_FILTER_RR="$val" ;;
        esac
    done < "$JOIF_CONFIG_FILE"
}

joif_save_config() {
    joif_ensure_dirs
    local tmp
    tmp="$(mktemp "${JOIF_CONFIG_DIR}/.config.env.XXXXXX")"
    cat > "$tmp" <<EOF
# joif-smartdns configuracion principal
PUBLIC_IP="${JOIF_PUBLIC_IP:-}"
UPSTREAM_DNS_1="${JOIF_UPSTREAM_DNS_1}"
UPSTREAM_DNS_2="${JOIF_UPSTREAM_DNS_2}"
UPSTREAM_DNS_3="${JOIF_UPSTREAM_DNS_3}"
UPSTREAM_DNS_4="${JOIF_UPSTREAM_DNS_4}"
INSTALL_DIR="${JOIF_INSTALL_DIR}"
DNSMASQ_FILTER_RR="${JOIF_DNSMASQ_FILTER_RR:-auto}"
EOF
    chmod 644 "$tmp"
    mv -f "$tmp" "$JOIF_CONFIG_FILE"
}

joif_get_public_ip() {
    joif_load_config
    if [[ -n "${JOIF_PUBLIC_IP:-}" ]] && joif_validate_ipv4 "$JOIF_PUBLIC_IP"; then
        printf '%s\n' "$JOIF_PUBLIC_IP"
        return 0
    fi
    joif_detect_public_ip
}

joif_with_lock() {
    joif_ensure_dirs
    if [[ "${JOIF_LOCK_HELD:-0}" == "1" ]]; then
        "$@"
        return $?
    fi
    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 15 200 || {
                log_error "No se pudo obtener bloqueo sobre ${JOIF_LOCK_FILE}."
                exit 1
            }
            export JOIF_LOCK_HELD=1
            "$@"
        ) 200>"$JOIF_LOCK_FILE"
    else
        JOIF_LOCK_HELD=1 "$@"
    fi
}
