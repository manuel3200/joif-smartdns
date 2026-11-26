#!/usr/bin/env bash
# menu.sh — Panel CLI visual e interactivo de joif-smartdns (enlazado en /usr/local/bin/smartdns)
set -euo pipefail

# Resolver ruta real del script aunque se invoque via symlink (/usr/local/bin/smartdns)
SOURCE_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE_PATH" ]]; do
    DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
    SOURCE_PATH="$(readlink "$SOURCE_PATH")"
    [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="${DIR}/${SOURCE_PATH}"
done
APP_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"

# shellcheck source=core/common.sh
source "${APP_DIR}/core/common.sh"
# shellcheck source=core/ui.sh
source "${APP_DIR}/core/ui.sh"
# shellcheck source=core/domains.sh
source "${APP_DIR}/core/domains.sh"
# shellcheck source=core/dnsmasq_gen.sh
source "${APP_DIR}/core/dnsmasq_gen.sh"
# shellcheck source=core/nginx_gen.sh
source "${APP_DIR}/core/nginx_gen.sh"
# shellcheck source=core/licenses.sh
source "${APP_DIR}/core/licenses.sh"
# shellcheck source=core/diagnostics.sh
source "${APP_DIR}/core/diagnostics.sh"
# shellcheck source=core/metrics.sh
source "${APP_DIR}/core/metrics.sh"
# shellcheck source=core/maintenance.sh
source "${APP_DIR}/core/maintenance.sh"
# shellcheck source=core/updater.sh
source "${APP_DIR}/core/updater.sh"
# shellcheck source=core/monitor.sh
source "${APP_DIR}/core/monitor.sh"

reload_services_safe() {
    joif_load_config
    log_info "Regenerando y validando configuraciones de dnsmasq y nginx..."
    local ok=0
    if ! dnsmasq_apply "${JOIF_PUBLIC_IP:-}"; then
        log_error "Error al aplicar dnsmasq (se mantuvo la configuracion anterior valida)."
        ok=1
    fi
    if ! nginx_apply; then
        log_error "Error al aplicar nginx (se mantuvo la configuracion anterior valida)."
        ok=1
    fi
    return "$ok"
}

_svc_is_on() {
    local svc="$1"
    if command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1 && "$JOIF_SYSTEMCTL_BIN" is-active --quiet "$svc" 2>/dev/null; then
        printf '1'
    else
        printf '0'
    fi
}

# Cuenta licencias activas y proximas a vencer (<= 3 dias)
_count_licenses_summary() {
    license_init_db
    local now active=0 soon=0
    now="$(joif_now_epoch)"
    local soon_limit=$(( now + 259200 ))
    local ip alias created expires status updated geo
    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        if [[ "$status" == "activa" ]]; then
            if [[ "$expires" == "0" ]] || (( expires > now )); then
                active=$((active + 1))
                if [[ "$expires" != "0" ]] && (( expires <= soon_limit )); then
                    soon=$((soon + 1))
                fi
            fi
        fi
    done < <(license_list_raw)
    printf '%s|%s\n' "$active" "$soon"
}

# Resumen compacto de categorias para mostrar junto a la opcion 2
_categories_short_summary() {
    local active_c=0 total_c=0 b_st="OFF" g_st="OFF" s_st="OFF"
    local slug label status count path
    while IFS='|' read -r slug label status count path; do
        [[ -z "$slug" ]] && continue
        total_c=$((total_c + 1))
        [[ "$status" == "activa" ]] && active_c=$((active_c + 1))
        case "$slug" in
            01-fintech-bancos) [[ "$status" == "activa" ]] && b_st="ON" ;;
            02-gobierno-ar)    [[ "$status" == "activa" ]] && g_st="ON" ;;
            03-streaming-ar)   [[ "$status" == "activa" ]] && s_st="ON" ;;
        esac
    done < <(domains_list_categories)
    printf '%s|%s|Bancos %s | Gob %s | Stream %s\n' "$active_c" "$total_c" "$b_st" "$g_st" "$s_st"
}

