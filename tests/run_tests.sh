#!/usr/bin/env bash
# tests/run_tests.sh — Suite automatizada local para joif-smartdns
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

# Sandbox temporal aislado (nunca toca el sistema del host)
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="${TEST_ROOT}/mock-bin"
mkdir -p "$MOCK_BIN"

# ------------------------------------------------------------------------------
# Helpers de asercion
# ------------------------------------------------------------------------------
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '[PASS] %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$1" >&2
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (esperado='${expected}', obtenido='${actual}')"
    fi
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    if grep -Fq -- "$pattern" "$file"; then
        pass "$msg"
    else
        fail "$msg (no se encontro '${pattern}' en ${file})"
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    if ! grep -Fq -- "$pattern" "$file"; then
        pass "$msg"
    else
        fail "$msg (se encontro texto prohibido '${pattern}' en ${file})"
    fi
}

assert_line_exact() {
    local file="$1"
    local exact_line="$2"
    local msg="$3"
    if grep -Fxq -- "$exact_line" "$file"; then
        pass "$msg"
    else
        fail "$msg (no se encontro linea exacta '${exact_line}' en ${file})"
    fi
}

assert_no_line_exact() {
    local file="$1"
    local exact_line="$2"
    local msg="$3"
    if ! grep -Fxq -- "$exact_line" "$file"; then
        pass "$msg"
    else
        fail "$msg (se encontro linea prohibida '${exact_line}' en ${file})"
    fi
}

# ------------------------------------------------------------------------------
# 1. Finales de linea LF y sintaxis bash -n
# ------------------------------------------------------------------------------
printf '\n=== [1] Verificacion LF y sintaxis bash -n ===\n'

crlf_files=()
while IFS= read -r f; do
    if grep -q $'\r' "$f"; then
        crlf_files+=("$f")
    fi
done < <(find "$REPO_DIR" -maxdepth 3 -type f \( -name '*.sh' -o -name '*.list' -o -name '*.service' -o -name '*.timer' -o -name '*.md' \))

assert_eq "0" "${#crlf_files[@]}" "Todos los scripts, listas y unidades systemd usan LF (sin CRLF)"

syntax_errors=0
while IFS= read -r shfile; do
    if bash -n "$shfile"; then
        pass "bash -n OK: ${shfile#"$REPO_DIR"/}"
    else
        fail "bash -n FALLO: ${shfile#"$REPO_DIR"/}"
        syntax_errors=$((syntax_errors + 1))
    fi
done < <(find "$REPO_DIR" -maxdepth 3 -type f -name '*.sh' | LC_ALL=C sort)

# ------------------------------------------------------------------------------
# 2. Preparar entorno aislado + cargar core/common.sh y core/domains.sh
# ------------------------------------------------------------------------------
printf '\n=== [2] Validadores comunes y parser de dominios ===\n'

export NO_COLOR=1
export JOIF_INSTALL_DIR="$REPO_DIR"
export JOIF_CONFIG_DIR="${TEST_ROOT}/etc/joif-smartdns"
export JOIF_STATE_DIR="${TEST_ROOT}/var/lib/joif-smartdns"
export JOIF_DOMAINS_DIR="${JOIF_CONFIG_DIR}/domains.d"
export JOIF_GENERATED_DIR="${JOIF_CONFIG_DIR}/generated"
export JOIF_CONFIG_FILE="${JOIF_CONFIG_DIR}/config.env"
export JOIF_LICENSES_DB="${JOIF_CONFIG_DIR}/licenses.db"
export JOIF_BACKUP_DIR="${JOIF_STATE_DIR}/backups"
export JOIF_LOCK_FILE="${JOIF_STATE_DIR}/joif.lock"
export JOIF_DNSMASQ_CONF="${TEST_ROOT}/etc/dnsmasq.d/99-joif-smartdns.conf"
export JOIF_NGINX_MAIN_CONF="${TEST_ROOT}/etc/nginx/nginx.conf"
export JOIF_NGINX_STREAM_CONF="${JOIF_GENERATED_DIR}/nginx-stream.conf"
export JOIF_NGINX_HTTP_CONF="${JOIF_GENERATED_DIR}/nginx-http.conf"
export JOIF_NGINX_LOG_DIR="${TEST_ROOT}/var/log/nginx"
export JOIF_IPSET_SAVE_FILE="${JOIF_STATE_DIR}/ipset.rules"
export JOIF_LOGROTATE_FILE="${TEST_ROOT}/etc/logrotate.d/joif-smartdns"
export JOIF_JOURNALD_DROPIN="${TEST_ROOT}/etc/systemd/journald.conf.d/99-joif-smartdns.conf"
export JOIF_SKIP_SERVICE_RELOAD=1
export JOIF_SKIP_SYSTEM_CLEANUP=1
export JOIF_DISABLE_GEO_LOOKUP=1

mkdir -p "$JOIF_DOMAINS_DIR" "$JOIF_GENERATED_DIR" "$JOIF_STATE_DIR" \
         "$(dirname "$JOIF_DNSMASQ_CONF")" "$(dirname "$JOIF_NGINX_MAIN_CONF")" "$JOIF_NGINX_LOG_DIR"
cp "${REPO_DIR}/domains.d/"*.list "$JOIF_DOMAINS_DIR/"

# shellcheck source=core/common.sh
source "${REPO_DIR}/core/common.sh"
# shellcheck source=core/domains.sh
source "${REPO_DIR}/core/domains.sh"

# Pruebas IPv4 / CIDR
joif_validate_ipv4 "200.58.120.10" && pass "IPv4 valida aceptada (200.58.120.10)" || fail "IPv4 valida rechazada"
! joif_validate_ipv4 "256.1.1.1"   && pass "IPv4 octeto >255 rechazada" || fail "IPv4 >255 aceptada"
! joif_validate_ipv4 "01.2.3.4"    && pass "IPv4 con cero inicial rechazada" || fail "IPv4 con cero inicial aceptada"

assert_eq "203.0.113.50/32" "$(joif_normalize_cidr "203.0.113.50")" "IP sola normaliza a /32"
assert_eq "198.51.100.0/24" "$(joif_normalize_cidr "198.51.100.0/24")" "CIDR /24 valido aceptado"
! joif_normalize_cidr "0.0.0.0/0" >/dev/null 2>&1 && pass "0.0.0.0/0 rechazado (anti open-resolver)" || fail "0.0.0.0/0 fue aceptado"
! joif_normalize_cidr "10.0.0.0/33" >/dev/null 2>&1 && pass "CIDR /33 rechazado" || fail "CIDR /33 aceptado"

# Pruebas de dominios
assert_eq "mercadopago.com.ar" "$(joif_normalize_domain "  *.MercadoPago.COM.AR. # test")" "Normalizacion de dominio con comodin, mayusculas y comentario"
! joif_normalize_domain "http://mercadopago.com.ar" >/dev/null 2>&1 && pass "URL con esquema rechazada como dominio" || fail "URL aceptada como dominio"
! joif_normalize_domain "bad.com;rm -rf /" >/dev/null 2>&1 && pass "Inyeccion de caracteres en dominio rechazada" || fail "Inyeccion aceptada"
! joif_normalize_domain "1.2.3.4" >/dev/null 2>&1 && pass "IP literal rechazada como dominio" || fail "IP aceptada como dominio"

# Pruebas de comparacion de versiones
joif_version_ge "2.90" "2.90" && pass "version_ge 2.90 >= 2.90" || fail "version_ge 2.90 >= 2.90"
joif_version_ge "2.91-1ubuntu1" "2.90" && pass "version_ge 2.91-1ubuntu1 >= 2.90" || fail "version_ge 2.91 >= 2.90"
joif_version_ge "2.100" "2.90" && pass "version_ge 2.100 >= 2.90" || fail "version_ge 2.100 >= 2.90"
! joif_version_ge "2.86" "2.90" && pass "version_ge 2.86 < 2.90" || fail "version_ge 2.86 deberia ser < 2.90"

