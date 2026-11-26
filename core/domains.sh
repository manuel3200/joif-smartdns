#!/usr/bin/env bash
# core/domains.sh — Parser, validacion y gestion de listas modulares en domains.d/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"

domains_category_label() {
    local slug="${1:-}"
    case "$slug" in
        01-fintech-bancos) printf 'Fintech, Billeteras y Bancos AR\n' ;;
        02-gobierno-ar)    printf 'Gobierno Argentino (.gob.ar)\n' ;;
        03-streaming-ar)   printf 'Streaming y TV Argentina\n' ;;
        99-custom)         printf 'Dominios Personalizados\n' ;;
        *)                 printf '%s\n' "$slug" ;;
    esac
}

# Parsea un archivo .list devolviendo dominios normalizados (uno por linea)
domains_parse_file() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1

    local line_no=0 raw norm
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_no=$((line_no + 1))
        # Limpiar BOM, CR y comentarios
        raw="${raw#$'\xef\xbb\xbf'}"
        raw="${raw//$'\r'/}"
        raw="${raw%%#*}"
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [[ -z "$raw" ]] && continue

        if norm="$(joif_normalize_domain "$raw")"; then
            printf '%s\n' "$norm"
        else
            log_warn "Dominio invalido ignorado en $(basename "$file"):${line_no} -> '${raw}'"
        fi
    done < "$file"
}