draw_header() {
    joif_load_config

    local lic_sum ip_active ip_soon cat_sum cat_on cat_tot cat_short dom_count
    lic_sum="$(_count_licenses_summary)"
    IFS='|' read -r ip_active ip_soon <<< "$lic_sum"
    cat_sum="$(_categories_short_summary)"
    IFS='|' read -r cat_on cat_tot cat_short <<< "$cat_sum"
    dom_count="$(domains_collect_active 2>/dev/null | wc -l | tr -d '[:space:]')"

    local d_on n_on f_on t_on
    d_on="$(_svc_is_on dnsmasq)"
    n_on="$(_svc_is_on nginx)"
    f_on="$(_svc_is_on joif-smartdns-firewall.service)"
    t_on="$(_svc_is_on joif-smartdns-expire.timer)"

    local disk_ram d_used d_tot d_pct d_avail r_used r_tot
    disk_ram="$(metrics_disk_ram)"
    IFS='|' read -r d_used d_tot d_pct d_avail r_used r_tot <<< "$disk_ram"

    local net_str="N/D"
    local sample_sec="${JOIF_HEADER_SAMPLE_SEC:-0.3}"
    if [[ "$sample_sec" != "0" ]]; then
        local net_info iface rx_m tx_m tot_m
        net_info="$(metrics_net_mbps "$sample_sec" 2>/dev/null || printf 'eth0|0.00|0.00|0.00')"
        IFS='|' read -r iface rx_m tx_m tot_m <<< "$net_info"
        net_str="${tot_m} Mbps (${iface})"
    fi

    clear 2>/dev/null || true
    ui_box_top
    ui_box_title "JOIF SMART DNS v${JOIF_VERSION} — Smart DNS + SNI Proxy Argentino"
    ui_box_sep
    ui_box_row "$(printf 'DNS Primario : %-18s Red   : %s' "${JOIF_PUBLIC_IP:-No configurado}" "$net_str")"
    ui_box_row "$(printf 'Disco (/)    : %-18s RAM   : %s / %s MB' "${d_avail} libre (${d_pct})" "$r_used" "$r_tot")"
    ui_box_row "$(printf 'Resumen      : %s IP(s) (%s x vencer) | %s dom. AR | %s/%s cat. ON' "$ip_active" "$ip_soon" "$dom_count" "$cat_on" "$cat_tot")"
    ui_box_bottom
    printf '  Servicios: %s  %s  %s  %s\n' \
        "$(ui_badge "DNS" "$d_on")" \
        "$(ui_badge "SNI" "$n_on")" \
        "$(ui_badge "FW" "$f_on")" \
        "$(ui_badge "AutoExp" "$t_on")"
    printf '\n'
}

# Imprime lista numerada compacta (<=74 cols, ideal movil/SSH) y llena IP_ITEMS[]
_render_numbered_licenses() {
    IP_ITEMS=()
    license_init_db
    local now
    now="$(joif_now_epoch)"

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

    local idx=0 ip alias created expires status updated geo
    local rem_str badge color traf_str rem_sec rem_days rem_hours
    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        idx=$((idx + 1))
        IP_ITEMS+=("$ip")
        [[ -z "$geo" ]] && geo="-"

        if [[ -n "${_ip_bytes[$ip]:-}" ]]; then
            traf_str="$(joif_human_bytes "${_ip_bytes[$ip]}")"
        else
            traf_str="0 B"
        fi

        if [[ "$expires" == "0" ]]; then
            rem_str="permanente"
        elif (( expires <= now )); then
            rem_str="VENCIDA"
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
        fi

        if [[ "$rem_str" == "VENCIDA" ]]; then
            color="$C_RED"; badge="[VENCIDA]"
        elif [[ "$status" == "activa" ]]; then
            color="$C_GREEN"; badge="[ACTIVA]"
        else
            color="$C_YELLOW"; badge="[PAUSADA]"
        fi

        printf '  %b[%d]%b %-19s %-18s %b%-10s%b %s\n' \
            "$C_CYAN" "$idx" "$C_RESET" "$ip" "${alias:0:17}" "$color" "$badge" "$C_RESET" "$rem_str"
        printf '      %bOrigen:%b %-33s | %bTrafico:%b %s\n' \
            "$C_DIM" "$C_RESET" "${geo:0:32}" "$C_DIM" "$C_RESET" "$traf_str"
    done < <(license_list_raw)

    if (( idx == 0 )); then
        printf '  (Sin IPs autorizadas. Usa la opcion 1 para autorizar tu VPS de Brasil/USA.)\n'
    fi
}