# Pruebas parser de domains.d + deduplicacion + activar/desactivar categorias
cat >> "${JOIF_DOMAINS_DIR}/99-custom.list" <<'EOF'
# Duplicado intencional en mayusculas + linea invalida + dominio custom nuevo
MERCADOPAGO.COM.AR
invalido;inyeccion.com
miapp-ar.com.ar
EOF

active_file="${TEST_ROOT}/active_domains.txt"
domains_collect_active > "$active_file" 2>/dev/null

mp_count="$(grep -Fxc "mercadopago.com.ar" "$active_file")"
assert_eq "1" "$mp_count" "Deduplicacion entre categorias evita duplicar mercadopago.com.ar"
assert_contains "$active_file" "miapp-ar.com.ar" "Dominio valido en 99-custom.list incluido"
assert_contains "$active_file" "argentina.gob.ar" "Dominio de 02-gobierno-ar.list incluido"
assert_contains "$active_file" "netflix.com" "Dominio de 03-streaming-ar.list incluido"
assert_not_contains "$active_file" "invalido" "Linea malformada ignorada por el parser"

# Desactivar categoria streaming y verificar que netflix.com desaparece
domains_disable_category "03-streaming-ar" >/dev/null
domains_collect_active > "$active_file" 2>/dev/null
assert_not_contains "$active_file" "netflix.com" "Desactivar 03-streaming-ar excluye netflix.com"
assert_contains "$active_file" "mercadopago.com.ar" "Desactivar streaming mantiene 01-fintech-bancos"

# Reactivar categoria streaming
domains_enable_category "03-streaming-ar" >/dev/null
domains_collect_active > "$active_file" 2>/dev/null
assert_contains "$active_file" "netflix.com" "Reactivar 03-streaming-ar restaura netflix.com"

# Custom add / remove
domains_custom_add "banco-prueba.com.ar" >/dev/null
assert_contains "${JOIF_DOMAINS_DIR}/99-custom.list" "banco-prueba.com.ar" "domains_custom_add agrega dominio"
domains_custom_remove "banco-prueba.com.ar" >/dev/null
assert_not_contains "${JOIF_DOMAINS_DIR}/99-custom.list" "banco-prueba.com.ar" "domains_custom_remove elimina dominio"

# ------------------------------------------------------------------------------
# 3. Generador dnsmasq + sondeo dinamico filter-rr + rollback
# ------------------------------------------------------------------------------
printf '\n=== [3] Generador dnsmasq, soporte filter-rr y rollback ===\n'

# Mock dnsmasq v2.90 (Ubuntu 24.04 / 26.04: soporta filter-rr=HTTPS,SVCB)
cat > "${MOCK_BIN}/dnsmasq-290" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "Dnsmasq version 2.90  Copyright (c) 2000-2024 Simon Kelley"
    exit 0
fi
if [[ "${MOCK_DNSMASQ_FAIL:-0}" == "1" ]]; then
    echo "dnsmasq: syntax check FAILED (simulated)" >&2
    exit 1
fi
echo "dnsmasq: syntax check OK."
exit 0
EOF
chmod +x "${MOCK_BIN}/dnsmasq-290"

# Mock dnsmasq v2.86 (Ubuntu 22.04: NO soporta filter-rr)
cat > "${MOCK_BIN}/dnsmasq-286" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "Dnsmasq version 2.86  Copyright (c) 2000-2021 Simon Kelley"
    exit 0
fi
for arg in "$@"; do
    if [[ "$arg" == --conf-file=* ]]; then
        cf="${arg#--conf-file=}"
        if grep -q '^filter-rr=' "$cf"; then
            echo "dnsmasq: unsupported option filter-rr in 2.86" >&2
            exit 1
        fi
    fi
done
echo "dnsmasq: syntax check OK."
exit 0
EOF
chmod +x "${MOCK_BIN}/dnsmasq-286"

# shellcheck source=core/dnsmasq_gen.sh
source "${REPO_DIR}/core/dnsmasq_gen.sh"

export JOIF_PUBLIC_IP="200.58.120.10"
joif_save_config

# Caso A: dnsmasq 2.90
export JOIF_DNSMASQ_BIN="${MOCK_BIN}/dnsmasq-290"
dnsmasq_apply "200.58.120.10" >/dev/null
assert_line_exact "$JOIF_DNSMASQ_CONF" "interface=*" "dnsmasq incluye interface=* para desactivar --local-service de Ubuntu"
assert_line_exact "$JOIF_DNSMASQ_CONF" "filter-rr=AAAA,HTTPS,SVCB" "dnsmasq 2.90 incluye directiva activa filter-rr=AAAA,HTTPS,SVCB"
assert_contains "$JOIF_DNSMASQ_CONF" "address=/personalpay.dev/200.58.120.10" "dnsmasq intercepta personalpay.dev"
assert_contains "$JOIF_DNSMASQ_CONF" "address=/paygilant.com/200.58.120.10" "dnsmasq intercepta paygilant.com"
assert_contains "$JOIF_DNSMASQ_CONF" "no-resolv" "dnsmasq incluye no-resolv"
assert_contains "$JOIF_DNSMASQ_CONF" "no-hosts" "dnsmasq incluye no-hosts"
assert_contains "$JOIF_DNSMASQ_CONF" "server=1.1.1.1" "dnsmasq reenvia normales a 1.1.1.1"
assert_contains "$JOIF_DNSMASQ_CONF" "address=/mercadopago.com.ar/200.58.120.10" "dnsmasq intercepta mercadopago.com.ar hacia IP AR"
assert_not_contains "$JOIF_DNSMASQ_CONF" "server=127.0.0.1" "dnsmasq no contiene bucle hacia 127.0.0.1"

# Caso B: dnsmasq 2.86 (Ubuntu 22.04)
export JOIF_DNSMASQ_BIN="${MOCK_BIN}/dnsmasq-286"
conf_286="${TEST_ROOT}/dnsmasq-286.conf"
dnsmasq_render_config "200.58.120.10" "$conf_286"
assert_no_line_exact "$conf_286" "filter-rr=AAAA,HTTPS,SVCB" "dnsmasq 2.86 omite directiva activa filter-rr=AAAA,HTTPS,SVCB dinamicamente"
assert_contains "$conf_286" "# Soporte filter-rr=HTTPS,SVCB: no" "dnsmasq 2.86 documenta en cabecera que filter-rr no esta soportado"
assert_contains "$conf_286" "address=/mercadopago.com.ar/200.58.120.10" "dnsmasq 2.86 sigue interceptando dominios AR"
"${MOCK_BIN}/dnsmasq-286" --test --conf-file="$conf_286" >/dev/null && pass "Config generada para dnsmasq 2.86 pasa --test" || fail "Config 2.86 fallo --test"

# Caso C: Rollback ante fallo de dnsmasq --test
export JOIF_DNSMASQ_BIN="${MOCK_BIN}/dnsmasq-290"
dnsmasq_apply "200.58.120.10" >/dev/null
prev_hash="$(sha256sum "$JOIF_DNSMASQ_CONF" | awk '{print $1}')"
if MOCK_DNSMASQ_FAIL=1 dnsmasq_apply "200.58.120.99" >/dev/null 2>&1; then
    fail "dnsmasq_apply debio fallar cuando --test retorna error"
else
    new_hash="$(sha256sum "$JOIF_DNSMASQ_CONF" | awk '{print $1}')"
    assert_eq "$prev_hash" "$new_hash" "Rollback de dnsmasq preserva intacta la configuracion previa valida"
fi

