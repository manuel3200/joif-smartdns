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
export JOIF_SKIP_SERVICE_RELOAD=1

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
assert_line_exact "$JOIF_DNSMASQ_CONF" "filter-rr=HTTPS,SVCB" "dnsmasq 2.90 incluye directiva activa filter-rr=HTTPS,SVCB"
assert_contains "$JOIF_DNSMASQ_CONF" "no-resolv" "dnsmasq incluye no-resolv"
assert_contains "$JOIF_DNSMASQ_CONF" "no-hosts" "dnsmasq incluye no-hosts"
assert_contains "$JOIF_DNSMASQ_CONF" "server=1.1.1.1" "dnsmasq reenvia normales a 1.1.1.1"
assert_contains "$JOIF_DNSMASQ_CONF" "address=/mercadopago.com.ar/200.58.120.10" "dnsmasq intercepta mercadopago.com.ar hacia IP AR"
assert_not_contains "$JOIF_DNSMASQ_CONF" "server=127.0.0.1" "dnsmasq no contiene bucle hacia 127.0.0.1"

# Caso B: dnsmasq 2.86 (Ubuntu 22.04)
export JOIF_DNSMASQ_BIN="${MOCK_BIN}/dnsmasq-286"
conf_286="${TEST_ROOT}/dnsmasq-286.conf"
dnsmasq_render_config "200.58.120.10" "$conf_286"
assert_no_line_exact "$conf_286" "filter-rr=HTTPS,SVCB" "dnsmasq 2.86 omite directiva activa filter-rr=HTTPS,SVCB dinamicamente"
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

# Mock ipset que persiste miembros del set activo tras swap
cat > "${MOCK_BIN}/ipset" <<EOF
#!/usr/bin/env bash
printf 'ipset %s\n' "\$*" >> "${FW_LOG}"
cmd="\${1:-}"
setname="\${2:-}"
case "\$cmd" in
    create)
        touch "${TEST_ROOT}/set_\${setname}"
        ;;
    flush)
        : > "${TEST_ROOT}/set_\${setname}"
        ;;
    add)
        echo "\${3:-}" >> "${TEST_ROOT}/set_\${setname}"
        ;;
    swap)
        tmp="\${2:-}"
        dst="\${3:-}"
        cp "${TEST_ROOT}/set_\${tmp}" "${TEST_ROOT}/set_\${dst}"
        cp "${TEST_ROOT}/set_\${dst}" "${IPSET_STATE}"
        ;;
    destroy)
        rm -f "${TEST_ROOT}/set_\${setname}"
        ;;
    save)
        if [[ -f "${TEST_ROOT}/set_\${setname}" ]]; then
            echo "create \${setname} hash:net family inet"
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

# Probar ayuda CLI de menu.sh e install.sh
bash "${REPO_DIR}/menu.sh" --help >/dev/null && pass "menu.sh --help ejecuta correctamente" || fail "menu.sh --help fallo"
bash "${REPO_DIR}/install.sh" --help >/dev/null && pass "install.sh --help ejecuta correctamente" || fail "install.sh --help fallo"

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