# Resuelve numero de lista (1..N) o IP/CIDR directa
_pick_ip_target() {
    local prompt_text="$1"
    local sel=""
    read -r -p "$prompt_text" sel || return 1
    [[ -z "$sel" ]] && return 1
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#IP_ITEMS[@]} )); then
        printf '%s\n' "${IP_ITEMS[$((sel - 1))]}"
        return 0
    fi
    printf '%s\n' "$sel"
}

menu_add_ip() {
    printf '\n%b--- Autorizar Nueva IP / Subred (Licencia) ---%b\n' "$C_BOLD" "$C_RESET"
    local ip alias days
    read -r -p "IP o subred CIDR (ej. 144.22.167.150 o 198.51.100.0/24): " ip || return 0
    [[ -z "$ip" ]] && { log_warn "Operacion cancelada."; return 0; }
    read -r -p "Alias / Cliente (ej. Nodo Brasil 01): " alias || return 0
    read -r -p "Dias de vigencia (0 = permanente para nodos JOIF) [0]: " days || return 0
    days="${days:-0}"

    if joif_with_lock license_add "$ip" "$alias" "$days"; then
        joif_load_config
        printf '\n%bSiguiente paso (prueba desde esa VPS):%b\n' "$C_CYAN" "$C_RESET"
        printf '  dig +short @%s mercadopago.com.ar A\n' "${JOIF_PUBLIC_IP:-<IP_VPS_AR>}"
    fi
    ui_pause
}