# ------------------------------------------------------------------------------
# 4. Generador nginx stream (443 ssl_preread) + http (80) + rollback
# ------------------------------------------------------------------------------
printf '\n=== [4] Generador nginx stream/http, anti-abuso y rollback ===\n'

cat > "${MOCK_BIN}/nginx" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_NGINX_FAIL:-0}" == "1" ]]; then
    echo "nginx: configuration file test failed (simulated)" >&2
    exit 1
fi
echo "nginx: configuration file syntax is ok"
exit 0
EOF
chmod +x "${MOCK_BIN}/nginx"

export JOIF_NGINX_BIN="${MOCK_BIN}/nginx"
# shellcheck source=core/nginx_gen.sh
source "${REPO_DIR}/core/nginx_gen.sh"

nginx_render_main_conf "$JOIF_NGINX_MAIN_CONF"
nginx_apply >/dev/null

# Validaciones nginx.conf principal
assert_contains "$JOIF_NGINX_MAIN_CONF" "stream {" "nginx.conf incluye bloque stream"
assert_contains "$JOIF_NGINX_MAIN_CONF" "http {" "nginx.conf incluye bloque http"
assert_contains "$JOIF_NGINX_MAIN_CONF" "include ${JOIF_NGINX_STREAM_CONF};" "nginx.conf incluye nginx-stream.conf"

# Validaciones nginx-stream.conf (puerto 443 TLS passthrough)
assert_contains "$JOIF_NGINX_STREAM_CONF" "ssl_preread on;" "nginx stream habilita ssl_preread sin descifrar TLS"
assert_not_contains "$JOIF_NGINX_STREAM_CONF" "ssl_certificate" "nginx stream NO termina TLS (sin ssl_certificate)"
assert_contains "$JOIF_NGINX_STREAM_CONF" "resolver 1.1.1.1 8.8.8.8 1.0.0.1 8.8.4.4 valid=300s ipv6=off;" "nginx stream usa resolvers externos con ipv6=off"
assert_not_contains "$JOIF_NGINX_STREAM_CONF" "resolver 127.0.0.1" "nginx stream nunca resuelve contra 127.0.0.1"
assert_contains "$JOIF_NGINX_STREAM_CONF" "hostnames;" "nginx stream map usa hostnames (O(1))"
assert_contains "$JOIF_NGINX_STREAM_CONF" "default 0;" "nginx stream bloquea por defecto SNI no listado"
assert_contains "$JOIF_NGINX_STREAM_CONF" ".mercadopago.com.ar 1;" "nginx stream autoriza .mercadopago.com.ar"
assert_contains "$JOIF_NGINX_STREAM_CONF" "listen 127.0.0.1:18443;" "nginx stream incluye sumidero local de rechazo"
assert_contains "$JOIF_NGINX_STREAM_CONF" "deny all;" "sumidero local de rechazo aplica deny all"
assert_contains "$JOIF_NGINX_STREAM_CONF" 'proxy_pass $joif_tls_host:$joif_tls_port;' "nginx stream reenvia por variables validadas"

# Verificar cero duplicados en map stream (nginx -t fallaria con duplicados)
dup_stream="$(grep -E '^[[:space:]]+\.[a-z0-9.-]+[[:space:]]+1;$' "$JOIF_NGINX_STREAM_CONF" | sort | uniq -d | wc -l | tr -d '[:space:]')"
assert_eq "0" "$dup_stream" "nginx stream map no contiene dominios duplicados"

# Validaciones nginx-http.conf (puerto 80)
assert_contains "$JOIF_NGINX_HTTP_CONF" "listen 80 default_server;" "nginx http escucha en puerto 80"
assert_contains "$JOIF_NGINX_HTTP_CONF" 'map $host $joif_http_allowed' "nginx http valida cabecera Host en allowlist"
assert_contains "$JOIF_NGINX_HTTP_CONF" "return 444;" "nginx http descarta trafico no autorizado con 444"
assert_contains "$JOIF_NGINX_HTTP_CONF" 'proxy_pass http://$host:80$request_uri;' "nginx http reenvia estrictamente a puerto 80 del Host validado"
assert_not_contains "$JOIF_NGINX_HTTP_CONF" "resolver 127.0.0.1" "nginx http nunca usa 127.0.0.1 como resolver"

# Rollback nginx ante fallo de nginx -t
prev_stream_hash="$(sha256sum "$JOIF_NGINX_STREAM_CONF" | awk '{print $1}')"
prev_http_hash="$(sha256sum "$JOIF_NGINX_HTTP_CONF" | awk '{print $1}')"
domains_custom_add "nuevo-rollback-test.com.ar" >/dev/null
if MOCK_NGINX_FAIL=1 nginx_apply >/dev/null 2>&1; then
    fail "nginx_apply debio fallar cuando nginx -t retorna error"
else
    cur_stream_hash="$(sha256sum "$JOIF_NGINX_STREAM_CONF" | awk '{print $1}')"
    cur_http_hash="$(sha256sum "$JOIF_NGINX_HTTP_CONF" | awk '{print $1}')"
    assert_eq "$prev_stream_hash" "$cur_stream_hash" "Rollback nginx restaura nginx-stream.conf anterior"
    assert_eq "$prev_http_hash" "$cur_http_hash" "Rollback nginx restaura nginx-http.conf anterior"
fi

# ------------------------------------------------------------------------------
# 5. Licencias por IP, expiracion automatica y firewall seguro (SSH intacto)
# ------------------------------------------------------------------------------
printf '\n=== [5] Licencias IP, vencimiento automatico y firewall (SSH seguro) ===\n'

FW_LOG="${TEST_ROOT}/firewall_calls.log"
IPSET_STATE="${TEST_ROOT}/ipset_members.state"
: > "$FW_LOG"
: > "$IPSET_STATE"

# Mock ipset que persiste miembros, flags (counters) y packets/bytes tras swap
cat > "${MOCK_BIN}/ipset" <<EOF
#!/usr/bin/env bash
printf 'ipset %s\n' "\$*" >> "${FW_LOG}"
cmd="\${1:-}"
setname="\${2:-}"
case "\$cmd" in
    create)
        touch "${TEST_ROOT}/set_\${setname}"
        if [[ " \$* " == *" counters "* ]]; then
            echo "counters" > "${TEST_ROOT}/hdr_\${setname}"
        else
            echo "plain" > "${TEST_ROOT}/hdr_\${setname}"
        fi
        ;;
    flush)
        : > "${TEST_ROOT}/set_\${setname}"
        ;;
    add)
        member="\${3:-}"
        pkts="0"
        byts="0"
        shift 3
        while [[ \$# -gt 0 ]]; do
            if [[ "\$1" == "packets" ]]; then pkts="\$2"; shift 2;
            elif [[ "\$1" == "bytes" ]]; then byts="\$2"; shift 2;
            else shift; fi
        done
        echo "\${member} packets \${pkts} bytes \${byts}" >> "${TEST_ROOT}/set_\${setname}"
        ;;
    swap)
        tmp="\${2:-}"
        dst="\${3:-}"
        h1="\$(cat "${TEST_ROOT}/hdr_\${tmp}" 2>/dev/null || echo plain)"
        h2="\$(cat "${TEST_ROOT}/hdr_\${dst}" 2>/dev/null || echo plain)"
        if [[ "\$h1" != "\$h2" ]]; then
            echo "ipset: sets cannot be swapped (different extensions: \$h1 vs \$h2)" >&2
            exit 1
        fi
        cp "${TEST_ROOT}/set_\${tmp}" "${TEST_ROOT}/set_\${dst}"
        cp "${TEST_ROOT}/set_\${dst}" "${IPSET_STATE}"
        ;;
    destroy)
        rm -f "${TEST_ROOT}/set_\${setname}" "${TEST_ROOT}/hdr_\${setname}"
        ;;
    list)
        if [[ "\${2:-}" == "-t" ]]; then
            sname="\${3:-}"
            [[ -f "${TEST_ROOT}/set_\${sname}" ]] || exit 1
            hdr="\$(cat "${TEST_ROOT}/hdr_\${sname}" 2>/dev/null || echo plain)"
            echo "Name: \${sname}"
            if [[ "\$hdr" == "counters" ]]; then
                echo "Header: family inet hashsize 1024 maxelem 65536 counters"
            else
                echo "Header: family inet hashsize 1024 maxelem 65536"
            fi
        else
            sname="\${2:-}"
            [[ -f "${TEST_ROOT}/set_\${sname}" ]] || exit 1
            echo "Name: \${sname}"
            echo "Members:"
            cat "${TEST_ROOT}/set_\${sname}"
        fi
        ;;
    save)
        if [[ -f "${TEST_ROOT}/set_\${setname}" ]]; then
            hdr="\$(cat "${TEST_ROOT}/hdr_\${setname}" 2>/dev/null || echo plain)"
            if [[ "\$hdr" == "counters" ]]; then
                echo "create \${setname} hash:net family inet counters"
            else
                echo "create \${setname} hash:net family inet"
            fi
            while IFS= read -r m; do
                [[ -n "\$m" ]] && echo "add \${setname} \${m}"
            done < "${TEST_ROOT}/set_\${setname}"
        fi
        ;;
