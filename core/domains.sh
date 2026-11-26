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
        *)
            echo "Uso: $0 {list|active|enable|disable|toggle|add|remove} [arg]" >&2
            exit 1
            ;;
    esac
fi