menu_manage_ips() {
    while true; do
        clear 2>/dev/null || true
        ui_section_header "Clientes y Nodos VPN — Licencias por IP" "licencias-ip"
        _render_numbered_licenses
        printf '\n'
        printf '  1) Autorizar nueva IP / CIDR\n'
        printf '  2) Renovar licencia (sumar dias o pasar a permanente)\n'
        printf '  3) Editar alias / nombre de una IP\n'
        printf '  4) Suspender licencia (bloqueo inmediato)\n'
        printf '  5) Reactivar licencia suspendida\n'
        printf '  6) Eliminar licencia\n'
        printf '  7) Actualizar origen (Geo/ISP) y purgar vencidas\n'
        printf '  0) Volver al menu principal\n\n'

        local opt target days new_alias rc confirm
        read -r -p "Elige una opcion [0-7]: " opt || return 0
        case "$opt" in
            1) menu_add_ip ;;
            2)
                target="$(_pick_ip_target "Numero [1-${#IP_ITEMS[@]}] o IP a renovar: ")" || continue
                read -r -p "Dias a sumar (0 = permanente): " days || continue
                [[ -z "$days" ]] && continue
                joif_with_lock license_renew "$target" "$days" || true
                ui_pause
                ;;
            3)
                target="$(_pick_ip_target "Numero [1-${#IP_ITEMS[@]}] o IP a renombrar: ")" || continue
                read -r -p "Nuevo alias (ej. Nodo Brasil 01): " new_alias || continue
                [[ -z "$new_alias" ]] && continue
                joif_with_lock license_edit_alias "$target" "$new_alias" || true
                ui_pause
                ;;
            4)
                target="$(_pick_ip_target "Numero [1-${#IP_ITEMS[@]}] o IP a suspender: ")" || continue
                joif_with_lock license_suspend "$target" || true
                ui_pause
                ;;
            5)
                target="$(_pick_ip_target "Numero [1-${#IP_ITEMS[@]}] o IP a reactivar: ")" || continue
                rc=0
                joif_with_lock license_reactivate "$target" || rc=$?
                if [[ "$rc" -eq 2 ]]; then
                    read -r -p "Esta vencida. Renovar ahora? Dias (0=permanente, Enter=cancelar): " days || true
                    if [[ -n "$days" ]]; then
                        joif_with_lock license_renew "$target" "$days" || true
                    fi
                fi
                ui_pause
                ;;
            6)
                target="$(_pick_ip_target "Numero [1-${#IP_ITEMS[@]}] o IP a eliminar: ")" || continue
                read -r -p "Confirmar eliminacion definitiva de '${target}'? [s/N]: " confirm || continue
                if [[ "$confirm" =~ ^[sSyY]$ ]]; then
                    joif_with_lock license_remove "$target" || true
                fi
                ui_pause
                ;;
            7)
                joif_with_lock license_refresh_geo || true
                bash "${APP_DIR}/core/expire-licenses.sh" || true
                ui_pause
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida."; sleep 1 ;;
        esac
    done
}

menu_manage_domains() {
    while true; do
        clear 2>/dev/null || true
        ui_section_header "Dominios y Categorias Argentinas" "dominios"

        local -a cat_slugs=()
        local idx=0 slug label status count path color badge
        while IFS='|' read -r slug label status count path; do
            [[ -z "$slug" ]] && continue
            idx=$((idx + 1))
            cat_slugs+=("$slug")
            if [[ "$status" == "activa" ]]; then
                color="$C_GREEN"; badge="[ACTIVA]"
            else
                color="$C_YELLOW"; badge="[PAUSADA]"
            fi
            printf '  %b[%d]%b %-33s %b%-9s%b (%s dom.)\n' \
                "$C_CYAN" "$idx" "$C_RESET" "${label:0:32}" "$color" "$badge" "$C_RESET" "$count"
        done < <(domains_list_categories)

        printf '\n'
        printf '  1) Activar / Pausar una categoria (por numero)\n'
        printf '  2) Buscar / Probar un dominio (Por donde sale X?)\n'
        printf '  3) Ver dominios de una categoria\n'
        printf '  4) Agregar dominio personalizado (99-custom.list)\n'
        printf '  5) Quitar dominio personalizado (por numero)\n'
        printf '  6) Regenerar y recargar dnsmasq + nginx (con rollback)\n'
        printf '  0) Volver al menu principal\n\n'

        local opt sel target dom rc add_now
        read -r -p "Elige una opcion [0-6]: " opt || return 0
        case "$opt" in
            1)
                read -r -p "Numero de categoria [1-${#cat_slugs[@]}] a alternar: " sel || continue
                [[ -z "$sel" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#cat_slugs[@]} )); then
                    target="${cat_slugs[$((sel - 1))]}"
                else
                    target="$sel"
                fi
                if domains_toggle_category "$target"; then
                    reload_services_safe || true
                fi
                ui_pause
                ;;
            2)
                read -r -p "Dominio o URL a consultar (ej. api.brubank.com.ar): " dom || continue
                [[ -z "$dom" ]] && continue
                rc=0
                domains_check_live "$dom" || rc=$?
                if [[ "$rc" -eq 2 ]]; then
                    local clean_host
                    clean_host="$(domains_extract_host "$dom" 2>/dev/null || printf '%s' "$dom")"
                    read -r -p "Quieres agregar '${clean_host}' a 99-custom.list ahora? [s/N]: " add_now || true
                    if [[ "$add_now" =~ ^[sSyY]$ ]]; then
                        if domains_custom_add "$clean_host"; then
                            reload_services_safe || true
                        fi
                    fi
                fi
                ui_pause
                ;;
            3)
                read -r -p "Numero de categoria [1-${#cat_slugs[@]}] a ver: " sel || continue
                [[ -z "$sel" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#cat_slugs[@]} )); then
                    target="${cat_slugs[$((sel - 1))]}"
                else
                    target="$sel"
                fi
                local file_show=""
                [[ -f "${JOIF_DOMAINS_DIR}/${target}.list" ]] && file_show="${JOIF_DOMAINS_DIR}/${target}.list"
                [[ -z "$file_show" && -f "${JOIF_DOMAINS_DIR}/${target}.list.disabled" ]] && file_show="${JOIF_DOMAINS_DIR}/${target}.list.disabled"
                if [[ -n "$file_show" ]]; then
                    printf '\n%bDominios en %s:%b\n' "$C_BOLD" "$(basename "$file_show")" "$C_RESET"
                    domains_parse_file "$file_show" | sed 's/^/  - /'
                else
                    log_error "Categoria '${target}' no encontrada."
                fi
                ui_pause
                ;;
            4)
                read -r -p "Dominio a agregar (ej. midominio.com.ar): " dom || continue
                [[ -z "$dom" ]] && continue
                if domains_custom_add "$dom"; then
                    reload_services_safe || true
                fi
                ui_pause
                ;;
            5)
                local custom_f="${JOIF_DOMAINS_DIR}/99-custom.list"
                local -a c_doms=()
                local ci=0 cd
                if [[ -f "$custom_f" ]]; then
                    printf '\n%bDominios en 99-custom.list:%b\n' "$C_BOLD" "$C_RESET"
                    while IFS= read -r cd; do
                        [[ -z "$cd" ]] && continue
                        ci=$((ci + 1))
                        c_doms+=("$cd")
                        printf '  %b[%d]%b %s\n' "$C_CYAN" "$ci" "$C_RESET" "$cd"
                    done < <(domains_parse_file "$custom_f" 2>/dev/null)
                fi
                if (( ci == 0 )); then
                    log_info "No hay dominios personalizados en 99-custom.list."
                    ui_pause
                    continue
                fi
                printf '\n'
                read -r -p "Numero [1-${ci}] o dominio a quitar: " sel || continue
                [[ -z "$sel" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#c_doms[@]} )); then
                    dom="${c_doms[$((sel - 1))]}"
                else
                    dom="$sel"
                fi
                if domains_custom_remove "$dom"; then
                    reload_services_safe || true
                fi
                ui_pause
                ;;
            6)
                reload_services_safe || true
                ui_pause
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida."; sleep 1 ;;
        esac
    done
}

menu_diagnostics_and_logs() {
    while true; do
        clear 2>/dev/null || true
        ui_section_header "Diagnostico, Metricas y Monitores en Vivo" "diagnostico"
        printf '  1) Diagnostico integral en vivo (DNS + Anti-fuga + SNI + Firewall)\n'
        printf '  2) Metricas en vivo: Mbps, disco/RAM, origen por IP y Top dominios\n'
        printf '  3) Ver ultimas 25 conexiones SNI (formateado con alias y trafico)\n'
        printf '  4) Monitor SNI en tiempo real (colores, Ctrl+C vuelve al menu)\n'
        printf '  5) Descubrir dominios de una app (asistente DNS sin ruido Android)\n'
        printf '  6) Ver estado detallado de ipset e iptables\n'
        printf '  0) Volver al menu principal\n\n'

        local opt
        read -r -p "Elige una opcion [0-6]: " opt || return 0
        case "$opt" in
            1) diagnostics_run; ui_pause ;;
            2) metrics_print_report; ui_pause ;;
            3) monitor_sni_recent 25; ui_pause ;;
            4) monitor_sni_live || true; ui_pause ;;
            5) monitor_discover_interactive || true; ui_pause ;;
            6)
                bash "${APP_DIR}/core/firewall.sh" status || true
                ui_pause
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida."; sleep 1 ;;
        esac
    done
}

