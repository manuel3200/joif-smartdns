#!/usr/bin/env bash
# core/nginx_gen.sh — Generador de nginx stream (443 ssl_preread) y http (80) con allowlist y rollback

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/domains.sh
source "${SCRIPT_DIR}/domains.sh"

# Genera /etc/nginx/nginx.conf limpio y compatible con Ubuntu 22.04 / 24.04 / 26.04 LTS
nginx_render_main_conf() {
    local output_file="${1:-}"
    local stream_include="${JOIF_NGINX_STREAM_CONF}"
    local http_include="${JOIF_NGINX_HTTP_CONF}"

    local load_module_block=""
    if [[ -d "/etc/nginx/modules-enabled" ]] && ls /etc/nginx/modules-enabled/*stream*.conf >/dev/null 2>&1; then
        load_module_block="include /etc/nginx/modules-enabled/*.conf;"
    elif [[ -f "/usr/lib/nginx/modules/ngx_stream_module.so" ]]; then
        load_module_block=$'include /etc/nginx/modules-enabled/*.conf;\nload_module /usr/lib/nginx/modules/ngx_stream_module.so;'
    else
        load_module_block="include /etc/nginx/modules-enabled/*.conf;"
    fi

    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# ==============================================================================
# joif-smartdns — Configuracion principal de NGINX (Ubuntu 22.04/24.04/26.04)
# Proxy transparente TLS (puerto 443 via ssl_preread) y HTTP (puerto 80)
# ==============================================================================
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
error_log ${JOIF_NGINX_LOG_DIR}/error.log warn;

${load_module_block}

events {
    worker_connections 8192;
    multi_accept on;
}

stream {
    include ${stream_include};
}

http {
    include ${http_include};
}
EOF

    if [[ -n "$output_file" ]]; then
        mkdir -p "$(dirname "$output_file")"
        chmod 644 "$tmp"
        mv -f "$tmp" "$output_file"
    else
        cat "$tmp"
        rm -f "$tmp"
    fi
}

# Genera bloque stream (puerto 443 TLS passthrough sin descifrar certificados)
nginx_render_stream_conf() {
    local output_file="${1:-}"

    local -a domains=()
    local d
    while IFS= read -r d; do
        [[ -n "$d" ]] && domains+=("$d")
    done < <(domains_collect_active)

    local tmp
    tmp="$(mktemp)"
    {
        cat <<EOF
# ==============================================================================
# joif-smartdns — NGINX Stream SNI Proxy (Puerto 443, TLS passthrough puro)
# Generado: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Total dominios autorizados: ${#domains[@]}
# ==============================================================================

map_hash_bucket_size 128;
map_hash_max_size 8192;

# Resolvers externos (NUNCA 127.0.0.1:53 para evitar bucle infinito con dnsmasq)
resolver ${JOIF_UPSTREAM_DNS_1} ${JOIF_UPSTREAM_DNS_2} ${JOIF_UPSTREAM_DNS_3} ${JOIF_UPSTREAM_DNS_4} valid=300s ipv6=off;
resolver_timeout 5s;

log_format joif_stream '\$remote_addr [\$time_local] '
                       'sni="\$ssl_preread_server_name" '
                       'allowed=\$joif_tls_allowed '
                       'target="\$joif_tls_host:\$joif_tls_port" '
                       'status=\$status '
                       'sent=\$bytes_sent recv=\$bytes_received '
                       'time=\$session_time';

# Sumidero interno para rechazar inmediatamente SNI vacio o no autorizado (anti-abuso)
server {
    listen 127.0.0.1:18443;
    deny all;
    return "";
}

# Allowlist estricta de dominios argentinos (.dominio matchea dominio y *.dominio en O(1))
map \$ssl_preread_server_name \$joif_tls_allowed {
    hostnames;
    default 0;
EOF
        for d in "${domains[@]}"; do
            printf '    .%s 1;\n' "$d"
        done

        cat <<EOF
}

map \$joif_tls_allowed \$joif_tls_host {
    1 \$ssl_preread_server_name;
    default 127.0.0.1;
}

map \$joif_tls_allowed \$joif_tls_port {
    1 443;
    default 18443;
}

server {
    listen 443;

    # Inspecciona unicamente el SNI del ClientHello sin terminar ni descifrar TLS
    ssl_preread on;
    preread_buffer_size 16k;
    preread_timeout 10s;

    proxy_connect_timeout 10s;
    proxy_timeout 300s;
    proxy_socket_keepalive on;
    proxy_pass \$joif_tls_host:\$joif_tls_port;

    access_log ${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log joif_stream;
    error_log ${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream-error.log warn;
}
EOF
    } > "$tmp"

    if [[ -n "$output_file" ]]; then
        mkdir -p "$(dirname "$output_file")"
        chmod 644 "$tmp"
        mv -f "$tmp" "$output_file"
    else
        cat "$tmp"
        rm -f "$tmp"
    fi
}

# Genera bloque http (puerto 80 transparente por cabecera Host con allowlist estricta)
nginx_render_http_conf() {
    local output_file="${1:-}"

    local -a domains=()
    local d
    while IFS= read -r d; do
        [[ -n "$d" ]] && domains+=("$d")
    done < <(domains_collect_active)

    local tmp
    tmp="$(mktemp)"
    {
        cat <<EOF
# ==============================================================================
# joif-smartdns — NGINX HTTP Proxy Transparente (Puerto 80)
# Generado: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Total dominios autorizados: ${#domains[@]}
# ==============================================================================

server_tokens off;
sendfile on;
tcp_nopush on;
tcp_nodelay on;
keepalive_timeout 65;

map_hash_bucket_size 128;
map_hash_max_size 8192;

log_format joif_http '\$remote_addr [\$time_local] host="\$host" '
                     'allowed=\$joif_http_allowed "\$request" '
                     'status=\$status bytes=\$body_bytes_sent';

# Allowlist estricta por cabecera Host (bloquea trafico sin Host valido o fuera de lista)
map \$host \$joif_http_allowed {
    hostnames;
    default 0;
EOF
        for d in "${domains[@]}"; do
            printf '    .%s 1;\n' "$d"
        done

        cat <<EOF
}

server {
    listen 80 default_server;
    server_name _;

    # Resolvers externos (NUNCA 127.0.0.1:53 para evitar bucle infinito)
    resolver ${JOIF_UPSTREAM_DNS_1} ${JOIF_UPSTREAM_DNS_2} ${JOIF_UPSTREAM_DNS_3} ${JOIF_UPSTREAM_DNS_4} valid=300s ipv6=off;
    resolver_timeout 5s;

    access_log ${JOIF_NGINX_LOG_DIR}/joif-smartdns-http.log joif_http;
    error_log ${JOIF_NGINX_LOG_DIR}/joif-smartdns-http-error.log warn;

    location / {
        if (\$joif_http_allowed = 0) {
            return 444;
        }

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_redirect off;
        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_pass http://\$host:80\$request_uri;
    }
}
EOF
    } > "$tmp"

    if [[ -n "$output_file" ]]; then
        mkdir -p "$(dirname "$output_file")"
        chmod 644 "$tmp"
        mv -f "$tmp" "$output_file"
    else
        cat "$tmp"
        rm -f "$tmp"
    fi
}

# Aplica nginx-stream.conf y nginx-http.conf con validacion nginx -t y rollback automatico
nginx_apply() {
    joif_load_config
    joif_ensure_dirs
    mkdir -p "$(dirname "$JOIF_NGINX_STREAM_CONF")" "$(dirname "$JOIF_NGINX_HTTP_CONF")"

    local tmp_stream tmp_http bak_stream bak_http
    local had_stream=0 had_http=0
    tmp_stream="$(mktemp)"
    tmp_http="$(mktemp)"
    bak_stream="$(mktemp)"
    bak_http="$(mktemp)"

    if ! nginx_render_stream_conf "$tmp_stream" || ! nginx_render_http_conf "$tmp_http"; then
        rm -f "$tmp_stream" "$tmp_http" "$bak_stream" "$bak_http"
        return 1
    fi

    if [[ -f "$JOIF_NGINX_STREAM_CONF" ]]; then
        cp -p "$JOIF_NGINX_STREAM_CONF" "$bak_stream"
        had_stream=1
    fi
    if [[ -f "$JOIF_NGINX_HTTP_CONF" ]]; then
        cp -p "$JOIF_NGINX_HTTP_CONF" "$bak_http"
        had_http=1
    fi

    chmod 644 "$tmp_stream" "$tmp_http"
    mv -f "$tmp_stream" "$JOIF_NGINX_STREAM_CONF"
    mv -f "$tmp_http" "$JOIF_NGINX_HTTP_CONF"

    if command -v "$JOIF_NGINX_BIN" >/dev/null 2>&1; then
        local -a test_args=(-t)
        if [[ -f "$JOIF_NGINX_MAIN_CONF" && "$JOIF_NGINX_MAIN_CONF" != "/etc/nginx/nginx.conf" ]]; then
            test_args=(-t -c "$JOIF_NGINX_MAIN_CONF")
        fi

        if ! "$JOIF_NGINX_BIN" "${test_args[@]}" >/dev/null 2>&1; then
            log_error "nginx -t fallo tras generar configuracion. Ejecutando rollback..."
            "$JOIF_NGINX_BIN" "${test_args[@]}" >&2 || true
            if [[ "$had_stream" -eq 1 ]]; then
                mv -f "$bak_stream" "$JOIF_NGINX_STREAM_CONF"
            else
                rm -f "$JOIF_NGINX_STREAM_CONF" "$bak_stream"
            fi
            if [[ "$had_http" -eq 1 ]]; then
                mv -f "$bak_http" "$JOIF_NGINX_HTTP_CONF"
            else
                rm -f "$JOIF_NGINX_HTTP_CONF" "$bak_http"
            fi
            return 1
        fi
    else
        log_warn "Binario '${JOIF_NGINX_BIN}' no encontrado; omitiendo nginx -t."
    fi

    rm -f "$bak_stream" "$bak_http"

    if [[ "${JOIF_SKIP_SERVICE_RELOAD:-0}" != "1" ]] && command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        if "$JOIF_SYSTEMCTL_BIN" is-active --quiet nginx 2>/dev/null; then
            if ! "$JOIF_SYSTEMCTL_BIN" reload nginx; then
                log_warn "reload nginx fallo; intentando restart nginx..."
                "$JOIF_SYSTEMCTL_BIN" restart nginx || return 1
            fi
        else
            "$JOIF_SYSTEMCTL_BIN" restart nginx || return 1
        fi
    fi

    log_ok "Configuracion de nginx (443 SNI stream + 80 HTTP) validada y aplicada."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-apply}"
    shift || true
    case "$cmd" in
        render-main)   nginx_render_main_conf "${1:-}" ;;
        render-stream) nginx_render_stream_conf "${1:-}" ;;
        render-http)   nginx_render_http_conf "${1:-}" ;;
        apply)         nginx_apply ;;
        *)
            echo "Uso: $0 {render-main|render-stream|render-http|apply} [out_file]" >&2
            exit 1
            ;;
    esac
fi