# Recolecta todos los dominios activos (solo archivos *.list, deduplicados y ordenados)
domains_collect_active() {
    [[ -d "$JOIF_DOMAINS_DIR" ]] || return 0
    local f
    local found=0
    {
        shopt -s nullglob
        for f in "${JOIF_DOMAINS_DIR}"/*.list; do
            [[ -f "$f" ]] || continue
            found=1
            domains_parse_file "$f"
        done
        shopt -u nullglob
    } | LC_ALL=C sort -u
    return 0
}

# Lista categorias en formato: slug|label|estado|cantidad|ruta
domains_list_categories() {
    [[ -d "$JOIF_DOMAINS_DIR" ]] || return 0
    local f base slug status count label
    shopt -s nullglob
    for f in "${JOIF_DOMAINS_DIR}"/*.list "${JOIF_DOMAINS_DIR}"/*.list.disabled; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        if [[ "$base" == *.list.disabled ]]; then
            slug="${base%.list.disabled}"
            status="desactivada"
        else
            slug="${base%.list}"
            status="activa"
        fi
        label="$(domains_category_label "$slug")"
        count="$(domains_parse_file "$f" 2>/dev/null | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')"
        printf '%s|%s|%s|%s|%s\n' "$slug" "$label" "$status" "$count" "$f"
    done | LC_ALL=C sort -t'|' -k1,1
    shopt -u nullglob
}

domains_enable_category() {
    local slug="${1:-}"
    slug="${slug%.list.disabled}"
    slug="${slug%.list}"
    local active="${JOIF_DOMAINS_DIR}/${slug}.list"
    local disabled="${JOIF_DOMAINS_DIR}/${slug}.list.disabled"

    if [[ -f "$active" ]]; then
        log_info "La categoria '${slug}' ya esta activa."
        return 0
    fi
    if [[ -f "$disabled" ]]; then
        mv -f "$disabled" "$active"
        log_ok "Categoria '${slug}' activada."
        return 0
    fi
    log_error "No existe la categoria '${slug}' en ${JOIF_DOMAINS_DIR}."
    return 1
}

domains_disable_category() {
    local slug="${1:-}"
    slug="${slug%.list.disabled}"
    slug="${slug%.list}"
    local active="${JOIF_DOMAINS_DIR}/${slug}.list"
    local disabled="${JOIF_DOMAINS_DIR}/${slug}.list.disabled"

    if [[ -f "$disabled" ]]; then
        log_info "La categoria '${slug}' ya esta desactivada."
        return 0
    fi
    if [[ -f "$active" ]]; then
        mv -f "$active" "$disabled"
        log_ok "Categoria '${slug}' desactivada."
        return 0
    fi
    log_error "No existe la categoria '${slug}' en ${JOIF_DOMAINS_DIR}."
    return 1
}

domains_toggle_category() {
    local slug="${1:-}"
    slug="${slug%.list.disabled}"
    slug="${slug%.list}"
    if [[ -f "${JOIF_DOMAINS_DIR}/${slug}.list" ]]; then
        domains_disable_category "$slug"
    elif [[ -f "${JOIF_DOMAINS_DIR}/${slug}.list.disabled" ]]; then
        domains_enable_category "$slug"
    else
        log_error "No existe la categoria '${slug}'."
        return 1
    fi
}

domains_custom_file() {
    joif_ensure_dirs
    local custom="${JOIF_DOMAINS_DIR}/99-custom.list"
    local custom_disabled="${JOIF_DOMAINS_DIR}/99-custom.list.disabled"
    if [[ ! -f "$custom" && -f "$custom_disabled" ]]; then
        mv -f "$custom_disabled" "$custom"
        log_info "Se reactivo automaticamente 99-custom.list."
    fi
    if [[ ! -f "$custom" ]]; then
        cat > "$custom" <<'EOF'
# joif-smartdns — Categoria: Dominios Personalizados
# Agrega aqui dominios adicionales (uno por linea) o usa el menu: smartdns
EOF
    fi
    printf '%s\n' "$custom"
}

domains_custom_add() {
    local raw="${1:-}"
    local norm
    if ! norm="$(joif_normalize_domain "$raw")"; then
        log_error "Dominio invalido: '${raw}'. Ejemplo valido: midominio.com.ar"
        return 1
    fi

    local custom
    custom="$(domains_custom_file)"

    if domains_parse_file "$custom" 2>/dev/null | grep -Fxq "$norm"; then
        log_warn "El dominio '${norm}' ya existe en 99-custom.list."
        return 0
    fi

    printf '%s\n' "$norm" >> "$custom"
    log_ok "Dominio '${norm}' agregado a 99-custom.list."
}

domains_custom_remove() {
    local raw="${1:-}"
    local norm
    if ! norm="$(joif_normalize_domain "$raw")"; then
        log_error "Dominio invalido: '${raw}'."
        return 1
    fi

    local custom="${JOIF_DOMAINS_DIR}/99-custom.list"
    [[ -f "$custom" ]] || {
        log_error "No existe ${custom}."
        return 1
    }

    local tmp removed=0 line parsed
    tmp="$(mktemp "${JOIF_DOMAINS_DIR}/.99-custom.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if parsed="$(joif_normalize_domain "$line" 2>/dev/null)" && [[ "$parsed" == "$norm" ]]; then
            removed=1
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$custom"

    if [[ "$removed" -eq 0 ]]; then
        rm -f "$tmp"
        log_warn "El dominio '${norm}' no se encontro en 99-custom.list."
        return 1
    fi

    chmod 644 "$tmp"
    mv -f "$tmp" "$custom"
    log_ok "Dominio '${norm}' eliminado de 99-custom.list."
}

# Extrae hostname limpio incluso si el usuario pega una URL completa (ej. https://api.brubank.com.ar/v1)
domains_extract_host() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw#http://}"
    raw="${raw#https://}"
    raw="${raw%%/*}"
    raw="${raw%%\?*}"
    raw="${raw%%:*}"
    joif_normalize_domain "$raw"
}

# Busca si un dominio o cualquiera de sus dominios padre esta en alguna lista (activa o desactivada)
# Salida: regla_coincidente|categoria_slug|estado|ruta_archivo (retorna 1 si no coincide con ninguna)
domains_find_match() {
    local host
    host="$(domains_extract_host "${1:-}")" || return 1
    [[ -d "$JOIF_DOMAINS_DIR" ]] || return 1

    # Primero buscar en listas activas (*.list), luego en pausadas (*.list.disabled)
    local f base slug status rule
    shopt -s nullglob
    for f in "${JOIF_DOMAINS_DIR}"/*.list "${JOIF_DOMAINS_DIR}"/*.list.disabled; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        if [[ "$base" == *.list.disabled ]]; then
            slug="${base%.list.disabled}"
            status="desactivada"
        else
            slug="${base%.list}"
            status="activa"
        fi

        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            if [[ "$host" == "$rule" || "$host" == *".${rule}" ]]; then
                shopt -u nullglob
                printf '%s|%s|%s|%s\n' "$rule" "$slug" "$status" "$f"
                return 0
            fi
        done < <(domains_parse_file "$f" 2>/dev/null)
    done
    shopt -u nullglob
    return 1
}

# Diagnostico puntual de un dominio: lista coincidente + prueba DNS local + prueba SNI 443
domains_check_live() {
    local raw="${1:-}"
    local host
    if ! host="$(domains_extract_host "$raw")"; then
        log_error "Dominio invalido: '${raw}'. Ejemplo: api.brubank.com.ar"
        return 1
    fi

    joif_load_config
    local pub_ip="${JOIF_PUBLIC_IP:-}"

    printf '\n%b--- Consulta de Dominio: %s ---%b\n' "$C_BOLD" "$host" "$C_RESET"

    local match="" rule="" slug="" status="" path="" label=""
    if match="$(domains_find_match "$host")"; then
        IFS='|' read -r rule slug status path <<< "$match"
        label="$(domains_category_label "$slug")"
        if [[ "$status" == "activa" ]]; then
            printf '  Ruta Smart DNS : %b[AR - INTERCEPTADO]%b\n' "$C_GREEN" "$C_RESET"
        else
            printf '  Ruta Smart DNS : %b[PAUSADA - SALE DIRECTO]%b\n' "$C_YELLOW" "$C_RESET"
        fi
        printf '  Regla          : %s (categoria: %s — %s)\n' "$rule" "$slug" "$label"
    else
        printf '  Ruta Smart DNS : %b[DIRECTO - NO ESTA EN LISTAS AR]%b\n' "$C_CYAN" "$C_RESET"
        printf '  Detalle        : Sale directo por tu VPS de Brasil/USA sin consumir ancho de banda en AR.\n'
    fi

    # Pruebas en vivo contra dnsmasq local si dig esta disponible
    if command -v dig >/dev/null 2>&1; then
        local ans_a ans_aaaa ans_t65
        ans_a="$(dig +short +time=2 +tries=1 @127.0.0.1 "$host" A 2>/dev/null | head -n1 || true)"
        ans_aaaa="$(dig +short +time=2 +tries=1 @127.0.0.1 "$host" AAAA 2>/dev/null | head -n1 || true)"
        ans_t65="$(dig +short +time=2 +tries=1 @127.0.0.1 "$host" TYPE65 2>/dev/null | head -n1 || true)"
        printf '  DNS local (A)  : %s\n' "${ans_a:-sin respuesta}"
        printf '  DNS local AAAA : %s\n' "${ans_aaaa:-vacio (OK, sin fuga IPv6)}"
        printf '  DNS TYPE65     : %s\n' "${ans_t65:-vacio (OK, sin fuga HTTPS/SVCB)}"
        if [[ "$status" == "activa" && -n "$pub_ip" && "$ans_a" != "$pub_ip" ]]; then
            log_warn "El dominio figura en lista activa, pero dnsmasq devolvio '${ans_a:-vacio}'. Ejecuta 'smartdns reload'."
        fi
    fi

    # Prueba SNI passthrough en 127.0.0.1:443 si esta interceptado y openssl existe
    if [[ "$status" == "activa" ]] && command -v openssl >/dev/null 2>&1 && [[ "${JOIF_SKIP_SERVICE_RELOAD:-0}" != "1" ]]; then
        local sni_out subj
        sni_out="$(timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "$host" </dev/null 2>&1 || true)"
        subj="$(printf '%s\n' "$sni_out" | grep -m1 '^subject=' || true)"
        if [[ -n "$subj" ]]; then
            printf '  SNI Proxy 443  : %bOK%b (%s)\n' "$C_GREEN" "$C_RESET" "$subj"
        else
            printf '  SNI Proxy 443  : %bSin respuesta TLS en 127.0.0.1:443%b\n' "$C_YELLOW" "$C_RESET"
        fi
    fi

    printf '\n'
    [[ -n "$match" ]] && return 0 || return 2
}

# Ejecucion directa CLI opcional
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-list}"
    shift || true
    case "$cmd" in
        list)    domains_list_categories ;;
        active)  domains_collect_active ;;
        enable)  domains_enable_category "${1:-}" ;;
        disable) domains_disable_category "${1:-}" ;;
        toggle)  domains_toggle_category "${1:-}" ;;
        add)     domains_custom_add "${1:-}" ;;
        remove)  domains_custom_remove "${1:-}" ;;
        match)   domains_find_match "${1:-}" ;;
        check)   domains_check_live "${1:-}" ;;
        *)
            echo "Uso: $0 {list|active|enable|disable|toggle|add|remove|match|check} [arg]" >&2
            exit 1
            ;;
    esac
fi