menu_maintenance() {
    while true; do
        joif_load_config
        local log_st="${JOIF_ACCESS_LOG:-on}"
        clear 2>/dev/null || true
        ui_section_header "Herramientas y Mantenimiento (VPS 10 GB)" "mantenimiento"
        printf '  1) Actualizar joif-smartdns desde GitHub (conserva licencias/listas)\n'
        printf '  2) Limpiar disco (cache APT, journald, rotados — ahorro 10 GB)\n'
        printf '  3) Vaciar logs de acceso de nginx ahora\n'
        printf '  4) Alternar access_log de nginx (actual: %b%s%b)\n' "$C_CYAN" "${log_st^^}" "$C_RESET"
        printf '  5) Crear backup liviano (~3 KB) de licencias, listas y config\n'
        printf '  6) Restaurar backup previo (seleccion por numero)\n'
        printf '  7) Cambiar IP publica configurada de esta VPS AR\n'
        printf '  8) Reaplicar reglas de firewall (ipset + iptables)\n'
        printf '  0) Volver al menu principal\n\n'

        local opt new_ip detected
        read -r -p "Elige una opcion [0-8]: " opt || return 0
        case "$opt" in
            1)
                if joif_with_lock updater_run; then
                    log_info "Recargando panel con la nueva version..."
                    ui_pause
                    exec "$SOURCE_PATH"
                fi
                ui_pause
                ;;
            2)
                maintenance_cleanup_disk || true
                ui_pause
                ;;
            3)
                maintenance_cleanup_disk --clear-logs || true
                ui_pause
                ;;
            4)
                if [[ "$log_st" == "off" ]]; then
                    JOIF_ACCESS_LOG="on"
                else
                    JOIF_ACCESS_LOG="off"
                fi
                joif_save_config
                nginx_apply || true
                log_ok "Access log de nginx cambiado a: ${JOIF_ACCESS_LOG}"
                ui_pause
                ;;
            5)
                maintenance_backup >/dev/null || true
                ui_pause
                ;;
            6)
                local -a bk_files=()
                local bi=0 bpath bsz bsel
                printf '\n%bBackups disponibles:%b\n' "$C_BOLD" "$C_RESET"
                while IFS='|' read -r bpath bsz; do
                    [[ -z "$bpath" ]] && continue
                    bi=$((bi + 1))
                    bk_files+=("$bpath")
                    printf '  %b[%d]%b %s (%s)\n' "$C_CYAN" "$bi" "$C_RESET" "$(basename "$bpath")" "$bsz"
                done < <(maintenance_list_backups)
                if (( bi == 0 )); then
                    log_info "No hay backups guardados todavia. Usa la opcion 5 primero."
                    ui_pause
                    continue
                fi
                printf '\n'
                read -r -p "Numero [1-${bi}] o ruta de backup a restaurar: " bsel || continue
                [[ -z "$bsel" ]] && continue
                local chosen="$bsel"
                if [[ "$bsel" =~ ^[0-9]+$ ]] && (( bsel >= 1 && bsel <= ${#bk_files[@]} )); then
                    chosen="${bk_files[$((bsel - 1))]}"
                fi
                maintenance_restore "$chosen" || true
                ui_pause
                ;;
            7)
                detected="$(joif_detect_public_ip 2>/dev/null || true)"
                printf 'IP publica detectada automaticamente: %s\n' "${detected:-no detectada}"
                read -r -p "Nueva IP publica IPv4 [${detected}]: " new_ip || continue
                new_ip="${new_ip:-$detected}"
                if joif_validate_ipv4 "$new_ip"; then
                    joif_load_config
                    JOIF_PUBLIC_IP="$new_ip"
                    joif_save_config
                    log_ok "IP publica actualizada a ${new_ip}."
                    reload_services_safe || true
                else
                    log_error "IPv4 invalida: '${new_ip}'."
                fi
                ui_pause
                ;;
            8)
                bash "${APP_DIR}/core/firewall.sh" apply || true
                ui_pause
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida."; sleep 1 ;;
        esac
    done
}

