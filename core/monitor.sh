#!/usr/bin/env bash
# core/monitor.sh — Monitor SNI en vivo formateado y Asistente "Descubrir dominios de una app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/ui.sh
source "${SCRIPT_DIR}/ui.sh"
# shellcheck source=core/domains.sh
source "${SCRIPT_DIR}/domains.sh"
# shellcheck source=core/licenses.sh
source "${SCRIPT_DIR}/licenses.sh"

# Determina si un dominio es ruido de fondo de Android / Google / Meta / OEM / CDNs genericos
monitor_is_noise_domain() {
    local d="${1,,}"
    d="${d%.}"
    local noise
    for noise in \
        google.com googleapis.com gstatic.com googleusercontent.com gvt1.com gvt2.com ggpht.com \
        android.com 1e100.net doubleclick.net googleadservices.com googlesyndication.com \
        google-analytics.com crashlytics.com app-measurement.com firebaseio.com \
        facebook.com fbcdn.net fbsbx.com whatsapp.net whatsapp.com instagram.com cdninstagram.com \
        apple.com icloud.com mzstatic.com microsoft.com windows.com live.com \
        xiaomi.com miui.com transsion-os.com shalltry.com aibotplatform.com oraclevcn.com \
        samsungcloud.com samsung.com heytapdl.com oppo.com \
        cloudfront.net amazonaws.com fastly.net akamaiedge.net edgekey.net edgesuite.net \
        cloudflare.net cloudflare-dns.com dns.google aliyuncs.com aliyuncsslbintl.com \
        cdnhwcohm19.com cdnhwcuim119.com adobeaemcloud.com marketingcloudapis.com
    do
        if [[ "$d" == "$noise" || "$d" == *".${noise}" ]]; then
            return 0
        fi
    done
    return 1
}

# Sugiere el dominio registrable base (respeta ccTLDs compuestos como .com.ar, .gob.ar, .com.br)
monitor_suggest_base_domain() {
    local d
    d="$(joif_normalize_domain "${1:-}")" || return 1

    local IFS='.'
    local -a parts=()
    read -r -a parts <<< "$d"
    local n="${#parts[@]}"
    if (( n <= 2 )); then
        printf '%s\n' "$d"
        return 0
    fi

    local last2="${parts[$((n - 2))]}.${parts[$((n - 1))]}"
    case "$last2" in
        com.ar|gob.ar|gov.ar|org.ar|net.ar|edu.ar|tur.ar|mil.ar|int.ar|\
        com.br|org.br|net.br|gov.br|co.uk|org.uk|ac.uk|\
        com.mx|com.uy|com.cl|com.co|com.pe|com.py|com.bo|com.ec)
            if (( n >= 3 )); then
                printf '%s.%s.%s\n' "${parts[$((n - 3))]}" "${parts[$((n - 2))]}" "${parts[$((n - 1))]}"
                return 0
            fi
            ;;
    esac

    printf '%s.%s\n' "${parts[$((n - 2))]}" "${parts[$((n - 1))]}"
}

