#!/usr/bin/env bash
# core/licenses.sh — Gestion de licencias por IP/CIDR (alta, renovacion, suspension, expiracion)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"

JOIF_AUTO_SYNC_FIREWALL="${JOIF_AUTO_SYNC_FIREWALL:-1}"

license_init_db() {
    joif_ensure_dirs
    mkdir -p "$(dirname "$JOIF_LICENSES_DB")"
    if [[ ! -f "$JOIF_LICENSES_DB" ]]; then
        cat > "$JOIF_LICENSES_DB" <<'EOF'
# joif-smartdns licenses v1
# ip_cidr|alias|created_at|expires_at|status|updated_at
EOF
        chmod 640 "$JOIF_LICENSES_DB"
    fi
}

_license_sync_hook() {
    if [[ "${JOIF_AUTO_SYNC_FIREWALL:-1}" == "1" && -f "${SCRIPT_DIR}/firewall.sh" ]]; then
        # Ejecutar sync en subshell para evitar dependencias circulares
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

# Lista filas crudas (sin comentarios)
license_list_raw() {
    license_init_db
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s\n' "$line"
    done < "$JOIF_LICENSES_DB"
}

# Devuelve solo IPs/CIDR activas y NO vencidas (fuente de verdad para ipset)
license_active_ips() {
    license_init_db
    local now
    now="$(joif_now_epoch)"

    local line ip alias created expires status updated
    while IFS='|' read -r ip alias created expires status updated; do
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

    local cidr alias now expires
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

    license_init_db

    if license_find "$cidr" >/dev/null 2>&1; then
        if [[ "$mode" == "--upsert" ]]; then
            local tmp line cur_ip cur_alias cur_created cur_expires cur_status cur_updated
            tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line//$'\r'/}"
                if [[ -z "$line" || "$line" == \#* ]]; then
                    printf '%s\n' "$line" >> "$tmp"
                    continue
                fi
                IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated <<< "$line"
                if [[ "$cur_ip" == "$cidr" ]]; then
                    printf '%s|%s|%s|%s|activa|%s\n' "$cidr" "$alias" "$cur_created" "$expires" "$now" >> "$tmp"
                else
                    printf '%s\n' "$line" >> "$tmp"
                fi
            done < "$JOIF_LICENSES_DB"
            chmod 640 "$tmp"
            mv -f "$tmp" "$JOIF_LICENSES_DB"
            log_ok "Licencia actualizada: ${cidr} (${alias}) -> $(joif_format_epoch "$expires")"
            _license_sync_hook
            return 0
        fi
        log_error "La IP/CIDR '${cidr}' ya existe. Usa renovar, reactivar o eliminar."
        return 1
    fi

    printf '%s|%s|%s|%s|activa|%s\n' "$cidr" "$alias" "$now" "$expires" "$now" >> "$JOIF_LICENSES_DB"
    log_ok "IP autorizada: ${cidr} (${alias}) | Vigencia: $(joif_format_epoch "$expires")"
    _license_sync_hook
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
    local now tmp found=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated new_expires base
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated <<< "$line"
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
            printf '%s|%s|%s|%s|activa|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$new_expires" "$now" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
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
    local now tmp found=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated <<< "$line"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            printf '%s|%s|%s|%s|suspendida|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$now" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
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
    local now tmp found=0 expired_err=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated <<< "$line"
        if [[ "$cur_ip" == "$cidr" ]]; then
            found=1
            if [[ "$cur_expires" != "0" ]] && (( cur_expires <= now )); then
                expired_err=1
                printf '%s\n' "$line" >> "$tmp"
            else
                printf '%s|%s|%s|%s|activa|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$now" >> "$tmp"
            fi
        else
            printf '%s\n' "$line" >> "$tmp"
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

    local now tmp changed=0 line cur_ip cur_alias cur_created cur_expires cur_status cur_updated
    now="$(joif_now_epoch)"
    tmp="$(mktemp "$(dirname "$JOIF_LICENSES_DB")/.licenses.XXXXXX")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        IFS='|' read -r cur_ip cur_alias cur_created cur_expires cur_status cur_updated <<< "$line"
        if [[ "$cur_status" == "activa" && "$cur_expires" != "0" ]] && (( cur_expires <= now )); then
            changed=$((changed + 1))
            log_warn "Licencia vencida desactivada automaticamente: ${cur_ip} (${cur_alias})"
            printf '%s|%s|%s|%s|suspendida|%s\n' "$cur_ip" "$cur_alias" "$cur_created" "$cur_expires" "$now" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
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

# Imprime tabla formateada para la consola
license_print_table() {
    license_init_db
    local now
    now="$(joif_now_epoch)"

    printf '%b%-20s %-24s %-22s %-22s %-14s%b\n' \
        "$C_BOLD" "IP / CIDR" "ALIAS / CLIENTE" "ESTADO" "EXPIRACION" "RESTANTE" "$C_RESET"
    printf '%s\n' "----------------------------------------------------------------------------------------------------------"

    local count=0 ip alias created expires status updated
    local exp_str rem_str state_str rem_sec rem_days rem_hours
    while IFS='|' read -r ip alias created expires status updated; do
        [[ -z "$ip" ]] && continue
        count=$((count + 1))
        exp_str="$(joif_format_epoch "$expires")"

        if [[ "$expires" == "0" ]]; then
            rem_str="permanente"
            state_str="$status"
        elif (( expires <= now )); then
            rem_str="VENCIDA"
            state_str="${status} (vencida)"
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
        if [[ "$status" != "activa" ]]; then
            color="$C_YELLOW"
        fi
        if [[ "$rem_str" == "VENCIDA" ]]; then
            color="$C_RED"
        fi

        printf '%-20s %-24s %b%-22s%b %-22s %-14s\n' \
            "$ip" "${alias:0:23}" "$color" "$state_str" "$C_RESET" "$exp_str" "$rem_str"
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
        add)        joif_with_lock license_add "${1:-}" "${2:-}" "${3:-0}" "${4:-}" ;;
        renew)      joif_with_lock license_renew "${1:-}" "${2:-}" ;;
        suspend)    joif_with_lock license_suspend "${1:-}" ;;
        reactivate) joif_with_lock license_reactivate "${1:-}" ;;
        remove)     joif_with_lock license_remove "${1:-}" ;;
        expire)     joif_with_lock license_expire_overdue "${1:-}" ;;
        active)     license_active_ips ;;
        list)       license_print_table ;;
        raw)        license_list_raw ;;
        *)
            echo "Uso: $0 {add|renew|suspend|reactivate|remove|expire|active|list|raw} [args]" >&2
            exit 1
            ;;
    esac
fi