menu_help_guide() {
    joif_load_config
    local pub="${JOIF_PUBLIC_IP:-<IP_VPS_AR>}"
    clear 2>/dev/null || true
    ui_section_header "Ayuda Rapida y Guia Oficial en GitHub" ""

    printf '  %bComo funciona JOIF Smart DNS:%b\n' "$C_BOLD" "$C_RESET"
    printf '  - Solo los dominios argentinos (~5%%) salen por esta VPS (%s).\n' "$pub"
    printf '  - El 95%% restante (YouTube, TikTok, gaming) sale directo por Brasil/USA.\n'
    printf '  - Los certificados TLS llegan intactos (sin descifrar trafico).\n\n'

    printf '  %bConectar una VPS VPN de Brasil/USA en 2 pasos:%b\n' "$C_BOLD" "$C_RESET"
    printf '  1) Aqui (VPS AR): autoriza su IP en Opcion 1 (Licencias IP).\n'
    printf '  2) En tu VPS Brasil/USA: apunta DNS (o DNAT puerto 53) a %s.\n\n' "$pub"

    printf '  %bEnlaces directos a la documentacion oficial:%b\n' "$C_BOLD" "$C_RESET"
    printf '  %s Guia completa : %b%s%b\n' "$UI_ARROW" "$C_CYAN" "$JOIF_DOCS_URL" "$C_RESET"
    printf '  %s Licencias IP  : %s#licencias-ip\n' "$UI_ARROW" "$JOIF_DOCS_URL"
    printf '  %s Dominios AR   : %s#dominios\n' "$UI_ARROW" "$JOIF_DOCS_URL"
    printf '  %s Diagnostico   : %s#diagnostico\n' "$UI_ARROW" "$JOIF_DOCS_URL"
    printf '  %s Limitaciones  : %s#limitaciones\n' "$UI_ARROW" "$JOIF_DOCS_URL"
    printf '  %s Repositorio   : %s\n' "$UI_ARROW" "${JOIF_REPO_URL%.git}"
    ui_pause
}