# Formatea lineas del log stream de nginx (stdin -> stdout) con alias, estado y bytes legibles (<=74 cols)
monitor_sni_format_stream() {
    local include_local=0
    [[ "${1:-}" == "--include-local" ]] && include_local=1

    # Cargar mapa IP -> Alias desde licenses.db
    declare -A ip_alias=()
    local ip alias created expires status updated geo base_ip
    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        base_ip="${ip%%/*}"
        ip_alias["$base_ip"]="$alias"
    done < <(license_list_raw 2>/dev/null)

    local line src ts_raw time_hms sni allowed sent recv total_b hbytes src_label badge color
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        src="${line%% *}"
        [[ "$include_local" -eq 0 && "$src" == "127.0.0.1" ]] && continue

        # Extraer HH:MM:SS desde [DD/Mon/YYYY:HH:MM:SS +0000]
        ts_raw="$(printf '%s' "$line" | sed -nE 's/^[^[]*\[[^:]+:([0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p')"
        time_hms="${ts_raw:---:--:--}"

        sni="$(printf '%s' "$line" | sed -nE 's/.*sni="([^"]*)".*/\1/p')"
        [[ -z "$sni" ]] && sni="(sin-SNI)"

        allowed="$(printf '%s' "$line" | sed -nE 's/.*allowed=([0-9]+).*/\1/p')"
        sent="$(printf '%s' "$line" | sed -nE 's/.*sent=([0-9]+).*/\1/p')"
        recv="$(printf '%s' "$line" | sed -nE 's/.*recv=([0-9]+).*/\1/p')"
        sent="${sent:-0}"
        recv="${recv:-0}"
        total_b=$(( sent + recv ))
        hbytes="$(joif_human_bytes "$total_b")"

        src_label="${ip_alias[$src]:-$src}"
        if [[ "$allowed" == "1" ]]; then
            color="$C_GREEN"; badge="[OK]"
        else
            color="$C_RED"; badge="[BLK]"
        fi

        # Formato compacto <= 74 cols: HH:MM:SS [OK]  Alias(14)  SNI(30)  Bytes(8)
        printf '%s %b%-5s%b %-14s %-30s %8s\n' \
            "$time_hms" "$color" "$badge" "$C_RESET" "${src_label:0:14}" "${sni:0:30}" "$hbytes"
    done
}

# Muestra ultimas N conexiones SNI formateadas
monitor_sni_recent() {
    local count="${1:-25}"
    local log_file="${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log"
    joif_load_config

    if [[ "${JOIF_ACCESS_LOG:-on}" == "off" ]]; then
        log_warn "El access_log de nginx esta DESACTIVADO. Activalo en Mantenimiento -> Opcion 4 para ver historial."
        return 0
    fi
    if [[ ! -f "$log_file" || ! -s "$log_file" ]]; then
        log_info "Aun no hay conexiones registradas en ${log_file}."
        return 0
    fi

    printf '%b%-8s %-5s %-14s %-30s %8s%b\n' "$C_BOLD" "HORA" "EST" "ORIGEN" "DOMINIO SNI" "TRAFICO" "$C_RESET"
    printf '%s\n' "--------------------------------------------------------------------------"
    tail -n "$count" "$log_file" | monitor_sni_format_stream
}

# Monitor SNI en tiempo real con Ctrl+C seguro (vuelve al menu)
monitor_sni_live() {
    local log_file="${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log"
    joif_load_config

    if [[ "${JOIF_ACCESS_LOG:-on}" == "off" ]]; then
        log_warn "El access_log de nginx esta DESACTIVADO. Activalo en Mantenimiento -> Opcion 4."
        return 1
    fi
    if [[ ! -f "$log_file" ]]; then
        touch "$log_file" 2>/dev/null || {
            log_error "No se encontro ${log_file}."
            return 1
        }
    fi

    printf '%bMonitor SNI en vivo (puerto 443) — Presiona Ctrl+C para volver al menu%b\n\n' "$C_CYAN" "$C_RESET"
    printf '%b%-8s %-5s %-14s %-30s %8s%b\n' "$C_BOLD" "HORA" "EST" "ORIGEN" "DOMINIO SNI" "TRAFICO" "$C_RESET"
    printf '%s\n' "--------------------------------------------------------------------------"

    ui_run_interruptible bash -c '
        source "'"${SCRIPT_DIR}/monitor.sh"'"
        tail -n 10 -F "'"${log_file}"'" 2>/dev/null | monitor_sni_format_stream
    '
}

# Parsea salida de tcpdump puerto 53 (stdin) extrayendo consultas DNS entrantes,
# filtrando ruido (salvo --all) y clasificando: status|base_domain|fqdn
# status: AR | PAUSADA | NUEVO
monitor_parse_tcpdump_dns() {
    local include_all=0
    [[ "${1:-}" == "--all" ]] && include_all=1

    local line qname norm base match rule slug status
    while IFS= read -r line; do
        # Solo consultas DNS entrantes (A?, AAAA?, HTTPS?, TYPE65?) — ignorar respuestas
        [[ "$line" == *" A? "* || "$line" == *" AAAA? "* || "$line" == *" HTTPS? "* || "$line" == *" TYPE65? "* ]] || continue
        qname="$(printf '%s' "$line" | sed -nE 's/.* (A|AAAA|HTTPS|TYPE65)\? ([^ ]+).*/\2/p')"
        [[ -z "$qname" ]] && continue
        norm="$(joif_normalize_domain "$qname" 2>/dev/null)" || continue

        if [[ "$include_all" -eq 0 ]] && monitor_is_noise_domain "$norm"; then
            continue
        fi

        base="$(monitor_suggest_base_domain "$norm" 2>/dev/null || printf '%s' "$norm")"
        if match="$(domains_find_match "$norm" 2>/dev/null)"; then
            IFS='|' read -r rule slug status _ <<< "$match"
            if [[ "$status" == "activa" ]]; then
                printf 'AR|%s|%s\n' "$base" "$norm"
            else
                printf 'PAUSADA|%s|%s\n' "$base" "$norm"
            fi
        else
            printf 'NUEVO|%s|%s\n' "$base" "$norm"
        fi
    done
}

# Agrupa salida de monitor_parse_tcpdump_dns para obtener lista deduplicada de candidatos NUEVOS
# Salida: base_domain|hits|sample_fqdn
monitor_summarize_new_candidates() {
    awk -F'|' '
        $1 == "NUEVO" && $2 != "" {
            c[$2]++;
            if (!($2 in sample)) sample[$2] = $3;
        }
        END {
            for (b in c) {
                printf "%s|%d|%s\n", b, c[b], sample[b];
            }
        }
    ' | sort -t'|' -k2,2nr -k1,1
}

# Asistente guiado para descubrir dominios de una app argentina en vivo y agregarlos por numero
monitor_discover_interactive() {
    local filter_ip="${1:-}"
    local duration="${2:-}"

    if ! command -v tcpdump >/dev/null 2>&1; then
        log_warn "No esta instalado 'tcpdump' (pesa ~1 MB)."
        local inst_ans=""
        read -r -p "Deseas instalar tcpdump ahora? [S/n]: " inst_ans || return 0
        inst_ans="${inst_ans:-S}"
        if [[ "$inst_ans" =~ ^[sSyY]$ ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq tcpdump
        else
            return 0
        fi
    fi

    # Elegir IP a monitorear si no se paso por argumento
    if [[ -z "$filter_ip" ]]; then
        local -a ips=()
        local i=0 ip alias created expires status updated geo
        printf '\n%bElige que nodo/IP monitorear:%b\n' "$C_BOLD" "$C_RESET"
        printf '  %b[0]%b Todas las IPs autorizadas\n' "$C_CYAN" "$C_RESET"
        while IFS='|' read -r ip alias created expires status updated geo; do
            [[ -z "$ip" || "$status" != "activa" ]] && continue
            i=$((i + 1))
            ips+=("${ip%%/*}")
            printf '  %b[%d]%b %-18s (%s)\n' "$C_CYAN" "$i" "$C_RESET" "${ip%%/*}" "$alias"
        done < <(license_list_raw)

        local sel=""
        printf '\n'
        read -r -p "Numero [0-${i}] o IP [0]: " sel || return 0
        sel="${sel:-0}"
        if [[ "$sel" == "0" ]]; then
            filter_ip=""
        elif [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#ips[@]} )); then
            filter_ip="${ips[$((sel - 1))]}"
        else
            filter_ip="${sel%%/*}"
        fi
    fi

    if [[ -z "$duration" ]]; then
        read -r -p "Segundos de captura (ej. 20, 30, 45) [25]: " duration || return 0
        duration="${duration:-25}"
    fi
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=25

    local bpf="port 53"
    [[ -n "$filter_ip" ]] && bpf="host ${filter_ip} and port 53"

    local raw_cap parsed_cap
    raw_cap="$(mktemp)"
    parsed_cap="$(mktemp)"

    printf '\n%b====================================================================%b\n' "$C_CYAN" "$C_RESET"
    printf '  Abre ahora la app en tu celular y realiza la accion a probar.\n'
    printf '  Capturando consultas DNS durante %ss (o Ctrl+C para terminar antes)...\n' "$duration"
    printf '  Filtro: %s (ruido de Android/Google/Meta ocultado automaticamente)\n' "$bpf"
    printf '%b====================================================================%b\n\n' "$C_CYAN" "$C_RESET"

    # Capturar con timeout y Ctrl+C seguro mostrando hallazgos en vivo
    ui_run_interruptible bash -c '
        source "'"${SCRIPT_DIR}/monitor.sh"'"
        timeout "'"${duration}"'" tcpdump -l -n -i any "'"${bpf}"'" 2>/dev/null \
            | monitor_parse_tcpdump_dns \
            | tee "'"${parsed_cap}"'" \
            | awk -F"|" -v g="'"$C_GREEN"'" -v y="'"$C_YELLOW"'" -v c="'"$C_CYAN"'" -v r="'"$C_RESET"'" '\''
                {
                    key=$1"|"$3;
                    if (seen[key]++) next;
                    if ($1 == "AR")      printf "  %s[  AR   ]%s %-34s (base: %s)\n", g, r, $3, $2;
                    else if ($1 == "PAUSADA") printf "  %s[PAUSADA]%s %-34s (base: %s)\n", y, r, $3, $2;
                    else                 printf "  %s[ NUEVO ]%s %-34s (sugerido: %s)\n", c, r, $3, $2;
                    fflush();
                }
            '\''
    '

    # Presentar resumen numerado de dominios NUEVOS para agregar al instante
    local -a cand_bases=()
    local ci=0 b hits sample
    printf '\n%b--- Dominios NUEVOS sugeridos (fuera de listas AR) ---%b\n' "$C_BOLD" "$C_RESET"
    while IFS='|' read -r b hits sample; do
        [[ -z "$b" ]] && continue
        ci=$((ci + 1))
        cand_bases+=("$b")
        printf '  %b[%d]%b %-26s (%s req | ej. %s)\n' "$C_CYAN" "$ci" "$C_RESET" "$b" "$hits" "${sample:0:32}"
    done < <(monitor_summarize_new_candidates < "$parsed_cap")

    rm -f "$raw_cap" "$parsed_cap"

    if (( ci == 0 )); then
        log_info "No se detectaron dominios nuevos (todos los consultados ya estaban cubiertos o eran ruido de fondo)."
        return 0
    fi

    printf '\n'
    local picks=""
    read -r -p "Numeros a agregar a 99-custom.list (ej. 1 2) o Enter para salir: " picks || return 0
    [[ -z "$picks" ]] && return 0

    local p added_any=0
    for p in $picks; do
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#cand_bases[@]} )); then
            if domains_custom_add "${cand_bases[$((p - 1))]}"; then
                added_any=1
            fi
        else
            log_warn "Numero ignorado: '${p}'"
        fi
    done

    if [[ "$added_any" -eq 1 ]]; then
        # shellcheck source=core/dnsmasq_gen.sh
        source "${SCRIPT_DIR}/dnsmasq_gen.sh"
        # shellcheck source=core/nginx_gen.sh
        source "${SCRIPT_DIR}/nginx_gen.sh"
        joif_load_config
        dnsmasq_apply "${JOIF_PUBLIC_IP:-}" || true
        nginx_apply || true
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-live}"
    shift || true
    case "$cmd" in
        live)     monitor_sni_live ;;
        recent)   monitor_sni_recent "${1:-25}" ;;
        discover) monitor_discover_interactive "${1:-}" "${2:-}" ;;
        *)
            echo "Uso: $0 {live|recent [N]|discover [ip] [segundos]}" >&2
            exit 1
            ;;
    esac
fi
