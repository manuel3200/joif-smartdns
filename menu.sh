#!/usr/bin/env bash
# menu.sh — Panel CLI administrativo de joif-smartdns (enlazado en /usr/local/bin/smartdns)
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

pause_prompt() {
    printf '\n'
    read -r -p "Presiona Enter para continuar..." _
}

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

draw_header() {
    joif_load_config
    local ip_count dom_count d_state n_state
    ip_count="$(license_active_ips 2>/dev/null | wc -l | tr -d '[:space:]')"
    dom_count="$(domains_collect_active 2>/dev/null | wc -l | tr -d '[:space:]')"

    d_state="off"
    n_state="off"
    if command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        "$JOIF_SYSTEMCTL_BIN" is-active --quiet dnsmasq 2>/dev/null && d_state="ON"
        "$JOIF_SYSTEMCTL_BIN" is-active --quiet nginx 2>/dev/null && n_state="ON"
    fi

    clear 2>/dev/null || true
    printf '%b==================================================================%b\n' "$C_CYAN" "$C_RESET"
    printf '%b  JOIF SMART DNS — Servidor Smart DNS + SNI Proxy AR (v%s)%b\n' "$C_BOLD" "$JOIF_VERSION" "$C_RESET"
    printf '%b==================================================================%b\n' "$C_CYAN" "$C_RESET"
    printf '  DNS Primario (VPS AR) : %b%s%b\n' "$C_GREEN" "${JOIF_PUBLIC_IP:-No configurado}" "$C_RESET"
    printf '  IPs con licencia      : %b%s activas%b   |   Dominios AR: %b%s%b\n' \
        "$C_CYAN" "$ip_count" "$C_RESET" "$C_CYAN" "$dom_count" "$C_RESET"
    printf '  Servicios             : dnsmasq=[%s]  nginx=[%s]\n' "$d_state" "$n_state"
    printf '%b------------------------------------------------------------------%b\n\n' "$C_CYAN" "$C_RESET"
}

menu_add_ip() {
    printf '\n%b--- Autorizar Nueva IP / Subred (Licencia) ---%b\n' "$C_BOLD" "$C_RESET"
    local ip alias days
    read -r -p "IP o subred CIDR (ej. 203.0.113.50 o 203.0.113.0/24): " ip
    [[ -z "$ip" ]] && { log_warn "Operacion cancelada."; return 0; }
    read -r -p "Alias / Cliente (ej. Nodo Brasil 01): " alias
    read -r -p "Dias de vigencia (0 = permanente para nodos JOIF) [0]: " days
    days="${days:-0}"

    joif_with_lock license_add "$ip" "$alias" "$days" || true
    pause_prompt
}

menu_manage_ips() {
    while true; do
        printf '\n%b--- Gestion de IPs Autorizadas (Licencias) ---%b\n\n' "$C_BOLD" "$C_RESET"
        license_print_table
        printf '\n'
        printf '  1) Autorizar nueva IP / CIDR\n'
        printf '  2) Renovar licencia (sumar dias o pasar a permanente)\n'
        printf '  3) Suspender licencia (bloqueo inmediato)\n'
        printf '  4) Reactivar licencia suspendida\n'
        printf '  5) Eliminar licencia\n'
        printf '  6) Ejecutar purga de IPs vencidas y sincronizar ipset\n'
        printf '  0) Volver al menu principal\n\n'
        local opt ip days rc
        read -r -p "Selecciona una opcion: " opt
        case "$opt" in
            1) menu_add_ip ;;
            2)
                read -r -p "IP o CIDR a renovar: " ip
                [[ -z "$ip" ]] && continue
                read -r -p "Dias a agregar (0 = permanente): " days
                [[ -z "$days" ]] && continue
                joif_with_lock license_renew "$ip" "$days" || true
                pause_prompt
                ;;
            3)
                read -r -p "IP o CIDR a suspender: " ip
                [[ -z "$ip" ]] && continue
                joif_with_lock license_suspend "$ip" || true
                pause_prompt
                ;;
            4)
                read -r -p "IP o CIDR a reactivar: " ip
                [[ -z "$ip" ]] && continue
                rc=0
                joif_with_lock license_reactivate "$ip" || rc=$?
                if [[ "$rc" -eq 2 ]]; then
                    read -r -p "Deseas renovarla ahora? Ingresa dias (0 = permanente, Enter = cancelar): " days
                    if [[ -n "$days" ]]; then
                        joif_with_lock license_renew "$ip" "$days" || true
                    fi
                fi
                pause_prompt
                ;;
            5)
                read -r -p "IP o CIDR a eliminar definitivamente: " ip
                [[ -z "$ip" ]] && continue
                local confirm
                read -r -p "Confirmar eliminacion de '${ip}'? [s/N]: " confirm
                if [[ "$confirm" =~ ^[sSyY]$ ]]; then
                    joif_with_lock license_remove "$ip" || true
                fi
                pause_prompt
                ;;
            6)
                bash "${APP_DIR}/core/expire-licenses.sh" || true
                pause_prompt
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida." ;;
        esac
    done
}

