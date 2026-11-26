#!/usr/bin/env bash
# core/licenses.sh — Gestion de licencias por IP/CIDR (alta, renovacion, suspension, expiracion, geo liviano)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"

JOIF_AUTO_SYNC_FIREWALL="${JOIF_AUTO_SYNC_FIREWALL:-1}"

license_init_db() {
    joif_ensure_dirs
    mkdir -p "$(dirname "$JOIF_LICENSES_DB")"
    if [[ ! -f "$JOIF_LICENSES_DB" ]]; then
        cat > "$JOIF_LICENSES_DB" <<'EOF'
# joif-smartdns licenses v2
# ip_cidr|alias|created_at|expires_at|status|updated_at|geo
EOF
        chmod 640 "$JOIF_LICENSES_DB"
    fi
}

_license_sync_hook() {
    if [[ "${JOIF_AUTO_SYNC_FIREWALL:-1}" == "1" && -f "${SCRIPT_DIR}/firewall.sh" ]]; then
        bash "${SCRIPT_DIR}/firewall.sh" sync-ipset || {
            log_warn "Licencia actualizada en DB, pero fallo la sincronizacion inmediata con ipset."
            return 1
        }
    fi
    return 0
}

# Devuelve la linea exacta de la DB para una IP/CIDR normalizada
license_find() {
    local norm_cidr
    norm_cidr="$(joif_normalize_cidr "${1:-}")" || return 1
    [[ -f "$JOIF_LICENSES_DB" ]] || return 1

    local line ip
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        ip="${line%%|*}"
        if [[ "$ip" == "$norm_cidr" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done < "$JOIF_LICENSES_DB"
    return 1
}

# Lista filas crudas (sin comentarios), normalizando filas v1 (6 cols) a v2 (7 cols con geo)
license_list_raw() {
    license_init_db
    local line ip alias created expires status updated geo
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        geo=""
        IFS='|' read -r ip alias created expires status updated geo <<< "$line"
        [[ -z "$ip" ]] && continue
        [[ -z "$geo" ]] && geo="-"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$ip" "$alias" "$created" "$expires" "$status" "$updated" "$geo"
    done < "$JOIF_LICENSES_DB"
}

# Devuelve solo IPs/CIDR activas y NO vencidas (fuente de verdad para ipset)
license_active_ips() {
    license_init_db
    local now
    now="$(joif_now_epoch)"

    local ip alias created expires status updated geo
    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        if [[ "$status" == "activa" ]]; then
            if [[ "$expires" == "0" ]] || (( expires > now )); then
                printf '%s\n' "$ip"
            fi
        fi
    done < <(license_list_raw)
}

# Alta de nueva licencia: license_add <ip_o_cidr> <alias> <dias: 0=permanente> [--upsert]
license_add() {
    local raw_ip="${1:-}"
    local raw_alias="${2:-}"
    local days="${3:-0}"
    local mode="${4:-}"

    local cidr alias now expires geo
    if ! cidr="$(joif_normalize_cidr "$raw_ip")"; then
        log_error "IP o subred CIDR invalida: '${raw_ip}'. Ejemplos: 203.0.113.10 o 203.0.113.0/24"
        return 1
    fi

    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
        log_error "Dias de vigencia invalido: '${days}' (usa 0 para permanente o un entero positivo)."
        return 1
    fi

    alias="$(joif_sanitize_alias "$raw_alias")"
    now="$(joif_now_epoch)"
    if (( 10#$days == 0 )); then
        expires=0
    else
        expires=$(( now + (10#$days * 86400) ))
    fi

    geo="$(joif_lookup_ip_geo "$cidr" || printf '%s\n' "-")"
    [[ -z "$geo" ]] && geo="-"

    license_init_db

    if license_find "$cidr" >/dev/null 2>&1; then
        if [[ "$mode" == "--upsert" ]]; then
            local tmp line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo
            tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line//$'\r'/}"
                if [[ -z "$line" || "$line" == \#* ]]; then
                    printf '%s\n' "$line" >> "$tmp"
                    continue
                fi
                cur_geo=""
                IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
                if [[ "$cur_ip" == "$cidr" ]]; then
                    [[ "$geo" == "-" && -n "$cur_geo" ]] && geo="$cur_geo"
                    printf '%s|%s|%s|%s|activa|%s|%s\n' "$cidr" "$alias" "$cur_created" "$expires" "$now" "${geo:--}" >> "$tmp"
                else
                    printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
                fi
            done < "$JOIF_LICENSES_DB"
            chmod 640 "$tmp"
            mv -f "$tmp" "$JOIF_LICENSES_DB"
            log_ok "Licencia actualizada: ${cidr} (${alias}) | Origen: ${geo} | Vigencia: $(joif_format_epoch "$expires")"
            _license_sync_hook
            return 0
        fi
        log_error "La IP/CIDR '${cidr}' ya existe. Usa renovar, reactivar o eliminar."
        return 1
    fi

    printf '%s|%s|%s|%s|activa|%s|%s\n' "$cidr" "$alias" "$now" "$expires" "$now" "$geo" >> "$JOIF_LICENSES_DB"
    log_ok "IP autorizada: ${cidr} (${alias}) | Origen: ${geo} | Vigencia: $(joif_format_epoch "$expires")"
    _license_sync_hook
}

# Editar alias de una licencia existente sin alterar vencimiento ni contadores
license_edit_alias() {
    local raw_ip="${1:-}"
    local raw_alias="${2:-}"

    local cidr new_alias
    if ! cidr="$(joif_normalize_cidr "$raw_ip")"; then
        log_error "IP o subred CIDR invalida: '${raw_ip}'."
        return 1
    fi
    new_alias="$(joif_sanitize_alias "$raw_alias")"

    license_init_db
    local now tmp found=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_geo=""
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$new_alias" "$cur_created" "$cur_expires" "$cur_status" "$now" "${cur_geo:--}" >> "$tmp"
        else
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
        fi
    done < "$JOIF_LICENSES_DB"

    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmp"
        log_error "No se encontro la licencia para '${cidr}'."
        return 1
    fi

    chmod 640 "$tmp"
    mv -f "$tmp" "$JOIF_LICENSES_DB"
    log_ok "Alias actualizado para ${cidr}: '${new_alias}'"
}

# Actualiza informacion liviana de origen (Pais/Ciudad/ISP) para una IP o todas las pendientes
license_refresh_geo() {
    local raw_target="${1:-}"
    local target_cidr=""
    if [[ -n "$raw_target" ]]; then
        if ! target_cidr="$(joif_normalize_cidr "$raw_target")"; then
            log_error "IP o subred CIDR invalida: '${raw_target}'."
            return 1
        fi
    fi

    license_init_db
    local now tmp updated_count=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo new_geo
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_geo=""
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
        [[ -z "$cur_geo" ]] && cur_geo="-"

        if [[ -n "$target_cidr" && "$cur_ip" == "$target_cidr" ]] || [[ -z "$target_cidr" && "$cur_geo" == "-" ]]; then
            new_geo="$(joif_lookup_ip_geo "$cur_ip" || printf '%s\n' "-")"
            [[ -n "$new_geo" && "$new_geo" != "-" ]] && cur_geo="$new_geo" && updated_count=$((updated_count + 1))
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$now" "$cur_geo" >> "$tmp"
        else
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "$cur_geo" >> "$tmp"
        fi
    done < "$JOIF_LICENSES_DB"

    chmod 640 "$tmp"
    mv -f "$tmp" "$JOIF_LICENSES_DB"
    log_ok "Informacion de origen (Geo/ISP) actualizada en ${updated_count} IP(s)."
}

# Renovar licencia: suma dias desde max(now, expires_at), o 0 para permanente, y activa
license_renew() {
    local raw_ip="${1:-}"
    local days="${2:-}"

    local cidr
    if ! cidr="$(joif_normalize_cidr "$raw_ip")"; then
        log_error "IP o subred CIDR invalida: '${raw_ip}'."
        return 1
    fi
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
        log_error "Dias de renovacion invalido: '${days}' (usa 0 para permanente o un entero positivo)."
        return 1
    fi

    license_init_db
    local now tmp found=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo new_expires base
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_geo=""
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            if (( 10#$days == 0 )); then
                new_expires=0
            else
                if [[ "$cur_expires" != "0" ]] && (( cur_expires > now )); then
                    base="$cur_expires"
                else
                    base="$now"
                fi
                new_expires=$(( base + (10#$days * 86400) ))
            fi
            printf '%s|%s|%s|%s|activa|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$new_expires" "$now" "${cur_geo:--}" >> "$tmp"
        else
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
        fi
    done < "$JOIF_LICENSES_DB"

    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmp"
        log_error "No se encontro la licencia para '${cidr}'."
        return 1
    fi

    chmod 640 "$tmp"
    mv -f "$tmp" "$JOIF_LICENSES_DB"
    log_ok "Licencia renovada y activada: ${cidr} -> $(joif_format_epoch "$new_expires")"
    _license_sync_hook
}

# Suspender licencia manualmente (bloqueo inmediato en ipset)
license_suspend() {
    local raw_ip="${1:-}"
    local cidr
    if ! cidr="$(joif_normalize_cidr "$raw_ip")"; then
        log_error "IP o subred CIDR invalida: '${raw_ip}'."
        return 1
    fi

    license_init_db
    local now tmp found=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_geo=""
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            printf '%s|%s|%s|%s|suspendida|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$now" "${cur_geo:--}" >> "$tmp"
        else
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
        fi
    done < "$JOIF_LICENSES_DB"

    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmp"
        log_error "No se encontro la licencia para '${cidr}'."
        return 1
    fi

    chmod 640 "$tmp"
    mv -f "$tmp" "$JOIF_LICENSES_DB"
    log_ok "Licencia suspendida: ${cidr}"
    _license_sync_hook
}

# Reactivar licencia suspendida (solo si es permanente o aun no vencio; si vencio retorna codigo 2)
license_reactivate() {
    local raw_ip="${1:-}"
    local cidr
    if ! cidr="$(joif_normalize_cidr "$raw_ip")"; then
        log_error "IP o subred CIDR invalida: '${raw_ip}'."
        return 1
    fi

    license_init_db
    local now tmp found=0 expired_err=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_geo=""
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            if [[ "$cur_expires" != "0" ]] && (( cur_expires <= now )); then
                expired_err=1
                printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
            else
                printf '%s|%s|%s|%s|activa|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$now" "${cur_geo:--}" >> "$tmp"
            fi
        else
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
        fi
    done < "$JOIF_LICENSES_DB"

    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmp"
        log_error "No se encontro la licencia para '${cidr}'."
        return 1
    fi
    if [[ "$expired_err" -eq 1 ]]; then
        rm -f "$tmp"
        log_error "La licencia '${cidr}' esta vencida. Usa renovar para asignar nuevos dias o hacerla permanente."
        return 2
    fi

    chmod 640 "$tmp"
    mv -f "$tmp" "$JOIF_LICENSES_DB"
    log_ok "Licencia reactivada: ${cidr}"
    _license_sync_hook
}

# Eliminar licencia permanentemente de la DB y de ipset
license_remove() {
    local raw_ip="${1:-}"
    local cidr
    if ! cidr="$(joif_normalize_cidr "$raw_ip")"; then
        log_error "IP o subred CIDR invalida: '${raw_ip}'."
        return 1
    fi

    license_init_db
    local tmp found=0 line cur_ip
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_ip="${line%%|*}"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$JOIF_LICENSES_DB"

    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmp"
        log_error "No se encontro la licencia para '${cidr}'."
        return 1
    fi

    chmod 640 "$tmp"
    mv -f "$tmp" "$JOIF_LICENSES_DB"
    log_ok "Licencia eliminada: ${cidr}"
    _license_sync_hook
}

# Desactiva automaticamente licencias vencidas y sincroniza ipset
license_expire_overdue() {
    local force_sync="${1:-}"
    license_init_db

    local now tmp changed=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_geo=""
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated cur_geo <<< "$line"
        if [[ "$cur_status" == "activa" && "$cur_expires" != "0" ]] && (( cur_expires <= now )); then
            changed=$((changed + 1))
            log_warn "Licencia vencida desactivada automaticamente: ${cur_ip} (${cur_alias})"
            printf '%s|%s|%s|%s|suspendida|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$now" "${cur_geo:--}" >> "$tmp"
        else
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$cur_status" "$cur_updated" "${cur_geo:--}" >> "$tmp"
        fi
    done < "$JOIF_LICENSES_DB"

    if (( changed > 0 )); then
        chmod 640 "$tmp"
        mv -f "$tmp" "$JOIF_LICENSES_DB"
        log_ok "Se desactivaron ${changed} licencia(s) vencida(s)."
        _license_sync_hook
    else
        rm -f "$tmp"
        if [[ "$force_sync" == "--force-sync" ]]; then
            _license_sync_hook
        fi
    fi

    printf '%s\n' "$changed"
}

# Imprime tabla formateada con origen (Geo/ISP) y trafico del kernel (ipset counters)
license_print_table() {
    license_init_db
    local now
    now="$(joif_now_epoch)"

    # Cargar contadores de trafico de ipset si esta disponible (0 KB en disco)
    declare -A _ip_bytes=()
    if command -v "$JOIF_IPSET_BIN" >/dev/null 2>&1; then
        local m_ip m_pkts m_bytes norm_m
        while read -r m_ip _ m_pkts _ m_bytes; do
            [[ -z "$m_ip" || ! "${m_bytes:-}" =~ ^[0-9]+$ ]] && continue
            norm_m="$m_ip"
            [[ "$norm_m" != */* ]] && norm_m="${norm_m}/32"
            _ip_bytes["$norm_m"]="$m_bytes"
        done < <("$JOIF_IPSET_BIN" list "$JOIF_IPSET_NAME" 2>/dev/null | awk '/^Members:/{f=1;next} f && $2=="packets" && $4=="bytes"{print $1, $2, $3, $4, $5}' || true)
    fi

    printf '%b%-19s %-18s %-24s %-10s %-16s %-11s%b\n' \
        "$C_BOLD" "IP / CIDR" "ALIAS" "ORIGEN (GEO/ISP)" "TRAFICO" "ESTADO" "RESTANTE" "$C_RESET"
    printf '%s\n' "--------------------------------------------------------------------------------------------------------"

    local count=0 ip alias created expires status updated geo
    local rem_str state_str traf_str rem_sec rem_days rem_hours
    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        count=$((count + 1))
        [[ -z "$geo" ]] && geo="-"

        if [[ -n "${_ip_bytes[$ip]:-}" ]]; then
            traf_str="$(joif_human_bytes "${_ip_bytes[$ip]}")"
        else
            traf_str="-"
        fi

        if [[ "$expires" == "0" ]]; then
            rem_str="permanente"
            state_str="$status"
        elif (( expires <= now )); then
            rem_str="VENCIDA"
            state_str="${status}(venc)"
        else
            rem_sec=$(( expires - now ))
            rem_days=$(( rem_sec / 86400 ))
            rem_hours=$(( (rem_sec % 86400) / 3600 ))
            if (( rem_days >= 1 )); then
                rem_str="${rem_days}d ${rem_hours}h"
            elif (( rem_hours >= 1 )); then
                rem_str="${rem_hours}h"
            else
                rem_str="<1h"
            fi
            state_str="$status"
        fi

        local color="$C_GREEN"
        [[ "$status" != "activa" ]] && color="$C_YELLOW"
        [[ "$rem_str" == "VENCIDA" ]] && color="$C_RED"

        printf '%-19s %-18s %-24s %-10s %b%-16s%b %-11s\n' \
            "$ip" "${alias:0:17}" "${geo:0:23}" "$traf_str" "$color" "$state_str" "$C_RESET" "$rem_str"
    done < <(license_list_raw)

    if (( count == 0 )); then
        printf '(Sin IPs autorizadas todavia. Usa la opcion 1 para autorizar tu VPS de Brasil/USA.)\n'
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-list}"
    shift || true
    case "$cmd" in
        add)         joif_with_lock license_add "${1:-}" "${2:-}" "${3:-0}" "${4:-}" ;;
        edit-alias)  joif_with_lock license_edit_alias "${1:-}" "${2:-}" ;;
        refresh-geo) joif_with_lock license_refresh_geo "${1:-}" ;;
        renew)       joif_with_lock license_renew "${1:-}" "${2:-}" ;;
        suspend)     joif_with_lock license_suspend "${1:-}" ;;
        reactivate)  joif_with_lock license_reactivate "${1:-}" ;;
        remove)      joif_with_lock license_remove "${1:-}" ;;
        expire)      joif_with_lock license_expire_overdue "${1:-}" ;;
        active)      license_active_ips ;;
        list)        license_print_table ;;
        raw)         license_list_raw ;;
        *)
            echo "Uso: $0 {add|edit-alias|refresh-geo|renew|suspend|reactivate|remove|expire|active|list|raw} [args]" >&2
            exit 1
            ;;
    esac
fi