menu_uninstall() {
    printf '\n%b--- Desinstalar joif-smartdns ---%b\n' "$C_RED" "$C_RESET"
    printf 'Esta accion eliminara dnsmasq/nginx de joif-smartdns, restaurara systemd-resolved\n'
    printf 'y limpiara el firewall SIN tocar SSH (puerto 22).\n\n'
    local confirm
    read -r -p "Escribe DESINSTALAR para confirmar: " confirm || return 0
    if [[ "$confirm" == "DESINSTALAR" ]]; then
        exec bash "${APP_DIR}/uninstall.sh" --yes
    else
        log_info "Desinstalacion cancelada."
        ui_pause
    fi
}

interactive_loop() {
    joif_require_root
    while true; do
        draw_header

        local lic_sum ip_active ip_soon cat_sum cat_on cat_tot cat_short
        lic_sum="$(_count_licenses_summary)"
        IFS='|' read -r ip_active ip_soon <<< "$lic_sum"
        cat_sum="$(_categories_short_summary)"
        IFS='|' read -r cat_on cat_tot cat_short <<< "$cat_sum"

        printf '  %b1)%b Clientes / Nodos VPN (Licencias IP)   %b[%s activas]%b\n' \
            "$C_CYAN" "$C_RESET" "$C_DIM" "$ip_active" "$C_RESET"
        printf '  %b2)%b Dominios y Categorias Argentinas      %b[%s]%b\n' \
            "$C_CYAN" "$C_RESET" "$C_DIM" "$cat_short" "$C_RESET"
        printf '  %b3)%b Diagnostico, Metricas y Logs en Vivo\n' "$C_CYAN" "$C_RESET"
        printf '  %b4)%b Herramientas y Mantenimiento          %b[update / 10GB / backup]%b\n' \
            "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
        printf '  %b5)%b Ayuda Rapida y Guia Oficial en GitHub\n' "$C_CYAN" "$C_RESET"
        printf '  %b6)%b Desinstalar joif-smartdns\n' "$C_RED" "$C_RESET"
        printf '  %b0)%b Salir\n\n' "$C_DIM" "$C_RESET"
        printf '  %bGuia:%b %s\n\n' "$C_DIM" "$C_RESET" "$JOIF_DOCS_URL"

        local choice
        read -r -p "Elige una opcion [0-6]: " choice || exit 0
        case "$choice" in
            1) menu_manage_ips ;;
            2) menu_manage_domains ;;
            3) menu_diagnostics_and_logs ;;
            4) menu_maintenance ;;
            5) menu_help_guide ;;
            6) menu_uninstall ;;
            0) exit 0 ;;
            *) log_warn "Opcion invalida."; sleep 1 ;;
        esac
    done
}