menu_manage_domains() {
    while true; do
        printf '\n%b--- Gestion de Listas de Dominios Argentinos ---%b\n\n' "$C_BOLD" "$C_RESET"
        printf '%b%-4s %-22s %-34s %-13s %s%b\n' \
            "$C_BOLD" "#" "CATEGORIA" "DESCRIPCION" "ESTADO" "DOMINIOS" "$C_RESET"
        printf '%s\n' "-------------------------------------------------------------------------------------"

        local -a cat_slugs=()
        local idx=0 slug label status count path color
        while IFS='|' read -r slug label status count path; do
            [[ -z "$slug" ]] && continue
            idx=$((idx + 1))
            cat_slugs+=("$slug")
            color="$C_GREEN"
            [[ "$status" != "activa" ]] && color="$C_YELLOW"
            printf '%-4s %-22s %-34s %b%-13s%b %s\n' \
                "$idx" "$slug" "${label:0:33}" "$color" "$status" "$C_RESET" "$count"
        done < <(domains_list_categories)

        printf '\n'
        printf '  1) Activar / Desactivar una categoria (por numero o nombre)\n'
        printf '  2) Ver dominios de una categoria\n'
        printf '  3) Agregar dominio personalizado (99-custom.list)\n'
        printf '  4) Quitar dominio personalizado (99-custom.list)\n'
        printf '  5) Regenerar y recargar dnsmasq + nginx (con validacion y rollback)\n'
        printf '  0) Volver al menu principal\n\n'

        local opt sel target dom
        read -r -p "Selecciona una opcion: " opt
        case "$opt" in
            1)
                read -r -p "Numero o nombre de categoria a alternar: " sel
                [[ -z "$sel" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#cat_slugs[@]} )); then
                    target="${cat_slugs[$((sel - 1))]}"
                else
                    target="$sel"
                fi
                if domains_toggle_category "$target"; then
                    reload_services_safe || true
                fi
                pause_prompt
                ;;
            2)
                read -r -p "Numero o nombre de categoria a inspeccionar: " sel
                [[ -z "$sel" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#cat_slugs[@]} )); then
                    target="${cat_slugs[$((sel - 1))]}"
                else
                    target="$sel"
                fi
                local file_show=""
                if [[ -f "${JOIF_DOMAINS_DIR}/${target}.list" ]]; then
                    file_show="${JOIF_DOMAINS_DIR}/${target}.list"
                elif [[ -f "${JOIF_DOMAINS_DIR}/${target}.list.disabled" ]]; then
                    file_show="${JOIF_DOMAINS_DIR}/${target}.list.disabled"
                fi
                if [[ -n "$file_show" ]]; then
                    printf '\n%bDominios en %s:%b\n' "$C_BOLD" "$(basename "$file_show")" "$C_RESET"
                    domains_parse_file "$file_show" | sed 's/^/  - /'
                else
                    log_error "Categoria '${target}' no encontrada."
                fi
                pause_prompt
                ;;
            3)
                read -r -p "Dominio a agregar (ej. midominio.com.ar): " dom
                [[ -z "$dom" ]] && continue
                if domains_custom_add "$dom"; then
                    reload_services_safe || true
                fi
                pause_prompt
                ;;
            4)
                read -r -p "Dominio a eliminar de 99-custom.list: " dom
                [[ -z "$dom" ]] && continue
                if domains_custom_remove "$dom"; then
                    reload_services_safe || true
                fi
                pause_prompt
                ;;
            5)
                reload_services_safe || true
                pause_prompt
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida." ;;
        esac
    done
}