esac
exit 0
EOF
chmod +x "${MOCK_BIN}/ipset"

# Mock iptables / ip6tables que registra cada invocacion
cat > "${MOCK_BIN}/iptables" <<EOF
#!/usr/bin/env bash
printf 'iptables %s\n' "\$*" >> "${FW_LOG}"
# Simular -C como ausente la primera vez para forzar -I
if [[ "\${1:-}" == "-C" ]]; then
    exit 1
fi
if [[ "\${1:-}" == "-D" ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/iptables"

cat > "${MOCK_BIN}/ip6tables" <<EOF
#!/usr/bin/env bash
printf 'ip6tables %s\n' "\$*" >> "${FW_LOG}"
if [[ "\${1:-}" == "-C" || "\${1:-}" == "-D" ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/ip6tables"

export JOIF_IPSET_BIN="${MOCK_BIN}/ipset"
export JOIF_IPTABLES_BIN="${MOCK_BIN}/iptables"
export JOIF_IP6TABLES_BIN="${MOCK_BIN}/ip6tables"

# Verificar regresion: cargar diagnostics.sh NO debe apagar JOIF_AUTO_SYNC_FIREWALL
export JOIF_AUTO_SYNC_FIREWALL=1
# shellcheck source=core/licenses.sh
source "${REPO_DIR}/core/licenses.sh"
# shellcheck source=core/diagnostics.sh
source "${REPO_DIR}/core/diagnostics.sh"
assert_eq "1" "$JOIF_AUTO_SYNC_FIREWALL" "Cargar diagnostics.sh mantiene JOIF_AUTO_SYNC_FIREWALL=1"

# Tiempo base fijo: 2023-11-14 22:13:20 UTC
export JOIF_NOW_EPOCH=1700000000

license_add "203.0.113.10" "Nodo Brasil 01" 0 >/dev/null
license_add "198.51.100.0/24" "Nodos USA | Backup" 5 >/dev/null
license_add "192.0.2.55" "Cliente Temporal" 1 >/dev/null

# Rechazar duplicado
! license_add "203.0.113.10" "Duplicado" 0 >/dev/null 2>&1 && pass "IP duplicada rechazada correctamente" || fail "IP duplicada fue aceptada"

# Verificar sanitizacion de '|' en alias
assert_contains "$JOIF_LICENSES_DB" "Nodos USA - Backup" "Caracter '|' en alias sanitizado a '-'"

# Verificar que las 3 IPs llegaron al ipset
assert_contains "$IPSET_STATE" "203.0.113.10/32" "ipset incluye Nodo Brasil 01 (permanente)"
assert_contains "$IPSET_STATE" "198.51.100.0/24" "ipset incluye subred CIDR Nodos USA"
assert_contains "$IPSET_STATE" "192.0.2.55/32" "ipset incluye Cliente Temporal"

# Suspender manualmente -> sale de ipset inmediatamente
license_suspend "198.51.100.0/24" >/dev/null
assert_not_contains "$IPSET_STATE" "198.51.100.0/24" "Suspender licencia remueve CIDR de ipset inmediatamente"

# Reactivar mientras aun esta vigente -> vuelve a ipset
license_reactivate "198.51.100.0/24" >/dev/null
assert_contains "$IPSET_STATE" "198.51.100.0/24" "Reactivar licencia vigente devuelve CIDR a ipset"

# Avanzar reloj 1 dia + 1 segundo (Cliente Temporal vence; Nodos USA y Brasil siguen vigentes)
export JOIF_NOW_EPOCH=$((1700000000 + 86401))
bash "${REPO_DIR}/core/expire-licenses.sh" >/dev/null

assert_not_contains "$IPSET_STATE" "192.0.2.55/32" "Job horario desactiva IP vencida del ipset automaticamente"
assert_contains "$IPSET_STATE" "203.0.113.10/32" "Licencia permanente (0 dias) nunca vence"
assert_contains "$IPSET_STATE" "198.51.100.0/24" "Licencia de 5 dias sigue activa al dia 1"
assert_contains "$JOIF_LICENSES_DB" "192.0.2.55/32|Cliente Temporal|1700000000|1700086400|suspendida|" "Estado en DB cambia a suspendida tras vencer"

# Intentar reactivar una vencida debe devolver codigo 2
rc=0
license_reactivate "192.0.2.55" >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "Reactivar IP vencida sin renovar retorna codigo 2"

# Renovar IP vencida (+30 dias) -> reactiva y vuelve a ipset
license_renew "192.0.2.55" 30 >/dev/null
assert_contains "$IPSET_STATE" "192.0.2.55/32" "Renovar IP vencida la reactiva y restaura en ipset"
expected_exp=$(( JOIF_NOW_EPOCH + 30 * 86400 ))
assert_contains "$JOIF_LICENSES_DB" "192.0.2.55/32|Cliente Temporal|1700000000|${expected_exp}|activa|" "Renovacion de vencida suma dias desde fecha actual"

# Renovacion anticipada de licencia vigente (+10 dias sobre los 5 originales = 15 dias desde inicio)
license_renew "198.51.100.0/24" 10 >/dev/null
expected_early=$(( 1700000000 + 15 * 86400 ))
assert_contains "$JOIF_LICENSES_DB" "198.51.100.0/24|Nodos USA - Backup|1700000000|${expected_early}|activa|" "Renovacion anticipada preserva dias restantes y suma los nuevos"

# Eliminar licencia
license_remove "192.0.2.55" >/dev/null
assert_not_contains "$JOIF_LICENSES_DB" "192.0.2.55/32" "Eliminar licencia la borra de licenses.db"
assert_not_contains "$IPSET_STATE" "192.0.2.55/32" "Eliminar licencia la quita de ipset"

# Aplicar firewall completo y auditar seguridad SSH
: > "$FW_LOG"
bash "${REPO_DIR}/core/firewall.sh" apply >/dev/null

assert_contains "$FW_LOG" "ipset swap joif_smartdns_allow_tmp joif_smartdns_allow" "Firewall usa swap atomico en ipset"
assert_contains "$FW_LOG" "iptables -A JOIF_SMARTDNS -s 127.0.0.1/32 -j ACCEPT" "Firewall permite loopback 127.0.0.1"
assert_contains "$FW_LOG" "iptables -A JOIF_SMARTDNS -m set --match-set joif_smartdns_allow src -j ACCEPT" "Firewall permite unicamente ipset joif_smartdns_allow"
assert_contains "$FW_LOG" "iptables -A JOIF_SMARTDNS -j DROP" "Firewall hace DROP a IPs no autorizadas"
assert_contains "$FW_LOG" "iptables -I INPUT 1 -p udp --dport 53 -j JOIF_SMARTDNS" "Firewall protege 53/udp"
assert_contains "$FW_LOG" "iptables -I INPUT 1 -p tcp --dport 53 -j JOIF_SMARTDNS" "Firewall protege 53/tcp"
assert_contains "$FW_LOG" "iptables -I INPUT 1 -p tcp --dport 80 -j JOIF_SMARTDNS" "Firewall protege 80/tcp"
assert_contains "$FW_LOG" "iptables -I INPUT 1 -p tcp --dport 443 -j JOIF_SMARTDNS" "Firewall protege 443/tcp"

# Invariantes criticos de seguridad SSH
assert_not_contains "$FW_LOG" "--dport 22" "INVARIANTE CRITICO: Firewall NUNCA toca el puerto SSH (22)"
assert_not_contains "$FW_LOG" "-P INPUT" "INVARIANTE CRITICO: Firewall NUNCA cambia politica por defecto de INPUT"
assert_not_contains "$FW_LOG" "-F INPUT" "INVARIANTE CRITICO: Firewall NUNCA vacia la cadena INPUT"

# Probar teardown limpio
bash "${REPO_DIR}/core/firewall.sh" teardown >/dev/null
assert_contains "$FW_LOG" "iptables -X JOIF_SMARTDNS" "Teardown elimina cadena JOIF_SMARTDNS"
assert_contains "$FW_LOG" "ipset destroy joif_smartdns_allow" "Teardown destruye ipset joif_smartdns_allow"
assert_not_contains "$FW_LOG" "--dport 22" "Teardown NUNCA toca el puerto SSH (22)"

# Probar ayuda CLI de menu.sh, install.sh y tools/acceso-root.sh
bash "${REPO_DIR}/menu.sh" --help >/dev/null && pass "menu.sh --help ejecuta correctamente" || fail "menu.sh --help fallo"
bash "${REPO_DIR}/install.sh" --help >/dev/null && pass "install.sh --help ejecuta correctamente" || fail "install.sh --help fallo"
bash "${REPO_DIR}/tools/acceso-root.sh" --help >/dev/null && pass "tools/acceso-root.sh --help ejecuta correctamente" || fail "acceso-root.sh --help fallo"

# ------------------------------------------------------------------------------
# 6. Utilidad tools/acceso-root.sh (prioridad cloud-init, salida y rollback)
# ------------------------------------------------------------------------------
printf '\n=== [6] Utilidad tools/acceso-root.sh ===\n'

SSH_TEST_DIR="${TEST_ROOT}/etc/ssh"
mkdir -p "${SSH_TEST_DIR}/sshd_config.d"
cat > "${SSH_TEST_DIR}/sshd_config" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
Port 22
EOF
cat > "${SSH_TEST_DIR}/sshd_config.d/50-cloud-init.conf" <<'EOF'
PasswordAuthentication no
EOF

CHPASSWD_LOG="${TEST_ROOT}/chpasswd.log"
cat > "${MOCK_BIN}/chpasswd" <<EOF
#!/usr/bin/env bash
cat > "${CHPASSWD_LOG}"
EOF
chmod +x "${MOCK_BIN}/chpasswd"

cat > "${MOCK_BIN}/passwd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/passwd"

cat > "${MOCK_BIN}/sshd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-T" ]]; then
    echo "port 22"
    exit 0
fi
if [[ "${MOCK_SSHD_FAIL:-0}" == "1" ]]; then
    echo "sshd: syntax error (simulated)" >&2
    exit 1
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/sshd"

ROOT_OUT="${TEST_ROOT}/acceso_root.out"
JOIF_ALLOW_NONROOT_TEST=1 \
JOIF_SSHD_CONF="${SSH_TEST_DIR}/sshd_config" \
JOIF_SSHD_DROPIN_DIR="${SSH_TEST_DIR}/sshd_config.d" \
JOIF_SSHD_DROPIN_FILE="${SSH_TEST_DIR}/sshd_config.d/00-joif-root.conf" \
JOIF_SSHD_BIN="${MOCK_BIN}/sshd" \
JOIF_CHPASSWD_BIN="${MOCK_BIN}/chpasswd" \
JOIF_PASSWD_BIN="${MOCK_BIN}/passwd" \
JOIF_SKIP_SSH_RESTART=1 \
JOIF_ROOT_PASSWORD_INPUT="ClaveSegura2026" \
JOIF_PUBLIC_IP_OVERRIDE="203.0.113.25" \
bash "${REPO_DIR}/tools/acceso-root.sh" > "$ROOT_OUT"

assert_contains "${SSH_TEST_DIR}/sshd_config.d/00-joif-root.conf" "PermitRootLogin yes" "acceso-root crea drop-in 00-joif-root.conf con PermitRootLogin yes"
assert_contains "${SSH_TEST_DIR}/sshd_config.d/00-joif-root.conf" "PasswordAuthentication yes" "acceso-root habilita PasswordAuthentication yes sobre cloud-init"
assert_contains "$CHPASSWD_LOG" "root:ClaveSegura2026" "acceso-root envia root:<clave> a chpasswd"
assert_contains "$ROOT_OUT" "Usuario: root   Clave: ClaveSegura2026   IP: 203.0.113.25" "acceso-root imprime tarjeta con Usuario, Clave e IP"

# Probar rollback de acceso-root si sshd -t falla
rm -f "${SSH_TEST_DIR}/sshd_config.d/00-joif-root.conf"
if MOCK_SSHD_FAIL=1 \
   JOIF_ALLOW_NONROOT_TEST=1 \
   JOIF_SSHD_CONF="${SSH_TEST_DIR}/sshd_config" \
   JOIF_SSHD_DROPIN_DIR="${SSH_TEST_DIR}/sshd_config.d" \
   JOIF_SSHD_DROPIN_FILE="${SSH_TEST_DIR}/sshd_config.d/00-joif-root.conf" \
   JOIF_SSHD_BIN="${MOCK_BIN}/sshd" \
   JOIF_CHPASSWD_BIN="${MOCK_BIN}/chpasswd" \
   JOIF_PASSWD_BIN="${MOCK_BIN}/passwd" \
   JOIF_SKIP_SSH_RESTART=1 \
   JOIF_ROOT_PASSWORD_INPUT="OtraClave" \
   bash "${REPO_DIR}/tools/acceso-root.sh" >/dev/null 2>&1; then
    fail "acceso-root debio fallar cuando sshd -t retorna error"
else
    if [[ ! -f "${SSH_TEST_DIR}/sshd_config.d/00-joif-root.conf" ]]; then
        pass "Rollback de acceso-root elimina drop-in invalido si sshd -t falla"
    else
        fail "Rollback de acceso-root dejo drop-in invalido"
    fi
fi

# ------------------------------------------------------------------------------
# 7. Fase 1: Geo/ISP liviano, ipset counters + migracion, metricas, disco 10GB, backup y updater
# ------------------------------------------------------------------------------
printf '\n=== [7] Fase 1: Geo/ISP, counters, metricas, disco 10 GB, backup y updater ===\n'

# 7.1 Geo/ISP liviano + human bytes + edicion de alias + retrocompatibilidad v1 (6 cols)
assert_eq "0 B"     "$(joif_human_bytes 0)"          "joif_human_bytes 0 -> 0 B"
assert_eq "1.5 KB"  "$(joif_human_bytes 1536)"       "joif_human_bytes 1536 -> 1.5 KB"
assert_eq "2.0 MB"  "$(joif_human_bytes 2097152)"    "joif_human_bytes 2MB -> 2.0 MB"
assert_eq "1.00 GB" "$(joif_human_bytes 1073741824)" "joif_human_bytes 1GB -> 1.00 GB"

assert_eq "Red privada/local" "$(JOIF_DISABLE_GEO_LOOKUP=0 joif_lookup_ip_geo "192.168.1.50/32")" "IP privada no consulta API externa"
assert_eq "BR/Sao Paulo (Oracle)" "$(JOIF_GEO_OVERRIDE="BR/Sao Paulo (Oracle)" joif_lookup_ip_geo "144.22.167.150")" "joif_lookup_ip_geo respeta override y sanitiza"

# Simular fila legacy v1 (6 columnas sin geo) y probar edit-alias + refresh-geo
cat > "$JOIF_LICENSES_DB" <<'EOF'
# joif-smartdns licenses v1
144.22.167.150/32|Nodo Brasil Viejo|1700000000|0|activa|1700000000
EOF
license_edit_alias "144.22.167.150" "Nodo Brasil 01" >/dev/null
assert_contains "$JOIF_LICENSES_DB" "144.22.167.150/32|Nodo Brasil 01|1700000000|0|activa|" "license_edit_alias actualiza alias preservando vencimiento"

JOIF_GEO_OVERRIDE="BR/Sao Paulo (Oracle Cloud)" license_refresh_geo "144.22.167.150" >/dev/null
assert_contains "$JOIF_LICENSES_DB" "|BR/Sao Paulo (Oracle Cloud)" "license_refresh_geo guarda origen Geo/ISP en licenses.db"

# 7.2 Migracion en caliente de ipset v1.0 (sin counters) -> v1.1 (con counters) y preservacion de contadores
echo "plain" > "${TEST_ROOT}/hdr_joif_smartdns_allow"
echo "144.22.167.150/32" > "${TEST_ROOT}/set_joif_smartdns_allow"
: > "$FW_LOG"
bash "${REPO_DIR}/core/firewall.sh" apply >/dev/null
assert_eq "counters" "$(cat "${TEST_ROOT}/hdr_joif_smartdns_allow")" "firewall migra ipset legacy sin counters a counters sin fallar"
assert_not_contains "$FW_LOG" "--dport 22" "Migracion de ipset a counters NUNCA toca SSH 22"

# Simular trafico acumulado en el kernel y comprobar que sync-ipset preserva packets/bytes
echo "144.22.167.150/32 packets 420 bytes 987654" > "${TEST_ROOT}/set_joif_smartdns_allow"
bash "${REPO_DIR}/core/firewall.sh" sync-ipset >/dev/null
assert_contains "${TEST_ROOT}/set_joif_smartdns_allow" "144.22.167.150/32 packets 420 bytes 987654" "sync-ipset preserva contadores packets/bytes existentes tras swap"

# 7.3 nginx_gen con JOIF_ACCESS_LOG=off
JOIF_ACCESS_LOG="off" nginx_render_stream_conf "${TEST_ROOT}/stream_nolog.conf"
JOIF_ACCESS_LOG="off" nginx_render_http_conf "${TEST_ROOT}/http_nolog.conf"
assert_contains "${TEST_ROOT}/stream_nolog.conf" "access_log off;" "nginx stream respeta JOIF_ACCESS_LOG=off"
assert_contains "${TEST_ROOT}/http_nolog.conf" "access_log off;" "nginx http respeta JOIF_ACCESS_LOG=off"

# 7.4 Metricas livianas (top dominios + actividad por IP combinando geo + ipset + log)
# shellcheck source=core/metrics.sh
source "${REPO_DIR}/core/metrics.sh"

cat > "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log" <<'EOF'
127.0.0.1 [26/Nov/2026:16:10:00 +0000] sni="mercadopago.com.ar" allowed=1 target="mercadopago.com.ar:443" status=200 sent=1000 recv=100 time=0.05
144.22.167.150 [26/Nov/2026:16:55:10 +0000] sni="api.transfers.prod.personalpay.dev" allowed=1 target="api.transfers.prod.personalpay.dev:443" status=200 sent=100000 recv=50000 time=2.1
144.22.167.150 [26/Nov/2026:16:55:20 +0000] sni="mercadopago.com.ar" allowed=1 target="mercadopago.com.ar:443" status=200 sent=20000 recv=5000 time=0.4
144.22.167.150 [26/Nov/2026:16:55:25 +0000] sni="example.com" allowed=0 target="127.0.0.1:18443" status=200 sent=0 recv=0 time=0.001
EOF

top_out="${TEST_ROOT}/top_domains.txt"
metrics_top_domains 5 > "$top_out"
assert_contains "$top_out" "api.transfers.prod.personalpay.dev|1|150000|" "metrics_top_domains agrega bytes y excluye 127.0.0.1 y bloqueados"
assert_not_contains "$top_out" "example.com" "metrics_top_domains excluye SNI rechazados (allowed=0)"

ip_act_out="${TEST_ROOT}/ip_activity.txt"
metrics_ip_activity > "$ip_act_out"
assert_contains "$ip_act_out" "144.22.167.150/32|Nodo Brasil 01|BR/Sao Paulo (Oracle Cloud)|420|987654|3|175000|26/Nov/2026:16:55:25" "metrics_ip_activity combina DB geo + ipset counters + log SNI"

# 7.5 Proteccion de disco 10 GB (logrotate + journald + recorte de log gigante + backup/restore)
# shellcheck source=core/maintenance.sh
source "${REPO_DIR}/core/maintenance.sh"

maintenance_install_disk_guards >/dev/null
assert_contains "$JOIF_LOGROTATE_FILE" "maxsize 5M" "logrotate instalado con tope maxsize 5M"
assert_contains "$JOIF_LOGROTATE_FILE" "rotate 2" "logrotate instalado con retencion acotada (rotate 2)"
assert_contains "$JOIF_JOURNALD_DROPIN" "SystemMaxUse=80M" "journald limitado a 80M para VPS de 10 GB"

# Simular log de >2000 bytes con tope JOIF_LOG_MAX_BYTES=2000 y verificar recorte a 500 lineas + purga .2.gz
printf 'linea de prueba de trafico smartdns\n%.0s' {1..700} > "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log"
touch "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log.2.gz"
JOIF_LOG_MAX_BYTES=2000 maintenance_enforce_log_cap >/dev/null
kept_lines="$(wc -l < "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log" | tr -d '[:space:]')"
assert_eq "500" "$kept_lines" "maintenance_enforce_log_cap recorta log excedido conservando ultimas 500 lineas"
[[ ! -f "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log.2.gz" ]] && pass "maintenance_enforce_log_cap elimina rotados viejos .2.gz" || fail "No elimino .2.gz"

# Backup y restore + rechazo de archivo malicioso (path traversal)
bk_file="$(maintenance_backup | tail -n1)"
[[ -f "$bk_file" ]] && pass "maintenance_backup genera archivo .tar.gz liviano" || fail "maintenance_backup no genero archivo"

# Mutar estado y restaurar desde backup
echo "corrupted" > "$JOIF_LICENSES_DB"
maintenance_restore "$bk_file" >/dev/null
assert_contains "$JOIF_LICENSES_DB" "144.22.167.150/32|Nodo Brasil 01|" "maintenance_restore recupera licenses.db intacto"

# 7.6 Actualizador real (core/updater.sh) con merge inteligente respetando categorias pausadas
# shellcheck source=core/updater.sh
source "${REPO_DIR}/core/updater.sh"

UPD_INSTALL="${TEST_ROOT}/opt/joif-smartdns-upd"
UPD_SRC="${TEST_ROOT}/fake-upstream-repo"
mkdir -p "$UPD_INSTALL" "$UPD_SRC"
cp -a "${REPO_DIR}/." "$UPD_SRC/"
rm -rf "${UPD_SRC}/.git"

# Agregar un dominio nuevo en upstream fintech y uno en upstream streaming (que dejaremos pausada!)
printf '\nnuevobanco-ar.com.ar\n' >> "${UPD_SRC}/domains.d/01-fintech-bancos.list"
printf '\nnuevostream-ar.com.ar\n' >> "${UPD_SRC}/domains.d/03-streaming-ar.list"
domains_disable_category "03-streaming-ar" >/dev/null
domains_custom_add "mi-custom-intacto.com.ar" >/dev/null

JOIF_INSTALL_DIR="$UPD_INSTALL" updater_run --source-dir "$UPD_SRC" >/dev/null

assert_contains "${JOIF_DOMAINS_DIR}/01-fintech-bancos.list" "nuevobanco-ar.com.ar" "updater hace merge de dominios nuevos en categoria activa"
[[ -f "${JOIF_DOMAINS_DIR}/03-streaming-ar.list.disabled" && ! -f "${JOIF_DOMAINS_DIR}/03-streaming-ar.list" ]] && pass "updater mantiene pausada la categoria 03-streaming-ar" || fail "updater reactivo categoria pausada"
assert_contains "${JOIF_DOMAINS_DIR}/03-streaming-ar.list.disabled" "nuevostream-ar.com.ar" "updater actualiza dominios dentro de categoria pausada sin activarla"
assert_contains "${JOIF_DOMAINS_DIR}/99-custom.list" "mi-custom-intacto.com.ar" "updater preserva intacto 99-custom.list"
assert_contains "$JOIF_LICENSES_DB" "144.22.167.150/32|Nodo Brasil 01|" "updater preserva intacto licenses.db"
[[ -x "${UPD_INSTALL}/core/updater.sh" ]] && pass "updater despliega scripts ejecutables en JOIF_INSTALL_DIR sin requerir .git" || fail "updater no desplego scripts"

# Regresion SIGPIPE/pipefail: re-ejecutar updater NO debe duplicar dominios existentes en el .list
mp_before_upd="$(grep -Fxc "mercadopago.com.ar" "${JOIF_DOMAINS_DIR}/01-fintech-bancos.list")"
printf 'mercadopago.com.ar\n' >> "${JOIF_DOMAINS_DIR}/01-fintech-bancos.list"
JOIF_INSTALL_DIR="$UPD_INSTALL" updater_run --source-dir "$UPD_SRC" >/dev/null
mp_after_upd="$(grep -Fxc "mercadopago.com.ar" "${JOIF_DOMAINS_DIR}/01-fintech-bancos.list")"
assert_eq "1" "$mp_before_upd" "updater no duplica dominios existentes bajo pipefail"
assert_eq "1" "$mp_after_upd" "updater deduplica automaticamente duplicados previos en listas base"

# ------------------------------------------------------------------------------
# 8. Fase 2: UI compacta (UTF-8 / ASCII <=74 cols) y buscador/probador de dominios
# ------------------------------------------------------------------------------
printf '\n=== [8] Fase 2: UI compacta y buscador/probador de dominios ===\n'

# shellcheck source=core/ui.sh
source "${REPO_DIR}/core/ui.sh"

# Probar modo ASCII fallback (terminales sin UTF-8) y ancho maximo <= 74 cols
ascii_box="${TEST_ROOT}/ui_ascii.txt"
(
    JOIF_UI_ASCII=1 ui_init_charset
    ui_box_top
    ui_box_title "JOIF SMART DNS v1.2.0 — Prueba de caja compacta para celular SSH"
    ui_box_row "Linea extremadamente larga que deberia recortarse automaticamente para nunca romper el ancho de 74 columnas en moviles"
    ui_box_bottom
) > "$ascii_box"

assert_contains "$ascii_box" "+--------" "UI modo ASCII genera bordes seguros (+---)"
max_w="$(awk '{if(length($0)>m) m=length($0)} END{print m+0}' "$ascii_box")"
if (( max_w <= 74 )); then
    pass "UI mantiene ancho maximo <= 74 columnas para celular (max=${max_w})"
else
    fail "UI excedio 74 columnas (max=${max_w})"
fi

# Probar domains_extract_host (URLs completas -> dominio limpio)
assert_eq "api.brubank.com.ar" "$(domains_extract_host "https://API.BRUBANK.COM.AR:443/v1/transfer?foo=1")" "domains_extract_host limpia URL completa con puerto y ruta"

# Probar domains_find_match (subdominio -> regla padre activa, pausada y no cubierto)
match_active="$(domains_find_match "api.transfers.prod.personalpay.dev")"
assert_eq "personalpay.dev|01-fintech-bancos|activa" "${match_active%|*}" "domains_find_match detecta subdominio de personalpay.dev en categoria activa"

match_paused="$(domains_find_match "www.netflix.com")"
assert_eq "netflix.com|03-streaming-ar|desactivada" "${match_paused%|*}" "domains_find_match detecta subdominio en categoria pausada"

! domains_find_match "youtube.com" >/dev/null 2>&1 && pass "domains_find_match retorna no-match para youtube.com" || fail "youtube.com no deberia estar interceptado"

# Probar domains_check_live salida y codigos de retorno
chk_ar="${TEST_ROOT}/chk_ar.txt"
domains_check_live "https://api.transfers.prod.personalpay.dev/ping" > "$chk_ar"
assert_contains "$chk_ar" "[AR - INTERCEPTADO]" "domains_check_live marca personalpay.dev como [AR - INTERCEPTADO]"

chk_paused="${TEST_ROOT}/chk_paused.txt"
domains_check_live "www.netflix.com" > "$chk_paused"
assert_contains "$chk_paused" "[PAUSADA - SALE DIRECTO]" "domains_check_live marca categoria pausada correctamente"

chk_direct="${TEST_ROOT}/chk_direct.txt"
rc=0
domains_check_live "youtube.com" > "$chk_direct" || rc=$?
assert_eq "2" "$rc" "domains_check_live retorna codigo 2 cuando dominio no esta en listas AR"
assert_contains "$chk_direct" "[DIRECTO - NO ESTA EN LISTAS AR]" "domains_check_live informa salida directa por Brasil/USA"

# Probar que menu.sh --help incluye nuevos comandos y enlace a la guia
help_out="${TEST_ROOT}/menu_help.txt"
bash "${REPO_DIR}/menu.sh" --help > "$help_out"
assert_contains "$help_out" "smartdns domains check" "menu.sh --help documenta 'smartdns domains check'"
assert_contains "$help_out" "smartdns monitor" "menu.sh --help documenta 'smartdns monitor'"
assert_contains "$help_out" "smartdns discover" "menu.sh --help documenta 'smartdns discover'"
assert_contains "$help_out" "docs/GUIA-COMPLETA.md" "menu.sh --help incluye enlace directo a la guia en GitHub"

# ------------------------------------------------------------------------------
# 9. Fase 3: Monitor SNI formateado y Asistente "Descubrir dominios de una app"
# ------------------------------------------------------------------------------
printf '\n=== [9] Fase 3: Monitor SNI y Descubridor de dominios de apps ===\n'

# shellcheck source=core/monitor.sh
source "${REPO_DIR}/core/monitor.sh"

# 9.1 Filtro inteligente de ruido Android/Google/Meta/OEM/CDNs
monitor_is_noise_domain "graph.facebook.com"            && pass "Filtro oculta ruido Meta (graph.facebook.com)" || fail "No filtro facebook"
monitor_is_noise_domain "play.googleapis.com"           && pass "Filtro oculta ruido Google (play.googleapis.com)" || fail "No filtro googleapis"
monitor_is_noise_domain "d231v1wfkp86y7.cloudfront.net" && pass "Filtro oculta CDN generico (cloudfront.net)" || fail "No filtro cloudfront"
monitor_is_noise_domain "ota-checker.transsion-os.com"  && pass "Filtro oculta ruido OEM (transsion-os.com)" || fail "No filtro transsion-os"
! monitor_is_noise_domain "api.transfers.prod.personalpay.dev" && pass "Filtro conserva dominio real de fintech (personalpay.dev)" || fail "Filtro incorrectamente personalpay.dev"
! monitor_is_noise_domain "api.miappbancaria.com.ar"    && pass "Filtro conserva dominio argentino nuevo" || fail "Filtro incorrectamente miappbancaria.com.ar"

# 9.2 Sugerencia de dominio base respetando ccTLDs compuestos (.com.ar, .gob.ar, .com.br)
assert_eq "personalpay.dev"   "$(monitor_suggest_base_domain "api.transfers.prod.personalpay.dev")" "suggest_base extrae personalpay.dev"
assert_eq "paygilant.com"     "$(monitor_suggest_base_domain "api-prod-us.paygilant.com")"          "suggest_base extrae paygilant.com"
assert_eq "bna.com.ar"        "$(monitor_suggest_base_domain "homebanking.bna.com.ar")"             "suggest_base respeta .com.ar (no recorta a com.ar)"
assert_eq "miargentina.gob.ar" "$(monitor_suggest_base_domain "auth.miargentina.gob.ar")"           "suggest_base respeta .gob.ar (no recorta a gob.ar)"

# 9.3 Parser real de salida tcpdump puerto 53 + agrupacion de candidatos NUEVOS
tcpdump_sample="${TEST_ROOT}/tcpdump_sample.log"
cat > "$tcpdump_sample" <<'EOF'
16:47:03.654224 eth0  In  IP 144.22.167.150.56363 > 192.168.192.33.53: 26588+ A? graph.facebook.com. (36)
16:47:03.674745 eth0  Out IP 192.168.192.33.53 > 144.22.167.150.56363: 26588 2/0/0 CNAME star.c10r.facebook.com., A 57.144.206.141 (76)
16:47:25.522453 eth0  In  IP 144.22.167.150.34727 > 192.168.192.33.53: 3931+ A? api.transfers.prod.personalpay.dev. (63)
16:47:26.451045 eth0  In  IP 144.22.167.150.37359 > 192.168.192.33.53: 32064+ A? api.nuevabilletera.com.ar. (43)
16:47:26.886774 eth0  In  IP 144.22.167.150.46726 > 192.168.192.33.53: 46598+ A? auth.nuevabilletera.com.ar. (50)
16:47:27.000000 eth0  In  IP 144.22.167.150.46727 > 192.168.192.33.53: 46599+ A? www.netflix.com. (35)
16:47:27.100000 eth0  In  IP 144.22.167.150.46728 > 192.168.192.33.53: 46600+ A? ota-checker.transsion-os.com. (46)
16:47:27.200000 eth0  In  IP 144.22.167.150.46729 > 192.168.192.33.53: 46601+ A? d231v1wfkp86y7.cloudfront.net. (47)
EOF

parsed_dns="${TEST_ROOT}/parsed_dns.txt"
monitor_parse_tcpdump_dns < "$tcpdump_sample" > "$parsed_dns"

assert_contains "$parsed_dns" "AR|personalpay.dev|api.transfers.prod.personalpay.dev" "tcpdump parser clasifica dominio activo como AR"
assert_contains "$parsed_dns" "PAUSADA|netflix.com|www.netflix.com" "tcpdump parser clasifica dominio en categoria pausada como PAUSADA"
assert_contains "$parsed_dns" "NUEVO|nuevabilletera.com.ar|api.nuevabilletera.com.ar" "tcpdump parser detecta dominio nuevo y sugiere base .com.ar"
assert_not_contains "$parsed_dns" "facebook.com" "tcpdump parser descarta ruido de Facebook"
assert_not_contains "$parsed_dns" "transsion-os.com" "tcpdump parser descarta ruido de Transsion"
assert_not_contains "$parsed_dns" "cloudfront.net" "tcpdump parser descarta CDN generico"

cand_out="${TEST_ROOT}/candidates.txt"
monitor_summarize_new_candidates < "$parsed_dns" > "$cand_out"
assert_contains "$cand_out" "nuevabilletera.com.ar|2|api.nuevabilletera.com.ar" "summarize agrupa subdominios de nuevabilletera.com.ar con conteo=2"

# 9.4 Formateador de log SNI en vivo (alias + [OK]/[BLK] + bytes + excluye 127.0.0.1 + <=74 cols)
sni_fmt="${TEST_ROOT}/sni_formatted.txt"
cat <<'EOF' | monitor_sni_format_stream > "$sni_fmt"
127.0.0.1 [26/Nov/2026:16:10:00 +0000] sni="mercadopago.com.ar" allowed=1 target="mercadopago.com.ar:443" status=200 sent=1000 recv=100 time=0.05
144.22.167.150 [26/Nov/2026:16:55:53 +0000] sni="api.transfers.prod.personalpay.dev" allowed=1 target="api.transfers.prod.personalpay.dev:443" status=200 sent=106984 recv=64376 time=35.873
144.22.167.150 [26/Nov/2026:16:55:54 +0000] sni="example.com" allowed=0 target="127.0.0.1:18443" status=200 sent=0 recv=0 time=0.001
EOF

assert_not_contains "$sni_fmt" "127.0.0.1" "monitor_sni_format_stream excluye pruebas locales 127.0.0.1 por defecto"
assert_contains "$sni_fmt" "16:55:53 [OK]" "monitor_sni_format_stream muestra hora y badge [OK]"
assert_contains "$sni_fmt" "Nodo Brasil 01" "monitor_sni_format_stream traduce IP de origen al alias de licenses.db"
assert_contains "$sni_fmt" "16:55:54 [BLK]" "monitor_sni_format_stream muestra badge [BLK] para SNI rechazados"
sni_max_w="$(awk '{if(length($0)>m) m=length($0)} END{print m+0}' "$sni_fmt")"
if (( sni_max_w <= 74 )); then
    pass "monitor_sni_format_stream mantiene ancho <= 74 cols (max=${sni_max_w})"
else
    fail "monitor_sni_format_stream excedio 74 cols (max=${sni_max_w})"
fi

# ------------------------------------------------------------------------------
# 10. Fase 4: Documentacion docs/GUIA-COMPLETA.md y verificacion de anclas #
# ------------------------------------------------------------------------------
printf '\n=== [10] Fase 4: Documentacion y anclas enlazadas desde el script ===\n'

GUIDE_FILE="${REPO_DIR}/docs/GUIA-COMPLETA.md"
[[ -f "$GUIDE_FILE" ]] && pass "docs/GUIA-COMPLETA.md existe" || fail "Falta docs/GUIA-COMPLETA.md"

for anchor in instalacion conectar-vps-vpn licencias-ip dominios diagnostico descubrir-apps mantenimiento limitaciones desinstalacion; do
    assert_contains "$GUIDE_FILE" "<a id=\"${anchor}\"></a>" "GUIA-COMPLETA.md contiene ancla #${anchor}"
done

assert_contains "${REPO_DIR}/README.md" "docs/GUIA-COMPLETA.md" "README.md enlaza a docs/GUIA-COMPLETA.md"
assert_contains "${REPO_DIR}/README.md" "manuel3200/joif-smartdns" "README.md apunta al repositorio oficial"

# ------------------------------------------------------------------------------
# Resumen final
# ------------------------------------------------------------------------------
printf '\n====================================================================\n'
printf '  RESULTADO TESTS joif-smartdns: PASS=%d | FAIL=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '====================================================================\n'

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