cli_usage() {
    cat <<EOF
Uso: smartdns [comando]

Sin argumentos abre el panel interactivo (v${JOIF_VERSION}).
Guia oficial: ${JOIF_DOCS_URL}

Comandos CLI disponibles:
  smartdns status                              Ejecuta diagnostico completo en vivo
  smartdns metrics                             Muestra Mbps en vivo, disco/RAM, origen/trafico por IP y top dominios
  smartdns monitor                             Monitor SNI en tiempo real (formateado con alias y colores)
  smartdns discover [ip] [segundos]            Asistente DNS para descubrir dominios nuevos de una app
  smartdns reload                              Regenera y valida dnsmasq + nginx con rollback
  smartdns sync-licenses                       Purga licencias vencidas y sincroniza ipset
  smartdns update [--no-lists]                 Actualiza joif-smartdns desde GitHub conservando licencias y config
  smartdns cleanup [--clear-logs]              Libera cache APT, journald y logs rotados (ideal para VPS 10 GB)
  smartdns backup [archivo.tar.gz]             Crea respaldo liviano (~3 KB) de config, licencias y listas
  smartdns restore <archivo.tar.gz>            Restaura un respaldo previo y recarga servicios
  smartdns logs <on|off>                       Activa o desactiva access_log de nginx (ahorro maximo de disco)
  smartdns ip list                             Lista todas las IPs autorizadas con origen Geo/ISP y trafico
  smartdns ip add <ip/cidr> <alias> [dias]     Autoriza nueva IP (dias=0 permanente)
  smartdns ip edit-alias <ip/cidr> <alias>     Cambia el alias de una IP autorizada
  smartdns ip refresh-geo [ip/cidr]            Actualiza Pais/Ciudad/ISP de una IP o todas las pendientes
  smartdns ip renew <ip/cidr> <dias>           Renueva licencia (dias=0 permanente)
  smartdns ip suspend <ip/cidr>                Suspende licencia inmediatamente
  smartdns ip reactivate <ip/cidr>             Reactiva licencia vigente
  smartdns ip remove <ip/cidr>                 Elimina licencia
  smartdns domains list                        Lista categorias de dominios
  smartdns domains check <dominio|url>         Consulta por donde sale un dominio y prueba DNS/SNI local
  smartdns domains enable <categoria>          Activa categoria y recarga servicios
  smartdns domains disable <categoria>         Desactiva categoria y recarga servicios
  smartdns domains add <dominio>               Agrega dominio a 99-custom.list y recarga
  smartdns domains remove <dominio>            Quita dominio de 99-custom.list y recarga
  smartdns uninstall [--yes]                   Desinstalacion limpia restaurando systemd-resolved
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        interactive_loop
        exit 0
    fi

    local cmd="$1"
    shift || true

    case "$cmd" in
        -h|--help|help)
            cli_usage
            ;;
        status|diag|diagnostics)
            joif_require_root
            diagnostics_run
            ;;
        metrics)
            joif_require_root
            metrics_print_report
            ;;
        monitor)
            joif_require_root
            monitor_sni_live
            ;;
        discover)
            joif_require_root
            monitor_discover_interactive "${1:-}" "${2:-}"
            ;;
        reload)
            joif_require_root
            reload_services_safe
            ;;
        sync-licenses)
            joif_require_root
            bash "${APP_DIR}/core/expire-licenses.sh"
            ;;
        update)
            joif_require_root
            joif_with_lock updater_run "$@"
            ;;
        cleanup)
            joif_require_root
            maintenance_cleanup_disk "${1:-}"
            ;;
        backup)
            joif_require_root
            maintenance_backup "${1:-}"
            ;;
        restore)
            joif_require_root
            maintenance_restore "${1:-}"
            ;;
        logs)
            joif_require_root
            local mode="${1:-}"
            if [[ "$mode" != "on" && "$mode" != "off" ]]; then
                log_error "Uso: smartdns logs <on|off>"
                exit 1
            fi
            joif_load_config
            JOIF_ACCESS_LOG="$mode"
            joif_save_config
            nginx_apply
            log_ok "Access log de nginx configurado en: ${mode}"
            ;;
        ip)
            joif_require_root
            local sub="${1:-list}"
            shift || true
            case "$sub" in
                list)        license_print_table ;;
                add)         joif_with_lock license_add "${1:-}" "${2:-Sin alias}" "${3:-0}" ;;
                edit-alias)  joif_with_lock license_edit_alias "${1:-}" "${2:-}" ;;
                refresh-geo) joif_with_lock license_refresh_geo "${1:-}" ;;
                renew)       joif_with_lock license_renew "${1:-}" "${2:-}" ;;
                suspend)     joif_with_lock license_suspend "${1:-}" ;;
                reactivate)  joif_with_lock license_reactivate "${1:-}" ;;
                remove)      joif_with_lock license_remove "${1:-}" ;;
                *)           cli_usage; exit 1 ;;
            esac
            ;;
        domains)
            joif_require_root
            local sub="${1:-list}"
            shift || true
            case "$sub" in
                list)    domains_list_categories ;;
                check)   domains_check_live "${1:-}" || true ;;
                enable)  domains_enable_category "${1:-}" && reload_services_safe ;;
                disable) domains_disable_category "${1:-}" && reload_services_safe ;;
                add)     domains_custom_add "${1:-}" && reload_services_safe ;;
                remove)  domains_custom_remove "${1:-}" && reload_services_safe ;;
                *)       cli_usage; exit 1 ;;
            esac
            ;;
        uninstall)
            joif_require_root
            exec bash "${APP_DIR}/uninstall.sh" "$@"
            ;;
        *)
            log_error "Comando desconocido: '${cmd}'"
            cli_usage
            exit 1
            ;;
    esac
}

main "$@"