menu_advanced() {
    while true; do
        printf '\n%b--- Configuracion Avanzada ---%b\n' "$C_BOLD" "$C_RESET"
        printf '  1) Actualizar IP publica configurada de esta VPS AR\n'
        printf '  2) Reaplicar reglas de firewall (ipset + iptables)\n'
        printf '  3) Ver ultimas 25 conexiones del SNI Proxy (puerto 443)\n'
        printf '  4) Ver estado detallado de ipset e iptables\n'
        printf '  0) Volver\n\n'

        local opt new_ip detected
        read -r -p "Selecciona una opcion: " opt
        case "$opt" in
            1)
                detected="$(joif_detect_public_ip 2>/dev/null || true)"
                printf 'IP publica detectada automaticamente: %s\n' "${detected:-no detectada}"
                read -r -p "Nueva IP publica IPv4 [${detected}]: " new_ip
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
                pause_prompt
                ;;
            2)
                bash "${APP_DIR}/core/firewall.sh" apply || true
                pause_prompt
                ;;
            3)
                if [[ -f "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log" ]]; then
                    tail -n 25 "${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log"
                else
                    log_info "Aun no hay registros en ${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log."
                fi
                pause_prompt
                ;;
            4)
                bash "${APP_DIR}/core/firewall.sh" status || true
                pause_prompt
                ;;
            0) return 0 ;;
            *) log_warn "Opcion no valida." ;;
        esac
    done
}

menu_uninstall() {
    printf '\n%b--- Desinstalar joif-smartdns ---%b\n' "$C_RED" "$C_RESET"
    printf 'Esta accion eliminara dnsmasq/nginx de joif-smartdns, restaurara systemd-resolved\n'
    printf 'y limpiara el firewall SIN tocar SSH (puerto 22).\n\n'
    local confirm
    read -r -p "Escribe DESINSTALAR para confirmar: " confirm
    if [[ "$confirm" == "DESINSTALAR" ]]; then
        exec bash "${APP_DIR}/uninstall.sh" --yes
    else
        log_info "Desinstalacion cancelada."
        pause_prompt
    fi
}

interactive_loop() {
    joif_require_root
    while true; do
        draw_header
        printf '  1) Autorizar nueva IP (Licencia)\n'
        printf '  2) Listar / Renovar / Suspender / Eliminar IPs autorizadas\n'
        printf '  3) Gestionar listas de dominios argentinos y recargar servicios\n'
        printf '  4) Estado y Diagnostico en vivo (DNS + Anti-fuga + SNI Proxy)\n'
        printf '  5) Configuracion avanzada (IP publica, firewall, logs SNI)\n'
        printf '  6) Desinstalar joif-smartdns\n'
        printf '  0) Salir\n\n'

        local choice
        read -r -p "Elige una opcion [0-6]: " choice
        case "$choice" in
            1) menu_add_ip ;;
            2) menu_manage_ips ;;
            3) menu_manage_domains ;;
            4) diagnostics_run; pause_prompt ;;
            5) menu_advanced ;;
            6) menu_uninstall ;;
            0) exit 0 ;;
            *) log_warn "Opcion invalida."; sleep 1 ;;
        esac
    done
}

cli_usage() {
    cat <<'EOF'
Uso: smartdns [comando]

Sin argumentos abre el panel interactivo.

Comandos CLI disponibles:
  smartdns status                              Ejecuta diagnostico completo en vivo
  smartdns metrics                             Muestra Mbps en vivo, disco/RAM, origen/trafico por IP y top dominios
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
